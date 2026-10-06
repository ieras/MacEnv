import SwiftUI

@MainActor
final class PhpViewModel: ObservableObject {
    private let state: AppState
    private let services: Services

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
    // 扩展来源：brew（Homebrew tap shivammathur/extensions）或 macports。
    @Published var extensionSource = "brew" {
        didSet { loadExtensions() }
    }

    // MacPorts 装没装。
    var macportsAvailable: Bool { services.php.macportsInstalled }

    // 选中的 PHP 是不是 MacPorts 装的 —— 只有它才能吃 MacPorts 的扩展，.so 的 ABI 是绑死的。
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

    // php-fpm 才是服务；php（CLI）只挂 PATH。视图通过这两个访问器读服务状态。
    var fpmRunningAny: Bool { services.phpFpm.anyRunning }
    func fpmRunning(_ version: PhpVersion) -> Bool { services.phpFpm.running(version) }

    func refresh() async {
        do {
            // 先问一次登录 shell 拿真实 PATH：GUI 启动的 app 继承不到用户 rc 里改过的 PATH，
            // 但 PathService 会去问 zsh/bash。
            try await services.paths.refresh()
            // PATH 里的目录也当扫描目标。用户可能用别的工具（FlyEnv 之类）装了 php，
            // shell 里 `php -v` 是 8.4、MacEnv 里却一个都看不到，版本号就对不上。
            versions = try await services.php.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "php", directory: $0.directory)) })
            // brew 一次要 search + info 两个子进程，好几秒 —— 丢后台慢慢填，
            // 版本列表（侧栏按钮亮不亮靠它）不该被公式列表拖住。
            Task { formulae = (try? await Brew.formulae("php")) ?? formulae }
            await services.phpFpm.adopt(versions)
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    // 每版本一个 master：stop 只停这个版本，restart 就是先停后起，都不影响别的版本。
    func operate(_ action: String, _ version: PhpVersion) async {
        guard !state.busy else { return }
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

    // 全部版本一起拉。已在跑的跳过；单个失败报错继续，不断批。不管 busy ——
    // 侧栏开关直接调它，launch() 联动调它时 busy 已经是 true。
    func startAll() async {
        for version in versions where !services.phpFpm.running(version) {
            do { try await services.phpFpm.start(version) }
            catch { state.message = error.localizedDescription }
        }
        objectWillChange.send()
    }

    func togglePath(_ version: PhpVersion) {
        guard !state.busy else { return }
        state.busy = true
        Task {
            defer { state.busy = false }
            do {
                try services.paths.toggle(kind: "php", directory: version.directory)
                try await services.paths.refresh(force: true)
                pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "php", directory: $0.directory)) })
                state.message = String(format: L(services.paths.membership(kind: "php", directory: version.directory) == .app ? "message.pathEnabledFor" : "message.pathDisabledFor"), "PHP \(version.version)")
            } catch {
                state.message = error.localizedDescription
            }
        }
    }

    func refreshVersionManager(_ source: String, force: Bool = false) async {
        if source == "Static" { await loadStatic(force: force) } else { await refresh() }
    }

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
        state.runStreaming(String(format: L("message.installingFor"), "PHP \(version.version)")) { report, attach in
            try await self.services.php.install(version, report: report, onStart: attach)
            self.staticVersions = try await self.services.catalog("php").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.uninstallingFor"), "PHP \(version.version)")) { _, _ in
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

    // php.ini 的位置由 PHP 自己决定，拿不到就在界面上报错，不猜。
    // 刻意不走 run{}：读文件不是写操作，不该因为别的任务在跑就被丢掉 ——
    // 被丢掉时 iniText/iniPath 还留着上一个版本的，接着按保存就写错文件了。
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

    // 扩展列表要四样东西才能拼出来：tap 里有哪些可装、Cellar 里装了哪些、扩展目录里有什么、
    // php.ini 里写了什么。全在本地读，不起任何子进程 —— 六十多个扩展逐个去问文件系统
    // 会慢得没法用，所以目录只各读一次，装进 Set 里查。
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
            // extension= 和 zend_extension= 两种写法都算启用：xdebug 写成 extension= 其实不生效，
            // 但用户真这么写了，界面得如实反映，不能装作没看见。
            let enabled = IniFile.values("extension", in: ini) + IniFile.values("zend_extension", in: ini)
            // MacPorts 的 .so 是给 MacPorts 自己的 PHP 编译的（ABI 绑死），只有当前这个 PHP 就是
            // MacPorts 装的时候才列它，否则装了也加载不了，只会把用户引到坑里。
            let macports = extensionSource == "macports" && version.executable.path.hasPrefix("/opt/local")
            let names = macports
                ? services.php.macportsExtensions(version.majorMinor)
                : services.php.availableExtensions(version.majorMinor)
            // brew 的 .so 留在 Cellar 的 keg 里（要再拷一份），MacPorts 的直接落在扩展目录，判定方式不同。
            let kegs = macports ? [] : ((try? FileManager.default.contentsOfDirectory(atPath: "/opt/homebrew/Cellar")) ?? [])
            availableExtensions = names.map { name in
                let soname = PhpService.extensionSonames[name] ?? "\(name).so"
                return PhpExtension(name: name,
                                    soname: soname,
                                    // keg 在 或 .so 已经拷过去，都算「装过」。
                                    installed: kegs.contains("\(name)@\(version.majorMinor)") || files.contains(soname),
                                    enabled: enabled.contains { $0.contains(soname) })
            }
        }
    }

    func installExtension(_ item: PhpExtension) {
        guard let version = selectedVersion else { return }
        state.runStreaming(String(format: L("message.installingFor"), "\(item.name)@\(version.majorMinor)")) { report, attach in
            // MacPorts 的 .so 由 port 直接放进扩展目录，不用拷；brew 的要自己从 keg 里捞。
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

    // 列表 = 内置的 ∪ 用户自己加的 ∪ php.ini 里已经写着的。
    // 第三项不能省：用户手改过 ini 的，得让他在这儿看见并且接着勾。
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
            // 一个都没勾就整行删掉，留一条 `disable_functions = ` 空值没有意义。
            text = value.isEmpty ? IniFile.remove("disable_functions", from: text)
                                 : IniFile.set("disable_functions", to: value, in: text)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            self.loadIni(version)
            self.state.message = L("message.configSaved")
        }
    }

    // MARK: - 日志

    // 前三种是 php-fpm 自己的日志，最后一种读 php.ini 里 error_log 指向的那个文件。
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
            // error_log 可能是相对路径，也可能是 (none)。读不到就是读不到，界面显示空，
            // 不去猜它相对谁 —— 猜错了读的是别的文件，比空着更糟。
            logPath = IniFile.value("error_log", in: ini) ?? ""
            logText = logPath.isEmpty ? "" : ((try? String(contentsOfFile: logPath, encoding: .utf8)).map { String($0.suffix(512_000)) } ?? "")
        }
    }
}

// 统一服务注册表条目：PHP-FPM。
extension PhpViewModel: ServiceManageable {
    var kind: String { "php" }
    var targets: [LaunchTarget] { versions.map { LaunchTarget(key: "php:" + $0.id, kind: "php", versionID: $0.id, title: "PHP-FPM " + $0.version) } }
    func isRunning(_ versionID: String) -> Bool { versions.first { $0.id == versionID }.map { services.phpFpm.running($0) } ?? false }
    // php-fpm 只有 unix socket，无 TCP 端口。
    func port(_ versionID: String) -> String? { nil }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        await operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
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
