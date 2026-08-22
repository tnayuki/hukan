import Darwin
import Foundation

/// Hukan's footprint — the app process *plus every descendant it spawned*: the `claude` sessions,
/// whatever those run, and the terminals' shells with what runs in them. The AppKit shell alone
/// is nearly idle, and the heavy in-process work (libgit2, FSEvents, transcript rendering) aside,
/// the load that matters lives in those children — so the figure that answers "am I burying the
/// machine running all this?" is the whole process tree, not just our own pid. It sits next to
/// the account-wide Claude usage because it is the same kind of number: global to the app, not
/// tied to any one worktree.
///
/// Each figure also splits four ways, so the tooltip can say where the load actually sits: our
/// own pid (Hukan), the engines themselves (Claude Code), what the engines spawned (a build, a
/// test run, a `gh` call — the agent's tools), and the terminals (a shell hukan opened and
/// whatever is running in it). Told apart by ancestry within the tree, not by name: a process is
/// what its branch off the root is, so an engine's grandchild is the engine's and a `make` typed
/// into a terminal is the terminal's. Root plus every branch is the whole tree, so the split is
/// exhaustive. The three that are not Hukan carry a process count, since "how many" is the other
/// half of "how much" once the number is a sum.
///
/// Sampling is `sysctl(KERN_PROC_ALL)` to walk the process table for our descendants, then
/// `proc_pid_rusage` per pid — both work for same-user processes without a `task_for_pid`
/// entitlement (which ad-hoc signing could not carry anyway). CPU is a rate, so it needs two
/// readings: cumulative CPU time per pid is diffed against the previous sample over the elapsed
/// wall time, and summed. That time comes back in mach absolute-time units, *not* nanoseconds —
/// on Apple Silicon a tick is ~41.67ns (timebase 125/3), so it is converted through
/// `mach_timebase_info` before the ratio (treating it as nanoseconds read CPU ~41× low, which
/// rounded to a flat 0%). The total is Activity-Monitor-style — one busy core is 100%, so a
/// parallel build across the tree can read well over 100%. State lives on the instance, so each
/// window samples independently.
struct SystemUsageSampler {
  /// Who a process in the tree belongs to.
  enum Kind: CaseIterable {
    /// The root pid: Hukan itself, the AppKit shell.
    case hukan
    /// A `claude` engine — a direct child of the root that a session is running.
    case engine
    /// Anything below an engine: the tools it runs.
    case spawned
    /// A direct child of the root that is not an engine — a terminal's shell — and everything
    /// under it.
    case terminal
  }

  /// One share of the tree.
  struct Bucket: Equatable {
    /// Summed across the share; exceeds 100% on a multi-core machine (Activity Monitor's scale).
    var cpuPercent = 0.0
    /// Summed phys-footprint — the same "Memory" figure Activity Monitor reports.
    var memoryBytes: UInt64 = 0
    var processes = 0
  }

  struct Snapshot {
    let buckets: [Kind: Bucket]
    subscript(kind: Kind) -> Bucket { buckets[kind] ?? Bucket() }
    /// The whole tree.
    var cpuPercent: Double { buckets.values.reduce(0) { $0 + $1.cpuPercent } }
    var memoryBytes: UInt64 { buckets.values.reduce(0) { $0 + $1.memoryBytes } }
  }

  // Cumulative CPU (mach ticks) per pid at the last sample, and when that sample was taken
  // (monotonic ns).
  private var lastCPU: [pid_t: UInt64] = [:]
  private var lastSampleTime: UInt64?

