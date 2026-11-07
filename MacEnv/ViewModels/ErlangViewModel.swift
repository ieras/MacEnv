import SwiftUI

@MainActor
final class ErlangViewModel: ObservableObject, PortListHost {
    let state: AppState
    let services: Services

    @Published var versions: [ErlangVersion] = []
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
            try await services.paths.refresh()
            versions = await services.erlang.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "erlang", directory: $0.directory)) })
        } catch {
            state.message = error.localizedDescription
        }
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
