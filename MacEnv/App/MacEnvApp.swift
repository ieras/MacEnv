import SwiftUI
import AppKit

final class MacEnvAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    weak var model: AppViewModel?
    private var closeObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?

    // 单元测试会以宿主进程方式加载本 app，此时不要建菜单栏、不要拦截退出，
    // 否则测试跑完 app 不退出，xcodebuild 会一直挂着。
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isTesting else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // TrayIcon.imageset 带 light/dark 双变体（SVG 矢量），系统切外观时 AppKit 自动换图。
        if let image = NSImage(named: "TrayIcon") {
            image.size = NSSize(width: 20.7, height: 18)
            item.button?.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            guard (notification.object as? NSWindow)?.identifier?.rawValue == "main" || (notification.object as? NSWindow)?.title == "MacEnv" else { return }
            guard self?.model?.state.hideOnClose == true else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: L("app.name"), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if let model {
            let running = model.state.quickStartTargets.contains { model.targetRunning($0) }
            let quickStart = NSMenuItem(title: running ? L("menu.stopQuickStart") : L("menu.startQuickStart"), action: #selector(toggleQuickStart), keyEquivalent: "")
            quickStart.target = self
            quickStart.isEnabled = !model.state.busy && !model.state.quickStartTargets.isEmpty
            menu.addItem(quickStart)
            menu.addItem(.separator())
        }
        let open = NSMenuItem(title: L("menu.open"), action: #selector(openMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: L("menu.settings"), action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleQuickStart() {
        Task { @MainActor [weak self] in
            guard let self, let model else { return }
            model.launch(model.state.quickStartTargets, stop: model.state.quickStartTargets.contains { model.targetRunning($0) })
        }
    }

    @objc private func openMainWindow() { Self.showMainWindow() }

    @objc private func openSettings() { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !isTesting else { return .terminateNow }
        Task { @MainActor in
            await model.stopAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showMainWindow()
        return true
    }

    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "MacEnv" }?.makeKeyAndOrderFront(nil)
    }
}

@main
struct MacEnvApp: App {
    @NSApplicationDelegateAdaptor(MacEnvAppDelegate.self) private var delegate
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        Window(L("app.name"), id: "main") {
            ContentView(app: model, nginxVM: model.nginxVM, databaseVM: model.databaseVM, redisVM: model.redisVM, phpVM: model.phpVM, hostVM: model.hostVM, goVM: model.goVM)
                .frame(minWidth: 900, minHeight: 620)
                .id(model.state.language)
                .onAppear { delegate.model = model; model.state.applyTheme() }
        }
        .defaultSize(width: 1000, height: 700)
        Settings {
            SettingsView(app: model)
                .id(model.state.language)
                .onAppear { model.state.applyTheme() }
        }
    }
}
