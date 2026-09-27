import AppKit
import Foundation
import PDFKit

/// Reads the original in place. Conversion and OCR stay in memory, with no retained copy.
public enum DocumentExtractor {
    public static let maximumFileBytes = 80 * 1024 * 1024
    public static let maximumPDFPages = 300
    public static let maximumTextCharacters = 1_000_000

    public static func extract(url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ExtractedDocument {
        let cancellation = ExtractionCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try cancellation.check()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard attributes.isRegularFile == true else {
                    throw TranslatorError("请选择 PDF 或 Word 文件。")
                }
                guard let size = attributes.fileSize, size > 0, size <= maximumFileBytes else {
                    throw TranslatorError("文件为空或超过 80 MB，请拆分文件后导入。")
                }
                progress(0)
                let result: ExtractedDocument
                switch url.pathExtension.lowercased() {
                case "pdf": result = try extractPDF(url, cancellation: cancellation, progress: progress)
                case "docx": result = try extractDOCX(url, cancellation: cancellation, progress: progress)
                case "doc": result = try extractLegacyWord(url, cancellation: cancellation)
                default: throw TranslatorError("暂时支持 PDF、Word（.docx、.doc）文件。")
                }
                try cancellation.check()
                guard !result.segments.isEmpty else {
                    throw TranslatorError("文件中没有可读取的文字。可能是空白文档、受保护文件，或图片文字无法识别。")
                }
                progress(1)
                return result
            }.value
        }, onCancel: { cancellation.cancel() })
    }

    private static func extractPDF(_ url: URL, cancellation: ExtractionCancellation,
                                   progress: @escaping @Sendable (Double) -> Void) throws -> ExtractedDocument {
        guard let document = PDFDocument(url: url) else {
            throw TranslatorError("无法打开 PDF，文件可能已损坏。")
        }
        guard !document.isLocked else { throw TranslatorError("PDF 已加密，请先在阅读软件中解锁并另存副本。") }
        guard document.allowsCopying else { throw TranslatorError("此 PDF 限制了文字复制，请使用允许提取文字的副本。") }
        guard document.pageCount > 0, document.pageCount <= maximumPDFPages else {
            throw TranslatorError("PDF 为空或超过 300 页，请按章节拆分后导入。")
        }
        var result = ExtractedDocument(title: url.lastPathComponent, segments: [], warnings: [
            "PDF 按页提取；多栏、表格、公式和图表可能无法保持正确顺序或完整结构。含有文字层的页面中，图片区域的文字不一定能提取，请对照原文件检查。"
        ])
        var totalCharacters = 0
        var ocrPages: [Int] = []
        var unreadablePages: [Int] = []
        for index in 0..<document.pageCount {
            try cancellation.check()
            try autoreleasepool {
                guard let page = document.page(at: index) else {
                    throw TranslatorError("无法读取 PDF 第 \(index + 1) 页，导入已停止，避免遗漏内容。")
                }
                var text = page.string ?? ""
                // A page number or short watermark does not make a scan a text PDF.
                if text.filter({ $0.isLetter || $0.isNumber }).count < 16 {
                    ocrPages.append(index + 1)
                    let bounds = page.bounds(for: .cropBox)
                    guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                        throw TranslatorError("PDF 第 \(index + 1) 页尺寸无效，无法识别。")
                    }
                    let scale = min(3, 2400 / max(bounds.width, bounds.height))
                    let thumbnail = page.thumbnail(of: NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale)), for: .cropBox)
                    guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        throw TranslatorError("PDF 第 \(index + 1) 页无法转为图片，导入已停止。")
                    }
                    let recognized = try ImageOCR.recognize(image: cgImage, cancellation: cancellation)
                    if !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = recognized }
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    unreadablePages.append(index + 1)
                } else {
                    totalCharacters += text.count
                    try checkTextLimit(totalCharacters)
                    appendSegments(text, page: index + 1, to: &result.segments)
                }
            }
            progress(Double(index + 1) / Double(document.pageCount))
        }
        if !ocrPages.isEmpty {
            result.warnings.append("第 \(pageList(ocrPages)) 页使用了本地 OCR，可能有错字；公式和复杂版面尤其需要核对。")
        }
        if !unreadablePages.isEmpty {
            result.warnings.append("第 \(pageList(unreadablePages)) 页未识别到文字（可能为空白页或纯图表），没有生成对应译文；请在原文件中检查这些页。")
        }
        return result
    }

    private static func extractDOCX(_ url: URL, cancellation: ExtractionCancellation,
                                    progress: @escaping @Sendable (Double) -> Void) throws -> ExtractedDocument {
        let listing = try runProcess("/usr/bin/unzip", arguments: ["-Z", "-1", url.path],
                                     byteLimit: 512 * 1024, cancellation: cancellation)
        guard let namesString = String(data: listing, encoding: .utf8) else {
            throw TranslatorError("Word 文件目录无法读取，请在 WPS 中另存为标准 .docx 后重试。")
        }
        let names = namesString.split(whereSeparator: \.isNewline).map(String.init)
        guard names.count <= 10_000, Set(names).count == names.count,
              names.contains("word/document.xml") else {
            throw TranslatorError("Word 文件结构无效或过于复杂，请在 WPS 中另存为标准 .docx 后重试。")
        }
        let supplements = names.filter {
            $0.range(of: #"^word/(header[0-9]+|footer[0-9]+|footnotes|endnotes)\.xml$"#, options: .regularExpression) != nil
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let parts = ["word/document.xml"] + supplements
        guard parts.count <= 100 else { throw TranslatorError("Word 文件包含过多页眉或附注，请拆分后导入。") }
        var result = ExtractedDocument(title: url.lastPathComponent, segments: [], warnings: [
            "Word 以文字顺序提取，不保留原排版；表格按行读取，自动编号、公式、图片、图表和嵌入对象可能缺失或简化，请核对原文件。"
        ])
        var totalCharacters = 0
        var totalXMLBytes = 0
        for (index, name) in parts.enumerated() {
            try cancellation.check()
            let xml = try runProcess("/usr/bin/unzip", arguments: ["-p", url.path, name],
                                     byteLimit: 24 * 1024 * 1024, cancellation: cancellation)
            totalXMLBytes += xml.count
            guard totalXMLBytes <= 48 * 1024 * 1024 else {
                throw TranslatorError("Word 解压后的文字数据过大，请拆分文件后导入。")
            }
            let reader = WordXMLReader(cancellation: cancellation)
            var text = try reader.read(xml)
            if name != "word/document.xml", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let label: String
                if name.contains("footnotes") { label = "脚注" }
                else if name.contains("endnotes") { label = "尾注" }
                else if name.contains("header") { label = "页眉" }
                else { label = "页脚" }
                text = "【\(label)：\(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent)】\n" + text
            }
            totalCharacters += text.count
            try checkTextLimit(totalCharacters)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appendSegments(text, page: nil, to: &result.segments)
            }
            if reader.hasEmbeddedContent, !result.warnings.contains(where: { $0.contains("检测到") }) {
                result.warnings.append("检测到图片、图表、公式或嵌入内容；其中的文字不一定能提取，必要时使用截图解释。")
            }
            progress(Double(index + 1) / Double(parts.count))
        }
        if !supplements.isEmpty {
            result.warnings.append("页眉、页脚、脚注和尾注附在正文之后；Word 的页码取决于排版，因此不标注原页码。")
        }
        return result
    }

    private static func extractLegacyWord(_ url: URL, cancellation: ExtractionCancellation) throws -> ExtractedDocument {
        let data = try runProcess("/usr/bin/textutil", arguments: ["-convert", "txt", "-stdout", "-encoding", "UTF-8", "-noload", "-nostore", "--", url.path],
                                  byteLimit: 6 * 1024 * 1024, cancellation: cancellation)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TranslatorError("无法读取旧版 Word，请先在 WPS 中另存为 .docx。")
        }
        try checkTextLimit(text.count)
        var segments: [DocumentSegment] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { appendSegments(text, page: nil, to: &segments) }
        return ExtractedDocument(title: url.lastPathComponent, segments: segments, warnings: [
            "旧版 .doc 使用系统转换器提取文字。表格、页眉、脚注、图片和公式可能缺失；建议在 WPS 中另存为 .docx 后导入并核对原文件。"
        ])
    }

    /// Keeps every character and each actual paragraph as its own translation unit.
    static func splitText(_ text: String, maxCharacters: Int = 3000) -> [String] {
        guard !text.isEmpty else { return [] }
        let limit = max(1, maxCharacters)
        var paragraphs: [Substring] = []
        var paragraphStart = text.startIndex
        var boundary: String.Index?
        var lineBreaks = 0
        var hasContent = false
        for index in text.indices {
            let character = text[index]
            if character.isNewline {
                lineBreaks += 1
                if lineBreaks >= 2 { boundary = text.index(after: index) }
            } else if !character.isWhitespace {
                if let end = boundary, hasContent {
                    paragraphs.append(text[paragraphStart..<end])
                    paragraphStart = end
                }
                hasContent = true
                boundary = nil
                lineBreaks = 0
            }
        }
        // Leading/trailing blank lines stay attached to meaningful paragraphs,
        // avoiding empty translation rows while retaining exact source text.
        paragraphs.append(text[paragraphStart...])
        var chunks: [String] = []
        for paragraph in paragraphs {
            var start = paragraph.startIndex
            while start < paragraph.endIndex {
                let hardEnd = paragraph.index(start, offsetBy: limit, limitedBy: paragraph.endIndex) ?? paragraph.endIndex
                var end = hardEnd
                if hardEnd < paragraph.endIndex {
                    let slice = paragraph[start..<hardEnd]
                    if let boundary = slice.lastIndex(where: { $0.isWhitespace }),
                       paragraph.distance(from: start, to: boundary) >= limit / 3 {
                        end = paragraph.index(after: boundary)
                    }
                }
                chunks.append(String(paragraph[start..<end]))
                start = end
            }
        }
        return chunks
    }

    private static func appendSegments(_ text: String, page: Int?, to segments: inout [DocumentSegment]) {
        for part in splitText(text) {
            segments.append(DocumentSegment(ordinal: segments.count + 1, source: part, page: page))
        }
    }

    private static func checkTextLimit(_ count: Int) throws {
        guard count <= maximumTextCharacters else { throw TranslatorError("文件文字超过 100 万字，请按章节拆分后导入。") }
    }

    private static func pageList(_ pages: [Int]) -> String {
        // A bounded page count keeps this warning complete: unreadable pages are never hidden.
        pages.map(String.init).joined(separator: "、")
    }

    /// Runs fixed system utilities without a shell, draining bounded stdout. No user content is logged.
    private static func runProcess(_ executable: String, arguments: [String], byteLimit: Int,
                                   cancellation: ExtractionCancellation) throws -> Data {
        try cancellation.check()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let registration = cancellation.register { if process.isRunning { process.terminate() } }
        defer {
            cancellation.unregister(registration)
            if process.isRunning { process.terminate() }
            try? pipe.fileHandleForReading.close()
        }
        var output = Data()
        while true {
            try cancellation.check()
            let chunk = try pipe.fileHandleForReading.read(upToCount: 32 * 1024) ?? Data()
            if chunk.isEmpty { break }
            guard output.count + chunk.count <= byteLimit else {
                if process.isRunning { process.terminate() }
                throw TranslatorError("文件解压或转换后的内容过大，请拆分后重试。")
            }
            output.append(chunk)
        }
        process.waitUntilExit()
        try cancellation.check()
        guard process.terminationStatus == 0 else {
            throw TranslatorError("Word 读取失败，文件可能已损坏、加密或格式不兼容；请在 WPS 中另存为 .docx 后重试。")
        }
        return output
    }
}

