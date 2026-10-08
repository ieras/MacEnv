import Foundation

// 对应 FlyEnv 的 Nginx 模块：Homebrew 提供二进制，MacEnv 用自己的配置和 PID 托管前台 master。
@MainActor
final class NginxService {
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningID: String?
    var onExit: (() -> Void)?

    var common: URL { root.appendingPathComponent("server/nginx/common", isDirectory: true) }
    var config: URL { common.appendingPathComponent("conf/nginx.conf") }
    var defaultConfig: URL { common.appendingPathComponent("conf/nginx.conf.default") }
    var errorLog: URL { common.appendingPathComponent("logs/error.log") }
    var accessLog: URL { common.appendingPathComponent("logs/access.log") }
    var pidFile: URL { common.appendingPathComponent("logs/nginx.pid") }
    var vhost: URL { root.appendingPathComponent("vhost/nginx", isDirectory: true) }

    init(root: URL) {
        self.root = root
        supervisor = ProcessSupervisor(marker: root.appendingPathComponent("server/nginx/common", isDirectory: true).path)
        supervisor.onExit = { [weak self] in
            self?.runningID = nil
            self?.onExit?()
        }
    }

    func running(_ version: NginxVersion) -> Bool { supervisor.isRunning && runningID == version.id }

    func prepare() throws {
        let fm = FileManager.default
        for path in ["conf", "logs", "run/client_body_temp", "run/proxy_temp", "run/fastcgi_temp", "run/uwsgi_temp", "run/scgi_temp"] {
            try fm.createDirectory(at: common.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: vhost, withIntermediateDirectories: true)
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let defaults = bundle.url(forResource: "NginxDefaults", withExtension: nil) else {
            throw CommandError(message: L("error.nginxDefaultsMissing"))
        }
        for source in try fm.contentsOfDirectory(at: defaults, includingPropertiesForKeys: nil) {
            // enable-php.conf 是模板，下面按 PHP 版本各展开一份；原样拷过去只会留个带 ##VERSION## 的死文件。
            guard source.lastPathComponent != "enable-php.conf" else { continue }
            let destination = common.appendingPathComponent("conf/" + source.lastPathComponent)
            if !fm.fileExists(atPath: destination.path) { try fm.copyItem(at: source, to: destination) }
        }
        // 站点里写 `include enable-php-<两位版本>.conf;` 用的就是这些。版本目录名就是两位版本号，
        // 跟 PhpFpmService.socketPath() 的 socket 名同源，两边不会跑偏。
        if let template = try? String(contentsOf: defaults.appendingPathComponent("enable-php.conf"), encoding: .utf8) {
            let phpFpm = root.appendingPathComponent("server/php-fpm", isDirectory: true)
            let versions = (try? fm.contentsOfDirectory(at: phpFpm, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for version in versions {
                try? template.replacingOccurrences(of: "##VERSION##", with: version.lastPathComponent)
                    .write(to: common.appendingPathComponent("conf/enable-php-\(version.lastPathComponent).conf"), atomically: true, encoding: .utf8)
            }
            // 反向清一遍：PHP 被卸载后它的 enable-php-<num>.conf 还留在磁盘上，站点 include 它就会
            // fastcgi_pass 到一个不存在的 socket。上面那份目录列表是唯一的真相来源，对不上的删掉。
            let confDirectory = common.appendingPathComponent("conf", isDirectory: true)
            let live = Set(versions.map { "enable-php-\($0.lastPathComponent).conf" })
            for file in (try? fm.contentsOfDirectory(at: confDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            where file.lastPathComponent.hasPrefix("enable-php-") && !live.contains(file.lastPathComponent) {
                try? fm.removeItem(at: file)
            }
        }
        // MacEnv 以当前用户前台跑 nginx，user 指令只在 master 是 root 时才有意义 —— 留着就是每次
        // 启动往 error.log 里塞一条 [warn]。模板里已经注释掉了，但**老版本装出来的 conf 是代码硬写
        // 进去的 `user <用户名>;`**，而上面那段拷贝对已存在的文件一律不覆盖，那份脏配置会永远留在
        // 磁盘上（.default 同理，它是「恢复默认」按钮的来源）。所以这里主动清一遍：
        // 新装靠模板、老装靠自愈，两条路都干净。只删未注释的行，模板里那行注释原样留着。
        stripUserDirective(config)
        stripUserDirective(defaultConfig)
        var content = try String(contentsOf: config, encoding: .utf8)
        if content.contains("#PREFIX#") {
            content = content.replacingOccurrences(of: "#PREFIX#/common/logs/access.log", with: doubleQuoted(accessLog.path))
                .replacingOccurrences(of: "#VHostPath#/*.conf", with: doubleQuoted(vhost.path + "/*.conf"))
            try content.write(to: config, atomically: true, encoding: .utf8)
            try content.write(to: defaultConfig, atomically: true, encoding: .utf8)
        }
        if content.range(of: "(?m)^\\s*listen\\s+", options: .regularExpression) == nil,
           let index = content.lastIndex(of: "}") {
            content.insert(contentsOf: "\n    server {\n        listen 80;\n        server_name localhost;\n    }\n", at: index)
            try content.write(to: config, atomically: true, encoding: .utf8)
        }
    }

    // 只吃未注释的 `user ...;`：正则要求行首（可带缩进）直接就是 user，`#user` 和
    // `#user  nobody;  # 说明` 这类注释行一个字都不动。内容没变就不写盘。
    private func stripUserDirective(_ file: URL) {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        let cleaned = content.replacingOccurrences(of: "(?m)^[ \\t]*user[ \\t]+[^;]+;[^\\n]*\\n?", with: "", options: .regularExpression)
        guard cleaned != content else { return }
        try? cleaned.write(to: file, atomically: true, encoding: .utf8)
    }

    func installedVersions(customDirectories: [String]) async throws -> [NginxVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let cellar = URL(fileURLWithPath: prefix + "/Cellar/nginx", isDirectory: true)
            if let kegs = try? fm.contentsOfDirectory(at: cellar, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                for keg in kegs { candidates.append((keg.appendingPathComponent("bin/nginx"), "Homebrew")) }
            }
        }
        candidates.append((URL(fileURLWithPath: "/opt/local/sbin/nginx"), "MacPorts"))
        let appDirectory = root.appendingPathComponent("app", isDirectory: true)
        let staticDirectory = root.appendingPathComponent("server/nginx/versions", isDirectory: true)
        var directories = customDirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        directories += (try? fm.contentsOfDirectory(at: appDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        directories += (try? fm.contentsOfDirectory(at: staticDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for directory in directories {
            for path in ["nginx", "bin/nginx", "sbin/nginx"] { candidates.append((directory.appendingPathComponent(path), "Static")) }
        }
        var seen = Set<String>()
        var result: [NginxVersion] = []
        for (binary, source) in candidates {
            let executable = binary.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            let output = try await Command.run(executable.path, ["-v"])
            guard output.status == 0, let version = output.text.split(separator: "/").last else { continue }
            let directory = executable.deletingLastPathComponent().lastPathComponent == "nginx" ? executable.deletingLastPathComponent() : executable.deletingLastPathComponent().deletingLastPathComponent()
            result.append(NginxVersion(version: String(version).trimmingCharacters(in: .whitespacesAndNewlines), directory: directory, executable: executable, source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func brewFormula() async throws -> BrewFormula? {
        guard let brew = Brew.executable else { return nil }
        let output = try await Command.run(brew, ["info", "--json=v2", "--formula", "nginx"], environment: Command.brewEnvironment)
        guard output.status == 0 else { throw CommandError(message: output.text) }
        let json = try JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any]
        guard let formula = (json?["formulae"] as? [[String: Any]])?.first else { throw CommandError(message: L("error.brewFormulaMissing")) }
        return BrewFormula(
            version: (formula["versions"] as? [String: Any])?["stable"] as? String ?? "",
            installedVersions: (formula["installed"] as? [[String: Any]] ?? []).compactMap { $0["version"] as? String },
            linkedVersion: formula["linked_keg"] as? String,
            outdated: formula["outdated"] as? Bool ?? false,
            versionedFormulae: formula["versioned_formulae"] as? [String] ?? []
        )
    }

    // 先校验 PID 文件，再按实例目录查找进程。
    // pid 文件那条路走 libproc 校验可执行路径 —— 不跑子进程、不受沙箱影响，也不怕 setproctitle。
    private func existing() async -> ManagedProcess? {
        if let owned = supervisor.owned(pidFile: pidFile, binary: "nginx") { return owned }
        return try? await supervisor.find("nginx")
    }

    func adopt(_ versions: [NginxVersion]) async {
        guard !supervisor.isRunning, let target = await existing() else { return }
        // 用内核记录的可执行路径匹配版本，不从展示标题里猜。
        guard let version = versions.first(where: { $0.executable.path == target.executable }) else { return }
        runningID = version.id
        supervisor.adopt(target)
        try? String(target.pid).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    func validate(_ version: NginxVersion) async throws -> String {
        let output = try await Command.run(version.executable.path, ["-t", "-p", common.path, "-e", errorLog.path, "-c", config.path, "-g", "pid \(doubleQuoted(pidFile.path)); error_log \(doubleQuoted(errorLog.path));"])
        guard output.status == 0 else { throw CommandError(message: output.text) }
        return output.text
    }

    func start(_ version: NginxVersion, environment: [String: String] = [:]) async throws {
        try await stopAll()
        try prepare()
        var content = try String(contentsOf: config, encoding: .utf8)
        let paths = ["client_body", "proxy", "fastcgi", "uwsgi", "scgi"].filter { !content.contains($0 + "_temp_path") }.map { "    \($0)_temp_path run/\($0)_temp;" }
        if !paths.isEmpty { content = content.replacingOccurrences(of: "http\\s*\\{", with: "http {\n" + paths.joined(separator: "\n"), options: .regularExpression) }
        try content.write(to: config, atomically: true, encoding: .utf8)
        _ = try await validate(version)

        let startupLog = common.appendingPathComponent("logs/nginx-\(version.version)-start-error.log")
        let item = try supervisor.launch(
            at: version.executable,
            arguments: ["-p", common.path, "-e", errorLog.path, "-c", config.path, "-g", "pid \(doubleQuoted(pidFile.path)); error_log \(doubleQuoted(errorLog.path)); daemon off;"],
            directory: version.executable.deletingLastPathComponent(),
            environment: environment,
            errorLog: startupLog
        )
        do {
            for _ in 0..<150 where item.isRunning && supervisor.owned(pidFile: pidFile, binary: "nginx")?.pid != item.processIdentifier {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard item.isRunning, supervisor.owned(pidFile: pidFile, binary: "nginx")?.pid == item.processIdentifier else {
                throw CommandError(message: ((try? String(contentsOf: startupLog, encoding: .utf8)) ?? "") + "\n" + L("error.serviceStartTimeout"))
            }
            runningID = version.id
            try String(item.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        } catch {
            try await Task { @MainActor in
                if let target = supervisor.target { try await supervisor.terminate(target, force: true) }
            }.value
            throw error
        }
    }

    func stop() async throws {
        guard let target = await existing() else {
            supervisor.forget()
            runningID = nil
            return
        }
        try await supervisor.terminate(target)
        runningID = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    func stopAll() async throws {
        if let target = await existing() {
            try await supervisor.terminate(target)
        }
        supervisor.forget()
        runningID = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    func reload(_ version: NginxVersion) async throws {
        _ = try await validate(version)
        guard let target = supervisor.target else { throw CommandError(message: L("error.nginxNotRunning")) }
        try supervisor.signal(target, SIGHUP)
    }

    // 停止时也校验落盘配置，防止「保存成功」却在下一次启动才发现语法错误。
    func reloadIfRunning() async throws {
        let target = supervisor.target
        let executable: URL
        if let target { executable = URL(fileURLWithPath: target.executable) }
        else {
            guard let version = try await installedVersions(customDirectories: []).first else { return }
            executable = version.executable
        }
        try prepare()
        _ = try await validate(NginxVersion(version: "", directory: executable.deletingLastPathComponent(), executable: executable, source: ""))
        if let target { try supervisor.signal(target, SIGHUP) }
    }

    func log(_ kind: String) -> String { readLogTail(kind == "error" ? errorLog : accessLog) }

    func port() -> String {
        let files = [config] + ((try? FileManager.default.contentsOfDirectory(at: vhost, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in content.split(whereSeparator: \.isNewline) {
                let value = line.trimmingCharacters(in: .whitespaces)
                guard value.hasPrefix("listen "), let port = Int(value.dropFirst(7).split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == " " }).last ?? "") else { continue }
                return String(port)
            }
        }
        return "—"
    }
}
