import SwiftUI
import AppKit

final class MacEnvAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppViewModel?
    private var closeObserver: NSObjectProtocol?

    // 单元测试会以宿主进程方式加载本 app，此时不要拦退出（托盘由 MenuBarExtra scene 负责，不受这里管），
    // 否则测试跑完 app 不退出，xcodebuild 会一直挂着。
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
            ContentView(app: model, nginxVM: model.nginxVM, databaseVM: model.databaseVM, redisVM: model.redisVM, certVM: model.certVM, phpVM: model.phpVM, hostVM: model.hostVM, goVM: model.goVM, postgresVM: model.postgresVM, clickhouseVM: model.clickhouseVM, qdrantVM: model.qdrantVM, consulVM: model.consulVM, etcdVM: model.etcdVM)
                .frame(minWidth: 900, minHeight: 620)
                // ModulePage（所有模块页的外壳）靠它读全局任务状态，画「任务进行中」指示条。
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
        // 托盘：点状态栏图标弹 TrayMenuView 面板（.window 风格），里面是纯 SwiftUI，
        // 开关/图标直接复用侧栏组件。SceneBuilder 的 if 只认 #available，不能拿 isTesting
        // 条件挂载；测试宿主里多一个状态项无害，真正要挡的 terminate 拦截在 delegate 里有 guard。
        MenuBarExtra {
            TrayMenuView(app: model, nginxVM: model.nginxVM, databaseVM: model.databaseVM, phpVM: model.phpVM, redisVM: model.redisVM, postgresVM: model.postgresVM, clickhouseVM: model.clickhouseVM, qdrantVM: model.qdrantVM, consulVM: model.consulVM, etcdVM: model.etcdVM)
        } label: {
            // MenuBarExtra 的 label 按视图的 natural size 渲染进状态栏按钮：Image("TrayIcon")
            // 的 natural size 是 SVG 的 96x96，.resizable().frame(18,18) 只改布局不改 natural ——
            // 按钮就按 96 宽出图，图标被撑成长条（改多大 frame 都没用，实锤过）。
            // NSImage.size 才是真正的渲染尺寸，跟旧 NSStatusItem 的 image.size 同一条路：
            // 预缩到 18x18 方形（TrayIcon.svg 的规矩：非方形画布会被撑成长条）。
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