private final class WordXMLReader: NSObject, XMLParserDelegate {
    private let cancellation: ExtractionCancellation
    private var text = ""
    private var collectingText = false
    private var ignoredDepth = 0
    private var parsingError: Error?
    private var characters = 0
    var hasEmbeddedContent = false
    private let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private let strictWordNamespace = "http://purl.oclc.org/ooxml/wordprocessingml/main"

    init(cancellation: ExtractionCancellation) { self.cancellation = cancellation }

    func read(_ data: Data) throws -> String {
        // Word parts never need a DTD. Disallow it even though external resolution is disabled.
        guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw TranslatorError("Word XML 编码无法读取，请在 WPS 中另存为标准 .docx。")
        }
        if decoded.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil {
            throw TranslatorError("Word XML 包含不支持的文档声明，请另存为标准 .docx。")
        }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        let success = parser.parse()
        try cancellation.check()
        if let parsingError { throw parsingError }
        guard success else { throw TranslatorError("Word 文本结构损坏，无法完整提取；请在 WPS 中另存为 .docx。") }
        return text
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard checkpoint(parser) else { return }
        if ignoredDepth > 0 { ignoredDepth += 1; return }
        let word = namespaceURI == wordNamespace || namespaceURI == strictWordNamespace
        if word && ["del", "moveFrom"].contains(elementName) { ignoredDepth = 1; return }
        if word && ["footnote", "endnote"].contains(elementName) {
            let kind = attribute("type", in: attributeDict)
            let id = attribute("id", in: attributeDict)
            if kind == "separator" || kind == "continuationSeparator" || id == "-1" {
                ignoredDepth = 1; return
            }
            append("\n[\(elementName == "footnote" ? "脚注" : "尾注") \(id)] ", parser: parser)
        }
        let math = namespaceURI?.contains("/math") == true
        if (word || math) && elementName == "t" { collectingText = true }
        if word && elementName == "tab" { append("\t", parser: parser) }
        if word && ["br", "cr"].contains(elementName) { append("\n", parser: parser) }
        if word && ["drawing", "pict", "object", "altChunk"].contains(elementName) || math {
            hasEmbeddedContent = true
        }
        if word && ["footnoteReference", "endnoteReference"].contains(elementName) {
            let id = attribute("id", in: attributeDict)
            append("[\(elementName == "footnoteReference" ? "脚注" : "尾注") \(id)]", parser: parser)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if ignoredDepth == 0 && collectingText { append(string, parser: parser) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if ignoredDepth > 0 { ignoredDepth -= 1; return }
        let word = namespaceURI == wordNamespace || namespaceURI == strictWordNamespace
        if elementName == "t" { collectingText = false }
        if word && elementName == "p" { append("\n\n", parser: parser) }
        if word && elementName == "tc" { append("\t", parser: parser) }
        if word && elementName == "tr" { append("\n", parser: parser) }
    }

    private func checkpoint(_ parser: XMLParser) -> Bool {
        do { try cancellation.check(); return true }
        catch { parsingError = error; parser.abortParsing(); return false }
    }

    private func attribute(_ name: String, in attributes: [String: String]) -> String {
        attributes.first(where: { $0.key.split(separator: ":").last.map(String.init) == name })?.value ?? ""
    }

    private func append(_ value: String, parser: XMLParser) {
        guard checkpoint(parser) else { return }
        characters += value.count
        guard characters <= DocumentExtractor.maximumTextCharacters else {
            parsingError = TranslatorError("Word 文字超过 100 万字，请按章节拆分后导入。")
            parser.abortParsing()
            return
        }
        text += value
    }
}
