import AppKit
import XCTest

@testable import Hukan

/// The Other row: the third answer, which lives on the card now rather than in the composer
/// below it. What is checked here is the wiring a snapshot cannot see — which keystroke answers,
/// what the answer carries, and that the draft leaves the view for somewhere a rebuild cannot
/// take it.
final class QuestionCardTests: XCTestCase {
  private var window: NSWindow!

  override func setUp() {
    super.setUp()
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
  }

  override func tearDown() {
    window = nil
    super.tearDown()
  }

  /// Return in the field is Done: the ticks as they stood, and then your own words.
  func testReturnAnswersWithTheTicksAndThenTheTypedLine() throws {
    var answered: [String]?
    let card = make(
      question: pending(multiSelect: true, ticked: [0, 2]), onAnswer: { answered = $0 })
    let field = try editableField(of: card)

    field.stringValue = "  Neither — put it on the rail  "
    XCTAssertTrue(commit(field, in: card))
    XCTAssertEqual(answered, ["Search", "Sync", "Neither — put it on the rail"])
  }

  /// A single-select question has nothing ticked, so the line is the whole answer.
  func testReturnOnItsOwnAnswersWithTheLineAlone() throws {
    var answered: [String]?
    let card = make(question: pending(multiSelect: false), onAnswer: { answered = $0 })
    let field = try editableField(of: card)

    field.stringValue = "Both, behind a flag"
    XCTAssertTrue(commit(field, in: card))
    XCTAssertEqual(answered, ["Both, behind a flag"])
  }

  /// Nothing typed and nothing ticked is what Skip says, and Skip is a button: the key does not
  /// skip a question because the field happened to hold the focus.
  func testReturnWithNothingToAnswerWithDoesNothing() throws {
    var answered: [String]?
    let card = make(question: pending(multiSelect: true), onAnswer: { answered = $0 })
    let field = try editableField(of: card)

    field.stringValue = "   "
    XCTAssertTrue(commit(field, in: card))
    XCTAssertNil(answered)
  }

  /// Escape hands the keyboard back, which is how you reach the composer — where a line means
  /// the other thing now.
  func testEscapeLeavesTheRow() throws {
    var escaped = false
    let card = make(question: pending(multiSelect: false), onEscape: { escaped = true })
    let field = try editableField(of: card)

    XCTAssertTrue(
      card.control(
        field, textView: NSTextView(),
        doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    XCTAssertTrue(escaped)
  }

  /// A key that means nothing here is handed back to the field editor, or the row would stop
  /// being a text field at the first arrow.
  func testAKeyTheRowHasNoUseForFallsThrough() throws {
    let card = make(question: pending(multiSelect: false))
    let field = try editableField(of: card)

    XCTAssertFalse(
      card.control(
        field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:))))
  }

  /// Every keystroke is reported so the draft can live in `PendingQuestion` — the card is thrown
  /// away and rebuilt on every state change, and the text must not go with it.
  func testTypingIsReportedForTheDraft() throws {
    var draft: String?
    let card = make(question: pending(multiSelect: false), onOther: { draft = $0 })
    let field = try editableField(of: card)

    type("half a th", into: field, on: card)
    XCTAssertEqual(draft, "half a th")
  }

  /// And a card built from a question carrying a draft shows it, which is the other half: the
  /// rebuild puts the text back where it was.
  func testACardShowsTheDraftItWasBuiltWith() throws {
    var question = pending(multiSelect: false)
    question.other = "typed before the batch landed"
    let field = try editableField(of: make(question: question))
    XCTAssertEqual(field.stringValue, "typed before the batch landed")
  }

