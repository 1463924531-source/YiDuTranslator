import Foundation

public enum TranslationMode: String, Codable, CaseIterable, Identifiable {
    case dictionary, translate, polish, explain, imageExplain
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .dictionary: return "查词"
        case .translate: return "翻译"
        case .polish: return "润色"
        case .explain: return "解释"
        case .imageExplain: return "截图解释"
        }
    }
}

public enum TranslationDirection: String, Codable, CaseIterable, Identifiable {
    case automatic, englishToChinese, chineseToEnglish
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return "自动识别"
        case .englishToChinese: return "英文 → 中文"
        case .chineseToEnglish: return "中文 → 英文"
        }
    }
}

public enum WritingStyle: String, Codable, CaseIterable, Identifiable {
    case daily, academic
    public var id: String { rawValue }
    public var title: String { self == .daily ? "日常" : "学术" }
}

public struct GlossaryEntry: Codable, Identifiable, Equatable {
    public var id: UUID
    public var source: String
    public var target: String
    public init(id: UUID = UUID(), source: String, target: String) {
        self.id = id; self.source = source; self.target = target
    }
}

public struct TranslationRequest: Equatable {
    public var text: String
    public var mode: TranslationMode
    public var direction: TranslationDirection
    public var style: WritingStyle
    public var context: String
    public var priorTranslation: String
    public var question: String
    public var imageData: Data?
    public var glossary: [GlossaryEntry]
    public init(text: String, mode: TranslationMode = .translate,
                direction: TranslationDirection = .automatic, style: WritingStyle = .daily,
                context: String = "", priorTranslation: String = "", question: String = "",
                imageData: Data? = nil, glossary: [GlossaryEntry] = []) {
        self.text = text; self.mode = mode; self.direction = direction; self.style = style
        self.context = context; self.priorTranslation = priorTranslation
        self.question = question; self.imageData = imageData; self.glossary = glossary
    }
}

public struct TokenUsage: Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedTokens: Int
    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedTokens: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cachedTokens = cachedTokens
    }
    public var totalTokens: Int { inputTokens + outputTokens }
    /// Range covers current ordinary off-peak and peak rates; this is not a bill.
    public var estimatedCostRange: ClosedRange<Double> {
        let cached = min(max(0, cachedTokens), max(0, inputTokens))
        let low = (Double(max(0, inputTokens - cached)) + Double(cached) * 0.02 + Double(max(0, outputTokens)) * 4) / 1_000_000
        return low...(low * 2)
    }
}

public enum TranslationEvent {
    case delta(String)
    case usage(TokenUsage)
}

public struct DocumentSegment: Identifiable, Equatable {
    public let id: UUID
    public var ordinal: Int
    public var source: String
    public var page: Int?
    public var label: String { page.map { "第 \($0) 页 · 段落 \(ordinal)" } ?? "段落 \(ordinal)" }
    public init(id: UUID = UUID(), ordinal: Int, source: String, page: Int? = nil) {
        self.id = id; self.ordinal = ordinal; self.source = source; self.page = page
    }
}

public struct ExtractedDocument {
    public var title: String
    public var segments: [DocumentSegment]
    public var warnings: [String]
    public init(title: String, segments: [DocumentSegment], warnings: [String] = []) {
        self.title = title; self.segments = segments; self.warnings = warnings
    }
}

public enum HotkeyAction: UInt32, CaseIterable {
    case dictionary = 1, translate = 2, screenshot = 3
}

public struct HotkeyBinding {
    public var action: HotkeyAction
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(action: HotkeyAction, keyCode: UInt32, modifiers: UInt32) {
        self.action = action; self.keyCode = keyCode; self.modifiers = modifiers
    }
}

public struct TranslatorError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
