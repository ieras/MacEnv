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
            // 先问一次登录 shell 拿真实 PATH；GUI 启动的 app 继承不到用户 rc 里改过的 PATH。
            try await services.paths.refresh()
            // PATH 里的目录也一起扫：用户可能在别处（~/composer/bin 之类）装了 composer，
            // shell 里能跑、MacEnv 里却看不到。
            versions = try services.composer.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "composer", directory: $0.directory)) })
            // brew 丢后台慢慢填，别拖住 refresh 返回（同 PhpViewModel）。
            Task { formulae = (try? await Brew.formulae("composer")) ?? formulae }
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
        state.run {
            try await self.services.composer.install(version)
            self.staticVersions = try await self.services.catalog("composer").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
            self.state.message = "Composer \(version.version) " + L("message.installed")
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        state.run {
            try self.services.composer.uninstall(version)
            self.staticVersions = try await self.services.catalog("composer").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
            self.state.message = "Composer \(version.version) " + L("message.uninstalled")
        }
    }

    func brewAction(_ action: String, formula: String) {
        state.run {
            _ = try await Brew.run(action, formula: formula)
            await self.refresh()
        }
    }
}
