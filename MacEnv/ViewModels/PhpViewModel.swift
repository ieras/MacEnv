import SwiftUI

@MainActor
final class PhpViewModel: ObservableObject, PortListHost {
    let state: AppState
    let services: Services

    @Published var versions: [PhpVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var formulae: [BrewFormulaItem] = []
    @Published var selectedID: String?
    @Published var iniText = ""
    @Published var iniPath = ""
    @Published var iniExists = false
    @Published var loadedExtensions: [String] = []
    @Published var availableExtensions: [PhpExtension] = []
    @Published var extensionDirectory = ""
    @Published var extensionsLoading = false
    @Published var extensionSource = "brew" {
        didSet { loadExtensions() }
    }

    var macportsAvailable: Bool { services.php.macportsInstalled }

    var macportsUsable: Bool { selectedVersion?.executable.path.hasPrefix("/opt/local") ?? false }
    @Published var disableFunctions: [PhpDisableFunction] = []
    @Published var customFunctions = UserDefaults.standard.stringArray(forKey: "macenv.php.disableFunctions") ?? [] {
        didSet { UserDefaults.standard.set(customFunctions, forKey: "macenv.php.disableFunctions") }
    }
    @Published var logKind = "fpm"
    @Published var logPath = ""
    @Published var logText = ""
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.php.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.php.directories") }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: PhpVersion? { versions.first { $0.id == selectedID } ?? versions.first }

    var fpmRunningAny: Bool { services.phpFpm.anyRunning }
    func fpmRunning(_ version: PhpVersion) -> Bool { services.phpFpm.running(version) }

    func refresh() async {
        do {
            try await services.paths.refresh()
            versions = try await services.php.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "php", directory: $0.directory)) })
            Task {
                do { formulae = try await Brew.formulae("php") }
                catch { state.message = error.localizedDescription }
            }
            await services.phpFpm.adopt(versions)
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    func operate(_ action: String, _ version: PhpVersion) async {
        guard !state.busy else { return }
        guard !state.isChanging(version.directory) else { state.message = L("message.taskInProgress"); return }
        state.busy = true
        defer {
            state.busy = false
            objectWillChange.send()
        }
        do {
            if action != "start" { try await services.phpFpm.stop(version) }
            if action != "stop" { try await services.phpFpm.start(version) }
            state.message = action == "stop" ? "PHP-FPM " + L("message.stopped") : "PHP-FPM \(version.version) " + L("message.started")
        } catch {
            state.message = error.localizedDescription
        }
    }

    func startAll() async {
        var started = Set<String>()
        let runningMinors = Set(versions.filter { services.phpFpm.running($0) }.map(\.majorMinor))
        for version in versions where !state.isChanging(version.directory) && !runningMinors.contains(version.majorMinor) && started.insert(version.majorMinor).inserted {
            do { try await services.phpFpm.start(version) }
            catch { state.message = error.localizedDescription }
        }
        objectWillChange.send()
    }

    func togglePath(_ version: PhpVersion) {
        state.run { [self] in
            try services.paths.toggle(kind: "php", directory: version.directory)
            try await services.paths.refresh(force: true)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "php", directory: $0.directory)) })
            state.message = String(format: L(services.paths.membership(kind: "php", directory: version.directory) == .app ? "message.pathEnabledFor" : "message.pathDisabledFor"), "PHP \(version.version)")
        }
    }

    func refreshVersionManager(_ source: String, force: Bool = false) async {
        switch source {
        case "Static": await loadStatic(force: force)
        case "MacPorts": await loadPortItems(force: force)
        default: await refresh()
        }
    }

    // MARK: - MacPorts 清单（加载与装/卸在 PortListHost 协议扩展里）

    @Published var portItems: [PortItem] = []
    @Published var portLoading = false
    var portApp: String { "php" }

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("php").cached()
        do {
            staticVersions = try await services.catalog("php").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        let target = services.php.versionsDirectory.appendingPathComponent("php-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && services.phpFpm.running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.installingFor"), "PHP \(version.version)"), packageDirectory: target) { report, attach in
            try await self.services.php.install(version, report: report, onStart: attach)
            self.staticVersions = try await self.services.catalog("php").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        let target = services.php.versionsDirectory.appendingPathComponent("php-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && services.phpFpm.running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.uninstallingFor"), "PHP \(version.version)"), packageDirectory: target) { _, _ in
            try self.services.catalog("php").uninstall(version)
            self.staticVersions = try await self.services.catalog("php").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func brewAction(_ action: String, formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh()
        }
    }

    func loadIni(_ version: PhpVersion? = nil) {
        guard let version = version ?? selectedVersion else { return }
        Task {
            do {
                let path = try await services.php.iniPath(version)
                iniPath = path
                iniText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                iniExists = FileManager.default.fileExists(atPath: path)
                state.message = iniExists ? "" : L("message.phpIniMissing")
            } catch {
                state.message = error.localizedDescription
            }
        }
    }

    func saveIni() {
        do {
            try iniText.write(toFile: iniPath, atomically: true, encoding: .utf8)
            state.message = L("message.configSaved")
        } catch {
            state.message = error.localizedDescription
        }
    }

    func createIni() {
        guard let version = selectedVersion else { return }
        state.run {
            self.iniPath = try await self.services.php.createIni(version)
            self.iniText = try String(contentsOfFile: self.iniPath, encoding: .utf8)
            self.iniExists = true
            self.state.message = L("message.phpIniCreated")
        }
    }

    // MARK: - 扩展

    func loadExtensions(_ version: PhpVersion? = nil) {
        guard let version = version ?? selectedVersion else { return }
        Task {
            extensionsLoading = true
            defer { extensionsLoading = false }
            let directory = await services.php.extensionDirectory(version)
            extensionDirectory = directory ?? ""
            loadedExtensions = await services.php.loadedExtensions(version)
            let ini = ((try? await services.php.iniPath(version)).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }) ?? ""
            let files = Set((try? FileManager.default.contentsOfDirectory(atPath: directory ?? "")) ?? [])
            let enabled = IniFile.values("extension", in: ini) + IniFile.values("zend_extension", in: ini)
            let macports = extensionSource == "macports" && version.executable.path.hasPrefix("/opt/local")
            let names = macports
                ? await services.php.macportsExtensions(version.majorMinor)
                : services.php.availableExtensions(version.majorMinor)
            let kegs = macports ? [] : ((try? FileManager.default.contentsOfDirectory(atPath: "/opt/homebrew/Cellar")) ?? [])
            availableExtensions = names.map { name in
                let soname = PhpService.extensionSonames[name] ?? "\(name).so"
                return PhpExtension(name: name,
                                    soname: soname,
                                    installed: kegs.contains("\(name)@\(version.majorMinor)") || files.contains(soname),
                                    enabled: enabled.contains { $0.contains(soname) })
            }
        }
    }

    func installExtension(_ item: PhpExtension) {
        guard let version = selectedVersion else { return }
        state.runStreaming(String(format: L("message.installingFor"), "\(item.name)@\(version.majorMinor)")) { report, attach in
            let soname: String
            if self.extensionSource == "macports" {
                try await self.services.php.macportsInstall(item.name, for: version)
                soname = item.soname
            } else {
                soname = try await self.services.php.installExtension(item.name, for: version, report: report, onStart: attach)
            }
            try await self.services.php.setExtension(item.name, soname: soname, enabled: true, for: version)
            self.loadExtensions(version)
        }
    }

    func enableExtension(_ item: PhpExtension) {
        guard let version = selectedVersion else { return }
        state.run {
            try await self.services.php.setExtension(item.name, soname: item.soname, enabled: true, for: version)
            self.loadExtensions(version)
            self.state.message = String(format: L("message.extensionEnabled"), item.name)
        }
    }

    func disableExtension(_ item: PhpExtension) {
        guard let version = selectedVersion else { return }
        state.run {
            try await self.services.php.setExtension(item.name, soname: item.soname, enabled: false, for: version)
            self.loadExtensions(version)
            self.state.message = String(format: L("message.extensionDisabled"), item.name)
        }
    }

    func removeExtension(_ item: PhpExtension) {
        guard let version = selectedVersion else { return }
        state.runStreaming(String(format: L("message.uninstallingFor"), "\(item.name)@\(version.majorMinor)")) { report, attach in
            try await self.services.php.setExtension(item.name, soname: item.soname, enabled: false, for: version)
            if self.extensionSource == "macports" {
                try await self.services.php.macportsRemove(item.name, for: version)
            } else {
                try await self.services.php.removeExtension(item.name, soname: item.soname, for: version, report: report, onStart: attach)
            }
            self.loadExtensions(version)
        }
    }

    // MARK: - 禁用函数

    func loadDisableFunctions(_ version: PhpVersion? = nil) {
        guard let version = version ?? selectedVersion else { return }
        Task {
            let ini = ((try? await services.php.iniPath(version)).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }) ?? ""
            let current = Set((IniFile.value("disable_functions", in: ini) ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            disableFunctions = Set(PhpService.commonDisableFunctions).union(customFunctions).union(current)
                .sorted()
                .map { PhpDisableFunction(name: $0, disabled: current.contains($0),
                                          removable: !PhpService.commonDisableFunctions.contains($0)) }
        }
    }

    func toggleDisableFunction(_ item: PhpDisableFunction) {
        guard let index = disableFunctions.firstIndex(where: { $0.name == item.name }) else { return }
        let disabled = !disableFunctions[index].disabled
        disableFunctions[index] = PhpDisableFunction(name: item.name, disabled: disabled, removable: item.removable)
    }

    func addDisableFunction(_ name: String) {
        let value = name.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !disableFunctions.contains(where: { $0.name == value }) else { return }
        customFunctions.append(value)
        loadDisableFunctions()
    }

    func removeDisableFunction(_ item: PhpDisableFunction) {
        customFunctions.removeAll { $0 == item.name }
        loadDisableFunctions()
    }

    func saveDisableFunctions() {
        guard let version = selectedVersion else { return }
        let value = disableFunctions.filter(\.disabled).map(\.name).joined(separator: ",")
        state.run {
            let path = try await self.services.php.iniPath(version)
            var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            text = value.isEmpty ? IniFile.remove("disable_functions", from: text)
                                 : IniFile.set("disable_functions", to: value, in: text)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            self.loadIni(version)
            self.state.message = L("message.configSaved")
        }
    }

    // MARK: - 日志

    func loadLog(_ kind: String? = nil) {
        guard let version = selectedVersion else { return }
        if let kind { logKind = kind }
        guard logKind == "ini" else {
            logPath = services.phpFpm.logPath(version, kind: logKind).path
            logText = services.phpFpm.log(version, kind: logKind)
            return
        }
        Task {
            let ini = ((try? await services.php.iniPath(version)).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }) ?? ""
            logPath = IniFile.value("error_log", in: ini) ?? ""
            logText = logPath.isEmpty ? "" : ((try? String(contentsOfFile: logPath, encoding: .utf8)).map { String($0.suffix(512_000)) } ?? "")
        }
    }
}

extension PhpViewModel: ServiceManageable {
    var kind: String { "php" }
    var singleInstance: Bool { false }
    var targets: [LaunchTarget] { versions.map { LaunchTarget(key: "php:" + $0.id, kind: "php", versionID: $0.id, title: "PHP-FPM " + $0.version) } }
    func isRunning(_ versionID: String) -> Bool { versions.first { $0.id == versionID }.map { services.phpFpm.running($0) } ?? false }
    func port(_ versionID: String) -> String? { nil }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        await operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        guard !state.isChanging(version.directory) else { throw CommandError(message: L("message.taskInProgress")) }
        if action == "stop" { try await services.phpFpm.stop(version) } else { try await services.phpFpm.start(version) }
    }
    func stopAll() async {
        do { try await services.phpFpm.stopAll() } catch { state.message = error.localizedDescription }
    }
    func membership(_ versionID: String) -> PathMembership { pathMembership[versionID] ?? .none }
    func togglePath(_ versionID: String) {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        togglePath(version)
    }
}
