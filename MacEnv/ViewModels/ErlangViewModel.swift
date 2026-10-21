import SwiftUI

// Erlang 是一等语言模块（跟 Go / Java 同级）。两个 tab：已安装（含环境变量开关）、
// 版本管理（Homebrew / MacPorts）。没有 Static 栏 —— 官方 macOS 没有预编译发行版。
@MainActor
final class ErlangViewModel: ObservableObject, PortListHost {
    let state: AppState
    let services: Services

    @Published var versions: [ErlangVersion] = []
    // 版本管理里的 Homebrew 一栏：erlang 和 erlang@大版本 这一族公式。
    @Published var formulae: [BrewFormulaItem] = []
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selectedID: String?
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.erlang.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.erlang.directories") }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: ErlangVersion? { versions.first { $0.id == selectedID } ?? versions.first }

    func refresh() async {
        do {
            // 先问一次登录 shell 拿真实 PATH，再把 PATH 里的目录也当扫描目标 ——
            // 用户可能用 kerl 之类装在非标准位置，shell 里 erl 有输出、
            // MacEnv 里却一个都看不到就说不通了（同 GoViewModel）。
            try await services.paths.refresh()
            versions = await services.erlang.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "erlang", directory: $0.directory)) })
        } catch {
            state.message = error.localizedDescription
        }
        // brew 查不到（没装、或公式被 tap 挡了）不该把上面的扫描结果一起判成失败（同 GoViewModel）。
        Task {
            do { formulae = try await Brew.formulae("erlang") }
            catch { state.message = error.localizedDescription }
        }
        objectWillChange.send()
    }

    func refreshVersionManager(_ source: String, force: Bool = false) async {
        switch source {
        case "MacPorts": await loadPortItems(force: force)
        default: await refresh()
        }
    }

    // MARK: - MacPorts 清单（加载与装/卸在 PortListHost 协议扩展里）

    @Published var portItems: [PortItem] = []
    @Published var portLoading = false
    var portApp: String { "erlang" }

    func brewAction(_ action: String, formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh()
        }
    }

    // Erlang 的 PATH 入口是 ERL_ROOT 那一级，PATH 上加的是它下面的 bin —— PathService 两种都写。
    func togglePath(_ version: ErlangVersion) {
        state.run {
            try self.services.paths.toggle(kind: "erlang", directory: version.directory)
            try await self.services.paths.refresh(force: true)
            self.pathMembership = Dictionary(uniqueKeysWithValues: self.versions.map { ($0.id, self.services.paths.membership(kind: "erlang", directory: $0.directory)) })
            let enabled = self.services.paths.membership(kind: "erlang", directory: version.directory) == .app
            self.state.message = String(format: L(enabled ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Erlang " + version.version)
        }
    }
}
