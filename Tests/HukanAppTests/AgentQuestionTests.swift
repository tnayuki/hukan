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
            ["label": "OAuth", "description": "Redirect flow"],
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
  }

  func testParseQuestionsDefaultsMissingFields() {
    let questions = AgentSession.parseQuestions(["questions": [[:]]])
    XCTAssertEqual(questions.count, 1)
    XCTAssertEqual(questions[0].header, "")
    XCTAssertEqual(questions[0].question, "")
    XCTAssertTrue(questions[0].options.isEmpty)
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

  func testAnswerMessageFallsBackWhenHeaderEmpty() {
    // No header — the CLI's generic `AskUserQuestion` stands in, so the prefix stays valid.
    let message = AgentSession.answerMessage([("", "Just the label")])
    XCTAssertEqual(message, "[User answered AskUserQuestion]: Just the label")
  }
}
