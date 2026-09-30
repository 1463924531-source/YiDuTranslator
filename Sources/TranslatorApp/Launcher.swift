import AppKit
import Combine
import SwiftUI
import TranslatorCore

@main
struct YiDuLauncher {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = TranslatorDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

@MainActor
final class TranslatorDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = AppSettings()
    private let favorites = FavoritesStore()
    private lazy var store = AppStore(settings: settings, favorites: favorites)
    private let hotkeys = GlobalHotkeyManager()
    private var mainWindow: NSWindow?
    private var resultPanel: TranslationPanel?
    private var statusItem: NSStatusItem?
    private var lookupMenuItem: NSMenuItem?
    private var translateMenuItem: NSMenuItem?
    private var screenshotMenuItem: NSMenuItem?
    private var subscriptions = Set<AnyCancellable>()
    private var lastFloatingEnabled = true
    private var awaitingSelectionShutdown = false
    private var isSmokeTest = CommandLine.arguments.contains("--smoke-test")

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        settings.applyAppearance()
        lastFloatingEnabled = settings.floatingEnabled
        makeMenu()
        createMainWindow()
        createStatusItem()
        store.showMain = { [weak self] in self?.openMain() }
        store.showResult = { [weak self] in self?.openResult() }
        store.hideForCapture = { [weak self] in self?.hideWindowsForScreenshot() }
        store.applyHotkeys = { [weak self] in self?.registerShortcuts() }
        store.updatePin = { [weak self] value in self?.resultPanel?.level = value ? .floating : .normal }
        settings.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                registerShortcuts()
                if lastFloatingEnabled && !settings.floatingEnabled && resultPanel?.isVisible == true {
                    resultPanel?.orderOut(nil); openMain()
                }
                lastFloatingEnabled = settings.floatingEnabled
            }.store(in: &subscriptions)
        registerShortcuts()
        openMain()
        if isSmokeTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                print("YIDU_SMOKE_OK: main window constructed")
                NSApp.terminate(nil)
            }
        }
    }

    private func createMainWindow() {
        let root = MainView().environmentObject(store).environmentObject(settings).environmentObject(favorites)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "译读"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 1000, height: 680)
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.delegate = self
        mainWindow = window
    }

    private func createPanel() {
        let root = FloatingTranslatorView().environmentObject(store).environmentObject(settings).environmentObject(favorites)
        let panel = TranslationPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
                                     styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "译读 · 随手翻译"
        panel.isReleasedWhenClosed = false; panel.isRestorable = false
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
        panel.level = store.pinned ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 500, height: 600)
        panel.contentView = NSHostingView(rootView: root)
        panel.delegate = self
        resultPanel = panel
    }

    func openMain() {
        if store.hasPendingSelection {
            store.cancelPendingSelection()
            Task { [weak self] in
                guard let self else { return }
                await store.waitForSelectionCleanup()
                guard !awaitingSelectionShutdown else { return }
                openMain()
            }
            return
        }
        store.cancelPendingSelection()
        if mainWindow == nil { createMainWindow() }
        resultPanel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func openResult() {
        if !settings.floatingEnabled { openMain(); return }
        if resultPanel == nil { createPanel() }
        if resultPanel?.isVisible != true, let panel = resultPanel {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
            let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let x = max(available.minX + 12, min(mouse.x + 18, available.maxX - panel.frame.width - 12))
            let y = max(available.minY + 12, min(mouse.y - panel.frame.height, available.maxY - panel.frame.height - 12))
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        NSApp.activate(ignoringOtherApps: true)
        resultPanel?.makeKeyAndOrderFront(nil)
    }

    private func hideWindowsForScreenshot() {
        mainWindow?.orderOut(nil); resultPanel?.orderOut(nil)
        NSApp.hide(nil)
    }

    private func registerShortcuts() {
        updateMenuShortcuts()
        guard !isSmokeTest else { return }
        guard settings.hotkeysEnabled else { hotkeys.unregisterAll(); store.hotkeyWarnings = []; return }
        var bindings = [settings.dictionaryShortcut.binding(for: .dictionary), settings.translationShortcut.binding(for: .translate)]
        if settings.screenshotEnabled { bindings.append(settings.screenshotShortcut.binding(for: .screenshot)) }
        store.hotkeyWarnings = hotkeys.register(bindings: bindings) { [weak self] action in
            guard let self else { return }
            if NSApp.isActive { performLocalAction(action) }
            else { store.handleShortcut(action) }
        }
    }

    private func performLocalAction(_ action: HotkeyAction) {
        guard !store.capturing else { return }
        if store.hasPendingSelection {
            store.cancelPendingSelection()
            Task { [weak self] in
                guard let self else { return }
                await store.waitForSelectionCleanup()
                guard !awaitingSelectionShutdown else { return }
                performLocalAction(action)
            }
            return
        }
        store.cancelPendingSelection()
        guard action != .screenshot else { store.captureScreenshot(); return }
        store.cancelTranslation(); store.cancelExplanation()
        store.mode = action == .dictionary ? .dictionary : .translate
        store.section = .translation
        openResult()
        if !store.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { store.runTranslation() }
    }

    private func updateMenuShortcuts() {
        let pairs: [(NSMenuItem?, ShortcutChoice, Bool)] = [
            (lookupMenuItem, settings.dictionaryShortcut, settings.hotkeysEnabled),
            (translateMenuItem, settings.translationShortcut, settings.hotkeysEnabled),
            (screenshotMenuItem, settings.screenshotShortcut, settings.hotkeysEnabled && settings.screenshotEnabled)
        ]
        for (item, choice, enabled) in pairs {
            item?.keyEquivalent = enabled ? String(choice.number) : ""
            switch choice.modifier {
            case .command: item?.keyEquivalentModifierMask = [.command]
            case .optionCommand: item?.keyEquivalentModifierMask = [.option, .command]
            case .controlOption: item?.keyEquivalentModifierMask = [.control, .option]
            }
        }
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "译读")
            button.toolTip = "译读 · 查词与翻译"
        }
        let menu = NSMenu()
        addItem("打开译读", action: #selector(openFromMenu), to: menu)
        addItem("截图翻译…", action: #selector(captureFromMenu), to: menu)
        menu.addItem(.separator())
        addItem("设置…", action: #selector(settingsFromMenu), to: menu)
        menu.addItem(.separator())
        addItem("退出译读", action: #selector(quitFromMenu), to: menu)
        statusItem?.menu = menu
    }

    private func makeMenu() {
        let menu = NSMenu()
        let appRoot = NSMenuItem(); menu.addItem(appRoot)
        let appMenu = NSMenu(); appRoot.submenu = appMenu
        addItem("关于译读", action: #selector(aboutFromMenu), to: appMenu)
        appMenu.addItem(.separator())
        addItem("设置…", action: #selector(settingsFromMenu), key: ",", to: appMenu)
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏译读", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp; appMenu.addItem(hide)
        appMenu.addItem(.separator())
        addItem("退出译读", action: #selector(quitFromMenu), key: "q", to: appMenu)
        let fileRoot = NSMenuItem(title: "文件", action: nil, keyEquivalent: ""); menu.addItem(fileRoot)
        let fileMenu = NSMenu(title: "文件"); fileRoot.submenu = fileMenu
        addItem("打开文件…", action: #selector(documentFromMenu), key: "o", to: fileMenu)
        addItem("打开主窗口", action: #selector(openFromMenu), key: "0", to: fileMenu)
        fileMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let translateRoot = NSMenuItem(title: "翻译", action: nil, keyEquivalent: ""); menu.addItem(translateRoot)
        let translateMenu = NSMenu(title: "翻译"); translateRoot.submenu = translateMenu
        lookupMenuItem = NSMenuItem(title: "查词", action: #selector(lookupFromMenu), keyEquivalent: "2")
        translateMenuItem = NSMenuItem(title: "翻译句子", action: #selector(translateFromMenu), keyEquivalent: "3")
        screenshotMenuItem = NSMenuItem(title: "框选截图…", action: #selector(captureFromMenu), keyEquivalent: "4")
        for item in [lookupMenuItem!, translateMenuItem!, screenshotMenuItem!] { item.target = self; translateMenu.addItem(item) }
        let editRoot = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); menu.addItem(editRoot)
        let edit = NSMenu(title: "编辑"); editRoot.submenu = edit
        for (title, selector, key) in [("撤销", Selector(("undo:")), "z"), ("重做", Selector(("redo:")), "Z"),
                                        ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"),
                                        ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        let windowRoot = NSMenuItem(title: "窗口", action: nil, keyEquivalent: ""); menu.addItem(windowRoot)
        let windowMenu = NSMenu(title: "窗口"); windowRoot.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }

    private func addItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }

    @objc private func openFromMenu() { openMain() }
    @objc private func settingsFromMenu() { store.section = .settings; openMain() }
    @objc private func documentFromMenu() {
        guard !store.capturing else { return }
        if store.hasPendingSelection {
            store.cancelPendingSelection()
            Task { [weak self] in
                guard let self else { return }
                await store.waitForSelectionCleanup()
                guard !awaitingSelectionShutdown else { return }
                documentFromMenu()
            }
            return
        }
        openMain(); store.chooseDocument()
    }
    @objc private func captureFromMenu() { store.captureScreenshot() }
    @objc private func lookupFromMenu() { performLocalAction(.dictionary) }
    @objc private func translateFromMenu() { performLocalAction(.translate) }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }
    @objc private func aboutFromMenu() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "译读", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.2",
            .credits: NSAttributedString(string: "为雅思学习与论文阅读准备的 Mac 翻译助手。\nDeepSeek V4.1 Flash · 只保存主动收藏的内容。")])
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openMain(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidBecomeActive(_ notification: Notification) { store.refreshPermissions() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.hasPendingSelection else { return .terminateNow }
        if !awaitingSelectionShutdown {
            awaitingSelectionShutdown = true
            hotkeys.unregisterAll()
            store.shutdown()
            Task { [weak self] in
                guard let self else { sender.reply(toApplicationShouldTerminate: true); return }
                await store.waitForSelectionCleanup()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { hotkeys.unregisterAll(); store.shutdown() }
    func windowWillClose(_ notification: Notification) { store.cancelPendingSelection(); store.stopSpeaking() }
}
