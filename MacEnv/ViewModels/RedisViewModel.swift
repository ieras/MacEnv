import SwiftUI

@MainActor
final class RedisViewModel: ObservableObject {
    private let state: AppState
    private let services: Services

    @Published var versions: [RedisVersion] = []
    @Published var formulae: [BrewFormulaItem] = []
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selected = ""
    @Published var configText = ""
    @Published var logText = ""
    @Published var customDirectories: [String] = {
        guard let data = UserDefaults.standard.data(forKey: "macenv.redis.directories"),
              let value = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return value
    }() {
        didSet { if let data = try? JSONEncoder().encode(customDirectories) { UserDefaults.standard.set(data, forKey: "macenv.redis.directories") } }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    func selectedVersion() -> RedisVersion? { versions.first { $0.id == selected } ?? versions.first }

    func configURL(_ version: RedisVersion) -> URL { services.redis.configURL(for: version) }
    func dataURL(_ version: RedisVersion) -> URL { services.redis.dataURL(for: version) }
    func logURL() -> URL? { selectedVersion().map { services.redis.logFile(for: $0) } }
    func port(_ version: RedisVersion) -> Int { services.redis.port(for: version) }
    func running(_ version: RedisVersion) -> Bool { services.redis.running(version) }

    func refresh() async {
        do {
            let service = services.redis
            let found = try await service.installedVersions(customDirectories: customDirectories)

            for version in found { try service.prepare(version) }
            versions = found
            await service.adopt(found)
            try await services.paths.refresh()
            pathMembership = Dictionary(uniqueKeysWithValues: found.map { ($0.id, services.paths.membership(kind: "redis", directory: $0.directory)) })
            // brew 丢后台慢慢填，别拖住 refresh 返回。
            Task { formulae = (try? await service.brewFormulae()) ?? formulae }
            if !found.contains(where: { $0.id == selected }) { selected = found.first?.id ?? "" }
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    func operate(_ operation: String, _ version: RedisVersion) async {
        guard !state.busy else { return }
        selected = version.id
        let service = services.redis
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
            state.message = "Redis " + (operation == "start" ? L("message.started") : L("message.stopped"))
            await refresh()
        } catch {
            state.message = error.localizedDescription
        }
    }

    func togglePath(_ version: RedisVersion) {
        guard !state.busy else { return }
        state.busy = true
        Task {
            defer { state.busy = false }
            do {
                try services.paths.toggle(kind: "redis", directory: version.directory)
                try await services.paths.refresh(force: true)
                pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "redis", directory: $0.directory)) })
                let enabled = pathMembership[version.id] == .app
                state.message = String(format: L(enabled ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Redis " + version.version)
            } catch {
                state.message = error.localizedDescription
            }
        }
    }

    func brewAction(_ action: String, _ formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            if action == "uninstall" { try await self.services.redis.stop() }
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh()
        }
    }

    func loadConfig() {
        guard let version = selectedVersion() else { return }
        do {
            try services.redis.prepare(version)
            configText = try String(contentsOf: configURL(version), encoding: .utf8)
        } catch { state.message = error.localizedDescription }
    }

    func saveConfig() {
        guard let version = selectedVersion() else { return }
        do {
            try configText.write(to: configURL(version), atomically: true, encoding: .utf8)
            state.message = L("message.configSaved")
        } catch { state.message = error.localizedDescription }
    }

    func loadLog() {
        guard let version = selectedVersion() else { logText = ""; return }
        logText = services.redis.log(version)
    }

    func setCustomDirectories(_ paths: [String]) {
        customDirectories = paths
        Task { await refresh() }
    }
}

extension RedisViewModel: ServiceManageable {
    var kind: String { "redis" }
    var targets: [LaunchTarget] { versions.map { LaunchTarget(key: $0.id, kind: "redis", versionID: $0.id, title: "Redis " + $0.version) } }
    func isRunning(_ versionID: String) -> Bool { versions.first { $0.id == versionID }.map { running($0) } ?? false }
    func port(_ versionID: String) -> String? { versions.first { $0.id == versionID }.map { String(port($0)) } }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        await operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        if action == "stop" { try await services.redis.stop() } else { try await services.redis.start(version) }
    }
    func stopAll() async { try? await services.redis.stop() }
    func membership(_ versionID: String) -> PathMembership { pathMembership[versionID] ?? .none }
    func togglePath(_ versionID: String) {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        togglePath(version)
    }
}
