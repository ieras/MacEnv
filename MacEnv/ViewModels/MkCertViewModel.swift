import SwiftUI

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
    @Published var caExists = false
    @Published var caTrusted = false
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
            try await services.paths.refresh()
            versions = try await services.mkcert.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "mkcert", directory: $0.directory)) })
        } catch {
            state.message = error.localizedDescription
        }
        if !versions.contains(where: { $0.id == selected }) { selected = versions.first?.id ?? "" }
        await loadCaroot()
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

    func uninstallCA() {
        guard let version = selectedVersion else { state.message = L("mkcert.noVersion"); return }
        state.run {
            try await self.services.mkcert.uninstallCA(version)
            await self.loadCaroot()
            self.state.message = L("mkcert.caUninstalled")
        }
    }

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
