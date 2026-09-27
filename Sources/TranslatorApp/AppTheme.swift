import AppKit
import SwiftUI

enum AppTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.36, green: 0.77, blue: 0.72, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.43, blue: 0.40, alpha: 1)
    })
    static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.105, green: 0.115, blue: 0.115, alpha: 1)
            : NSColor(srgbRed: 0.970, green: 0.964, blue: 0.949, alpha: 1)
    })
    static let surface = Color(nsColor: .textBackgroundColor)
    static let border = Color.primary.opacity(0.085)
}

struct SurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.border, lineWidth: 1))
    }
}

struct StoreBanners: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 8) {
            if let message = store.errorMessage {
                banner(message, symbol: "exclamationmark.circle.fill", color: .red) { store.errorMessage = nil }
            }
            if let message = store.notice {
                banner(message, symbol: "info.circle", color: AppTheme.accent) { store.notice = nil }
            }
        }
    }

    private func banner(_ text: String, symbol: String, color: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).padding(.top, 1)
            Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭提示")
                .accessibilityLabel("关闭提示")
        }
        .padding(11)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ReadableMarkdown: View {
    let text: String
    var size: Double = 16
    private var attributedText: AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
    var body: some View {
        Text(attributedText)
            .font(.system(size: size)).lineSpacing(7)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