  /// The caret is handed back too. `otherFocus` is nil while the row is not being typed in, and
  /// the range the running column reads off it is what the next card is focused with.
  func testTheCaretSurvivesTheCardBeingReplaced() throws {
    var question = pending(multiSelect: false)
    question.other = "abcdef"
    let card = make(question: question)
    XCTAssertNil(card.otherFocus, "not being typed in, so there is no caret to put back")

    card.focusOther()
    XCTAssertEqual(
      card.otherFocus, NSRange(location: 6, length: 0), "a fresh card caret is at the end")

    card.focusOther(selecting: NSRange(location: 2, length: 3))
    XCTAssertEqual(card.otherFocus, NSRange(location: 2, length: 3))
  }

  /// Done sends what the card has, so it comes on for a typed line exactly as it does for a
  /// tick — the button and Return must never disagree about whether there is an answer here.
  func testDoneComesOnForATypedLineWithNothingTicked() throws {
    let card = make(question: pending(multiSelect: true))
    let done = try button(titled: "Done", of: card)
    let field = try editableField(of: card)
    XCTAssertFalse(done.isEnabled, "nothing ticked and nothing typed is what Skip says")

    type("Neither, actually", into: field, on: card)
    XCTAssertTrue(done.isEnabled)

    // Whitespace is not an answer, and the row it would be sent as is not one either.
    type("   ", into: field, on: card)
    XCTAssertFalse(done.isEnabled)
  }

  /// And a card rebuilt mid-answer comes up with the button in the state its draft earns, since
  /// the rebuild is what the draft in `PendingQuestion` exists to survive.
  func testDoneIsOnFromTheStartWhenTheDraftCameBack() throws {
    var question = pending(multiSelect: true)
    question.other = "carried across the rebuild"
    XCTAssertTrue(try button(titled: "Done", of: make(question: question)).isEnabled)
  }

  // MARK: harness

  private func pending(multiSelect: Bool, ticked: Set<Int> = []) -> PendingQuestion {
    let questions = AgentSession.parseQuestions([
      "questions": [
        [
          "header": "Layout", "question": "Where?", "multiSelect": multiSelect,
          "options": [["label": "Search"], ["label": "Export"], ["label": "Sync"]],
        ]
      ]
    ])
    return PendingQuestion(requestID: "r1", questions: questions, ticked: ticked)
  }

  private func make(
    question: PendingQuestion, onAnswer: @escaping ([String]) -> Void = { _ in },
    onOther: @escaping (String) -> Void = { _ in }, onEscape: @escaping () -> Void = {}
  ) -> QuestionCard {
    let card = QuestionCard(
      question: question, onAnswer: onAnswer, onToggleOption: { _ in }, onTogglePreview: { _ in },
      onOther: onOther, onEscape: onEscape)
    card.frame = NSRect(x: 0, y: 0, width: 380, height: 300)
    window.contentView?.addSubview(card)
    window.layoutIfNeeded()
    return card
  }

  /// The Other row, found the way anyone looking at the card would: the one field on it that can
  /// be typed into.
  private func editableField(of card: QuestionCard) throws -> NSTextField {
    func fields(in view: NSView) -> [NSTextField] {
      let own = (view as? NSTextField).map { [$0] } ?? []
      return own + view.subviews.flatMap(fields(in:))
    }
    let editable = fields(in: card).filter(\.isEditable)
    return try XCTUnwrap(editable.first, "the card has no field to type an answer into")
  }

  /// A named button on the card, found the way the field is.
  private func button(titled title: String, of card: QuestionCard) throws -> NSButton {
    func buttons(in view: NSView) -> [NSButton] {
      let own = (view as? NSButton).map { [$0] } ?? []
      return own + view.subviews.flatMap(buttons(in:))
    }
    return try XCTUnwrap(
      buttons(in: card).first { $0.title == title }, "the card has no \(title) button")
  }

  /// A keystroke, as the field editor reports it.
  private func type(_ text: String, into field: NSTextField, on card: QuestionCard) {
    field.stringValue = text
    card.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: field))
  }

  /// Return, as the field editor delivers it.
  private func commit(_ field: NSTextField, in card: QuestionCard) -> Bool {
    card.control(
      field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
  }
}
