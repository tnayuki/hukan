import Foundation

/// Where the rail has been, in the order it went there — what Back and Forward walk.
///
/// A place is the session that was showing, or the repository heading when none was named. A
/// session is kept by its own id and not by the worktree it stood in: an agent's `EnterWorktree`
/// moves a session without anyone choosing anything, and going back to it means going back to the
/// conversation wherever it now lives, not to the checkout it left. That is also why the move
/// adds no step — the place has not changed.
///
/// Nothing is ever removed for having gone: a session deleted or a worktree git stopped listing
/// is stepped over when it is reached, so the order of everything around it stays what it was.
/// One window's, and never saved — the places a reader went are this window's facts.
struct SelectionHistory {
  enum Place: Equatable {
    case session(UUID)
    case worktree(UUID)
  }

  /// Enough for a day's back-and-forth; a step past it drops the oldest.
  static let capacity = 100

  private(set) var places: [Place] = []
  private(set) var index = -1

  var current: Place? { places.indices.contains(index) ? places[index] : nil }

  /// The selection landed somewhere. The same place again is no step, and a step taken after
  /// going back drops what was ahead, the way a browser's does.
  mutating func visit(_ place: Place) {
    guard place != current else { return }
    places.removeSubrange((index + 1)...)
    places.append(place)
    if places.count > Self.capacity { places.removeFirst(places.count - Self.capacity) }
    index = places.count - 1
  }

  /// The nearest place in `direction` (-1 back, +1 forward) that still exists.
  func target(_ direction: Int, exists: (Place) -> Bool) -> Int? {
    var i = index + direction
    while places.indices.contains(i) {
      if exists(places[i]), places[i] != current { return i }
      i += direction
    }
    return nil
  }

  mutating func move(to target: Int) {
    guard places.indices.contains(target) else { return }
    index = target
  }
}