  /// mach absolute-time units to nanoseconds — `numer/denom` from the timebase. 1 on Intel, 125/3
  /// on Apple Silicon. Cached: the timebase never changes for the life of the process.
  private static let ticksToNanos: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom)
  }()

  /// Take a reading. `engines` is the pids of the sessions' running engines, which is what tells
  /// an engine's branch of the tree from a terminal's. The first call has no baseline, so every
  /// `cpuPercent` is 0; memory is always real. Cheap enough to run on the main thread on a timer
  /// (one process-table copy plus a handful of per-pid syscalls for our own subtree).
  mutating func sample(engines: Set<pid_t>) -> Snapshot {
    let now = DispatchTime.now().uptimeNanoseconds
    let root = getpid()
    let kinds = Self.classify(parents: Self.processTree(root: root), root: root, engines: engines)

    var currentCPU: [pid_t: UInt64] = [:]
    var buckets: [Kind: Bucket] = [:]
    for (pid, kind) in kinds {
      guard let usage = Self.rusage(pid) else { continue }
      currentCPU[pid] = usage.cpuTicks
      buckets[kind, default: Bucket()].memoryBytes += usage.footprintBytes
      buckets[kind, default: Bucket()].processes += 1
    }

    if let last = lastSampleTime, now > last {
      let wallDelta = Double(now - last)
      for (pid, cpu) in currentCPU {
        // Only pids seen last tick contribute: a freshly-spawned process is recorded now and
        // starts counting next round, so an agent starting up does not dump its whole prior CPU
        // total into a single tick as a spike. A pid can be reused after a process exits, so also
        // guard against a lower reading subtracting.
        guard let previous = lastCPU[pid], cpu >= previous, let kind = kinds[pid] else { continue }
        // Ticks → nanoseconds, then a fraction of the wall interval, as a percentage.
        buckets[kind, default: Bucket()].cpuPercent +=
          Double(cpu - previous) * Self.ticksToNanos / wallDelta * 100
      }
    }

    lastCPU = currentCPU
    lastSampleTime = now
    return Snapshot(buckets: buckets)
  }

  /// Which share each process of the tree belongs to, from the tree's parent links: the root is
  /// Hukan, and everything else is what its branch off the root is — the branch's own pid being
  /// an engine makes the branch the engine's, and any other branch is a terminal's.
  static func classify(parents: [pid_t: pid_t], root: pid_t, engines: Set<pid_t>)
    -> [pid_t: Kind]
  {
    var kinds: [pid_t: Kind] = [:]
    for pid in parents.keys {
      guard pid != root else {
        kinds[pid] = .hukan
        continue
      }
      var branch = pid
      while let parent = parents[branch], parent != root { branch = parent }
      if engines.contains(branch) {
        kinds[pid] = pid == branch ? .engine : .spawned
      } else {
        kinds[pid] = .terminal
      }
    }
    return kinds
  }

  /// `root` and every process transitively descended from it, each with its parent, from a single
  /// `KERN_PROC_ALL` snapshot of the process table. Returns just the root if the table cannot be
  /// read.
  private static func processTree(root: pid_t) -> [pid_t: pid_t] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var length = 0
    guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
      return [root: 0]
    }

    let capacity = length / MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
    guard sysctl(&mib, u_int(mib.count), &procs, &length, nil, 0) == 0 else { return [root: 0] }
    // sysctl rewrites `length` with the bytes actually filled — the table can shrink between the
    // sizing call and this one — so trust it, not `capacity`, for how many entries are valid.
    let count = length / MemoryLayout<kinfo_proc>.stride

    var childrenByParent: [pid_t: [pid_t]] = [:]
    for index in 0..<count {
      let pid = procs[index].kp_proc.p_pid
      let ppid = procs[index].kp_eproc.e_ppid
      childrenByParent[ppid, default: []].append(pid)
    }

    var tree: [pid_t: pid_t] = [root: 0]
    var frontier: [pid_t] = [root]
    while let pid = frontier.popLast() {
      for child in childrenByParent[pid] ?? [] {
        tree[child] = pid
        frontier.append(child)
      }
    }
    return tree
  }

  /// Cumulative CPU time (user + system, mach absolute-time units) and phys footprint (bytes) for
  /// one process, or nil if it has gone or cannot be read. `rusage_info_v0` already carries both
  /// fields, so there is no reason to ask for a later flavour.
  private static func rusage(_ pid: pid_t) -> (cpuTicks: UInt64, footprintBytes: UInt64)? {
    var info = rusage_info_v0()
    let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
        proc_pid_rusage(pid, RUSAGE_INFO_V0, rebound)
      }
    }
    guard result == 0 else { return nil }
    return (info.ri_user_time + info.ri_system_time, info.ri_phys_footprint)
  }
}
