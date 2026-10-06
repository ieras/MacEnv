import Foundation

// 对应 FlyEnv 的 PHP 模块：版本管理 + PATH 注入 + php.ini，不托管进程（PHP-FPM 是另一个模块）。
//
// 注意 static-php-cli 的包是「一个裸二进制」：CLI 包解出 php，FPM 包解出 php-fpm，
// 所以安装走自己的流程，不能复用 StaticCatalogService.install —— 它按「二进制往上退两级」
// 找包根目录，裸二进制会退到 versions 目录本身，直接把整个目录搬走。
@MainActor
final class PhpService {
    let root: URL

    var directory: URL { root.appendingPathComponent("server/php", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    private var archives: URL { root.appendingPathComponent("cache", isDirectory: true) }

    init(root: URL) { self.root = root }

    // Homebrew 的 php / php@x.y keg + 自己装的 Static 版本 + 自定义目录。
    func installedVersions(customDirectories: [String] = []) async throws -> [PhpVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String, String?)] = []
        // 直接扫 Cellar，不问 brew：brew search 只认 core 里还存在的公式，
        // php@7.4 这种已经下架、keg 还躺在磁盘上的版本根本查不到。而且这里省掉一次 brew 子进程。
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let cellar = URL(fileURLWithPath: prefix + "/Cellar", isDirectory: true)
            for rack in (try? fm.contentsOfDirectory(at: cellar, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                let formula = rack.lastPathComponent
                guard formula == "php" || formula.hasPrefix("php@") else { continue }
                for keg in (try? fm.contentsOfDirectory(at: rack, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                    let file = keg.appendingPathComponent("bin/php")
                    if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Homebrew", formula)) }
                }
            }
        }
        for item in (try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            for path in ["bin/php", "sbin/php", "php"] {
                let file = item.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static", nil)); break }
            }
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["php", "bin/php", "sbin/php"] {
                let file = item.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static", nil)) }
            }
        }
        var seen = Set<String>()
        var result: [PhpVersion] = []
        for (file, source, formula) in candidates {
            let executable = file.resolvingSymlinksInPath()
            // 只认常规文件：PATH 里可能有跟 php 同名的目录，isExecutableFile 对目录也返回真。
            guard fm.isExecutableFile(atPath: executable.path),
                  (try? executable.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  seen.insert(executable.path).inserted else { continue }
            let directory = executable.deletingLastPathComponent().deletingLastPathComponent()
            // 候选现在包含用户 PATH 里的任意目录，跑不起来是常态（架构不对、缺动态库、
            // 甚至根本不是二进制）。用 try? 兜住，否则一个坏候选能把整次扫描带走。
            let output = try? await Command.run(executable.path, ["-v"])
            // php -v 的版本行是「PHP 8.5.8 (cli) ...」。但 php 会先把它启动时的
            // Deprecated / Warning 一并吐出来（ini 里留着过时设置就会，比如 PHP 8.4 下的
            // session.sid_length），盲取第二个词会拿到 "PHP" 当成版本号。
            // 所以认准以「PHP 」开头的那一行，取它后面的第一个词。
            // 跑不起来时退回 keg 目录名，这样界面至少还列得出来，用户能看见自己的版本、
            // 能改 php.ini，只是启动会失败。Static / PATH 没这个约定，跳过。
            var version: String?
            let runnable = output?.status == 0
            if let output, output.status == 0 {
                version = output.text.split(whereSeparator: \.isNewline)
                    .first { $0.hasPrefix("PHP ") }?
                    .dropFirst(4).split(separator: " ").first.map(String.init)
            }
            if version == nil { version = formula.flatMap { _ in directory.lastPathComponent.components(separatedBy: "_").first } }
            guard let version, !version.isEmpty else { continue }
            result.append(PhpVersion(version: version, directory: directory, executable: executable,
                                     source: directory.path.hasPrefix("/opt/local") ? "MacPorts" : source,
                                     formula: formula, runnable: runnable))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    // 接口给的是 -fpm- 的地址，把这一段换成 -cli- 就是 CLI 包（FlyEnv 同款做法）。
    // 归档名跟 StaticCatalogService 保持一致，列表里的「已下载」标记才对得上。
    func install(_ version: StaticVersion, report: @escaping (String) -> Void = { _ in }, onStart: ((Process) -> Void)? = nil) async throws {
        let cli = URL(string: version.url.absoluteString.replacingOccurrences(of: "-fpm-", with: "-cli-")) ?? version.url
        let cliArchive = archives.appendingPathComponent("static-php-\(version.version).tar.gz")
        let fpmArchive = archives.appendingPathComponent("static-php-\(version.version)-fpm.tar.gz")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        try await download(cli, to: cliArchive, report: report, onStart: onStart)
        try await download(version.url, to: fpmArchive, report: report, onStart: onStart)

        let target = versionsDirectory.appendingPathComponent("php-\(version.version)")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("sbin"), withIntermediateDirectories: true)
        try await extract(cliArchive, into: target.appendingPathComponent("bin"), report: report)
        try await extract(fpmArchive, into: target.appendingPathComponent("sbin"), report: report)
    }

    // 问 PHP 自己要 ini 在哪。static-php-cli 编译进去的是 /usr/local/etc/php（目录要管理员权限才能建），
    // Homebrew 的在 /opt/homebrew/etc/php/<版本>/（可写）。
    func iniPath(_ version: PhpVersion) async throws -> String {
        var directory = ""
        // 跑不起来的版本直接跳过这一步：php -i 只会再 SIGABRT 一次、再写一份崩溃报告。
        if version.runnable, let output = try? await Command.run(version.executable.path, ["-i"]) {
            for line in output.text.split(whereSeparator: \.isNewline) {
                let parts = line.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                if parts[0] == "Loaded Configuration File", parts[1] != "(none)" { return parts[1] }
                if parts[0] == "Configuration File (php.ini) Path" { directory = parts[1] }
            }
        }
        // php -i 跑不起来不等于问不出 ini 在哪。php-config 是个不加载 PHP 本体的 shell 脚本，
        // 缺 dylib 的 php 照样给得出 --ini-path（本机 php@8.2 就是靠这条拿到
        // /opt/homebrew/etc/php/8.2 的），而那个目录是可写的，php.ini 就能编。
        if directory.isEmpty,
           let output = try? await Command.run(version.directory.appendingPathComponent("bin/php-config").path, ["--ini-path"]) {
            directory = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !directory.isEmpty else { throw CommandError(message: L("error.phpIniNotFound")) }
        return directory + "/php.ini"
    }

    // PHP 没自带 ini 时从内置模板建一份。目录不可写会直接抛错，界面上会显示出来。
    func createIni(_ version: PhpVersion) async throws -> String {
        let path = try await iniPath(version)
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            guard let template = Bundle.main.url(forResource: "PhpDefaults", withExtension: nil)?.appendingPathComponent("php.ini") else {
                throw CommandError(message: L("error.phpDefaultsMissing"))
            }
            try fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: template, to: URL(fileURLWithPath: path))
        }
        return path
    }

    // MARK: - 扩展

    // 常见高危函数，抄 FlyEnv 的 DisableFunction.vue（initFunctions）。紧凑写法省 160 行。
    static let commonDisableFunctions = """
    exec system passthru shell_exec proc_open popen pcntl_exec pcntl_alarm pcntl_fork
    pcntl_waitpid pcntl_wait pcntl_wifexited pcntl_wifstopped pcntl_wifsignaled
    pcntl_wifcontinued pcntl_wexitstatus pcntl_wtermsig pcntl_wstopsig pcntl_signal
    pcntl_signal_get_handler pcntl_signal_dispatch pcntl_get_last_error pcntl_strerror
    pcntl_sigprocmask pcntl_sigwaitinfo pcntl_sigtimedwait pcntl_getpriority
    pcntl_setpriority pcntl_async_signals pcntl_unshare eval assert create_function
    chmod chown chgrp link symlink ini_alter dl show_source highlight_file phpinfo
    getmyuid getmypid getmygid getmyinode get_current_user getrusage posix_getpwuid
    posix_getgrgid posix_getgroups posix_geteuid posix_getegid posix_getgid posix_getuid
    posix_kill posix_mkfifo posix_setpgid posix_setsid posix_setuid posix_setgid posix_uname
    putenv proc_get_status proc_nice proc_terminate escapeshellcmd escapeshellarg
    disk_total_space disk_free_space diskfreespace tempnam tmpfile pfsockopen fsockopen
    ftp_connect ftp_login ftp_pasv ftp_exec ftp_raw ftp_rawlist ftp_nb_fput ftp_nb_put
    ftp_nb_continue ftp_get ftp_fget ftp_put ftp_fput ftp_delete ftp_rename ftp_chmod
    ftp_mkdir ftp_rmdir ftp_size ftp_mdtm ftp_systype mail openlog syslog closelog
    define_syslog_variables apache_child_terminate apache_get_modules apache_get_version
    apache_getenv apache_lookup_uri apache_note apache_request_headers apache_reset_timeout
    apache_response_headers apache_setenv virtual curl_multi_exec curl_exec parse_ini_file
    set_time_limit ignore_user_abort debug_backtrace debug_print_backtrace gc_collect_cycles
    gc_disable gc_enable gc_enabled gc_mem_caches gc_status get_defined_constants
    get_defined_functions get_defined_vars get_included_files get_loaded_extensions
    get_required_files get_resource_type get_resources getenv gethostbyaddr gethostbyname
    gethostbynamel gethostname getopt getprotobyname getprotobynumber getservbyname
    getservbyport header_remove header_register_callback headers_list headers_sent hex2bin
    highlight_string hrtime http_build_query http_response_code inet_ntop inet_pton
    ip2long long2ip md5_file md5 sha1_file sha1 sleep usleep time_nanosleep
    time_sleep_until uniqid unpack vsprintf wordwrap
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    // 公式名和 .so 名对不上的几个，只能硬编码。FlyEnv 也是这么干的
    // （src/fork/module/Brew/index.ts 的 names 表）。
    static let extensionSonames = ["pecl_http": "http.so", "phalcon5": "phalcon.so",
                                   "phalcon4": "phalcon.so", "phalcon3": "phalcon.so",
                                   "mongodb1": "mongodb.so"]

    // xdebug / opcache 是 Zend 扩展，必须写成 zend_extension=，写成 extension= 会被静默忽略。
    static let zendExtensions = ["xdebug", "opcache"]

    private static let extensionTap = "/opt/homebrew/Library/Taps/shivammathur/homebrew-extensions/Formula"
    private static let cellar = "/opt/homebrew/Cellar"

    // 扩展目录。只有带 php-config 的 PHP 才支持动态扩展：static-php-cli 的 prebuilt 是静态链接，
    // 扩展编进二进制里了，既没有 php-config，它编进去的 extension_dir 还是
    // /lib/php/extensions/...（编译容器的路径，macOS 上根本不存在）。
    // 返回 nil 就代表这个版本装不了扩展，界面据此把入口关掉，而不是等用户点了按钮才报错。
    func extensionDirectory(_ version: PhpVersion) async -> String? {
        // MacPorts 的可执行文件叫 php-config84，Homebrew / Static 叫 php-config，两个都试。
        let suffix = version.majorMinor.replacingOccurrences(of: ".", with: "")
        let config = ["php-config", "php-config\(suffix)"]
            .map { version.directory.appendingPathComponent("bin/\($0)") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let config, let output = try? await Command.run(config.path, ["--extension-dir"]) else { return nil }
        let directory = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return directory.isEmpty ? nil : directory
    }

    // 已加载的扩展：php -m 分 [PHP Modules] 和 [Zend Modules] 两段，两段都算「在用」。
    // 输出里混着段标题和启动期的 Deprecated 行，一并滤掉。跑不起来就返回空表、不报错 ——
    // 一个缺 dylib 的 PHP 显示不出扩展是正常现象，弹错误框反而吓人。
    func loadedExtensions(_ version: PhpVersion) async -> [String] {
        guard version.runnable, let output = try? await Command.run(version.executable.path, ["-m"]) else { return [] }
        return Array(Set(output.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.contains("Deprecated") && !$0.contains("=>") }))
            .sorted()
    }

    // 可安装的扩展：直接读本地 tap 的 Formula 目录，不跑 `brew search` ——
    // 那个要联网、要好几秒，输出还得再正则抠一遍名字，本地文件就是现成的答案。
    // 注意目录名是 homebrew-extensions，而 tap 名和公式前缀都是 shivammathur/extensions。
    func availableExtensions(_ majorMinor: String) -> [String] {
        let suffix = "@\(majorMinor).rb"
        return ((try? FileManager.default.contentsOfDirectory(atPath: Self.extensionTap)) ?? [])
            .filter { $0.hasSuffix(suffix) }
            .map { String($0.dropLast(suffix.count)) }
            .sorted()
    }

    // MARK: - MacPorts 扩展

    static let macportsPort = "/opt/local/bin/port"

    var macportsInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.macportsPort) }

    // 可安装的 MacPorts 扩展：读本地 PortIndex（每行第一段就是 port 名），
    // 不跑 `port search` —— 那个要先 sync 索引，联网要等好几秒。
    // MacPorts 的 PHP 扩展 port 一律叫 php<XX>-<名字>（php84-swoole、php84-redis…）。
    func macportsExtensions(_ majorMinor: String) -> [String] {
        let prefix = "php" + majorMinor.replacingOccurrences(of: ".", with: "") + "-"
        let sources = "/opt/local/var/macports/sources"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: sources) else { return [] }
        var names: Set<String> = []
        for dir in dirs {
            let index = "\(sources)/\(dir)/macports/release/tarballs/PortIndex"
            guard let text = try? String(contentsOfFile: index, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.hasPrefix(prefix) {
                if let name = line.split(separator: " ").first, name.count > prefix.count {
                    names.insert(String(name.dropFirst(prefix.count)))
                }
            }
        }
        return names.sorted()
    }

    // MacPorts 装完直接把 .so 放进 php-config 报出来的扩展目录，不用像 brew 那样再拷一份。
    // 但那个 .so 是给 MacPorts 自己的 PHP 编译的，配 Homebrew / Static 的 PHP 会加载失败，
    // 所以调用方要先用 version.executable 判断这个 PHP 是不是 MacPorts 装的。
    func macportsInstall(_ name: String, for version: PhpVersion) async throws {
        try await privileged("PATH=/opt/local/bin:/usr/bin:/bin \(Self.macportsPort) -q install \(macportsPortName(name, version))")
    }

    func macportsRemove(_ name: String, for version: PhpVersion) async throws {
        try await privileged("PATH=/opt/local/bin:/usr/bin:/bin \(Self.macportsPort) -q uninstall \(macportsPortName(name, version))")
    }

    private func macportsPortName(_ name: String, _ version: PhpVersion) -> String {
        "php" + version.majorMinor.replacingOccurrences(of: ".", with: "") + "-" + name
    }

    // 装扩展分两步，FlyEnv 也这么干 —— 区别是它第二步让用户把 .so 复制到剪贴板自己粘，
    // 这里直接替用户拷过去：
    // 1. brew install shivammathur/extensions/<name>@8.4
    // 2. brew 把 .so 留在 Cellar 的 keg 里，PHP 的扩展目录看不到它，得拷一份
    // 返回真实的 soname，调用方拿去写 php.ini。
    func installExtension(_ name: String, for version: PhpVersion, report: @escaping (String) -> Void = { _ in }, onStart: ((Process) -> Void)? = nil) async throws -> String {
        guard let directory = await extensionDirectory(version) else {
            throw CommandError(message: L("error.phpExtensionUnsupported"))
        }
        try await Brew.run("install", formula: "shivammathur/extensions/\(name)@\(version.majorMinor)", report: report, onStart: onStart)
        // keg 里的 .so 不一定在顶层（xdebug 塞在 no-debug-non-zts-xxx/ 下面），递归找。
        let keg = URL(fileURLWithPath: "\(Self.cellar)/\(name)@\(version.majorMinor)", isDirectory: true)
        var source: URL?
        if let walker = FileManager.default.enumerator(at: keg, includingPropertiesForKeys: nil) {
            for case let file as URL in walker where file.pathExtension == "so" { source = file; break }
        }
        // 名字用 keg 里真实找到的那个：tap 里六十多个扩展，映射表兜不住的那几个
        // 猜错了会把一个不存在的 .so 名写进 php.ini，PHP 起来就报 "Unable to load"。
        guard let source else { throw CommandError(message: L("error.phpExtensionNotFound") + "（\(name)）") }
        let soname = source.lastPathComponent
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: directory), withIntermediateDirectories: true)
        let target = URL(fileURLWithPath: directory).appendingPathComponent(soname)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
        return soname
    }

    // 卸载：先删扩展目录里的 .so，再让 brew 收走公式。顺序是有意的 ——
    // 就算 brew 那步失败，PHP 也已经看不到这个扩展了，不会留下「ini 里还写着、文件却没了」的坏状态。
    func removeExtension(_ name: String, soname: String, for version: PhpVersion, report: @escaping (String) -> Void = { _ in }, onStart: ((Process) -> Void)? = nil) async throws {
        if let directory = await extensionDirectory(version) {
            try? FileManager.default.removeItem(atPath: directory + "/" + soname)
        }
        // 公式可能本来就没装过（用户手工拷的 .so），brew 会报错，这里不当失败处理。
        try? await Brew.run("uninstall", formula: "shivammathur/extensions/\(name)@\(version.majorMinor)", report: report, onStart: onStart)
    }

    // 把扩展写进 / 摘出 php.ini。装完不写 ini 等于没装，FlyEnv 到这一步是让用户复制粘贴的。
    func setExtension(_ name: String, soname: String, enabled: Bool, for version: PhpVersion) async throws {
        let path = try await iniPath(version)
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        // 先按 .so 名摘干净再写：同一个扩展可能被写成 extension= 也可能被写成 zend_extension=，
        // 两种都留着 PHP 会加载两遍。只摘指向这个 .so 的行，别的扩展一行不动。
        text = IniFile.remove("extension", containing: soname, from: text)
        text = IniFile.remove("zend_extension", containing: soname, from: text)
        if enabled {
            let key = Self.zendExtensions.contains(name) ? "zend_extension" : "extension"
            // php.ini 末尾没有换行时直接拼会把最后一行吃掉。
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\(key)=\(soname)\n"
        }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func download(_ source: URL, to archive: URL, report: @escaping (String) -> Void, onStart: ((Process) -> Void)? = nil) async throws {
        // 归档是我们的下载缓存，已经有了就别再拉一遍（PHP 的包一个上百 MB）。
        if FileManager.default.fileExists(atPath: archive.path) { return }
        try await Command.download(source, to: archive, report: report, onStart: onStart)
    }

    private func extract(_ archive: URL, into directory: URL, report: @escaping (String) -> Void) async throws {
        let status = try await Command.stream("/usr/bin/tar", ["-xzf", archive.path, "-C", directory.path], onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.unpackFailed") + "（\(status)）") }
    }
}
