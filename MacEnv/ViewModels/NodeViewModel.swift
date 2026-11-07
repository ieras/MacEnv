import SwiftUI

@MainActor
final class NodeViewModel: ObservableObject, PortListHost {
    let state: AppState
    let services: Services

    @Published var versions: [NodeVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var formulae: [BrewFormulaItem] = []
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selectedID: String?
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.node.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.node.directories") }
    }

    @Published var nvmInstalled: Bool?
    @Published var fnmInstalled: Bool?
    @Published var nvmRootPath = ""
    @Published var fnmDirectoryPath = ""

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: NodeVersion? { versions.first { $0.id == selectedID } ?? versions.first }

    func refresh() async {
        do {
            try await services.paths.refresh()
            versions = await services.node.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "node", directory: $0.directory)) })
            pruneEnvLink()
        } catch {
            state.message = error.localizedDescription
        }
        Task {
            do { formulae = try await Brew.formulae("node") }
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
    var portApp: String { "node" }

    // MARK: - PATH

    func togglePath(_ version: NodeVersion) {
        state.run {
            try self.services.paths.toggle(kind: "node", directory: version.directory)
            try await self.services.paths.refresh(force: true)
            self.pathMembership = Dictionary(uniqueKeysWithValues: self.versions.map { ($0.id, self.services.paths.membership(kind: "node", directory: $0.directory)) })
            self.state.message = String(format: L(self.services.paths.membership(kind: "node", directory: version.directory) == .app ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Node \(version.version)")
        }
    }

    private func pruneEnvLink() {
        let fm = FileManager.default
        let link = services.paths.envDirectory.appendingPathComponent("node")
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return }
        let target = URL(fileURLWithPath: destination, relativeTo: link).standardizedFileURL
        guard !fm.isExecutableFile(atPath: target.appendingPathComponent("bin/node").path) else { return }
        try? services.paths.removeLinks(pointingInside: target)
    }

    // MARK: - Static

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("node").cached()
        do {
            staticVersions = try await services.catalog("node").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.installingFor"), "Node \(version.version)")) { report, attach in
            try await self.services.catalog("node").install(version, report: report, onStart: attach)
            await self.services.node.clearQuarantine(version)
            self.staticVersions = try await self.services.catalog("node").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.uninstallingFor"), "Node \(version.version)")) { _, _ in
            try self.services.catalog("node").uninstall(version)
            self.staticVersions = try await self.services.catalog("node").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func brewAction(_ action: String, formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh()
        }
    }

    // MARK: - nvm / fnm

    func checkManagers() {
        Task {
            let nvmRoot = await services.node.nvmRoot()
            nvmInstalled = FileManager.default.fileExists(atPath: nvmRoot.appendingPathComponent("nvm.sh").path)
            nvmRootPath = (nvmInstalled == true) ? nvmRoot.path : ""
            let fnmDir = await services.node.fnmDirectory()
            fnmInstalled = await services.node.fnmInstalled()
            fnmDirectoryPath = fnmDir?.path ?? ""
        }
    }

    func managerAction(_ manager: String, _ action: String, _ version: String) {
        guard !version.isEmpty else { return }
        let title: String
        let verb: String
        switch action {
        case "alias":
            title = String(format: L("node.setDefaultTitle"), manager, version)
            verb = manager == "nvm" ? "alias default" : "default"
        case "install":
            title = String(format: L("message.installingFor"), "\(manager) \(version)")
            verb = action
        default:
            title = String(format: L("message.uninstallingFor"), "\(manager) \(version)")
            verb = action
        }
        state.runStreaming(title) { report, attach in
            if manager == "nvm" {
                try await self.services.node.nvm(verb, version: version, onStart: attach, onOutput: report)
            } else {
                try await self.services.node.fnm(verb, version: version, onStart: attach, onOutput: report)
            }
            await self.refresh()
        }
    }

    // MARK: - 本体装卸（安装 / 更新 / 卸载 nvm / fnm 自己）

    func managerSelfAction(_ manager: String, _ action: String) {
        if action == "uninstall" {
            state.run {
                let directory: URL? = manager == "nvm" ? await self.services.node.nvmRoot() : await self.services.node.fnmDirectory()
                if let directory { try? self.services.paths.removeLinks(pointingInside: directory) }
                try await self.services.node.uninstallManager(manager)
                _ = try self.services.paths.removeLines(containing: manager, from: self.services.node.profileFiles)
                await self.checkManagers()
                await self.refresh()
            }
        } else {
            let title = String(format: L(action == "install" ? "node.installingManager" : "node.updatingManager"), manager)
            state.runStreaming(title) { report, attach in
                try await self.services.node.installManager(manager, onStart: attach, onOutput: report)
                await self.checkManagers()
                await self.refresh()
            }
        }
    }
}
