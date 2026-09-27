import Foundation
import ImageIO
import Vision

/// Local OCR only. Image bytes and recognized text are never written to a temporary file.
public enum ImageOCR {
    public static func recognize(data: Data) async throws -> String {
        let cancellation = ExtractionCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try cancellation.check()
                guard !data.isEmpty, data.count <= 40 * 1024 * 1024 else {
                    throw TranslatorError("图片为空或超过 40 MB，请缩小图片后重试。")
                }
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    throw TranslatorError("无法读取图片，请使用 PNG、JPEG 或其他常见图片格式。")
                }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
                let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
                guard width > 0, height > 0, width <= 20_000, height <= 20_000, width * height <= 60_000_000 else {
                    throw TranslatorError("图片尺寸过大或无效，请缩小至 6000 万像素以内后重试。")
                }
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2400,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else {
                    throw TranslatorError("无法读取图片，请使用 PNG、JPEG 或其他常见图片格式。")
                }
                let text = try recognize(image: image, cancellation: cancellation)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TranslatorError("图片中没有识别到文字，请截取更清晰的文字区域。")
                }
                return text
            }.value
        }, onCancel: { cancellation.cancel() })
    }

    static func recognize(image: CGImage, cancellation: ExtractionCancellation) throws -> String {
        try cancellation.check()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.usesLanguageCorrection = true
        let registration = cancellation.register { request.cancel() }
        defer { cancellation.unregister(registration) }
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            try cancellation.check()
            throw TranslatorError("本地文字识别失败，请尝试更清晰的图片。")
        }
        try cancellation.check()
        // Vision returns text observations in its detected reading order. Re-sorting by x/y
        // here would interleave columns and destroy that ordering.
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

/// Shared cancellation bridge for synchronous Apple frameworks and child processes.
final class ExtractionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: () -> Void] = [:]

    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let callbacks = Array(handlers.values)
        lock.unlock()
        for callback in callbacks { callback() }
    }

    func register(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        let shouldCancel = cancelled
        if !shouldCancel { handlers[id] = handler }
        lock.unlock()
        if shouldCancel { handler() }
        return id
    }

    func unregister(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }
}
