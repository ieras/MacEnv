import SwiftUI

// MkCert 的版本管理 + 根 CA。mkcert 没有常驻进程，所以这里没有启停 / 端口 / 配置 / 日志那一套，
// 只有「装了哪些版本、根 CA 在哪、要不要把根 CA 装进钥匙串」。
@MainActor
final class MkCertViewModel: ObservableObject, PortListHost {
    let state: AppState
    let services: Services

    @Published var versions: [MkCertVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var formulae: [BrewFormulaItem] = []
    @Published var selected = ""
    @Published var caroot = ""
    // 根 CA 装没装、有没有被信任。装完 / 卸完都要重新查一次，不然界面看不出到底成没成。
    @Published var caExists = false
    @Published var caTrusted = false
    // 每个已安装版本在 PATH 里是什么状态（MacEnv 挂的 / shell 里本来就有 / 没有）。
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.mkcert.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.mkcert.directories") }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: MkCertVersion? { versions.first { $0.id == selected } ?? versions.first }

    func refresh() async {
        do {
            // 先问一次登录 shell 拿真实 PATH；GUI 启动的 app 继承不到用户 rc 里改过的 PATH。
            try await services.paths.refresh()
            // PATH 里的目录也一起扫：用户可能在别处装了 mkcert，shell 里能跑、MacEnv 里却看不到。
            versions = try await services.mkcert.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "mkcert", directory: $0.directory)) })
        } catch {
            state.message = error.localizedDescription
        }
        if !versions.contains(where: { $0.id == selected }) { selected = versions.first?.id ?? "" }
        await loadCaroot()
        // brew 查不到（没装、或公式被 tap 挡了）不该把上面的扫描结果一起判成失败，
        // 丢后台慢慢填，别拖住 refresh 返回（同 Redis / Go）。
        Task {
            do { formulae = try await services.mkcert.brewFormulae() }
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
    var portApp: String { "mkcert" }

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("mkcert").cached()
        do {
            staticVersions = try await services.catalog("mkcert").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.installingFor"), "mkcert \(version.version)")) { report, attach in
            try await self.services.catalog("mkcert").install(version, report: report, onStart: attach)
            await self.loadStatic()
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.uninstallingFor"), "mkcert \(version.version)")) { _, _ in
            try self.services.catalog("mkcert").uninstall(version)
            await self.loadStatic()
            await self.refresh()
        }
    }

    func brewAction(_ action: String, _ formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh()
        }
    }

    // 根 CA 目录 + 状态。没装 mkcert 就没有这几项。
    func loadCaroot() async {
        guard let version = selectedVersion else { caroot = ""; caExists = false; caTrusted = false; return }
        caroot = await services.mkcert.caroot(version)
        caExists = await services.mkcert.caExists(version)
        caTrusted = await services.mkcert.caTrusted(version)
    }

    func installCA() {
        guard let version = selectedVersion else { state.message = L("mkcert.noVersion"); return }
        state.run {
            try await self.services.mkcert.installCA(version)
            await self.loadCaroot()
            self.state.message = L("mkcert.caInstalled")
        }
    }

    // 卸载会连 CA 文件一起删掉，之后得重新安装才能签证书 —— 界面上先确认一次。
    func uninstallCA() {
        guard let version = selectedVersion else { state.message = L("mkcert.noVersion"); return }
        state.run {
            try await self.services.mkcert.uninstallCA(version)
            await self.loadCaroot()
            self.state.message = L("mkcert.caUninstalled")
        }
    }

    // 把某个版本挂到 PATH 上（往 MacEnv 的 env 目录建软链，再重写 shell 配置块）。
    func togglePath(_ version: MkCertVersion) {
        state.run {
            try self.services.paths.toggle(kind: "mkcert", directory: version.directory)
            try await self.services.paths.refresh(force: true)
            self.pathMembership = Dictionary(uniqueKeysWithValues: self.versions.map { ($0.id, self.services.paths.membership(kind: "mkcert", directory: $0.directory)) })
            self.state.message = String(format: L(self.services.paths.membership(kind: "mkcert", directory: version.directory) == .app ? "message.pathEnabledFor" : "message.pathDisabledFor"), "MkCert \(version.version)")
        }
    }

    func setCustomDirectories(_ paths: [String]) {
        customDirectories = paths
        Task { await refresh() }
    }
}
