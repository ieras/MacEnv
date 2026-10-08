import SwiftUI

@MainActor
final class ClickHouseViewModel: ObservableObject {
    let state: AppState
    let services: Services

    @Published var versions: [ClickHouseVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selectedID: String?
    @Published var configText = ""
    @Published var logText = ""
    // 配置页要在 config.xml 和 users.xml 之间切，两个都是 MacEnv 自己生成的用户可编辑文件。
    @Published var configTarget = "config.xml"
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.clickhouse.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.clickhouse.directories") }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: ClickHouseVersion? { versions.first { $0.id == selectedID } ?? versions.first }

    // 配置单份、不分版本，所以端口跟选哪个版本无关；一次读全，别让表格每行读两遍盘。
    func port(_ version: ClickHouseVersion) -> String {
        let ports = services.clickhouse.ports()
        return "\(ports.http) / \(ports.tcp)"
    }

    func dataURL() -> URL { services.clickhouse.dataDirectory }
    func logURL() -> URL { services.clickhouse.logFile() }
    func running(_ version: ClickHouseVersion) -> Bool { services.clickhouse.running(version) }
    func configURL() -> URL {
        configTarget == "users.xml" ? services.clickhouse.usersFile : services.clickhouse.configFile
    }

    func refresh() async {
        do {
            try await services.paths.refresh()
            let service = services.clickhouse
            // 配置是全局单份、且「已存在就不覆盖」—— 不先落一份的话，用户第一次进「配置」tab
            // 看到的是空白编辑器，手一滑保存就把空内容写进 config.xml；之后 prepare 见文件
            // 已存在不再生成，ClickHouse 直接起不来。所以刷新时就把配置落好（同 Qdrant）。
            try service.prepare()
            // 版本来源只认 MacEnv 自己管的目录 + 用户自定义目录 —— 跟 Redis / Database /
            // PostgreSQL / Qdrant 一致，不把用户的 shell PATH 当版本来源（FlyEnv 也只认
            // setup 里的 dirs）。所以 paths.refresh() 排在扫描之后，只喂下面的 membership。
            versions = try await service.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            await service.adopt(versions)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "clickhouse", directory: $0.directory)) })
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    func operate(_ operation: String, _ version: ClickHouseVersion) async {
        guard !state.busy else { return }
        guard !state.isChanging(version.directory) else { state.message = L("message.taskInProgress"); return }
        selectedID = version.id
        let service = services.clickhouse
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
            state.message = "ClickHouse " + (operation == "start" ? L("message.started") : L("message.stopped"))
            await refresh()
        } catch {
            state.message = error.localizedDescription
        }
    }

    func togglePath(_ version: ClickHouseVersion) {
        state.run { [self] in
            try services.paths.toggle(kind: "clickhouse", directory: version.directory)
            try await services.paths.refresh(force: true)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "clickhouse", directory: $0.directory)) })
            let enabled = pathMembership[version.id] == .app
            state.message = String(format: L(enabled ? "message.pathEnabledFor" : "message.pathDisabledFor"), "ClickHouse " + version.version)
        }
    }

    // MARK: - 静态包（唯一来源：Homebrew 只有 cask、MacPorts 没有 port）

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("clickhouse").cached()
        do {
            staticVersions = try await services.catalog("clickhouse").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        let target = services.clickhouse.versionsDirectory.appendingPathComponent("clickhouse-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.installingFor"), "ClickHouse \(version.version)"), packageDirectory: target) { report, attach in
            try await self.services.catalog("clickhouse").install(version, report: report, onStart: attach)
            self.staticVersions = try await self.services.catalog("clickhouse").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        let target = services.clickhouse.versionsDirectory.appendingPathComponent("clickhouse-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.uninstallingFor"), "ClickHouse \(version.version)"), packageDirectory: target) { _, _ in
            try self.services.catalog("clickhouse").uninstall(version)
            self.staticVersions = try await self.services.catalog("clickhouse").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func loadConfig() { configText = (try? String(contentsOf: configURL(), encoding: .utf8)) ?? "" }

    func saveConfig() {
        do {
            try configText.write(to: configURL(), atomically: true, encoding: .utf8)
            state.message = L("message.configSaved")
        } catch { state.message = error.localizedDescription }
    }

    func loadLog() { logText = services.clickhouse.log() }

    func setCustomDirectories(_ paths: [String]) {
        customDirectories = paths
        Task { await refresh() }
    }
}

extension ClickHouseViewModel: ServiceManageable {
    var kind: String { "clickhouse" }
    var targets: [LaunchTarget] { versions.map { LaunchTarget(key: $0.id, kind: "clickhouse", versionID: $0.id, title: "ClickHouse " + $0.version) } }
    func isRunning(_ versionID: String) -> Bool { versions.first { $0.id == versionID }.map { running($0) } ?? false }
    func port(_ versionID: String) -> String? { versions.first { $0.id == versionID }.map { port($0) } }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        await operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        guard !state.isChanging(version.directory) else { throw CommandError(message: L("message.taskInProgress")) }
        if action == "stop" { try await services.clickhouse.stop() } else { try await services.clickhouse.start(version) }
    }
    func stopAll() async { try? await services.clickhouse.stop() }
    func membership(_ versionID: String) -> PathMembership { pathMembership[versionID] ?? .none }
    func togglePath(_ versionID: String) {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        togglePath(version)
    }
}
