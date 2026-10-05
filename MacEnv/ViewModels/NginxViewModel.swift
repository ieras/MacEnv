import SwiftUI

@MainActor
final class NginxViewModel: ObservableObject {
    private let state: AppState
    private let services: Services

    @Published var versions: [NginxVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var formula: BrewFormula?
    @Published var selectedID: String?
    @Published var configText = ""
    @Published var logText = ""
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.nginx.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.nginx.directories") }
    }
    @Published var notes = UserDefaults.standard.dictionary(forKey: "macenv.nginx.notes") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(notes, forKey: "macenv.nginx.notes") }
    }
    @Published var aliases: [String: [ServiceAlias]] = [:] {
        didSet { if let data = try? JSONEncoder().encode(aliases) { UserDefaults.standard.set(data, forKey: "macenv.nginx.aliases") } }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
        if let data = UserDefaults.standard.data(forKey: "macenv.nginx.aliases"), let value = try? JSONDecoder().decode([String: [ServiceAlias]].self, from: data) {
            aliases = value
        }
    }

    var selectedVersion: NginxVersion? { versions.first { $0.id == selectedID } ?? versions.first }
    var configURL: URL { services.nginx.config }
    var defaultConfigURL: URL { services.nginx.defaultConfig }
    var errorLogURL: URL { services.nginx.errorLog }
    var accessLogURL: URL { services.nginx.accessLog }
    var aliasDirectory: URL { services.paths.aliasDirectory }

    func syncRunning() { objectWillChange.send() }

    func running(_ version: NginxVersion) -> Bool { services.nginx.running(version) }

    var isRunning: Bool { versions.contains { services.nginx.running($0) } }

    func refresh() async {
        do {
            try services.nginx.prepare()
            versions = try await services.nginx.installedVersions(customDirectories: customDirectories)
            await services.nginx.adopt(versions)
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
            try await services.paths.refresh()
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "nginx", directory: $0.directory)) })
            // brew 丢后台慢慢填，别拖住 refresh 返回（同 PhpViewModel）。
            Task { formula = (try? await services.nginx.brewFormula()) ?? formula }
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    func operate(_ operation: String, _ version: NginxVersion) async {
        guard !state.busy else { return }
        selectedID = version.id
        state.busy = true
        defer {
            state.busy = false
            objectWillChange.send()
        }
        do {
            switch operation {
            case "start", "restart":
                try await start(version)
                state.message = L("message.nginxStarted") + version.version
            case "stop":
                try await stop(version)
                state.message = L("message.nginxStopped")
            case "reload":
                try await services.nginx.reload(version)
                state.message = L("message.configReloaded")
            case "validate":
                state.message = try await services.nginx.validate(version)
            default: break
            }
        } catch {
            state.message = error.localizedDescription
        }
    }

    func start(_ version: NginxVersion) async throws {
        try await services.nginx.start(version, environment: services.paths.processEnvironment())
    }

    func stop(_ version: NginxVersion) async throws {
        guard services.nginx.running(version) else { return }
        try await services.nginx.stop()
    }

    func togglePath(_ version: NginxVersion) {
        guard !state.busy else { return }
        state.busy = true
        Task {
            defer { state.busy = false }
            do {
                try services.paths.toggle(kind: "nginx", directory: version.directory)
                try await services.paths.refresh(force: true)
                pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "nginx", directory: $0.directory)) })
                state.message = services.paths.membership(kind: "nginx", directory: version.directory) == .app ? L("message.pathEnabled") : L("message.pathDisabled")
            } catch {
                state.message = error.localizedDescription
            }
        }
    }

    func refreshVersionManager(_ source: String, force: Bool = false) async {
        if source == "Static" { await loadStatic(force: force) } else { await refresh() }
    }

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("nginx").cached()
        do {
            staticVersions = try await services.catalog("nginx").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        state.run {
            try await self.services.catalog("nginx").install(version)
            self.staticVersions = try await self.services.catalog("nginx").fetch(customEndpoint: self.state.catalogURL)
            self.versions = try await self.services.nginx.installedVersions(customDirectories: self.customDirectories)
            self.state.message = L("message.installed") + version.version
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        guard !state.busy else { return }
        if let installed = versions.first(where: { $0.version == version.version }), services.nginx.running(installed) {
            state.message = L("message.stopFirst")
            return
        }
        state.run {
            try self.services.catalog("nginx").uninstall(version)
            self.staticVersions = try await self.services.catalog("nginx").fetch(customEndpoint: self.state.catalogURL)
            self.versions = try await self.services.nginx.installedVersions(customDirectories: self.customDirectories)
            self.state.message = L("message.uninstalled") + version.version
        }
    }

    func brewAction(_ action: String) {
        state.run {
            if action == "uninstall" { try await self.services.nginx.stopAll() }
            self.state.message = try await Brew.run(action, formula: "nginx")
            await self.refresh()
        }
    }

    func loadConfig() {
        do { configText = try String(contentsOf: services.nginx.config, encoding: .utf8) }
        catch { state.message = error.localizedDescription }
    }

    func saveConfig() {
        do {
            try configText.write(to: services.nginx.config, atomically: true, encoding: .utf8)
            state.message = L("message.configSaved")
        } catch { state.message = error.localizedDescription }
    }

    func loadLog(_ kind: String) { logText = services.nginx.log(kind) }

    func saveAlias(_ version: NginxVersion, name: String, id: UUID? = nil) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var items = aliases[version.id, default: []]
        if let id, let index = items.firstIndex(where: { $0.id == id }) {
            if items.contains(where: { $0.id != id && $0.name == value }) { state.message = L("message.aliasExists"); return }
            try? services.paths.removeAlias(items[index])
            items[index] = ServiceAlias(id: id, name: value)
        } else {
            guard !items.contains(where: { $0.name == value }) else { state.message = L("message.aliasExists"); return }
            items.append(ServiceAlias(id: UUID(), name: value))
        }
        do {
            let item = id.flatMap { value in items.first(where: { $0.id == value }) } ?? items.last!
            try services.paths.saveAlias(item, executable: version.executable)
            aliases[version.id] = items
        } catch { state.message = error.localizedDescription }
    }

    func deleteAlias(_ version: NginxVersion, _ alias: ServiceAlias) {
        try? services.paths.removeAlias(alias)
        aliases[version.id]?.removeAll { $0.id == alias.id }
    }
}

// 统一服务注册表条目：Nginx。
extension NginxViewModel: ServiceManageable {
    var kind: String { "nginx" }
    var targets: [LaunchTarget] { versions.map { LaunchTarget(key: "nginx:" + $0.id, kind: "nginx", versionID: $0.id, title: "Nginx " + $0.version) } }
    func isRunning(_ versionID: String) -> Bool { versions.first { $0.id == versionID }.map { services.nginx.running($0) } ?? false }
    func port(_ versionID: String) -> String? { versions.contains { $0.id == versionID } ? services.nginx.port() : nil }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        await operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        if action == "stop" { try await stop(version) } else { try await start(version) }
    }
    func stopAll() async {
        do { try await services.nginx.stopAll() } catch { state.message = error.localizedDescription }
    }
    func membership(_ versionID: String) -> PathMembership { pathMembership[versionID] ?? .none }
    func togglePath(_ versionID: String) {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        togglePath(version)
    }
}
