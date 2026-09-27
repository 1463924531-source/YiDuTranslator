import Foundation

/// Errors deliberately carry no input, API key, response body, or underlying network error.
public enum DeepSeekError: LocalizedError, CustomStringConvertible, Equatable {
    case invalidAPIKey, emptyInput, invalidRequest, unsupportedImage, imageTooLarge, requestTooLarge
    case httpStatus(Int), invalidResponse, malformedStream, incompleteStream, emptyResponse
    case outputLimit, contentFiltered, serviceInterrupted, unexpectedFinish, network, timeout

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "请在设置中填写有效的 DeepSeek API Key。"
        case .emptyInput: return "请先输入文字或选择一张截图。"
        case .invalidRequest: return "无法准备请求，请检查输入后重试。"
        case .unsupportedImage: return "截图格式不支持，请使用 PNG 或 JPEG 图片。"
        case .imageTooLarge: return "图片超过 32 MiB，请缩小截图范围后重试。"
        case .requestTooLarge: return "本次请求过大，请减少文字或缩小截图后重试。"
        case .httpStatus(401): return "DeepSeek 密钥无效或已失效，请在设置中更新。"
        case .httpStatus(402): return "DeepSeek 账户余额不足，请前往官方平台检查余额。"
        case .httpStatus(403): return "DeepSeek 拒绝了本次访问，请检查账户权限。"
        case .httpStatus(413): return "本次请求过大，请减少文字或缩小截图后重试。"
        case .httpStatus(429): return "DeepSeek 请求过于频繁，请稍后重试。"
        case .httpStatus(let status) where status >= 500: return "DeepSeek 服务暂时不可用，请稍后重试。"
        case .httpStatus(let status): return "DeepSeek 请求失败（HTTP \(status)），请检查输入后重试。"
        case .invalidResponse: return "服务返回了无法识别的响应，请重试。"
        case .malformedStream: return "服务响应格式异常，当前结果可能不完整，请重试。"
        case .incompleteStream: return "连接提前结束，当前结果不完整，请重试。"
        case .emptyResponse: return "服务未返回可显示的内容，请重试。"
        case .outputLimit: return "回复达到长度上限，当前结果不完整，请缩短原文后重试。"
        case .contentFiltered: return "服务未能完整处理本次内容，请检查输入。"
        case .serviceInterrupted: return "服务中断了生成，当前结果可能不完整，请重试。"
        case .unexpectedFinish: return "服务意外结束了生成，当前结果可能不完整，请重试。"
        case .network: return "网络连接失败，请检查网络后重试。"
        case .timeout: return "请求超时，请检查网络或稍后重试。"
        }
    }
    public var description: String { errorDescription ?? "翻译失败，请重试。" }
}

func normalizedAPIKey(_ key: String) throws -> String {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096,
          trimmed.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
        throw DeepSeekError.invalidAPIKey
    }
    return trimmed
}

public final class DeepSeekClient {
    public static let model = "deepseek-flash"
    public static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    private let configurationFactory: () -> URLSessionConfiguration

    public init() { configurationFactory = Self.sessionConfiguration }

    init(configurationFactory: @escaping () -> URLSessionConfiguration) {
        self.configurationFactory = configurationFactory
    }

    public func stream(request: TranslationRequest, apiKey: String) -> AsyncThrowingStream<TranslationEvent, Error> {
        AsyncThrowingStream { continuation in
            let configuration = configurationFactory()
            let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
            let worker = Task {
                defer { session.invalidateAndCancel() }
                do {
                    try Task.checkCancellation()
                    let urlRequest = try Self.makeURLRequest(request: request, apiKey: apiKey)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    try Self.validate(response)
                    var parser = DeepSeekSSEParser()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        for event in try parser.append(byte) { continuation.yield(event) }
                        if parser.isComplete { break }
                    }
                    for event in try parser.finish() { continuation.yield(event) }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else if let error = error as? DeepSeekError {
                        continuation.finish(throwing: error)
                    } else if (error as? URLError)?.code == .timedOut {
                        continuation.finish(throwing: DeepSeekError.timeout)
                    } else {
                        continuation.finish(throwing: DeepSeekError.network)
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in
                worker.cancel()
                session.invalidateAndCancel()
            }
        }
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = false
        return configuration
    }

    static func makeURLRequest(request: TranslationRequest, apiKey: String) throws -> URLRequest {
        let key = try normalizedAPIKey(apiKey)
        let payload: [String: Any] = [
            "model": model,
            "messages": try PromptBuilder.messages(for: request),
            "thinking": ["type": "disabled"],
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": 8_192,
            "temperature": 0.3
        ]
        let body: Data
        do { body = try JSONSerialization.data(withJSONObject: payload) }
        catch { throw DeepSeekError.invalidRequest }
        guard body.count <= 48 * 1_024 * 1_024 else { throw DeepSeekError.requestTooLarge }
        var result = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        result.httpMethod = "POST"
        result.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        result.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        result.httpBody = body
        return result
    }

    static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw DeepSeekError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw DeepSeekError.httpStatus(response.statusCode) }
        guard response.mimeType?.lowercased() == "text/event-stream" else { throw DeepSeekError.invalidResponse }
    }
}

