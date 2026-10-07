import SwiftUI

@MainActor
final class ToolsViewModel: ObservableObject {
    private let state: AppState
    private let services: Services

    @Published var brewVersion = ""
    @Published var brewItems: [ToolItem] = []
    @Published var macPortsVersion = ""
    @Published var macPortsItems: [ToolItem] = []
    @Published var sdkmanItems: [ToolItem] = []
    @Published var search = ""
    @Published var loading = false
    @Published var confirmBrewUninstall = false
    @Published var confirmMacPortsUninstall = false
    @Published var confirmSDKMANUninstall = false

    // 装 / 卸掉一个工具会连带改掉一堆模块的版本列表（brew 卸了，nginx/php/mysql 全没了），
    // 但工具页看不到那些 VM。由 AppViewModel 注入一个「刷全部」的回调，别让这里反向依赖它。
    var onRefreshAll: (() async -> Void)?

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var brewInstalled: Bool { services.tools.brewInstalled }
    var macPortsInstalled: Bool { services.tools.macPortsInstalled }
    var sdkmanInstalled: Bool { services.tools.sdkmanInstalled }

    // 有长任务在跑就锁住按钮：runStreaming 本来就会丢掉并发请求，
    // 但按钮亮着不响应比直接变灰更让人困惑。
    var busy: Bool { state.task != nil }

    var brewPath: String { services.tools.brewPrefix }
    var macPortsPath: String { "/opt/local" }
    var sdkmanPath: String { services.tools.sdkmanRoot.path }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        // 三个工具的探测互不依赖，并行跑。
        async let brew = services.tools.brewVersion()
        async let brewList = services.tools.brewItems()
        async let port = services.tools.macPortsVersion()
        async let portList = services.tools.macPortsItems()
        brewVersion = await brew
        brewItems = await brewList
        macPortsVersion = await port
        macPortsItems = await portList
        sdkmanItems = services.tools.sdkmanItems()
    }

    // MARK: - Homebrew

    func installBrew() {
        state.runStreaming(L("tools.installBrew")) { report, attach in
            try await self.services.tools.installBrew(report: report, onStart: attach)
            await self.finish()
        }
    }

    func updateBrew() {
        state.runStreaming(L("tools.updateBrew")) { report, attach in
            try await Brew.run("update", formula: "brew", report: report, onStart: attach)
            await self.finish()
        }
    }

    func uninstallBrew() {
        state.runStreaming(L("tools.uninstallBrew")) { report, _ in
            try await self.services.tools.uninstallBrew(report: report)
            await self.finish()
        }
    }

    func uninstallBrewFormula(_ item: ToolItem) {
        state.runStreaming(taskTitle("uninstall", item.name)) { report, attach in
            try await Brew.run("uninstall", formula: item.name, report: report, onStart: attach)
            await self.refresh()
        }
    }

    // MARK: - MacPorts

    func installMacPorts() {
        state.runStreaming(L("tools.installMacPorts")) { report, _ in
            try await self.services.tools.installMacPorts(report: report)
            await self.finish()
        }
    }

    func uninstallMacPorts() {
        state.runStreaming(L("tools.uninstallMacPorts")) { report, _ in
            try await self.services.tools.uninstallMacPorts(report: report)
            // 摘 MacEnv 自己写的 PATH 软链，再清 shell 配置里那几行 —— 软链和 PATH 都指向
            // /opt/local，目录删了它们就是悬空的，留着下次开 shell 会报一行错。
            try self.services.paths.removeLinks(pointingInside: URL(fileURLWithPath: "/opt/local", isDirectory: true))
            try self.services.paths.removeLines(containing: "/opt/local", from: [".zprofile", ".zshrc", ".profile", ".bash_profile", ".bash_login"].map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0) })
            await self.finish()
        }
    }

    func uninstallMacPortsPort(_ item: ToolItem) {
        state.runStreaming(taskTitle("uninstall", item.name)) { report, _ in
            try await self.services.tools.uninstallMacPortsPort(item.name, report: report)
            await self.refresh()
        }
    }

    // MARK: - SDKMAN

    func installSDKMAN() {
        state.runStreaming(L("tools.installSDKMAN")) { report, attach in
            try await self.services.tools.installSDKMAN(report: report, onStart: attach)
            await self.finish()
        }
    }

    func uninstallSDKMAN() {
        state.runStreaming(L("tools.uninstallSDKMAN")) { report, _ in
            _ = report
            try self.services.paths.removeLinks(pointingInside: self.services.tools.sdkmanRoot)
            try self.services.tools.uninstallSDKMAN()
            try self.services.paths.removeLines(containing: "sdkman", from: self.services.tools.sdkmanProfileFiles)
            await self.finish()
        }
    }

    func uninstallSDKMANCandidate(_ item: ToolItem) {
        state.runStreaming(taskTitle("uninstall", "\(item.name) \(item.version)")) { report, attach in
            try await self.services.tools.uninstallSDKMANCandidate(item.name, version: item.version, report: report, onStart: attach)
            await self.refresh()
        }
    }

    // 工具换了，所有模块的版本列表都可能是旧的，一起刷。
    private func finish() async {
        await refresh()
        await onRefreshAll?()
    }

    func filtered(_ items: [ToolItem]) -> [ToolItem] {
        let key = search.trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(key) || $0.version.localizedCaseInsensitiveContains(key) }
    }
}
