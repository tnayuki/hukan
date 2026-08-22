import AppKit

/// One event of a saved conversation — the unit `Transcript.render` turns into styled text. The
/// engine parses these out of the jsonl and hands them over; turning them into a transcript is the
/// caller's job, so the store never touches rendering (and stays testable without AppKit).
struct HistoryRecord {
  enum Kind {
    case userText(String)
    case assistantText(String)
    case toolUse(name: String, input: [String: Any])
  }
  let kind: Kind
  /// The record's own timestamp, so `render` can place a time separator wherever the
  /// conversation paused — nil when the jsonl line carried none.
  let stamp: Date?
  /// The uuid of the transcript record immediately *before* this one, which is what a fork
  /// truncates at: `--resume-session-at` keeps the anchor and everything above it, so anchoring
  /// a user message on its predecessor reproduces the conversation as it stood the moment
  /// before that message was sent. Nil on the first record (there is nothing to fork from) and
  /// on every kind but `userText`, which is the only block a fork can be started from.
  let forkAnchor: String?
  /// The record's *own* uuid, which is what a rewind names: `--resume-session-at` cuts at the
  /// record before a message, while `rewind_conversation` is told the message itself. Carried
  /// only for `userText`, the one kind either verb can be aimed at.
  let messageUUID: String?

  init(kind: Kind, stamp: Date?, forkAnchor: String? = nil, messageUUID: String? = nil) {
    self.kind = kind
    self.stamp = stamp
    self.forkAnchor = forkAnchor
    self.messageUUID = messageUUID
  }
}

extension Transcript {
  /// Render a saved conversation into the transcript, a time separator wherever it paused.
  /// Mirrors the live path's block choices (thinking and tool results left out), so a restored
  /// session and a running one look the same.
  ///
  /// `previousStamp` is the last stamp of whatever was rendered before this batch — the one
  /// piece of state a record carries across to the next. Threading it through is what makes
  /// rendering in slices exact: `render(all)` and the concatenation of `render(prefix)` and
  /// `render(rest, previousStamp: prefix's last stamp)` are the same text, so a transcript
  /// loaded tail-first ends up byte-identical to one loaded whole, and every offset computed
  /// against a full render (the rail's search hits) stays true once the prefix lands.
  static func render(
    _ records: [HistoryRecord], previousStamp: Date? = nil
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    var previous = previousStamp
    for record in records {
      if let stamp = record.stamp {
        if previous.map({ stamp.timeIntervalSince($0) >= timeGap }) ?? true {
          result.append(timeSeparator(stamp))
        }
        previous = stamp
      }
      switch record.kind {
      case .userText(let body):
        result.append(userMessage(body, forkAnchor: record.forkAnchor))
      case .assistantText(let body):
        result.append(markdown(body))
        result.append(text("\n"))
      case .toolUse(let name, let input):
        result.append(toolUse(name: name, input: input))
      }
    }
    return result
  }
}
