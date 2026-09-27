import XCTest
@testable import TranslatorCore

final class DeepSeekSSEParserTests: XCTestCase {
    func testUnicodeByteFragmentsBOMCommentsCRLFAndUsageOnlyChunk() throws {
        let input = "\u{feff}: keep-alive\r\nid: ignored\r\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"你好🌍\"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\r\n\r\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":8,\"prompt_cache_hit_tokens\":4}}\r\n\r\ndata: [DONE]\r\n\r\n"
        var parser = DeepSeekSSEParser()
        var events: [TranslationEvent] = []
        for byte in input.utf8 { events += try parser.append(byte) }
        events += try parser.finish()
        XCTAssertTrue(parser.isComplete)
        XCTAssertEqual(deltas(events), "你好🌍")
        XCTAssertEqual(usages(events), [TokenUsage(inputTokens: 20, outputTokens: 8, cachedTokens: 4)])
    }

    func testMultilineSSEEventLoneCRAndFinalChunkUsage() throws {
        let input = "data: {\"choices\":\rdata: [{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":\"stop\"}],\rdata: \"usage\":{\"prompt_tokens\":12,\"completion_tokens\":1,\"prompt_tokens_details\":{\"cached_tokens\":2}}}\r\rdata: [DONE]"
        var parser = DeepSeekSSEParser()
        var events = try parser.append(Data(input.utf8))
        events += try parser.finish()
        XCTAssertEqual(deltas(events), "Hello")
        XCTAssertEqual(usages(events), [TokenUsage(inputTokens: 12, outputTokens: 1, cachedTokens: 2)])
    }

    func testReasoningContentIsNotDisplayed() throws {
        var parser = DeepSeekSSEParser()
        let events = try parser.append(Data("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hidden\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"Visible\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
        _ = try parser.finish()
        XCTAssertEqual(deltas(events), "Visible")
    }

    func testFinishReasonsAreFailuresRatherThanSuccessfulPartialResults() {
        let reasons: [(String, DeepSeekError)] = [
            ("length", .outputLimit), ("content_filter", .contentFiltered),
            ("insufficient_system_resource", .serviceInterrupted), ("aborted", .serviceInterrupted),
            ("tool_calls", .unexpectedFinish), ("server-secret-value", .unexpectedFinish)
        ]
        for (reason, expected) in reasons {
            var parser = DeepSeekSSEParser()
            XCTAssertThrowsError(try parser.append(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"\(reason)\"}]}\n\n".utf8))) {
                XCTAssertEqual($0 as? DeepSeekError, expected)
                XCTAssertFalse($0.localizedDescription.contains("server-secret-value"))
            }
        }
    }

    func testMissingDoneAndMissingStopBothFail() throws {
        var noDone = DeepSeekSSEParser()
        _ = try noDone.append(Data("data: {\"choices\":[{\"delta\":{\"content\":\"Partial\"},\"finish_reason\":\"stop\"}]}\n\n".utf8))
        XCTAssertThrowsError(try noDone.finish()) { XCTAssertEqual($0 as? DeepSeekError, .incompleteStream) }
        var noStop = DeepSeekSSEParser()
        XCTAssertThrowsError(try noStop.append(Data("data: {\"choices\":[{\"delta\":{\"content\":\"Partial\"}}]}\n\ndata: [DONE]\n\n".utf8))) {
            XCTAssertEqual($0 as? DeepSeekError, .incompleteStream)
        }
    }

    func testEmptyResultIsFailure() {
        var parser = DeepSeekSSEParser()
        XCTAssertThrowsError(try parser.append(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))) {
            XCTAssertEqual($0 as? DeepSeekError, .emptyResponse)
        }
    }

    func testMalformedJSONAndServerErrorsDoNotIncludeResponseContent() {
        for input in [
            "data: server-private-secret\n\n",
            "data: {\"error\":{\"message\":\"server-private-secret\"}}\n\n",
            "event: error\ndata: server-private-secret\n\n"
        ] {
            var parser = DeepSeekSSEParser()
            XCTAssertThrowsError(try parser.append(Data(input.utf8))) {
                XCTAssertFalse($0.localizedDescription.contains("server-private-secret"))
                XCTAssertFalse(String(reflecting: $0).contains("server-private-secret"))
            }
        }
    }

    func testInvalidUTF8AndExcessivelyLargeEventsAreRejected() {
        var utf8 = DeepSeekSSEParser()
        XCTAssertThrowsError(try utf8.append(Data([0xff, 0x0a]))) { XCTAssertEqual($0 as? DeepSeekError, .malformedStream) }
        var large = DeepSeekSSEParser()
        XCTAssertThrowsError(try large.append(Data(repeating: 65, count: 2 * 1_024 * 1_024 + 1))) {
            XCTAssertEqual($0 as? DeepSeekError, .malformedStream)
        }
    }

    private func deltas(_ events: [TranslationEvent]) -> String {
        events.compactMap { if case .delta(let text) = $0 { return text }; return nil }.joined()
    }
    private func usages(_ events: [TranslationEvent]) -> [TokenUsage] {
        events.compactMap { if case .usage(let usage) = $0 { return usage }; return nil }
    }
}
