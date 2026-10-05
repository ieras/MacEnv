import SwiftUI

@MainActor
final class SwooleViewModel: ObservableObject {
    private let state: AppState
    private let services: Services

    @Published var versions: [SwooleVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selectedID: String?
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.swoole.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.swoole.directories") }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: SwooleVersion? { versions.first { $0.id == selectedID } ?? versions.first }

    func refresh() async {
        do {
            versions = try await services.swoole.installedVersions(customDirectories: customDirectories)
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
            try await services.paths.refresh()
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "swoole", directory: $0.directory)) })
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    func togglePath(_ version: SwooleVersion) {
        state.run {
            try self.services.paths.toggle(kind: "swoole", directory: version.directory)
            try await self.services.paths.refresh(force: true)
            self.pathMembership = Dictionary(uniqueKeysWithValues: self.versions.map { ($0.id, self.services.paths.membership(kind: "swoole", directory: $0.directory)) })
            self.state.message = String(format: L(self.services.paths.membership(kind: "swoole", directory: version.directory) == .app ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Swoole CLI \(version.version)")
        }
    }

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("swoole-cli").cached()
        do {
            staticVersions = try await services.catalog("swoole-cli").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        state.run {
            try await self.services.swoole.install(version)
            self.staticVersions = try await self.services.catalog("swoole-cli").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
            self.state.message = "Swoole CLI \(version.version) " + L("message.installed")
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        state.run {
            try self.services.catalog("swoole-cli").uninstall(version)
            self.staticVersions = try await self.services.catalog("swoole-cli").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
            self.state.message = "Swoole CLI \(version.version) " + L("message.uninstalled")
        }
    }
}
