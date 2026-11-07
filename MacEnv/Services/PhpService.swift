import Foundation

@MainActor
final class PhpService {
    let root: URL

    var directory: URL { root.appendingPathComponent("server/php", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    private var archives: URL { root.appendingPathComponent("cache", isDirectory: true) }
    private var cacheDirectory: URL { root.appendingPathComponent("catalog", isDirectory: true) }
    private static let portRefreshInterval: TimeInterval = 3600

    init(root: URL) { self.root = root }

    func installedVersions(customDirectories: [String] = []) async throws -> [PhpVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String, String?)] = []
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
        for item in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/opt/local/bin", isDirectory: true), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            let name = item.lastPathComponent
            guard name.range(of: "^php\\d+$", options: .regularExpression) != nil, fm.isExecutableFile(atPath: item.path) else { continue }
            candidates.append((item, "MacPorts", nil))
        }
        var seen = Set<String>()
        var result: [PhpVersion] = []
        for (file, source, formula) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path),
                  (try? executable.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  seen.insert(executable.path).inserted else { continue }
            let digits = executable.lastPathComponent.dropFirst("php".count)
            let directory = source == "MacPorts" ? executable.deletingLastPathComponent()
                                                 : executable.deletingLastPathComponent().deletingLastPathComponent()
            let output = try? await Command.run(executable.path, ["-v"])
            var version: String?
            let runnable = output?.status == 0
            if let output, output.status == 0 {
                version = output.text.split(whereSeparator: \.isNewline)
                    .first { $0.hasPrefix("PHP ") }?
                    .dropFirst(4).split(separator: " ").first.map(String.init)
            }
            if version == nil { version = formula.flatMap { _ in directory.lastPathComponent.components(separatedBy: "_").first } }
            if version == nil, source == "MacPorts", let n = Int(digits), (10...99).contains(n) {
                version = "\(n / 10).\(n % 10)"
            }
            guard let version, !version.isEmpty else { continue }
            var fpmOverride: URL?
            if source == "MacPorts", !digits.isEmpty {
                fpmOverride = URL(fileURLWithPath: "/opt/local/sbin/php-fpm\(digits)")
            }
            result.append(PhpVersion(version: version, directory: directory, executable: executable,
                                     source: directory.path.hasPrefix("/opt/local") ? "MacPorts" : source,
                                     formula: formula, runnable: runnable, fpmOverride: fpmOverride))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func install(_ version: StaticVersion, report: @escaping (String) -> Void = { _ in }, onStart: ((Process) -> Void)? = nil) async throws {
        let cli = URL(string: version.url.absoluteString.replacingOccurrences(of: "-fpm-", with: "-cli-")) ?? version.url
        let cliArchive = archives.appendingPathComponent("static-php-\(version.version).tar.gz")
        let fpmArchive = archives.appendingPathComponent("static-php-\(version.version)-fpm.tar.gz")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        try await download(cli, to: cliArchive, report: report, onStart: onStart)
        try await download(version.url, to: fpmArchive, report: report, onStart: onStart)

        let target = versionsDirectory.appendingPathComponent("php-\(version.version)")
        let staging = versionsDirectory.appendingPathComponent(".staging-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("sbin"), withIntermediateDirectories: true)
        try await extract(cliArchive, into: staging.appendingPathComponent("bin"), report: report)
        try await extract(fpmArchive, into: staging.appendingPathComponent("sbin"), report: report)
        guard FileManager.default.isExecutableFile(atPath: staging.appendingPathComponent("bin/php").path),
              FileManager.default.isExecutableFile(atPath: staging.appendingPathComponent("sbin/php-fpm").path) else {
            throw CommandError(message: L("error.binaryMissing") + "PHP / PHP-FPM")
        }
        try Task.checkCancellation()
        try FileManager.default.replaceDirectory(at: target, with: staging)
    }

    func iniPath(_ version: PhpVersion) async throws -> String {
        var directory = ""
        if version.runnable, let output = try? await Command.run(version.executable.path, ["-i"]) {
            for line in output.text.split(whereSeparator: \.isNewline) {
                let parts = line.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                if parts[0] == "Loaded Configuration File", parts[1] != "(none)" { return parts[1] }
                if parts[0] == "Configuration File (php.ini) Path" { directory = parts[1] }
            }
        }
        if directory.isEmpty,
           let output = try? await Command.run(version.directory.appendingPathComponent("bin/php-config").path, ["--ini-path"]) {
            directory = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !directory.isEmpty else { throw CommandError(message: L("error.phpIniNotFound")) }
        return directory + "/php.ini"
    }

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

    static let extensionSonames = ["pecl_http": "http.so", "phalcon5": "phalcon.so",
                                   "phalcon4": "phalcon.so", "phalcon3": "phalcon.so",
                                   "mongodb1": "mongodb.so"]

    static let zendExtensions = ["xdebug", "opcache"]

    private static let extensionTap = "/opt/homebrew/Library/Taps/shivammathur/homebrew-extensions/Formula"
    private static let cellar = "/opt/homebrew/Cellar"

    func extensionDirectory(_ version: PhpVersion) async -> String? {
        let suffix = version.majorMinor.replacingOccurrences(of: ".", with: "")
        let config = ["php-config", "php-config\(suffix)"]
            .map { version.directory.appendingPathComponent("bin/\($0)") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let config, let output = try? await Command.run(config.path, ["--extension-dir"]) else { return nil }
        let directory = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return directory.isEmpty ? nil : directory
    }

    func loadedExtensions(_ version: PhpVersion) async -> [String] {
        guard version.runnable, let output = try? await Command.run(version.executable.path, ["-m"]) else { return [] }
        return Array(Set(output.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.contains("Deprecated") && !$0.contains("=>") }))
            .sorted()
    }

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

    func macportsExtensions(_ majorMinor: String) async -> [String] {
        let prefix = "php" + majorMinor.replacingOccurrences(of: ".", with: "") + "-"
        let cache = cacheDirectory.appendingPathComponent("port-\(prefix)extensions.json")
        let modified = (try? FileManager.default.attributesOfItem(atPath: cache.path))?[.modificationDate] as? Date
        if let modified, Date().timeIntervalSince(modified) < Self.portRefreshInterval,
           let data = try? Data(contentsOf: cache),
           let names = try? JSONDecoder().decode([String].self, from: data) { return names }
        guard let output = try? await Command.run(Self.macportsPort, ["search", "--name", "--line", prefix]) else {
            return ((try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? []
        }
        let names = Self.parsePortExtensionNames(output.stdout, prefix: prefix)
        if !names.isEmpty {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(names).write(to: cache, options: .atomic)
        }
        return names
    }

    static func parsePortExtensionNames(_ text: String, prefix: String) -> [String] {
        var names: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) where !line.contains("lang www") {
            guard let name = line.split(separator: "\t", omittingEmptySubsequences: true).first,
                  name.hasPrefix(prefix), name.count > prefix.count else { continue }
            names.insert(String(name.dropFirst(prefix.count)).lowercased())
        }
        return names.sorted()
    }

    func macportsInstall(_ name: String, for version: PhpVersion) async throws {
        try await privileged("PATH=/opt/local/bin:/usr/bin:/bin \(Self.macportsPort) -q install \(macportsPortName(name, version))")
    }

    func macportsRemove(_ name: String, for version: PhpVersion) async throws {
        try await privileged("PATH=/opt/local/bin:/usr/bin:/bin \(Self.macportsPort) -q uninstall \(macportsPortName(name, version))")
    }

    private func macportsPortName(_ name: String, _ version: PhpVersion) -> String {
        "php" + version.majorMinor.replacingOccurrences(of: ".", with: "") + "-" + name
    }

    func installExtension(_ name: String, for version: PhpVersion, report: @escaping (String) -> Void = { _ in }, onStart: ((Process) -> Void)? = nil) async throws -> String {
        guard let directory = await extensionDirectory(version) else {
            throw CommandError(message: L("error.phpExtensionUnsupported"))
        }
        try await Brew.run("install", formula: "shivammathur/extensions/\(name)@\(version.majorMinor)", report: report, onStart: onStart)
        let keg = URL(fileURLWithPath: "\(Self.cellar)/\(name)@\(version.majorMinor)", isDirectory: true)
        var source: URL?
        if let walker = FileManager.default.enumerator(at: keg, includingPropertiesForKeys: nil) {
            source = walker.compactMap { $0 as? URL }.first { $0.pathExtension == "so" }
        }
        guard let source else { throw CommandError(message: L("error.phpExtensionNotFound") + "（\(name)）") }
        let soname = source.lastPathComponent
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: directory), withIntermediateDirectories: true)
        let target = URL(fileURLWithPath: directory).appendingPathComponent(soname)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
        return soname
    }

    func removeExtension(_ name: String, soname: String, for version: PhpVersion, report: @escaping (String) -> Void = { _ in }, onStart: ((Process) -> Void)? = nil) async throws {
        if let directory = await extensionDirectory(version) {
            try? FileManager.default.removeItem(atPath: directory + "/" + soname)
        }
        try? await Brew.run("uninstall", formula: "shivammathur/extensions/\(name)@\(version.majorMinor)", report: report, onStart: onStart)
    }

    func setExtension(_ name: String, soname: String, enabled: Bool, for version: PhpVersion) async throws {
        let path = try await iniPath(version)
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        text = IniFile.remove("extension", containing: soname, from: text)
        text = IniFile.remove("zend_extension", containing: soname, from: text)
        if enabled {
            let key = Self.zendExtensions.contains(name) ? "zend_extension" : "extension"
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\(key)=\(soname)\n"
        }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func download(_ source: URL, to archive: URL, report: @escaping (String) -> Void, onStart: ((Process) -> Void)? = nil) async throws {
        if FileManager.default.fileExists(atPath: archive.path) { return }
        try await Command.download(source, to: archive, report: report, onStart: onStart)
    }

    private func extract(_ archive: URL, into directory: URL, report: @escaping (String) -> Void) async throws {
        let status = try await Command.stream("/usr/bin/tar", ["-xzf", archive.path, "-C", directory.path], onOutput: report)
        guard status == 0 else {
            try FileManager.default.removeItem(at: archive)
            throw CommandError(message: L("error.unpackFailed") + "（\(status)）")
        }
    }
}
