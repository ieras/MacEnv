import SwiftUI

// MkCert 的版本管理 + 根 CA。mkcert 没有常驻进程，所以这里没有启停 / 端口 / 配置 / 日志那一套，
// 只有「装了哪些版本、根 CA 在哪、要不要把根 CA 装进钥匙串」。
@MainActor
final class MkCertViewModel: ObservableObject {
    private let state: AppState
    private let services: Services

    @Published var versions: [MkCertVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var formulae: [BrewFormulaItem] = []
    @Published var selected = ""
    @Published var caroot = ""
    // 根 CA 装没装、有没有被信任。装完 / 卸完都要重新查一次，不然界面看不出到底成没成。
    @Published var caExists = false
    @Published var caTrusted = false
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
            versions = try await services.mkcert.installedVersions(customDirectories: customDirectories)
        } catch {
            state.message = error.localizedDescription
        }
        if !versions.contains(where: { $0.id == selected }) { selected = versions.first?.id ?? "" }
        await loadCaroot()
        // brew 查不到（没装、或公式被 tap 挡了）不该把上面的扫描结果一起判成失败，
        // 丢后台慢慢填，别拖住 refresh 返回（同 Redis / Go）。
        Task { formulae = (try? await services.mkcert.brewFormulae()) ?? formulae }
        objectWillChange.send()
    }

    func refreshVersionManager(_ source: String, force: Bool = false) async {
        if source == "Static" { await loadStatic(force: force) } else { await refresh() }
    }

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
        state.run {
            try await self.services.catalog("mkcert").install(version)
            await self.loadStatic()
            await self.refresh()
            self.state.message = "mkcert \(version.version) " + L("message.installed")
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        state.run {
            try self.services.catalog("mkcert").uninstall(version)
            await self.loadStatic()
            await self.refresh()
            self.state.message = "mkcert \(version.version) " + L("message.uninstalled")
        }
    }

    func brewAction(_ action: String, _ formula: String) {
        state.run {
            _ = try await Brew.run(action, formula: formula)
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

    func setCustomDirectories(_ paths: [String]) {
        customDirectories = paths
        Task { await refresh() }
    }
}
