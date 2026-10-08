import SwiftUI

@MainActor
final class PostgresViewModel: ObservableObject, PortListHost {
    let state: AppState
    let services: Services

    @Published var versions: [PostgresVersion] = []
    @Published var formulae: [BrewFormulaItem] = []
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selected = ""
    @Published var configText = ""
    @Published var logText = ""
    @Published var customDirectories: [String] = {
        guard let data = UserDefaults.standard.data(forKey: "macenv.postgresql.directories"),
              let value = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return value
    }() {
        didSet { if let data = try? JSONEncoder().encode(customDirectories) { UserDefaults.standard.set(data, forKey: "macenv.postgresql.directories") } }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    func selectedVersion() -> PostgresVersion? { versions.first { $0.id == selected } ?? versions.first }

    func dataURL(_ version: PostgresVersion) -> URL { services.postgres.dataURL(for: version) }
    func logURL() -> URL? { selectedVersion().map { services.postgres.logFile(for: $0) } }
    func port(_ version: PostgresVersion) -> Int { services.postgres.port(for: version) }
    func running(_ version: PostgresVersion) -> Bool { services.postgres.running(version) }

    func refresh() async {
        do {
            let service = services.postgres
            let found = try await service.installedVersions(customDirectories: customDirectories)
            versions = found
            await service.adopt(found)
            try await services.paths.refresh()
            pathMembership = Dictionary(uniqueKeysWithValues: found.map { ($0.id, services.paths.membership(kind: "postgresql", directory: $0.directory)) })
            // brew 丢后台慢慢填，别拖住 refresh 返回。
            Task {
                do { formulae = try await service.brewFormulae() }
                catch { state.message = error.localizedDescription }
            }
            if !found.contains(where: { $0.id == selected }) { selected = found.first?.id ?? "" }
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    // MARK: - MacPorts 清单（加载与装/卸在 PortListHost 协议扩展里）

    @Published var portItems: [PortItem] = []
    @Published var portLoading = false
    var portApp: String { "postgresql" }

    func operate(_ operation: String, _ version: PostgresVersion) async {
        guard !state.busy else { return }
        selected = version.id
        let service = services.postgres
        if operation == "start", service.runningVersion != nil, !service.running(version) {
            state.message = L("message.databaseAlreadyRunning") + version.version
            return
        }
        state.busy = true
        defer {
            state.busy = false
            objectWillChange.send()
        }
        do {
            if operation != "stop" { try await service.start(version) }
            else { try await service.stop() }
            state.message = "PostgreSQL " + (operation == "start" ? L("message.started") : L("message.stopped"))
            await refresh()
        } catch {
            state.message = error.localizedDescription
        }
    }

    func togglePath(_ version: PostgresVersion) {
        state.run { [self] in
            try services.paths.toggle(kind: "postgresql", directory: version.directory)
            try await services.paths.refresh(force: true)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "postgresql", directory: $0.directory)) })
            let enabled = pathMembership[version.id] == .app
            state.message = String(format: L(enabled ? "message.pathEnabledFor" : "message.pathDisabledFor"), "PostgreSQL " + version.version)
        }
    }

    func brewAction(_ action: String, _ formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            if action == "uninstall" { try await self.services.postgres.stop() }
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh()
        }
    }

    // PG 的配置就是数据目录里的 postgresql.conf（initdb 生成），直接编辑它。
    func loadConfig() {
        guard let version = selectedVersion() else { configText = ""; return }
        configText = (try? String(contentsOf: services.postgres.configURL(for: version), encoding: .utf8)) ?? ""
    }

    func saveConfig() {
        guard let version = selectedVersion() else { return }
        do {
            try configText.write(to: services.postgres.configURL(for: version), atomically: true, encoding: .utf8)
            state.message = L("message.configSaved")
        } catch { state.message = error.localizedDescription }
    }

    func loadLog() {
        guard let version = selectedVersion() else { logText = ""; return }
        logText = services.postgres.log(version)
    }

    func setCustomDirectories(_ paths: [String]) {
        customDirectories = paths
        Task { await refresh() }
    }
}

extension PostgresViewModel: ServiceManageable {
    var kind: String { "postgresql" }
    var targets: [LaunchTarget] { versions.map { LaunchTarget(key: $0.id, kind: "postgresql", versionID: $0.id, title: "PostgreSQL " + $0.version) } }
    func isRunning(_ versionID: String) -> Bool { versions.first { $0.id == versionID }.map { running($0) } ?? false }
    func port(_ versionID: String) -> String? { versions.first { $0.id == versionID }.map { String(port($0)) } }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        await operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        if action == "stop" { try await services.postgres.stop() } else { try await services.postgres.start(version) }
    }
    func stopAll() async { try? await services.postgres.stop() }
    func membership(_ versionID: String) -> PathMembership { pathMembership[versionID] ?? .none }
    func togglePath(_ versionID: String) {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        togglePath(version)
    }
}
