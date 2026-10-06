import SwiftUI

@MainActor
final class DatabaseViewModel: ObservableObject {
    private let state: AppState
    private let services: Services

    @Published var versions: [DatabaseKind: [DatabaseVersion]] = [:]
    @Published var formulae: [DatabaseKind: [BrewFormulaItem]] = [:]
    @Published var staticVersions: [DatabaseKind: [StaticVersion]] = [:]
    @Published var pathMembership: [DatabaseKind: [String: PathMembership]] = [:]
    @Published var selected: [DatabaseKind: String] = [:]
    @Published var configText = ""
    @Published var logText = ""
    @Published var customDirectories: [DatabaseKind: [String]] = {
        guard let data = UserDefaults.standard.data(forKey: "macenv.database.directories"),
              let value = try? JSONDecoder().decode([DatabaseKind: [String]].self, from: data) else { return [:] }
        return value
    }() {
        didSet { if let data = try? JSONEncoder().encode(customDirectories) { UserDefaults.standard.set(data, forKey: "macenv.database.directories") } }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    func selectedVersion(_ kind: DatabaseKind) -> DatabaseVersion? {
        guard let versions = versions[kind] else { return nil }
        return versions.first { $0.id == selected[kind] } ?? versions.first
    }

    func configURL(_ kind: DatabaseKind, _ version: DatabaseVersion) -> URL { services.database(kind).configURL(for: version) }
    func dataURL(_ kind: DatabaseKind, _ version: DatabaseVersion) -> URL { services.database(kind).dataURL(for: version) }
    func errorLogURL(_ kind: DatabaseKind) -> URL? { selectedVersion(kind).map { services.database(kind).errorLog(for: $0) } }
    func slowLogURL(_ kind: DatabaseKind) -> URL? { selectedVersion(kind).map { services.database(kind).slowLog(for: $0) } }
    func port(_ version: DatabaseVersion) -> Int { services.database(version.kind).port(for: version) }

    func running(_ kind: DatabaseKind) -> Bool { services.database(kind).runningVersion != nil }

    func running(_ version: DatabaseVersion) -> Bool { services.database(version.kind).running(version) }

    func refresh(_ kind: DatabaseKind) async {
        do {
            let service = services.database(kind)
            let found = try await service.installedVersions(customDirectories: customDirectories[kind, default: []])
            for version in found { try service.prepare(version) }
            versions[kind] = found
            await service.adopt(found)
            try await services.paths.refresh()
            pathMembership[kind] = Dictionary(uniqueKeysWithValues: found.map { ($0.id, services.paths.membership(kind: kind.rawValue, directory: $0.directory)) })
            // brew 丢后台慢慢填，别拖住 refresh 返回（同 PhpViewModel）。
            Task { formulae[kind] = (try? await service.brewFormulae()) ?? formulae[kind] }
            if !found.contains(where: { $0.id == selected[kind] }) { selected[kind] = found.first?.id }
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    func operate(_ operation: String, _ version: DatabaseVersion) async {
        guard !state.busy else { return }
        selected[version.kind] = version.id
        let service = services.database(version.kind)
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
            state.message = "\(version.kind.title) " + (operation == "start" ? L("message.started") : L("message.stopped"))
            await refresh(version.kind)
        } catch {
            state.message = error.localizedDescription
        }
    }

    func start(_ kind: DatabaseKind, _ version: DatabaseVersion) async throws {
        try await services.database(kind).start(version)
    }

    func stop(_ kind: DatabaseKind) async throws {
        try await services.database(kind).stop()
    }

    func togglePath(_ version: DatabaseVersion) {
        guard !state.busy else { return }
        state.busy = true
        Task {
            defer { state.busy = false }
            do {
                try services.paths.toggle(kind: version.kind.rawValue, directory: version.directory)
                try await services.paths.refresh(force: true)
                pathMembership[version.kind] = Dictionary(uniqueKeysWithValues: (versions[version.kind] ?? []).map { ($0.id, services.paths.membership(kind: version.kind.rawValue, directory: $0.directory)) })
                let enabled = pathMembership[version.kind]?[version.id] == .app
                state.message = String(format: L(enabled ? "message.pathEnabledFor" : "message.pathDisabledFor"), "\(version.kind.title) \(version.version)")
            } catch {
                state.message = error.localizedDescription
            }
        }
    }

    func refreshVersionManager(_ kind: DatabaseKind, _ source: String, force: Bool = false) async {
        if source == "Static" { await loadStatic(kind, force: force) } else { await refresh(kind) }
    }

    func loadStatic(_ kind: DatabaseKind, force: Bool = false) async {
        let catalog = services.catalog(kind.rawValue)
        staticVersions[kind] = catalog.cached()
        do { staticVersions[kind] = try await catalog.fetch(customEndpoint: state.catalogURL, force: force) }
        catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion, _ kind: DatabaseKind) {
        state.runStreaming(String(format: L("message.installingFor"), "\(kind.title) \(version.version)")) { report, attach in
            try await self.services.catalog(kind.rawValue).install(version, report: report, onStart: attach)
            await self.loadStatic(kind)
            await self.refresh(kind)
        }
    }

    func uninstallStatic(_ version: StaticVersion, _ kind: DatabaseKind) {
        state.runStreaming(String(format: L("message.uninstallingFor"), "\(kind.title) \(version.version)")) { _, _ in
            try self.services.catalog(kind.rawValue).uninstall(version)
            await self.loadStatic(kind)
            await self.refresh(kind)
        }
    }

    func brewAction(_ action: String, _ kind: DatabaseKind, _ formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            if action == "uninstall" { try await self.services.database(kind).stop() }
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh(kind)
        }
    }

    func loadConfig(_ kind: DatabaseKind) {
        guard let version = selectedVersion(kind) else { return }
        do {
            try services.database(kind).prepare(version)
            configText = try String(contentsOf: services.database(kind).configURL(for: version), encoding: .utf8)
        } catch { state.message = error.localizedDescription }
    }

    func saveConfig(_ kind: DatabaseKind) {
        guard let version = selectedVersion(kind) else { return }
        do {
            try configText.write(to: services.database(kind).configURL(for: version), atomically: true, encoding: .utf8)
            state.message = L("message.configSaved")
        } catch { state.message = error.localizedDescription }
    }

    func loadLog(_ kind: DatabaseKind, _ name: String) {
        guard let version = selectedVersion(kind) else { logText = ""; return }
        logText = services.database(kind).log(name, for: version)
    }

    func setCustomDirectories(_ paths: [String], for kind: DatabaseKind) {
        customDirectories[kind] = paths
        Task { await refresh(kind) }
    }
}

// 统一服务注册表条目：数据库一个 VM 管两个 kind，注册表按 kind 各挂一个。
@MainActor
struct DatabaseManageable: ServiceManageable {
    let dbKind: DatabaseKind
    let vm: DatabaseViewModel

