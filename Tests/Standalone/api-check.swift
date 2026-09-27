import Foundation

enum CheckFailure: Error { case failed(String) }

@main
struct APIClientChecks {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw CheckFailure.failed(label) }
        checks += 1
    }
    static func expect(_ expected: DeepSeekError, _ label: String, _ operation: () throws -> Void) throws {
        do { try operation(); throw CheckFailure.failed("Missing error: " + label) }
        catch let error as DeepSeekError { try check(error == expected, label) }
    }
    static func client() -> DeepSeekClient {
        DeepSeekClient(configurationFactory: {
            let config = DeepSeekClient.sessionConfiguration()
            config.protocolClasses = [MockProtocol.self]
            return config
        })
    }
    static func collect() async throws -> [TranslationEvent] {
        var events: [TranslationEvent] = []
        for try await event in client().stream(request: .init(text: "private-source"), apiKey: "test-placeholder") { events.append(event) }
        return events
    }
    static func text(_ events: [TranslationEvent]) -> String {
        events.compactMap { if case .delta(let value) = $0 { return value }; return nil }.joined()
    }
    static func usages(_ events: [TranslationEvent]) -> [TokenUsage] {
        events.compactMap { if case .usage(let value) = $0 { return value }; return nil }
    }

    static func main() async throws {
        let request = try DeepSeekClient.makeURLRequest(request: .init(text: "Hello"), apiKey: " test-placeholder ")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        try check(request.url!.absoluteString == "https://api.deepseek.com/chat/completions", "fixed official endpoint")
        try check(body["model"] as? String == "deepseek-flash", "model")
        try check((body["thinking"] as? [String: String])?["type"] == "disabled", "thinking disabled")
        try check(body["stream"] as? Bool == true && (body["stream_options"] as? [String: Bool])?["include_usage"] == true, "stream usage")
        try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-placeholder", "normalized authorization")
        let config = DeepSeekClient.sessionConfiguration()
        try check(config.urlCache == nil && config.httpCookieStorage == nil && config.urlCredentialStorage == nil, "no disk caches or credentials")
        try check(!config.httpShouldSetCookies && config.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData, "no cookies/cache")
        try expect(.invalidAPIKey, "header injection rejected") { _ = try normalizedAPIKey("secret\r\nInjected: value") }
        try expect(.invalidAPIKey, "empty key rejected") { _ = try normalizedAPIKey("  ") }
        try expect(.emptyInput, "empty request rejected") { _ = try PromptBuilder.messages(for: .init(text: "  ")) }

        let messages = try PromptBuilder.messages(for: .init(text: "private-source", mode: .dictionary, context: "private-context", priorTranslation: "private-prior", question: "private-question", glossary: [.init(source: "private-term", target: "private-target")]))
        let system = messages[0]["content"] as! String
        let user = messages[1]["content"] as! String
        try check(!system.contains("private-") && user.contains("private-source") && user.contains("private-term"), "untrusted input separated")
        try check(system.contains("中文释义为主") && system.contains("常见搭配") && system.contains("中英双语例句"), "dictionary product behavior")
        let translation = try PromptBuilder.messages(for: .init(text: "你好", direction: .chineseToEnglish, style: .academic))[0]["content"] as! String
        try check(translation.contains("中文译为英文") && translation.contains("表达风格：学术") && translation.contains("仅输出自然、准确的译文"), "translation preferences")
        for (bytes, mime) in [(Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), "image/png"), (Data([0xff, 0xd8, 0xff, 0xe0]), "image/jpeg")] {
            let imageMessages = try PromptBuilder.messages(for: .init(text: "", mode: .imageExplain, imageData: bytes))
            let blocks = imageMessages[1]["content"] as! [[String: Any]]
            let image = blocks[1]["image_url"] as! [String: String]
            try check(image["url"] == "data:\(mime);base64,\(bytes.base64EncodedString())", "sniffed " + mime)
        }
        try expect(.unsupportedImage, "image spoof rejected") { _ = try PromptBuilder.imageMIMEType(Data("fake.png".utf8)) }

        let full = "\u{feff}: keepalive\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"你好🌍\"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\r\n\r\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":8,\"prompt_cache_hit_tokens\":4}}\r\n\r\ndata: [DONE]\r\n\r\n"
        var parser = DeepSeekSSEParser()
        var events: [TranslationEvent] = []
        for byte in full.utf8 { events += try parser.append(byte) }
        events += try parser.finish()
        try check(text(events) == "你好🌍" && parser.isComplete, "fragmented unicode + BOM + CRLF")
        try check(usages(events) == [.init(inputTokens: 20, outputTokens: 8, cachedTokens: 4)], "usage-only event")
        var multiline = DeepSeekSSEParser()
        let multilineInput = "data: {\"choices\":\rdata: [{\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}],\rdata: \"usage\":{\"prompt_tokens\":10,\"completion_tokens\":2,\"prompt_tokens_details\":{\"cached_tokens\":1}}}\r\rdata: [DONE]"
        var multilineEvents = try multiline.append(Data(multilineInput.utf8))
        multilineEvents += try multiline.finish()
        try check(text(multilineEvents) == "OK" && usages(multilineEvents) == [.init(inputTokens: 10, outputTokens: 2, cachedTokens: 1)], "multiline + CR + terminal without newline + final usage")
        for (reason, error) in [("length", DeepSeekError.outputLimit), ("content_filter", .contentFiltered), ("aborted", .serviceInterrupted), ("insufficient_system_resource", .serviceInterrupted), ("tool_calls", .unexpectedFinish)] {
            var failure = DeepSeekSSEParser()
            try expect(error, "finish reason " + reason) { _ = try failure.append(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"\(reason)\"}]}\n\n".utf8)) }
        }
        var incomplete = DeepSeekSSEParser()
        _ = try incomplete.append(Data("data: {\"choices\":[{\"delta\":{\"content\":\"Partial\"},\"finish_reason\":\"stop\"}]}\n\n".utf8))
        try expect(.incompleteStream, "EOF without DONE") { _ = try incomplete.finish() }
        var missingStop = DeepSeekSSEParser()
        try expect(.incompleteStream, "DONE without stop") { _ = try missingStop.append(Data("data: [DONE]\n\n".utf8)) }
        var empty = DeepSeekSSEParser()
        try expect(.emptyResponse, "empty result") { _ = try empty.append(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)) }
        for input in ["data: server-secret\n\n", "data: {\"error\":{\"message\":\"server-secret\"}}\n\n", "event: error\ndata: server-secret\n\n"] {
            var invalid = DeepSeekSSEParser()
            do { _ = try invalid.append(Data(input.utf8)); throw CheckFailure.failed("missing parser error") }
            catch let error as DeepSeekError { try check(!error.localizedDescription.contains("server-secret") && !String(reflecting: error).contains("server-secret"), "server error sanitized") }
        }

        MockProtocol.handler = { protocolInstance in
            protocolInstance.response(200, "text/event-stream")
            for data in [Data(full.prefix(20).utf8), Data(full.dropFirst(20).utf8)] { protocolInstance.data(data) }
            protocolInstance.complete()
        }
        let integration = try await collect()
        try check(text(integration) == "你好🌍" && usages(integration).count == 1, "actual URLSession stream with fake transport")
        MockProtocol.handler = { protocolInstance in
            protocolInstance.response(401, "application/json")
            protocolInstance.data(Data("server-secret".utf8))
            protocolInstance.complete()
        }
        do { _ = try await collect(); throw CheckFailure.failed("missing HTTP failure") }
        catch let error as DeepSeekError { try check(error == .httpStatus(401) && !error.localizedDescription.contains("server-secret"), "HTTP status privacy") }
        MockProtocol.handler = { protocolInstance in
            protocolInstance.fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "key-secret private-source"]))
        }
        do { _ = try await collect(); throw CheckFailure.failed("missing network failure") }
        catch let error as DeepSeekError { try check(error == .network && !String(reflecting: error).contains("secret"), "network error privacy") }

        var startedContinuation: AsyncStream<Void>.Continuation!
        var stoppedContinuation: AsyncStream<Void>.Continuation!
        let started = AsyncStream<Void> { startedContinuation = $0 }
        let stopped = AsyncStream<Void> { stoppedContinuation = $0 }
        MockProtocol.handler = { protocolInstance in
            protocolInstance.onStop = { stoppedContinuation.yield(()); stoppedContinuation.finish() }
            protocolInstance.response(200, "text/event-stream")
            startedContinuation.yield(())
            startedContinuation.finish()
        }
        let consumer = Task {
            do { _ = try await collect() }
            catch is CancellationError {} // Expected.
            catch { throw error }
        }
        for await _ in started { break }
        consumer.cancel()
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in stopped { return true }; return false }
            group.addTask { try await Task.sleep(nanoseconds: 2_000_000_000); return false }
            let cancelled = try await group.next()!
            group.cancelAll()
            try check(cancelled, "consumer cancellation tears down network")
        }
        try await consumer.value
        MockProtocol.handler = nil
        print("API checks passed: \(checks). No live API requests or keychain reads/writes performed.")
    }
}

private final class MockProtocol: URLProtocol {
    static var handler: ((MockProtocol) -> Void)?
    var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() { onStop?(); onStop = nil }
    func response(_ status: Int, _ mime: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    func data(_ data: Data) { client?.urlProtocol(self, didLoad: data) }
    func complete() { client?.urlProtocolDidFinishLoading(self) }
    func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }
}