/// Do not follow redirects carrying sensitive request contents or credentials.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Byte-based parsing retains SSE blank lines and handles UTF-8 split across network packets.
struct DeepSeekSSEParser {
    private var line = Data()
    private var dataLines: [String] = []
    private var eventSize = 0
    private var eventType = ""
    private var skipLF = false
    private var firstLine = true
    private var sawStop = false
    private var sawText = false
    private(set) var isComplete = false
    private static let maximumEventBytes = 2 * 1_024 * 1_024

    mutating func append(_ byte: UInt8) throws -> [TranslationEvent] {
        if isComplete { return [] }
        if skipLF {
            skipLF = false
            if byte == 0x0a { return [] }
        }
        if byte == 0x0d || byte == 0x0a {
            skipLF = byte == 0x0d
            return try consumeLine()
        }
        guard line.count < Self.maximumEventBytes else { throw DeepSeekError.malformedStream }
        line.append(byte)
        return []
    }

    mutating func append(_ data: Data) throws -> [TranslationEvent] {
        var events: [TranslationEvent] = []
        for byte in data { events.append(contentsOf: try append(byte)) }
        return events
    }

    mutating func finish() throws -> [TranslationEvent] {
        var events: [TranslationEvent] = []
        if !line.isEmpty { events.append(contentsOf: try consumeLine()) }
        if !dataLines.isEmpty { events.append(contentsOf: try consumeEvent()) }
        guard isComplete, sawStop else { throw DeepSeekError.incompleteStream }
        guard sawText else { throw DeepSeekError.emptyResponse }
        return events
    }

    private mutating func consumeLine() throws -> [TranslationEvent] {
        guard var text = String(data: line, encoding: .utf8) else { throw DeepSeekError.malformedStream }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if text.hasPrefix("\u{feff}") { text.removeFirst() }
        }
        if text.isEmpty { return try consumeEvent() }
        if text.hasPrefix(":") { return [] }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "data":
            eventSize += value.utf8.count + 1
            guard eventSize <= Self.maximumEventBytes else { throw DeepSeekError.malformedStream }
            dataLines.append(value)
        case "event": eventType = value
        default: break // SSE id and retry fields do not affect a one-shot request.
        }
        return []
    }

    private mutating func consumeEvent() throws -> [TranslationEvent] {
        let type = eventType
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        eventType = ""
        eventSize = 0
        if type == "error" { throw DeepSeekError.serviceInterrupted }
        guard !payload.isEmpty else { return [] }
        if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            guard sawStop else { throw DeepSeekError.incompleteStream }
            guard sawText else { throw DeepSeekError.emptyResponse }
            isComplete = true
            return []
        }
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: Data(payload.utf8)) }
        catch { throw DeepSeekError.malformedStream }
        guard let object = parsed as? [String: Any] else { throw DeepSeekError.malformedStream }
        if object["error"] != nil { throw DeepSeekError.serviceInterrupted }
        guard object["choices"] is [[String: Any]] || object["usage"] is [String: Any] else {
            throw DeepSeekError.malformedStream
        }
        var events: [TranslationEvent] = []
        for choice in (object["choices"] as? [[String: Any]] ?? []) {
            if let index = choice["index"] as? Int, index != 0 { continue }
            if let delta = choice["delta"] as? [String: Any], let content = delta["content"], !(content is NSNull) {
                guard let text = content as? String else { throw DeepSeekError.malformedStream }
                if !text.isEmpty {
                    guard !sawStop else { throw DeepSeekError.malformedStream }
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sawText = true }
                    events.append(.delta(text))
                }
            }
            if let reason = choice["finish_reason"] as? String {
                switch reason {
                case "stop": sawStop = true
                case "length": throw DeepSeekError.outputLimit
                case "content_filter": throw DeepSeekError.contentFiltered
                case "insufficient_system_resource", "aborted": throw DeepSeekError.serviceInterrupted
                default: throw DeepSeekError.unexpectedFinish
                }
            }
        }
        if let usage = object["usage"] as? [String: Any],
           let input = usage["prompt_tokens"] as? Int, let output = usage["completion_tokens"] as? Int {
            let details = usage["prompt_tokens_details"] as? [String: Any]
            let cached = (usage["prompt_cache_hit_tokens"] as? Int) ?? (details?["cached_tokens"] as? Int) ?? 0
            guard input >= 0, output >= 0, cached >= 0 else { throw DeepSeekError.malformedStream }
            events.append(.usage(TokenUsage(inputTokens: input, outputTokens: output, cachedTokens: min(input, cached))))
        }
        return events
    }
}
