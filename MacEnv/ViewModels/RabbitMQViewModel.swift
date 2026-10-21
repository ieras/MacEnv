import SwiftUI

@MainActor
final class RabbitMQViewModel: ObservableObject, PortListHost {
    let state: AppState
    let services: Services

    @Published var versions: [RabbitMQVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var pathMembership: [String: PathMembership] = [:]
    // 版本管理里的 Homebrew / MacPorts 两栏。
    @Published var formulae: [BrewFormulaItem] = []
    @Published var portItems: [PortItem] = []
    @Published var portLoading = false
    @Published var selected = ""
    @Published var configText = ""
    @Published var logText = ""
    // Erlang 装卸、换绑定时让 Erlang 列重算（绑定存在 UserDefaults 里，不是 @Published）。
    @Published private var erlangRevision = 0
    @Published var customDirectories: [String] = {
        guard let data = UserDefaults.standard.data(forKey: "macenv.rabbitmq.directories"),
              let value = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return value
    }() {
        didSet { if let data = try? JSONEncoder().encode(customDirectories) { UserDefaults.standard.set(data, forKey: "macenv.rabbitmq.directories") } }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    func selectedVersion() -> RabbitMQVersion? { versions.first { $0.id == selected } ?? versions.first }

    func configURL(_ version: RabbitMQVersion) -> URL { services.rabbitmq.configURL(for: version) }
    func mnesiaURL(_ version: RabbitMQVersion) -> URL { services.rabbitmq.mnesiaURL(for: version) }
    func logURL() -> URL? { selectedVersion().map { services.rabbitmq.logFile(for: $0) } }
    // AMQP（5672）给客户端驱动用，管理界面（15672）给浏览器用，两个都展示。
    func port(_ version: RabbitMQVersion) -> String {
        let ports = services.rabbitmq.ports(for: version)
        return "\(ports.amqp) / \(ports.management)"
    }
    func managementPort(_ version: RabbitMQVersion) -> Int { services.rabbitmq.ports(for: version).management }
    func running(_ version: RabbitMQVersion) -> Bool { services.rabbitmq.running(version) }

    func refresh() async {
        do {
            try await services.paths.refresh()
            let service = services.rabbitmq
            // Erlang 列表必须先就位：扫 RabbitMQ 版本要借一个 erl 跑 rabbitmqctl version
            // （escript 离不了 PATH 里的 erl），自动绑定也要从这份列表里挑。
            // Erlang 模块刷新同一批目录，这里单独刷一份（同 Neo4j 的 installedJava）。
            service.installedErlang = await services.erlang.installedVersions(customDirectories: services.paths.allPath)
            let found = try await service.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            for version in found { try service.prepare(version) }
            service.reconcileBindings(found)
            versions = found
            await service.adopt(found)
            pathMembership = Dictionary(uniqueKeysWithValues: found.map { ($0.id, services.paths.membership(kind: "rabbitmq", directory: $0.directory)) })
            if !found.contains(where: { $0.id == selected }) { selected = found.first?.id ?? "" }
            erlangRevision += 1
        } catch {
            state.message = error.localizedDescription
        }
        // brew 查不到（没装、或公式被 tap 挡了）不该把上面的扫描结果一起判成失败（同 GoViewModel）。
        Task {
            do { formulae = try await Brew.formulae("rabbitmq") }
            catch { state.message = error.localizedDescription }
        }
        objectWillChange.send()
    }

    // MARK: - Erlang 绑定

    func erlangCandidates(_ version: RabbitMQVersion) -> [ErlangVersion] {
        services.rabbitmq.erlangCandidates(version.version)
    }

    func selectedErlang(_ version: RabbitMQVersion) -> String { services.rabbitmq.binding(for: version) ?? "" }

    func setErlang(_ version: RabbitMQVersion, _ erlangHome: String) {
        guard !running(version) else { state.message = L("message.rabbitmqErlangWhileRunning"); return }
        services.rabbitmq.setBinding(version, erlangHome)
        erlangRevision += 1
    }

    // MARK: - 服务操作

    func operate(_ operation: String, _ version: RabbitMQVersion) async {
        guard !state.busy else { return }
        guard !state.isChanging(version.directory) else { state.message = L("message.taskInProgress"); return }
        selected = version.id
        let service = services.rabbitmq
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
            state.message = "RabbitMQ " + (operation == "start" ? L("message.started") : L("message.stopped"))
            await refresh()
        } catch {
            state.message = error.localizedDescription
        }
    }

    func togglePath(_ version: RabbitMQVersion) {
        state.run { [self] in
            try services.paths.toggle(kind: "rabbitmq", directory: version.directory)
            try await services.paths.refresh(force: true)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "rabbitmq", directory: $0.directory)) })
            let enabled = pathMembership[version.id] == .app
            state.message = String(format: L(enabled ? "message.pathEnabledFor" : "message.pathDisabledFor"), "RabbitMQ " + version.version)
        }
    }

    // MARK: - 版本管理（Homebrew / MacPorts）

    var portApp: String { "rabbitmq" }

    func brewAction(_ action: String, formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh()
        }
    }

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("rabbitmq").cached()
        do {
            staticVersions = try await services.catalog("rabbitmq").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        // StaticCatalogService 的落点是 versions/<app>-<版本>，整包（含 sbin/）搬过去。
        let target = services.rabbitmq.versionsDirectory.appendingPathComponent("rabbitmq-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.installingFor"), "RabbitMQ \(version.version)"), packageDirectory: target) { report, attach in
            try await self.services.catalog("rabbitmq").install(version, report: report, onStart: attach)
            self.staticVersions = try await self.services.catalog("rabbitmq").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        let target = services.rabbitmq.versionsDirectory.appendingPathComponent("rabbitmq-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.uninstallingFor"), "RabbitMQ \(version.version)"), packageDirectory: target) { _, _ in
            try await self.services.catalog("rabbitmq").uninstall(version)
            self.staticVersions = try await self.services.catalog("rabbitmq").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func loadConfig() {
        guard let version = selectedVersion() else { return }
        do {
            try services.rabbitmq.prepare(version)
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
        logText = services.rabbitmq.log(version)
    }

    func setCustomDirectories(_ paths: [String]) {
        customDirectories = paths
        Task { await refresh() }
    }
}

extension RabbitMQViewModel: ServiceManageable {
    var kind: String { "rabbitmq" }
    var targets: [LaunchTarget] { versions.map { LaunchTarget(key: $0.id, kind: "rabbitmq", versionID: $0.id, title: "RabbitMQ " + $0.version) } }
    func isRunning(_ versionID: String) -> Bool { versions.first { $0.id == versionID }.map { running($0) } ?? false }
    func port(_ versionID: String) -> String? { versions.first { $0.id == versionID }.map { port($0) } }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        await operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        guard !state.isChanging(version.directory) else { throw CommandError(message: L("message.taskInProgress")) }
        if action == "stop" { try await services.rabbitmq.stop() } else { try await services.rabbitmq.start(version) }
    }
    func stopAll() async { try? await services.rabbitmq.stop() }
    func membership(_ versionID: String) -> PathMembership { pathMembership[versionID] ?? .none }
    func togglePath(_ versionID: String) {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        togglePath(version)
    }
}
