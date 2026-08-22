import XCTest

@testable import Hukan

/// Parsing an `AskUserQuestion` tool input into value types, and assembling the answer the model
/// reads back. Both are pure `[String: Any]`/tuple transforms.
final class AgentQuestionTests: XCTestCase {
  func testParseQuestionsReadsHeadersAndOptions() {
    let input: [String: Any] = [
      "questions": [
        [
          "header": "Auth", "question": "Which method?",
          "options": [
            ["label": "OAuth", "description": "Redirect flow", "preview": "app → idp → app"],
            ["label": "Token", "description": "Paste a token"],
          ],
        ]
      ]
    ]
    let questions = AgentSession.parseQuestions(input)
    XCTAssertEqual(questions.count, 1)
    XCTAssertEqual(questions[0].header, "Auth")
    XCTAssertEqual(questions[0].question, "Which method?")
    XCTAssertEqual(questions[0].options.map(\.label), ["OAuth", "Token"])
    XCTAssertEqual(questions[0].options.first?.description, "Redirect flow")
    XCTAssertEqual(questions[0].options.first?.preview, "app → idp → app")
    // No preview is an empty one, so the card has nothing to fold rather than a stub to open.
    XCTAssertEqual(questions[0].options.last?.preview, "")
    XCTAssertFalse(questions[0].multiSelect)
  }

  /// What Done sends, and what a composer line answering as "Other" carries with it.
  func testTickedLabelsFollowTheOfferedOrder() {
    let questions = AgentSession.parseQuestions([
      "questions": [
        [
          "multiSelect": true,
          "options": [["label": "Search"], ["label": "Export"], ["label": "Sync"]],
        ]
      ]
    ])
    let question = questions[0]
    XCTAssertEqual(question.labels(ticked: [2, 0]), ["Search", "Sync"])
    XCTAssertEqual(question.labels(ticked: []), [])
    // An index the question never offered cannot reach the answer.
    XCTAssertEqual(question.labels(ticked: [1, 9]), ["Export"])
  }

  func testParseQuestionsReadsMultiSelect() {
    let input: [String: Any] = [
      "questions": [
        ["header": "Features", "question": "Which ones?", "multiSelect": true],
        ["header": "Auth", "question": "Which method?", "multiSelect": false],
      ]
    ]
    let questions = AgentSession.parseQuestions(input)
    XCTAssertEqual(questions.map(\.multiSelect), [true, false])
  }

  func testParseQuestionsDefaultsMissingFields() {
    let questions = AgentSession.parseQuestions(["questions": [[:]]])
    XCTAssertEqual(questions.count, 1)
    XCTAssertEqual(questions[0].header, "")
    XCTAssertEqual(questions[0].question, "")
    XCTAssertTrue(questions[0].options.isEmpty)
    XCTAssertFalse(questions[0].multiSelect)
  }

  func testParseQuestionsEmptyWhenNoQuestionsKey() {
    XCTAssertTrue(AgentSession.parseQuestions([:]).isEmpty)
    XCTAssertTrue(AgentSession.parseQuestions(["questions": "not an array"]).isEmpty)
  }

  func testAnswerMessageLabelsEachAnswer() {
    let message = AgentSession.answerMessage([("Auth", "OAuth"), ("Database", "Postgres")])
    XCTAssertEqual(
      message,
      """
      [User answered Auth]: OAuth
      [User answered Database]: Postgres
      """)
  }

  func testAnswerMessageKeepsSeveralPicksOnOneLine() {
    // A multi-select question is still one question, so its picks share the one prefix.
    let message = AgentSession.answerMessage([("Features", "Search, Export")])
    XCTAssertEqual(message, "[User answered Features]: Search, Export")
  }

  func testAnswerMessageFallsBackWhenHeaderEmpty() {
    // No header — the CLI's generic `AskUserQuestion` stands in, so the prefix stays valid.
    let message = AgentSession.answerMessage([("", "Just the label")])
    XCTAssertEqual(message, "[User answered AskUserQuestion]: Just the label")
  }
}
