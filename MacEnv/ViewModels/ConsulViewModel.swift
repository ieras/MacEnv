import SwiftUI

@MainActor
final class ConsulViewModel: ObservableObject {
    let state: AppState
    let services: Services

    @Published var versions: [ConsulVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var portItems: [PortItem] = []
    @Published var portLoading = false
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selectedID: String?
    @Published var configText = ""
    @Published var logText = ""
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.consul.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.consul.directories") }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: ConsulVersion? { versions.first { $0.id == selectedID } ?? versions.first }

    // 端口按版本读（配置是每主版本一份），表格每行显示自己那份配置里的值。
    func port(_ version: ConsulVersion) -> String {
        let ports = services.consul.ports(version)
        return "\(ports.http) / \(ports.dns)"
    }

    // 数据目录按主版本分：Consul 的 raft 存储格式跨大版本不保证兼容。
    func dataURL(_ version: ConsulVersion) -> URL { services.consul.dataDirectory(version) }
    func logURL() -> URL { services.consul.logFile() }
    func running(_ version: ConsulVersion) -> Bool { services.consul.running(version) }
    func configURL() -> URL? { selectedVersion.map { services.consul.configFile($0) } }

    func refresh() async {
        do {
            let service = services.consul
            try await services.paths.refresh()
            versions = try await service.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            await service.adopt(versions)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "consul", directory: $0.directory)) })
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
            // 选中的版本先把配置落好：配置是「已存在就不覆盖」，不先落一份的话用户第一次进
            // 「配置」tab 看到的是空白编辑器，手一滑保存就把空内容写进去，Consul 之后起不来（同 ClickHouse）。
            if let version = selectedVersion { try service.prepare(version) }
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    func operate(_ operation: String, _ version: ConsulVersion) async {
        guard !state.busy else { return }
        guard !state.isChanging(version.directory) else { state.message = L("message.taskInProgress"); return }
        selectedID = version.id
        let service = services.consul
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
            state.message = "Consul " + (operation == "start" ? L("message.started") : L("message.stopped"))
            await refresh()
        } catch {
            state.message = error.localizedDescription
        }
    }

    func togglePath(_ version: ConsulVersion) {
        state.run { [self] in
            try services.paths.toggle(kind: "consul", directory: version.directory)
            try await services.paths.refresh(force: true)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "consul", directory: $0.directory)) })
            let enabled = pathMembership[version.id] == .app
            state.message = String(format: L(enabled ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Consul " + version.version)
        }
    }

    // Consul 自带 Web UI（:8500/ui，靠配置里的 ui_config.enabled 打开）。
    func openWebUI(_ version: ConsulVersion) {
        NSWorkspace.shared.open(services.consul.webUI(version))
    }

    // MARK: - 静态包（来源之一：one-env 的 zip）

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("consul").cached()
        do {
            staticVersions = try await services.catalog("consul").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        let target = services.consul.versionsDirectory.appendingPathComponent("consul-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.installingFor"), "Consul \(version.version)"), packageDirectory: target) { report, attach in
            try await self.services.catalog("consul").install(version, report: report, onStart: attach)
            self.staticVersions = try await self.services.catalog("consul").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        let target = services.consul.versionsDirectory.appendingPathComponent("consul-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.uninstallingFor"), "Consul \(version.version)"), packageDirectory: target) { _, _ in
            try self.services.catalog("consul").uninstall(version)
            self.staticVersions = try await self.services.catalog("consul").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    // MARK: - 配置 / 日志

    func loadConfig() {
        guard let version = selectedVersion else {
            configText = ""
            return
        }
        // 进配置页时顺手补一份：没装版本时没有落点，装完 refresh 已经落过了。
        try? services.consul.prepare(version)
        configText = services.consul.configText(version)
    }

    func saveConfig() {
        guard let url = configURL() else { return }
        do {
            try configText.write(to: url, atomically: true, encoding: .utf8)
            state.message = L("message.configSaved")
        } catch { state.message = error.localizedDescription }
    }

    func loadLog() { logText = services.consul.log() }

    func setCustomDirectories(_ paths: [String]) {
        customDirectories = paths
        Task { await refresh() }
    }
}

// 版本管理页的 MacPorts 一栏：加载与装/卸走 ToolService.portCatalogs["consul"]。
extension ConsulViewModel: PortListHost {
    var portApp: String { "consul" }
}

extension ConsulViewModel: ServiceManageable {
    var kind: String { "consul" }
    var targets: [LaunchTarget] { versions.map { LaunchTarget(key: $0.id, kind: "consul", versionID: $0.id, title: "Consul " + $0.version) } }
    func isRunning(_ versionID: String) -> Bool { versions.first { $0.id == versionID }.map { running($0) } ?? false }
    func port(_ versionID: String) -> String? { versions.first { $0.id == versionID }.map { port($0) } }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        await operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        guard !state.isChanging(version.directory) else { throw CommandError(message: L("message.taskInProgress")) }
        if action == "stop" { try await services.consul.stop() } else { try await services.consul.start(version) }
    }
    func stopAll() async { try? await services.consul.stop() }
    func membership(_ versionID: String) -> PathMembership { pathMembership[versionID] ?? .none }
    func togglePath(_ versionID: String) {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        togglePath(version)
    }
}
