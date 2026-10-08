import SwiftUI

@MainActor
final class PythonViewModel: ObservableObject, PortListHost {
    let state: AppState
    let services: Services

    @Published var versions: [PythonVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    // 版本管理里的 Homebrew 一栏：python / python@3.9 … python@3.14 这一族公式。
    @Published var formulae: [BrewFormulaItem] = []
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selectedID: String?
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.python.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.python.directories") }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: PythonVersion? { versions.first { $0.id == selectedID } ?? versions.first }

    func refresh() async {
        do { try await services.paths.refresh() } catch { state.message = error.localizedDescription }
        versions = await services.python.installedVersions(customDirectories: customDirectories + services.paths.allPath)
        if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
        pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, membership($0)) })
        pruneShims()
        // brew 查不到（没装、或公式被 tap 挡了）不该把上面的扫描结果一起判成失败，丢后台慢慢填。
        Task {
            do { formulae = try await Brew.formulae("python") }
            catch { state.message = error.localizedDescription }
        }
        objectWillChange.send()
    }

    func refreshVersionManager(_ source: String, force: Bool = false) async {
        switch source {
        case "Static": await loadStatic(force: force)
        case "MacPorts": await loadPortItems(force: force)
        default: await refresh()
        }
    }

    // MARK: - MacPorts 清单（加载与装/卸在 PortListHost 协议扩展里）

    @Published var portItems: [PortItem] = []
    @Published var portLoading = false
    var portApp: String { "python" }

    // MARK: - 环境变量

    // PATH 上加的是 shim 目录（里面 python / python3 / python3.x 三个名字都齐），不是 Python Home
    // —— Home 里从来没有同时在的两个名字，直接加 Home 的话用户敲另一个就找不到解释器。
    private func shimDirectory(_ version: PythonVersion) -> URL { services.python.shimDirectory(for: version) }

    private func membership(_ version: PythonVersion) -> PathMembership {
        services.paths.membership(kind: "python", directory: shimDirectory(version))
    }

    func togglePath(_ version: PythonVersion) {
        state.run {
            // shim 必须在 toggle 之前建好：env/python 要指向它，而软链得按当前版本重建。
            let directory = try self.services.python.shim(for: version)
            try self.services.paths.toggle(kind: "python", directory: directory)
            try await self.services.paths.refresh(force: true)
            self.pathMembership = Dictionary(uniqueKeysWithValues: self.versions.map { ($0.id, self.membership($0)) })
            self.state.message = String(format: L(self.membership(version) == .app ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Python \(version.version)")
        }
    }

    // 版本被删掉之后（brew uninstall 我们不知道什么时候发生）留下的 shim 死链，刷新时顺手清掉。
    private func pruneShims() {
        for directory in services.python.staleShims() {
            try? services.paths.removeLinks(pointingInside: directory)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Static

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("python").cached()
        do {
            staticVersions = try await services.catalog("python").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.installingFor"), "Python \(version.version)")) { report, attach in
            try await self.services.catalog("python").install(version, report: report, onStart: attach)
            await self.services.python.clearQuarantine(version)
            self.staticVersions = try await self.services.catalog("python").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.uninstallingFor"), "Python \(version.version)")) { _, _ in
            let directory = self.services.python.versionsDirectory.appendingPathComponent("python-\(version.version)")
            // 必须在删目录**之前**摘掉指向它内部的 shim 和 env/python 软链：目录没了之后
            // shim 解不出真身，就只能留一条死链，env/python 会指向一个空壳目录。
            for shim in self.services.python.shims(pointingInside: directory) {
                try? self.services.paths.removeLinks(pointingInside: shim)
                try? FileManager.default.removeItem(at: shim)
            }
            try self.services.catalog("python").uninstall(version)
            self.staticVersions = try await self.services.catalog("python").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func brewAction(_ action: String, formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh()
        }
    }
}
