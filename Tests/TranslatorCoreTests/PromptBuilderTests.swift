import XCTest
@testable import TranslatorCore

final class PromptBuilderTests: XCTestCase {
    func testSourceContextAndGlossaryAreOnlyUserData() throws {
        let request = TranslationRequest(text: "untrusted-source-instructions", context: "untrusted-context", priorTranslation: "untrusted-prior",
                                         question: "untrusted-question", glossary: [.init(source: "untrusted-term", target: "untrusted-target")])
        let messages = try PromptBuilder.messages(for: request)
        let system = try XCTUnwrap(messages[0]["content"] as? String)
        let user = try XCTUnwrap(messages[1]["content"] as? String)
        for value in [request.text, request.context, request.priorTranslation, request.question, "untrusted-term", "untrusted-target"] {
            XCTAssertFalse(system.contains(value))
            XCTAssertTrue(user.contains(value))
        }
        let data = try XCTUnwrap(user.data(using: .utf8))
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(input["source_text"] as? String, request.text)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
    }

    func testDictionaryIsChineseWithCollocationsAndBilingualExamples() throws {
        let messages = try PromptBuilder.messages(for: .init(text: "bank", mode: .dictionary))
        let system = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(system.contains("中文释义为主"))
        XCTAssertTrue(system.contains("常见搭配"))
        XCTAssertTrue(system.contains("中英双语例句"))
        XCTAssertTrue(system.contains("不罗列全部罕见义项"))
    }

    func testTranslationDirectionStyleAndExplanationAreIndependent() throws {
        let translate = try PromptBuilder.messages(for: .init(text: "你好", direction: .chineseToEnglish, style: .academic))
        let system = try XCTUnwrap(translate[0]["content"] as? String)
        XCTAssertTrue(system.contains("中文译为英文"))
        XCTAssertTrue(system.contains("表达风格：学术"))
        XCTAssertTrue(system.contains("仅输出自然、准确的译文"))
        let explanation = try PromptBuilder.messages(for: .init(text: "A phrase", mode: .explain, priorTranslation: "一个短语", question: "解释语法"))
        XCTAssertTrue((explanation[0]["content"] as? String)?.contains("任务：用简体中文解释") == true)
        XCTAssertTrue((explanation[1]["content"] as? String)?.contains("解释语法") == true)
    }

    func testImageUsesSniffedPNGAndJPEGInUserMessage() throws {
        for (bytes, mime) in [([UInt8](arrayLiteral: 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a), "image/png"),
                              ([UInt8](arrayLiteral: 0xff, 0xd8, 0xff, 0xe0), "image/jpeg")] {
            let data = Data(bytes)
            let messages = try PromptBuilder.messages(for: .init(text: "", mode: .imageExplain, imageData: data))
            let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
            let image = try XCTUnwrap(content[1]["image_url"] as? [String: String])
            XCTAssertEqual(image["url"], "data:\(mime);base64,\(data.base64EncodedString())")
            XCTAssertEqual(image["detail"], "original")
        }
    }

    func testUnsupportedImagesAndEmptyRequestsFailLocally() {
        XCTAssertThrowsError(try PromptBuilder.messages(for: .init(text: " "))) { XCTAssertEqual($0 as? DeepSeekError, .emptyInput) }
        XCTAssertThrowsError(try PromptBuilder.messages(for: .init(text: "Image", imageData: Data("fake.png".utf8)))) {
            XCTAssertEqual($0 as? DeepSeekError, .unsupportedImage)
        }
    }
}