    var kind: String { dbKind.rawValue }

    var targets: [LaunchTarget] {
        (vm.versions[dbKind] ?? []).map { LaunchTarget(key: $0.id, kind: dbKind.rawValue, versionID: $0.id, title: dbKind.title + " " + $0.version) }
    }
    func isRunning(_ versionID: String) -> Bool { (vm.versions[dbKind] ?? []).first { $0.id == versionID }.map { vm.running($0) } ?? false }
    func port(_ versionID: String) -> String? { (vm.versions[dbKind] ?? []).first { $0.id == versionID }.map { String(vm.port($0)) } }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = (vm.versions[dbKind] ?? []).first(where: { $0.id == versionID }) else { return }
        await vm.operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = (vm.versions[dbKind] ?? []).first(where: { $0.id == versionID }) else { return }
        if action == "stop" { try await vm.stop(dbKind) } else { try await vm.start(dbKind, version) }
    }
    func stopAll() async { try? await vm.stop(dbKind) }
    func membership(_ versionID: String) -> PathMembership { vm.pathMembership[dbKind]?[versionID] ?? .none }
    func togglePath(_ versionID: String) {
        guard let version = (vm.versions[dbKind] ?? []).first(where: { $0.id == versionID }) else { return }
        vm.togglePath(version)
    }
}
