import SwiftUI

@MainActor
final class GoViewModel: ObservableObject, PortListHost {
    let state: AppState
    let services: Services

    @Published var versions: [GoVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var formulae: [BrewFormulaItem] = []
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selectedID: String?
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.go.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.go.directories") }
    }

    @Published var gvmInstalled: Bool?
    @Published var gvmVersions: [GvmVersion] = []
    @Published var gvmLoading = false
    @Published var gvmSearch = ""

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: GoVersion? { versions.first { $0.id == selectedID } ?? versions.first }

    var gvmRootPath: String { services.go.gvmRoot.path }
    var gvmInstalledCount: Int { gvmVersions.filter(\.installed).count }

    func refresh() async {
        do {
            try await services.paths.refresh()
            versions = try await services.go.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "go", directory: $0.directory)) })
        } catch {
            state.message = error.localizedDescription
        }
        Task {
            do { formulae = try await Brew.formulae("go") }
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
    var portApp: String { "golang" }

    func brewAction(_ action: String, formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh()
        }
    }

    func togglePath(_ version: GoVersion) {
        state.run {
            try self.services.paths.toggle(kind: "go", directory: version.directory)
            try await self.services.paths.refresh(force: true)
            self.pathMembership = Dictionary(uniqueKeysWithValues: self.versions.map { ($0.id, self.services.paths.membership(kind: "go", directory: $0.directory)) })
            self.state.message = String(format: L(self.services.paths.membership(kind: "go", directory: version.directory) == .app ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Go \(version.version)")
        }
    }

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("golang").cached()
        do {
            staticVersions = try await services.catalog("golang").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.installingFor"), "Go \(version.version)")) { report, attach in
            try await self.services.catalog("golang").install(version, report: report, onStart: attach)
            try await self.services.go.clearQuarantine(version)
            self.staticVersions = try await self.services.catalog("golang").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.uninstallingFor"), "Go \(version.version)")) { _, _ in
            try self.services.catalog("golang").uninstall(version)
            self.staticVersions = try await self.services.catalog("golang").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    // MARK: - GVM

    func checkGvm() {
        gvmInstalled = services.go.gvmInstalled
        if gvmInstalled == true { Task { await loadGvmVersions() } }
    }

    func loadGvmVersions() async {
        guard !gvmLoading else { return }
        gvmLoading = true
        defer { gvmLoading = false }
        do {
            gvmVersions = try await services.go.gvmVersions()
            gvmInstalled = true
        } catch {
            gvmInstalled = services.go.gvmInstalled
            state.message = error.localizedDescription
        }
    }

    func installGvm() {
        state.runStreaming(L("gvm.install")) { report, attach in
            try await self.services.go.installGvm(onStart: attach, onOutput: report)
            self.gvmInstalled = self.services.go.gvmInstalled
            await self.loadGvmVersions()
            await self.refresh()
        }
    }

    func uninstallGvm() {
        state.run {
            try self.services.paths.removeLinks(pointingInside: self.services.go.gvmRoot)
            try self.services.go.uninstallGvm()
            _ = try self.services.paths.removeLines(containing: "gvm", from: self.services.go.profileFiles)
            self.gvmInstalled = self.services.go.gvmInstalled
            self.gvmVersions = []
            self.gvmSearch = ""
            await self.refresh()
            self.state.message = L("message.gvmUninstalled")
        }
    }

    func gvm(_ action: GvmAction, version: GvmVersion) {
        let title = action == .install
            ? String(format: L("message.installingFor"), "Go \(version.version)")
            : action == .uninstall
                ? String(format: L("message.uninstallingFor"), "Go \(version.version)")
                : String(format: L("message.gvmDefaultSet"), version.version)
        state.runStreaming(title) { report, attach in
            try await self.services.go.gvm(action, version: version, onStart: attach, onOutput: report)
            await self.loadGvmVersions()
            await self.refresh()
        }
    }
}
