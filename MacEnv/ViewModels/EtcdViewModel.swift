import SwiftUI

@MainActor
final class EtcdViewModel: ObservableObject {
    let state: AppState
    let services: Services

    @Published var versions: [EtcdVersion] = []
    @Published var formulae: [BrewFormulaItem] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selected = ""
    @Published var configText = ""
    @Published var logText = ""
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.etcd.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.etcd.directories") }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    func selectedVersion() -> EtcdVersion? { versions.first { $0.id == selected } ?? versions.first }

    // 端口按版本读（配置是每主版本一份），表格每行显示自己那份配置里的值。
    func port(_ version: EtcdVersion) -> String {
        let ports = services.etcd.ports(version)
        return "\(ports.client) / \(ports.peer)"
    }

    func dataURL(_ version: EtcdVersion) -> URL { services.etcd.dataDirectory(version) }
    func logURL() -> URL { services.etcd.logFile() }
    func running(_ version: EtcdVersion) -> Bool { services.etcd.running(version) }
    func configURL() -> URL? { selectedVersion().map { services.etcd.configFile($0) } }

    func refresh() async {
        do {
            try await services.paths.refresh()
            let service = services.etcd
            let found = try await service.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            versions = found
            await service.adopt(found)
            pathMembership = Dictionary(uniqueKeysWithValues: found.map { ($0.id, services.paths.membership(kind: "etcd", directory: $0.directory)) })
            // brew 清单丢后台慢慢填，别拖住 refresh 返回。
            Task {
                do { formulae = try await service.brewFormulae() }
                catch { state.message = error.localizedDescription }
            }
            if !found.contains(where: { $0.id == selected }) { selected = found.first?.id ?? "" }
            // 选中的版本先把配置落好：配置是「已存在就不覆盖」，不先落一份的话用户第一次进
            // 「配置」tab 看到的是空白编辑器，手一滑保存就把空内容写进去，etcd 之后起不来（同 Consul / ClickHouse）。
            if let version = selectedVersion() { try service.prepare(version) }
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    func operate(_ operation: String, _ version: EtcdVersion) async {
        guard !state.busy else { return }
        guard !state.isChanging(version.directory) else { state.message = L("message.taskInProgress"); return }
        selected = version.id
        let service = services.etcd
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
            // restart 落到 start：start 里会先把还在跑的实例收掉。
            if operation != "stop" { try await service.start(version) }
            else { try await service.stop() }
            state.message = "etcd " + (operation == "start" ? L("message.started") : L("message.stopped"))
            await refresh()
        } catch {
            state.message = error.localizedDescription
        }
    }

    func togglePath(_ version: EtcdVersion) {
        state.run { [self] in
            try services.paths.toggle(kind: "etcd", directory: version.directory)
            try await services.paths.refresh(force: true)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "etcd", directory: $0.directory)) })
            let enabled = pathMembership[version.id] == .app
            state.message = String(format: L(enabled ? "message.pathEnabledFor" : "message.pathDisabledFor"), "etcd " + version.version)
        }
    }

    func brewAction(_ action: String, _ formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            if action == "uninstall" { try await self.services.etcd.stop() }
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh()
        }
    }

    // MARK: - 静态包（来源之一：one-env 给的官方 GitHub release zip）

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("etcd").cached()
        do {
            staticVersions = try await services.catalog("etcd").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        let target = services.etcd.versionsDirectory.appendingPathComponent("etcd-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.installingFor"), "etcd \(version.version)"), packageDirectory: target) { report, attach in
            try await self.services.catalog("etcd").install(version, report: report, onStart: attach)
            self.staticVersions = try await self.services.catalog("etcd").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        let target = services.etcd.versionsDirectory.appendingPathComponent("etcd-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.uninstallingFor"), "etcd \(version.version)"), packageDirectory: target) { _, _ in
            try self.services.catalog("etcd").uninstall(version)
            self.staticVersions = try await self.services.catalog("etcd").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    // MARK: - 配置 / 日志

    func loadConfig() {
        guard let version = selectedVersion() else {
            configText = ""
            return
        }
        // 进配置页时顺手补一份：没装版本时没有落点，装完 refresh 已经落过了。
        try? services.etcd.prepare(version)
        configText = services.etcd.configText(version)
    }

    func saveConfig() {
        guard let url = configURL() else { return }
        do {
            try configText.write(to: url, atomically: true, encoding: .utf8)
            state.message = L("message.configSaved")
        } catch { state.message = error.localizedDescription }
    }

    func loadLog() { logText = services.etcd.log() }

    func setCustomDirectories(_ paths: [String]) {
        customDirectories = paths
        Task { await refresh() }
    }
}

extension EtcdViewModel: ServiceManageable {
    var kind: String { "etcd" }
    var targets: [LaunchTarget] { versions.map { LaunchTarget(key: $0.id, kind: "etcd", versionID: $0.id, title: "etcd " + $0.version) } }
    func isRunning(_ versionID: String) -> Bool { versions.first { $0.id == versionID }.map { running($0) } ?? false }
    func port(_ versionID: String) -> String? { versions.first { $0.id == versionID }.map { port($0) } }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        await operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        guard !state.isChanging(version.directory) else { throw CommandError(message: L("message.taskInProgress")) }
        if action == "stop" { try await services.etcd.stop() } else { try await services.etcd.start(version) }
    }
    func stopAll() async { try? await services.etcd.stop() }
    func membership(_ versionID: String) -> PathMembership { pathMembership[versionID] ?? .none }
    func togglePath(_ versionID: String) {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        togglePath(version)
    }
}
