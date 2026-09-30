import AppKit
import Carbon
import Combine
import Foundation
import TranslatorCore

enum ShortcutModifier: String, CaseIterable, Identifiable, Codable {
    case command, optionCommand, controlOption
    var id: String { rawValue }
    var title: String {
        switch self { case .command: return "⌘"; case .optionCommand: return "⌥⌘"; case .controlOption: return "⌃⌥" }
    }
    var carbonValue: UInt32 {
        switch self {
        case .command: return UInt32(cmdKey)
        case .optionCommand: return UInt32(optionKey | cmdKey)
        case .controlOption: return UInt32(controlKey | optionKey)
        }
    }
}

struct ShortcutChoice: Codable, Equatable {
    var number: Int
    var modifier: ShortcutModifier
    var label: String { modifier.title + String(number) }
    func binding(for action: HotkeyAction) -> HotkeyBinding {
        let codes: [Int: UInt32] = [1:18, 2:19, 3:20, 4:21, 5:23, 6:22, 7:26, 8:28, 9:25]
        return HotkeyBinding(action: action, keyCode: codes[number] ?? 19, modifiers: modifier.carbonValue)
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var floatingEnabled: Bool { didSet { defaults.set(floatingEnabled, forKey: "floatingEnabled") } }
    @Published var selectionEnabled: Bool { didSet { defaults.set(selectionEnabled, forKey: "selectionEnabled") } }
    @Published var wpsCopyCompatibilityEnabled: Bool { didSet { defaults.set(wpsCopyCompatibilityEnabled, forKey: "wpsCopyCompatibilityEnabled") } }
    @Published var hotkeysEnabled: Bool { didSet { defaults.set(hotkeysEnabled, forKey: "hotkeysEnabled") } }
    @Published var screenshotEnabled: Bool { didSet { defaults.set(screenshotEnabled, forKey: "screenshotEnabled") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    @Published var style: WritingStyle { didSet { defaults.set(style.rawValue, forKey: "style") } }
    @Published var direction: TranslationDirection { didSet { defaults.set(direction.rawValue, forKey: "direction") } }
    @Published var dictionaryShortcut: ShortcutChoice { didSet { persist(dictionaryShortcut, key: "dictionaryShortcut") } }
    @Published var translationShortcut: ShortcutChoice { didSet { persist(translationShortcut, key: "translationShortcut") } }
    @Published var screenshotShortcut: ShortcutChoice { didSet { persist(screenshotShortcut, key: "screenshotShortcut") } }
    @Published var glossary: [GlossaryEntry] { didSet { persist(glossary, key: "glossary") } }
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance"); applyAppearance() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func boolean(_ key: String, fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func decoded<T: Decodable>(_ key: String, fallback: T) -> T {
            guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return value
        }
        floatingEnabled = boolean("floatingEnabled", fallback: true)
        selectionEnabled = boolean("selectionEnabled", fallback: true)
        wpsCopyCompatibilityEnabled = boolean("wpsCopyCompatibilityEnabled", fallback: true)
        hotkeysEnabled = boolean("hotkeysEnabled", fallback: true)
        screenshotEnabled = boolean("screenshotEnabled", fallback: true)
        fontSize = max(13, min(22, defaults.object(forKey: "fontSize") as? Double ?? 16))
        style = WritingStyle(rawValue: defaults.string(forKey: "style") ?? "") ?? .daily
        direction = TranslationDirection(rawValue: defaults.string(forKey: "direction") ?? "") ?? .automatic
        dictionaryShortcut = decoded("dictionaryShortcut", fallback: ShortcutChoice(number: 2, modifier: .command))
        translationShortcut = decoded("translationShortcut", fallback: ShortcutChoice(number: 3, modifier: .command))
        screenshotShortcut = decoded("screenshotShortcut", fallback: ShortcutChoice(number: 4, modifier: .optionCommand))
        glossary = decoded("glossary", fallback: [GlossaryEntry]())
        appearance = defaults.string(forKey: "appearance") ?? "system"
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    func applyAppearance() {
        NSApp.appearance = appearance == "light" ? NSAppearance(named: .aqua) : appearance == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
}
