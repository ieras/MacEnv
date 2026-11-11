import SwiftUI

@MainActor
final class MinioViewModel: ObservableObject {
    let state: AppState
    let services: Services

    @Published var versions: [MinioVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selectedID: String?
    @Published var configText = ""
    @Published var logText = ""
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.minio.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.minio.directories") }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: MinioVersion? { versions.first { $0.id == selectedID } ?? versions.first }

    func port(_ version: MinioVersion) -> String {
        let ports = services.minio.ports()
        return "\(ports.api) / \(ports.console)"
    }

    func dataURL() -> URL { services.minio.dataDirectory }
    func configURL() -> URL { services.minio.configFile }
    func logURL() -> URL { services.minio.logFile() }
    var consoleURL: URL { services.minio.consoleURL() }
    func running(_ version: MinioVersion) -> Bool { services.minio.running(version) }

    func refresh() async {
        do {
            try await services.paths.refresh()
            let service = services.minio
            try service.prepare()
            versions = try await service.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            await service.adopt(versions)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "minio", directory: $0.directory)) })
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    func operate(_ operation: String, _ version: MinioVersion) async {
        guard !state.busy else { return }
        guard !state.isChanging(version.directory) else { state.message = L("message.taskInProgress"); return }
        selectedID = version.id
        let service = services.minio
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
            state.message = "MinIO " + (operation == "start" ? L("message.started") : L("message.stopped"))
            await refresh()
        } catch {
            state.message = error.localizedDescription
        }
    }

    func togglePath(_ version: MinioVersion) {
        state.run { [self] in
            try services.paths.toggle(kind: "minio", directory: version.directory)
            try await services.paths.refresh(force: true)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "minio", directory: $0.directory)) })
            let enabled = pathMembership[version.id] == .app
            state.message = String(format: L(enabled ? "message.pathEnabledFor" : "message.pathDisabledFor"), "MinIO " + version.version)
        }
    }

    // MARK: - 静态包

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("minio").cached()
        do {
            staticVersions = try await services.catalog("minio").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        let target = services.minio.versionsDirectory.appendingPathComponent("minio-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.installingFor"), "MinIO \(version.version)"), packageDirectory: target) { report, attach in
            try await self.services.catalog("minio").install(version, report: report, onStart: attach)
            self.staticVersions = try await self.services.catalog("minio").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        let target = services.minio.versionsDirectory.appendingPathComponent("minio-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.uninstallingFor"), "MinIO \(version.version)"), packageDirectory: target) { _, _ in
            try self.services.catalog("minio").uninstall(version)
            self.staticVersions = try await self.services.catalog("minio").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    // MARK: - 配置与日志

    func loadConfig() { configText = (try? String(contentsOf: configURL(), encoding: .utf8)) ?? "" }

    func saveConfig() {
        do {
            try configText.write(to: configURL(), atomically: true, encoding: .utf8)
            state.message = L("message.configSaved")
        } catch { state.message = error.localizedDescription }
    }

    func loadLog() { logText = services.minio.log() }

    func setCustomDirectories(_ paths: [String]) {
        customDirectories = paths
        Task { await refresh() }
    }

    func setDataDirectory(_ url: URL) {
        state.run { [self] in
            UserDefaults.standard.set(url.path, forKey: "macenv.minio.dataDir")
            try services.minio.prepare()
            await refresh()
        }
    }
}

extension MinioViewModel: ServiceManageable {
    var kind: String { "minio" }
    var targets: [LaunchTarget] { versions.map { LaunchTarget(key: $0.id, kind: "minio", versionID: $0.id, title: "MinIO " + $0.version) } }
    func isRunning(_ versionID: String) -> Bool { versions.first { $0.id == versionID }.map { running($0) } ?? false }
    func port(_ versionID: String) -> String? { versions.first { $0.id == versionID }.map { port($0) } }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        await operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        guard !state.isChanging(version.directory) else { throw CommandError(message: L("message.taskInProgress")) }
        if action == "stop" { try await services.minio.stop() } else { try await services.minio.start(version) }
    }
    func stopAll() async { try? await services.minio.stop() }
    func membership(_ versionID: String) -> PathMembership { pathMembership[versionID] ?? .none }
    func togglePath(_ versionID: String) {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        togglePath(version)
    }
}
