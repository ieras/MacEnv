import SwiftUI
import AppKit

final class MacEnvAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppViewModel?
    private var closeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isTesting else { return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            guard (notification.object as? NSWindow)?.identifier?.rawValue == "main" || (notification.object as? NSWindow)?.title == "MacEnv" else { return }
            Task { @MainActor in
                guard self?.model?.state.hideOnClose == true else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

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
            ContentView(app: model, nginxVM: model.nginxVM, databaseVM: model.databaseVM, redisVM: model.redisVM, certVM: model.certVM, phpVM: model.phpVM, hostVM: model.hostVM, goVM: model.goVM, erlangVM: model.erlangVM, postgresVM: model.postgresVM, clickhouseVM: model.clickhouseVM, qdrantVM: model.qdrantVM, neo4jVM: model.neo4jVM, rabbitmqVM: model.rabbitmqVM, consulVM: model.consulVM, etcdVM: model.etcdVM, minioVM: model.minioVM, rustfsVM: model.rustfsVM, kafkaVM: model.kafkaVM)
                .frame(minWidth: 900, minHeight: 620)
                .environmentObject(model.state)
                .id(model.state.language)
                .onAppear { delegate.model = model; model.state.applyTheme() }
        }
        .defaultSize(width: 1000, height: 700)
        Settings {
            SettingsView(app: model)
                .id(model.state.language)
                .onAppear { model.state.applyTheme() }
        }
        MenuBarExtra {
            TrayMenuView(app: model, nginxVM: model.nginxVM, databaseVM: model.databaseVM, phpVM: model.phpVM, redisVM: model.redisVM, postgresVM: model.postgresVM, clickhouseVM: model.clickhouseVM, qdrantVM: model.qdrantVM, consulVM: model.consulVM, etcdVM: model.etcdVM)
        } label: {
            Image(nsImage: Self.trayIcon)
        }
        .menuBarExtraStyle(.window)
    }

    static let trayIcon: NSImage = {
        let image = NSImage(named: "TrayIcon") ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
