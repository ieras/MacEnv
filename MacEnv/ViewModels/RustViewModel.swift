import SwiftUI

@MainActor
final class RustViewModel: ObservableObject, PortListHost {
    let state: AppState
    let services: Services

    @Published var versions: [RustVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var formulae: [BrewFormulaItem] = []
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selectedID: String?
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.rust.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.rust.directories") }
    }

    @Published var rustupInstalled: Bool?
    @Published var rustupPath = ""

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: RustVersion? { versions.first { $0.id == selectedID } ?? versions.first }

    func refresh() async {
        do {
            try await services.paths.refresh()
            versions = await services.rust.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "rust", directory: $0.directory)) })
            pruneEnvLink()
        } catch {
            state.message = error.localizedDescription
        }
        Task {
            do { formulae = try await Brew.formulae("rust") }
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
    var portApp: String { "rust" }

    // MARK: - PATH

    func togglePath(_ version: RustVersion) {
        state.run {
            try self.services.paths.toggle(kind: "rust", directory: version.directory)
            try await self.services.paths.refresh(force: true)
            self.pathMembership = Dictionary(uniqueKeysWithValues: self.versions.map { ($0.id, self.services.paths.membership(kind: "rust", directory: $0.directory)) })
            self.state.message = String(format: L(self.services.paths.membership(kind: "rust", directory: version.directory) == .app ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Rust \(version.version)")
        }
    }

    private func pruneEnvLink() {
        let fm = FileManager.default
        let link = services.paths.envDirectory.appendingPathComponent("rust")
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return }
        let target = URL(fileURLWithPath: destination, relativeTo: link).standardizedFileURL
        guard !fm.isExecutableFile(atPath: target.appendingPathComponent("bin/rustc").path) else { return }
        try? services.paths.removeLinks(pointingInside: target)
    }

    // MARK: - Static

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("rust").cached()
        do {
            staticVersions = try await services.catalog("rust").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.installingFor"), "Rust \(version.version)")) { report, attach in
            try await self.services.rust.install(version, report: report, onStart: attach)
            await self.services.rust.clearQuarantine(version)
            self.staticVersions = try await self.services.catalog("rust").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.uninstallingFor"), "Rust \(version.version)")) { _, _ in
            try self.services.rust.uninstall(version)
            self.staticVersions = try await self.services.catalog("rust").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func brewAction(_ action: String, formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh()
        }
    }

    // MARK: - rustup

    func checkRustup() {
        Task {
            let installed = await services.rust.rustupInstalled()
            rustupInstalled = installed
            rustupPath = ""
            if installed { rustupPath = await services.rust.cargoHome().path }
        }
    }

    func rustupAction(_ action: String, _ version: String) {
        guard !version.isEmpty else { return }
        let title: String
        let arguments: [String]
        switch action {
        case "alias":
            title = String(format: L("rust.setDefaultTitle"), version)
            arguments = ["default", version]
        case "install":
            title = String(format: L("message.installingFor"), "rustup \(version)")
            arguments = ["toolchain", "install", version]
        default:
            title = String(format: L("message.uninstallingFor"), "rustup \(version)")
            arguments = ["toolchain", "uninstall", version]
        }
        state.runStreaming(title) { report, attach in
            try await self.services.rust.rustup(arguments, onStart: attach, onOutput: report)
            await self.refresh()
        }
    }

    // MARK: - 本体装卸（安装 / 更新 / 卸载 rustup 自己）

    func rustupSelfAction(_ action: String) {
        if action == "uninstall" {
            state.runStreaming(String(format: L("tools.uninstallManager"), "rustup")) { report, attach in
                try? self.services.paths.removeLinks(pointingInside: await self.services.rust.rustupHome())
                try await self.services.rust.uninstallManager(onStart: attach, onOutput: report)
                await self.checkRustup()
                await self.refresh()
            }
        } else {
            let title = String(format: L(action == "install" ? "rust.installingManager" : "rust.updatingManager"), "rustup")
            state.runStreaming(title) { report, attach in
                try await self.services.rust.installManager(onStart: attach, onOutput: report)
                await self.checkRustup()
                await self.refresh()
            }
        }
    }
}
