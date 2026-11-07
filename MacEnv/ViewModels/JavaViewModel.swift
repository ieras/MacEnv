import SwiftUI

@MainActor
final class JavaViewModel: ObservableObject, PortListHost {
    let state: AppState
    let services: Services

    @Published var versions: [JavaVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var formulae: [BrewFormulaItem] = []
    @Published var sdkmanVersions: [SdkmanVersion] = []
    @Published var sdkmanLoading = false
    @Published var sdkmanSearch = ""
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selectedID: String?
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.java.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.java.directories") }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: JavaVersion? { versions.first { $0.id == selectedID } ?? versions.first }
    var sdkmanInstalled: Bool { services.tools.sdkmanInstalled }

    func refresh() async {
        do { try await services.paths.refresh() } catch { state.message = error.localizedDescription }
        versions = await services.java.installedVersions(customDirectories: customDirectories + services.paths.allPath)
        if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
        pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "java", directory: $0.directory)) })
        Task {
            do { formulae = try await Brew.formulae("openjdk") }
            catch { state.message = error.localizedDescription }
        }
        objectWillChange.send()
    }

    func refreshVersionManager(_ source: String, force: Bool = false) async {
        switch source {
        case "Static": await loadStatic(force: force)
        case "SDKMAN": await loadSdkman()
        case "MacPorts": await loadPortItems(force: force)
        default: await refresh()
        }
    }

    // MARK: - MacPorts 清单（加载与装/卸在 PortListHost 协议扩展里）

    @Published var portItems: [PortItem] = []
    @Published var portLoading = false
    var portApp: String { "java" }

    func togglePath(_ version: JavaVersion) {
        state.run {
            try self.services.paths.toggle(kind: "java", directory: version.directory)
            try await self.services.paths.refresh(force: true)
            self.pathMembership = Dictionary(uniqueKeysWithValues: self.versions.map { ($0.id, self.services.paths.membership(kind: "java", directory: $0.directory)) })
            self.state.message = String(format: L(self.services.paths.membership(kind: "java", directory: version.directory) == .app ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Java \(version.version)")
        }
    }

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("java").cached()
        do {
            staticVersions = try await services.catalog("java").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.installingFor"), "Java \(version.version)")) { report, attach in
            try await self.services.catalog("java").install(version, report: report, onStart: attach)
            await self.services.java.clearQuarantine(version)
            self.staticVersions = try await self.services.catalog("java").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.uninstallingFor"), "Java \(version.version)")) { _, _ in
            try? self.services.paths.removeLinks(pointingInside: self.services.java.versionsDirectory.appendingPathComponent("java-\(version.version)"))
            try self.services.catalog("java").uninstall(version)
            self.staticVersions = try await self.services.catalog("java").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func brewAction(_ action: String, formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh()
        }
    }

    // MARK: - SDKMAN

    func loadSdkman() async {
        guard sdkmanInstalled, !sdkmanLoading else { return }
        sdkmanLoading = true
        defer { sdkmanLoading = false }
        do { sdkmanVersions = try await services.java.sdkmanJavaVersions() }
        catch { state.message = error.localizedDescription }
    }

    func sdkman(_ action: String, version: SdkmanVersion) {
        let title = action == "default"
            ? String(format: L("message.sdkmanDefaultSet"), version.identifier)
            : taskTitle(action, version.identifier)
        state.runStreaming(title) { report, attach in
            try await self.services.java.sdkmanJava(action, identifier: version.identifier, report: report, onStart: attach)
            await self.loadSdkman()
            await self.refresh()
        }
    }

    func filteredSdkman() -> [SdkmanVersion] {
        let key = sdkmanSearch.trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? sdkmanVersions : sdkmanVersions.filter {
            $0.identifier.localizedCaseInsensitiveContains(key) || $0.vendor.localizedCaseInsensitiveContains(key)
        }
    }
}
