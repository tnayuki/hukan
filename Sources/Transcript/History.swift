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
}

extension Transcript {
  /// Render a saved conversation into the transcript, a time separator wherever it paused.
  /// Mirrors the live path's block choices (thinking and tool results left out), so a restored
  /// session and a running one look the same.
  static func render(_ records: [HistoryRecord]) -> NSAttributedString {
    let result = NSMutableAttributedString()
    var previous: Date?
    for record in records {
      if let stamp = record.stamp {
        if previous.map({ stamp.timeIntervalSince($0) >= timeGap }) ?? true {
          result.append(timeSeparator(stamp))
        }
        previous = stamp
      }
      switch record.kind {
      case .userText(let body):
        result.append(userMessage(body))
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
