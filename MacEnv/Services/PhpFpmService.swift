import Foundation

// 对应 FlyEnv 的 PHP-FPM 模块。php（CLI）不是服务，php-fpm 才是 —— 常驻、要起停、
// 是 Nginx fastcgi_pass 的对端。配置按 PHP 版本各存一套，跟 FlyEnv 的
// <PhpDir>/<v>/{conf,var} 同一个思路。
// 每个版本一个 master 进程、一个 socket，互不干扰：8.4 和 8.5 可以同时跑（对齐 FlyEnv）。
@MainActor
final class PhpFpmService {
    let root: URL
    // key 是两位版本号（83），每版本一个 supervisor，marker 用版本自己的目录，
    // find/stop 就只会命中这个版本的 master，不会误伤别的版本。
    private var supervisors: [String: ProcessSupervisor] = [:]
    var onExit: (() -> Void)?

    var directory: URL { root.appendingPathComponent("server/php-fpm", isDirectory: true) }

    // php-fpm 仅通过 unix socket 暴露给 Nginx，无独立 TCP 端口，勿再加。

    init(root: URL) { self.root = root }

    // 两位版本号（8.3 → 83）。socket 名必须跟 Nginx 侧 enable-php.conf 的 fastcgi_pass 一致。
    private func num(_ version: PhpVersion) -> String { version.version.split(separator: ".").prefix(2).joined() }

    private func supervisor(_ version: PhpVersion) -> ProcessSupervisor {
        if let item = supervisors[num(version)] { return item }
        let item = ProcessSupervisor(marker: versionDirectory(version).path)
        item.onExit = { [weak self] in self?.onExit?() }
        supervisors[num(version)] = item
        return item
    }

    func running(_ version: PhpVersion) -> Bool { supervisor(version).isRunning }
    var anyRunning: Bool { supervisors.values.contains { $0.isRunning } }

    func configURL(_ version: PhpVersion) -> URL { versionDirectory(version).appendingPathComponent("php-fpm.conf") }
    func socketPath(_ version: PhpVersion) -> String { "/tmp/macenv-php-cgi-\(num(version)).sock" }

    private func versionDirectory(_ version: PhpVersion) -> URL { directory.appendingPathComponent(num(version), isDirectory: true) }

    func prepare(_ version: PhpVersion) throws {
        let fm = FileManager.default
        let base = versionDirectory(version)
        for path in ["log", "run"] { try fm.createDirectory(at: base.appendingPathComponent(path), withIntermediateDirectories: true) }
        let file = configURL(version)
        guard !fm.fileExists(atPath: file.path),
              let template = Bundle.main.url(forResource: "PhpDefaults", withExtension: nil)?.appendingPathComponent("php-fpm.conf") else { return }
        try String(contentsOf: template, encoding: .utf8)
            .replacingOccurrences(of: "##PHP-CGI-VERSION##", with: num(version))
            .write(to: file, atomically: true, encoding: .utf8)
    }

    // 接管上次运行留下的各版本 php-fpm master：命令行里得带着该版本自己的配置文件路径才算。
    func adopt(_ versions: [PhpVersion]) async {
        // 顺手把每个已装版本的配置目录建出来。Nginx 侧的 enable-php-<版本>.conf 是按这些目录展开的，
        // 只有 start 时才建的话，没启动过的版本在 Nginx 配置里就没有对应的一份。
        for version in versions { try? prepare(version) }
        // 卸载 PHP 之后它留下的 server/php-fpm/<num>/ 没人管，而 Nginx 侧是照这个目录列表展开
        // enable-php-<num>.conf 的 —— 站点 include 一份指向不存在 socket 的配置，请求直接 502。
        // 每次刷新顺手清掉没有对应版本的目录。有 FPM 在跑就先不动。
        if !anyRunning {
            let live = Set(versions.map { num($0) })
            for item in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            where !live.contains(item.lastPathComponent) {
                try? FileManager.default.removeItem(at: item)
            }
        }
        // worker 进程的命令行是 setproctitle 过的「php-fpm: pool www」，不含配置路径，天然匹配不上；
        // 只有 master 带着 -y <配置路径>，所以每个 master 恰好认领回它自己的版本。
        guard let output = try? await Command.run("/bin/ps", ["-axo", "pid=,command="]) else { return }
        for line in output.stdout.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int32(parts[0]), parts[1].contains("php-fpm") else { continue }
            guard let version = versions.first(where: { parts[1].contains(configURL($0).path) }) else { continue }
            supervisor(version).adopt(ManagedProcess(pid: pid, command: String(parts[1])))
        }
    }

    func start(_ version: PhpVersion) async throws {
        guard FileManager.default.isExecutableFile(atPath: version.fpm.path) else { throw CommandError(message: L("error.phpFpmMissing")) }
        try prepare(version)
        let item = supervisor(version)
        guard !item.isRunning else { return }
        let base = versionDirectory(version)
        let startupLog = base.appendingPathComponent("log/start-error.log")
        // -p 定相对路径的基准，-y 指定池配置，-F 强制前台让 ProcessSupervisor 直接拿住 master。
        let process = try item.launch(at: version.fpm,
                                      arguments: ["-p", base.path, "-y", configURL(version).path,
                                                  "-g", base.appendingPathComponent("run/php-fpm.pid").path, "-F"],
                                      directory: version.directory,
                                      environment: ProcessInfo.processInfo.environment,
                                      errorLog: startupLog)
        for _ in 0..<100 where process.isRunning && !FileManager.default.fileExists(atPath: socketPath(version)) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard process.isRunning else {
            item.forget()
            throw CommandError(message: (try? String(contentsOf: startupLog, encoding: .utf8)) ?? L("error.phpFpmStartFailed"))
        }
    }

    func stop(_ version: PhpVersion) async throws {
        let item = supervisor(version)
        guard let target = try await item.find("php-fpm") else {
            item.forget()
            return
        }
        try await item.terminate(target)
    }

    func stopAll() async throws {
        for item in supervisors.values where item.isRunning {
            if let target = try await item.find("php-fpm") { try await item.terminate(target) }
            else { item.forget() }
        }
    }

    // php-fpm.conf 里 error_log / slowlog 都是相对 -p 基准的相对路径，落到 <版本目录>/log/ 下。
    // start-error.log 是 MacEnv 自己接的 master 启动 stderr —— php-fpm 还没起来时的报错只在这里，
    // 上面两个文件那时候还是空的。
    func logPath(_ version: PhpVersion, kind: String) -> URL {
        let name = ["slow": "php-fpm-slow.log", "start": "start-error.log"][kind] ?? "php-fpm.log"
        return versionDirectory(version).appendingPathComponent("log/\(name)")
    }

    func log(_ version: PhpVersion, kind: String) -> String { readLogTail(logPath(version, kind: kind)) }
}
