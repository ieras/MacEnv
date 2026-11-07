import SwiftUI

@MainActor
final class ComposerViewModel: ObservableObject {
    private let state: AppState
    private let services: Services

    @Published var versions: [ComposerVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var formulae: [BrewFormulaItem] = []
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.composer.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.composer.directories") }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    func refresh() async {
        do {
            try await services.paths.refresh()
            versions = try services.composer.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "composer", directory: $0.directory)) })
            Task {
                do { formulae = try await Brew.formulae("composer") }
                catch { state.message = error.localizedDescription }
            }
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    func togglePath(_ version: ComposerVersion) {
        state.run {
            try self.services.paths.toggle(kind: "composer", directory: version.directory)
            try await self.services.paths.refresh(force: true)
            self.pathMembership = Dictionary(uniqueKeysWithValues: self.versions.map { ($0.id, self.services.paths.membership(kind: "composer", directory: $0.directory)) })
            self.state.message = String(format: L(self.services.paths.membership(kind: "composer", directory: version.directory) == .app ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Composer \(version.version)")
        }
    }

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("composer").cached()
        do {
            staticVersions = try await services.catalog("composer").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.installingFor"), "Composer \(version.version)")) { report, attach in
            try await self.services.composer.install(version, report: report, onStart: attach)
            self.staticVersions = try await self.services.catalog("composer").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.uninstallingFor"), "Composer \(version.version)")) { _, _ in
            try self.services.composer.uninstall(version)
            self.staticVersions = try await self.services.catalog("composer").fetch(customEndpoint: self.state.catalogURL)
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
