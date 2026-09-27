import AppKit
import CoreText
import PDFKit

final class DocumentExtractorTests: XCTestCase {
    func testSplittingPreservesEveryCharacterAndParagraphs() {
        XCTAssertEqual(DocumentExtractor.splitText("a\n\nb"), ["a\n\n", "b"])
        XCTAssertEqual(DocumentExtractor.splitText("a\r\n\r\nb"), ["a\r\n\r\n", "b"])
        XCTAssertEqual(DocumentExtractor.splitText("\n\na\n \n\nb\n\n"), ["\n\na\n \n\n", "b\n\n"])
        let sample = "IELTS, Computing and Economics\n\nIELTS reading requires careful attention.\n\nAn algorithm solves a problem.\n\nEconomic growth increases production.\n\n"
        XCTAssertEqual(DocumentExtractor.splitText(sample).count, 4)
        XCTAssertEqual(DocumentExtractor.splitText(sample).joined(), sample)
        let text = String(repeating: "Economics 与计算机 👩🏽‍💻. ", count: 90) + "\n\n" +
            String(repeating: "Second paragraph 学术写作\n", count: 240)
        let pieces = DocumentExtractor.splitText(text)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.joined(), text)
        XCTAssertTrue(pieces.allSatisfy { !$0.isEmpty && $0.count <= 3000 })
        let paragraphs = String(repeating: "a", count: 1800) + "\n\n" + String(repeating: "b", count: 1800)
        XCTAssertTrue(DocumentExtractor.splitText(paragraphs)[0].hasSuffix("\n\n"))
        XCTAssertEqual(DocumentExtractor.splitText("🇨🇳e\u{301}😀", maxCharacters: 1).count, 3)
    }

    func testRealDOCXPreservesRunsTablesAndNotesWithoutDeletedText() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeDOCX(in: directory)
        let before = try Data(contentsOf: file)
        let document = try await DocumentExtractor.extract(url: file)
        let text = document.segments.map(\.source).joined()
        XCTAssertTrue(text.contains("Economic growth & technology"))
        XCTAssertTrue(text.contains("Cell A"))
        XCTAssertTrue(text.contains("Cell B"))
        XCTAssertTrue(text.contains("Accepted wording"))
        XCTAssertFalse(text.contains("Deleted wording"))
        XCTAssertTrue(text.contains("Research header"))
        XCTAssertTrue(text.contains("Footnote explanation"))
        XCTAssertFalse(text.contains("Separator must not appear"))
        XCTAssertTrue(document.warnings.contains { $0.contains("检测到") })
        XCTAssertTrue(document.segments.allSatisfy { $0.page == nil })
        try XCTAssertEqual(try Data(contentsOf: file), before, "Import must leave the original untouched")
    }

    func testShortDOCXHasFourParagraphSegments() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paragraphs = ["IELTS, Computing and Economics", "IELTS reading requires careful attention.",
                          "An algorithm solves a problem.", "Economic growth increases production."]
        let url = try makeDOCX(in: directory, simpleParagraphs: paragraphs)
        let document = try await DocumentExtractor.extract(url: url)
        XCTAssertEqual(document.segments.count, 4)
        XCTAssertEqual(document.segments.map { $0.source.trimmingCharacters(in: .whitespacesAndNewlines) }, paragraphs)
        XCTAssertEqual(document.segments.map(\.source).joined(), paragraphs.map { $0 + "\n\n" }.joined())
    }

    func testPDFKeepsPageNumbersAndReportsBlankPages() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("text.pdf")
        try makeTextPDF(at: url, pages: ["Computer science research", "Economic models and evidence", nil])
        let document = try await DocumentExtractor.extract(url: url)
        XCTAssertTrue(document.segments.contains { $0.page == 1 && $0.source.contains("Computer science research") })
        XCTAssertTrue(document.segments.contains { $0.page == 2 && $0.source.contains("Economic models and evidence") })
        XCTAssertFalse(document.segments.contains { $0.page == 3 })
        XCTAssertTrue(document.warnings.contains { $0.contains("第 3 页未识别到文字") })
        XCTAssertEqual(document.segments.map(\.ordinal), Array(1...document.segments.count))
    }

    func testScannedPDFUsesLocalOCR() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scan.pdf")
        let image = try textImage("Economic research and computer science")
        let pdf = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 1500, height: 400))))
        pdf.insert(page, at: 0)
        XCTAssertTrue(pdf.write(to: url))
        XCTAssertTrue((page.string ?? "").isEmpty, "Fixture must be image-only")
        let document = try await DocumentExtractor.extract(url: url)
        let text = document.segments.map(\.source).joined().lowercased()
        XCTAssertTrue(text.contains("economic research"), text)
        XCTAssertTrue(document.warnings.contains { $0.contains("OCR") })
        XCTAssertEqual(document.segments.first?.page, 1)
    }

    func testImageOCRReadsActualBitmap() async throws {
        let image = try textImage("Learning English every day")
        let bitmap = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let text = try await ImageOCR.recognize(data: data)
        XCTAssertTrue(text.lowercased().contains("learning english"), text)
    }

    func testRejectsCorruptWordAndOversizePDFPageCount() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = directory.appendingPathComponent("corrupt.docx")
        try Data("not a zip".utf8).write(to: corrupt)
        do {
            _ = try await DocumentExtractor.extract(url: corrupt)
            XCTFail("Corrupt documents must not be imported")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Word")) }
        let long = directory.appendingPathComponent("too-many-pages.pdf")
        try makeTextPDF(at: long, pages: Array(repeating: nil, count: 301))
        do {
            _ = try await DocumentExtractor.extract(url: long)
            XCTFail("PDF page limit must apply before OCR")
        } catch { XCTAssertTrue(error.localizedDescription.contains("300 页")) }
    }

    func testCancelledImportDoesNotReturnPartialDocument() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cancel.pdf")
        try makeTextPDF(at: url, pages: ["Do not translate cancelled jobs"])
        let task = Task { try await DocumentExtractor.extract(url: url) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled jobs must throw")
        } catch is CancellationError { }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("YiDu-Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDOCX(in directory: URL, simpleParagraphs: [String]? = nil) throws -> URL {
        let root = directory.appendingPathComponent("package", isDirectory: true)
        let word = root.appendingPathComponent("word", isDirectory: true)
        let relationships = root.appendingPathComponent("_rels", isDirectory: true)
        let wordRelationships = word.appendingPathComponent("_rels", isDirectory: true)
        try FileManager.default.createDirectory(at: wordRelationships, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relationships, withIntermediateDirectories: true)
        let contents = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/><Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/></Types>
        """
        let namespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="\(namespace)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>
        <w:p><w:r><w:t xml:space="preserve">Economic </w:t></w:r><w:r><w:t>growth &amp; technology</w:t></w:r></w:p>
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Cell B</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        <w:p><w:del w:id="1"><w:r><w:delText>Deleted wording</w:delText></w:r></w:del><w:ins w:id="2"><w:r><w:t>Accepted wording</w:t></w:r></w:ins><w:r><w:footnoteReference w:id="1"/></w:r></w:p>
        <w:p><w:r><w:drawing/></w:r></w:p>
        <w:sectPr><w:headerReference w:type="default" r:id="rIdHeader"/></w:sectPr>
        </w:body></w:document>
        """
        if let simpleParagraphs {
            let body = simpleParagraphs.map { "<w:p><w:r><w:t>\($0)</w:t></w:r></w:p>" }.joined()
            xml = "<w:document xmlns:w=\"\(namespace)\"><w:body>\(body)</w:body></w:document>"
        }
        try contents.write(to: root.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try xml.write(to: word.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        try "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>".write(to: relationships.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rIdHeader\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/><Relationship Id=\"rIdNotes\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes\" Target=\"footnotes.xml\"/></Relationships>".write(to: wordRelationships.appendingPathComponent("document.xml.rels"), atomically: true, encoding: .utf8)
        try "<w:hdr xmlns:w=\"\(namespace)\"><w:p><w:r><w:t>Research header</w:t></w:r></w:p></w:hdr>".write(to: word.appendingPathComponent("header1.xml"), atomically: true, encoding: .utf8)
        try "<w:footnotes xmlns:w=\"\(namespace)\"><w:footnote w:type=\"separator\" w:id=\"-1\"><w:p><w:r><w:t>Separator must not appear</w:t></w:r></w:p></w:footnote><w:footnote w:id=\"1\"><w:p><w:r><w:t>Footnote explanation</w:t></w:r></w:p></w:footnote></w:footnotes>".write(to: word.appendingPathComponent("footnotes.xml"), atomically: true, encoding: .utf8)
        if simpleParagraphs != nil {
            try "<w:hdr xmlns:w=\"\(namespace)\"/>".write(to: word.appendingPathComponent("header1.xml"), atomically: true, encoding: .utf8)
            try "<w:footnotes xmlns:w=\"\(namespace)\"/>".write(to: word.appendingPathComponent("footnotes.xml"), atomically: true, encoding: .utf8)
        }
        let url = directory.appendingPathComponent("research.docx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-r", url.path, "."]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return url
    }

    private func makeTextPDF(at url: URL, pages: [String?]) throws {
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for text in pages {
            context.beginPDFPage(nil)
            if let text { draw(text, in: context, at: CGPoint(x: 48, y: 680), fontSize: 24) }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func textImage(_ text: String) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1500, height: 400, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: 1500, height: 400))
        draw(text, in: context, at: CGPoint(x: 55, y: 210), fontSize: 52)
        return try XCTUnwrap(context.makeImage())
    }

    private func draw(_ text: String, in context: CGContext, at point: CGPoint, fontSize: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, fontSize, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor.black
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}

class XCTestCase {}
func XCTAssertTrue(_ condition: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { precondition(condition(), message.isEmpty ? "Expected true" : message, file: file, line: line) }
func XCTAssertFalse(_ condition: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { precondition(!condition(), message.isEmpty ? "Expected false" : message, file: file, line: line) }
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) rethrows { let a = try lhs(); let b = try rhs(); precondition(a == b, message.isEmpty ? "Values differ: \(a) vs \(b)" : message, file: file, line: line) }
func XCTAssertGreaterThan<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) { precondition(lhs > rhs, "Expected greater", file: file, line: line) }
func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) { preconditionFailure(message, file: file, line: line) }
func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { guard let value else { preconditionFailure("Unexpected nil", file: file, line: line) }; return value }

@main struct DocumentChecks {
    static func main() async throws {
        let tests = DocumentExtractorTests()
        tests.testSplittingPreservesEveryCharacterAndParagraphs()
        print("PASS: lossless Unicode/paragraph chunking")
        try await tests.testShortDOCXHasFourParagraphSegments()
        print("PASS: four short DOCX paragraphs remain four independent segments")
        try await tests.testRealDOCXPreservesRunsTablesAndNotesWithoutDeletedText()
        print("PASS: actual DOCX paragraphs/tables/tracked changes/header/footnotes and unchanged original")
        try await tests.testPDFKeepsPageNumbersAndReportsBlankPages()
        print("PASS: PDF text, page numbering, blank-page warning")
        try await tests.testScannedPDFUsesLocalOCR()
        print("PASS: scanned PDF OCR")
        try await tests.testImageOCRReadsActualBitmap()
        print("PASS: bitmap OCR")
        try await tests.testRejectsCorruptWordAndOversizePDFPageCount()
        print("PASS: corrupted DOCX and PDF page bound")
        try await tests.testCancelledImportDoesNotReturnPartialDocument()
        print("PASS: cancellation")
    }
}
