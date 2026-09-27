import XCTest
@testable import TranslatorCore

final class DeepSeekClientTests: XCTestCase {
    func testRequestUsesOfficialStreamingEndpointAndDisabledThinking() throws {
        let request = try DeepSeekClient.makeURLRequest(request: .init(text: "A test."), apiKey: " test-placeholder ")
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-placeholder")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual((body["stream_options"] as? [String: Bool])?["include_usage"], true)
    }

    func testSessionCannotPersistResponsesCookiesOrCredentials() {
        let configuration = DeepSeekClient.sessionConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertGreaterThan(configuration.timeoutIntervalForRequest, 0)
        XCTAssertLessThanOrEqual(configuration.timeoutIntervalForResource, 180)
    }

    func testRejectsEmptyKeyAndHeaderInjectionWithoutLeakingIt() {
        for value in ["", "  ", "secret\r\nX-Fake: value", "secret token", "密钥"] {
            XCTAssertThrowsError(try DeepSeekClient.makeURLRequest(request: .init(text: "private-source"), apiKey: value)) {
                XCTAssertEqual($0 as? DeepSeekError, .invalidAPIKey)
                XCTAssertFalse($0.localizedDescription.contains("private-source"))
                XCTAssertFalse(String(describing: $0).contains("secret"))
            }
        }
    }

    func testHTTPFailureAndWrongContentTypeDoNotExposeURLOrBody() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid/private-secret")!, statusCode: 401,
                                                   httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        XCTAssertThrowsError(try DeepSeekClient.validate(response)) {
            XCTAssertEqual($0 as? DeepSeekError, .httpStatus(401))
            XCTAssertFalse($0.localizedDescription.contains("private-secret"))
        }
        let wrongType = try XCTUnwrap(HTTPURLResponse(url: DeepSeekClient.endpoint, statusCode: 200,
                                                    httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        XCTAssertThrowsError(try DeepSeekClient.validate(wrongType)) {
            XCTAssertEqual($0 as? DeepSeekError, .invalidResponse)
        }
    }

    func testStreamingDeliversContentAndUsageThroughURLSession() async throws {
        ClientURLProtocol.handler = { protocolInstance in
            protocolInstance.sendResponse(status: 200, mime: "text/event-stream")
            protocolInstance.send(Data("data: {\"choices\":[{\"delta\":{\"content\":\"你好\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":3}}\n\ndata: [DONE]\n\n".utf8))
            protocolInstance.complete()
        }
        defer { ClientURLProtocol.handler = nil }
        var text = ""
        var usage: TokenUsage?
        for try await event in makeTestClient().stream(request: .init(text: "Hello"), apiKey: "test-placeholder") {
            switch event {
            case .delta(let value): text += value
            case .usage(let value): usage = value
            }
        }
        XCTAssertEqual(text, "你好")
        XCTAssertEqual(usage, TokenUsage(inputTokens: 10, outputTokens: 3))
    }

    func testCancellingConsumerStopsNetworkRequest() async throws {
        let started = expectation(description: "Request started")
        let stopped = expectation(description: "Request stopped")
        ClientURLProtocol.handler = { protocolInstance in
            protocolInstance.onStop = { stopped.fulfill() }
            protocolInstance.sendResponse(status: 200, mime: "text/event-stream")
            started.fulfill()
        }
        defer { ClientURLProtocol.handler = nil }
        let task = Task {
            do {
                for try await _ in makeTestClient().stream(request: .init(text: "Hello"), apiKey: "test-placeholder") {}
            } catch is CancellationError {
                // Expected cancellation never becomes a network error in the UI.
            } catch {
                XCTFail("Unexpected sanitized error: \(error)")
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        await task.value
    }

    func testNetworkFailureDropsUnderlyingSensitiveDescription() async {
        ClientURLProtocol.handler = { protocolInstance in
            protocolInstance.fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                                          userInfo: [NSLocalizedDescriptionKey: "test-secret-key private-source server-response"]))
        }
        defer { ClientURLProtocol.handler = nil }
        do {
            for try await _ in makeTestClient().stream(request: .init(text: "private-source"), apiKey: "test-secret-key") {}
            XCTFail("Expected network failure")
        } catch {
            XCTAssertEqual(error as? DeepSeekError, .network)
            for sensitive in ["test-secret-key", "private-source", "server-response"] {
                XCTAssertFalse(error.localizedDescription.contains(sensitive))
                XCTAssertFalse(String(reflecting: error).contains(sensitive))
            }
        }
    }

    private func makeTestClient() -> DeepSeekClient {
        DeepSeekClient(configurationFactory: {
            let configuration = DeepSeekClient.sessionConfiguration()
            configuration.protocolClasses = [ClientURLProtocol.self]
            return configuration
        })
    }
}

private final class ClientURLProtocol: URLProtocol {
    static var handler: ((ClientURLProtocol) -> Void)?
    var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() { onStop?(); onStop = nil }
    func sendResponse(status: Int, mime: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    func send(_ data: Data) { client?.urlProtocol(self, didLoad: data) }
    func complete() { client?.urlProtocolDidFinishLoading(self) }
    func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }
}
