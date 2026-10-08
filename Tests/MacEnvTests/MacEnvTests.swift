import XCTest
import Network
@testable import MacEnv

// MARK: - 数据库类型

final class DatabaseKindTests: XCTestCase {
    // MySQL 与 MariaDB 默认端口必须错开，否则两个服务无法同时启动。
    func testDefaultPortsAreDistinct() {
        XCTAssertEqual(DatabaseKind.mysql.defaultPort, 3306)
        XCTAssertEqual(DatabaseKind.mariadb.defaultPort, 3307)
    }

    func testBinaryNames() {
        XCTAssertEqual(DatabaseKind.mysql.binaryName, "mysqld")
        XCTAssertEqual(DatabaseKind.mariadb.binaryName, "mariadbd")
        XCTAssertEqual(DatabaseKind.mysql.adminBinaryName, "mysqladmin")
        XCTAssertEqual(DatabaseKind.mariadb.adminBinaryName, "mariadb-admin")
    }

    func testSocketPaths() {
        XCTAssertEqual(DatabaseKind.mysql.socketPath, "/tmp/mysql.socket")
        XCTAssertEqual(DatabaseKind.mariadb.socketPath, "/tmp/mariadb.socket")
    }

    func testConfigSections() {
        XCTAssertEqual(DatabaseKind.mysql.configSection, "mysqld")
        XCTAssertEqual(DatabaseKind.mariadb.configSection, "mariadbd")
    }
}

// MARK: - 数据库版本

final class DatabaseVersionTests: XCTestCase {
    private func make(_ kind: DatabaseKind, _ version: String) -> DatabaseVersion {
        DatabaseVersion(kind: kind, version: version,
                        directory: URL(fileURLWithPath: "/tmp"),
                        executable: URL(fileURLWithPath: "/tmp/bin"),
                        source: "static", formula: nil)
    }

    func testMajorMinor() {
        XCTAssertEqual(make(.mysql, "8.4.2").majorMinor, "8.4")
        XCTAssertEqual(make(.mariadb, "13.0.2").majorMinor, "13.0")
    }

    func testMajorMinorWithSingleComponent() {
        XCTAssertEqual(make(.mysql, "8").majorMinor, "8")
    }

    // 同一个可执行路径在不同 kind 下必须是不同的 id，否则列表会串。
    func testIdentityIsNamespacedByKind() {
        XCTAssertNotEqual(make(.mysql, "8.4.2").id, make(.mariadb, "8.4.2").id)
    }
}

// MARK: - Static 版本清单

final class StaticVersionTests: XCTestCase {
    private let sample = StaticVersion(name: "nginx", version: "1.27.0",
                                       url: URL(string: "https://example.com/nginx-1.27.0.tar.xz")!,
                                       downloaded: true, installed: false)

    func testIdIsVersion() {
        XCTAssertEqual(sample.id, "1.27.0")
    }

    // 清单要永久存盘再读回来，编解码必须无损。
    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode([sample])
        let decoded = try JSONDecoder().decode([StaticVersion].self, from: data)
        XCTAssertEqual(decoded, [sample])
    }
}

// MARK: - 命令执行

final class CommandTests: XCTestCase {
    func testRunCapturesStdout() async throws {
        let output = try await Command.run("/bin/echo", ["macenv"])
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "macenv")
    }

    func testRunReportsNonZeroStatus() async throws {
        let output = try await Command.run("/bin/sh", ["-c", "exit 3"])
        XCTAssertEqual(output.status, 3)
    }

    func testRunCapturesStderr() async throws {
        let output = try await Command.run("/bin/sh", ["-c", "echo boom >&2; exit 1"])
        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.text.contains("boom"))
    }

    func testRunThrowsForMissingExecutable() async {
        do {
            _ = try await Command.run("/nonexistent/macenv-binary", [])
            XCTFail("可执行文件不存在时应当抛错")
        } catch {
            // 预期路径
        }
    }

    func testPrivilegedLaunchCommandAvoidsNohupAndRedirectsAllStreams() {
        let command = Command.privilegedLaunchCommand(
            script: URL(fileURLWithPath: "/tmp/macenv task.sh"),
            log: URL(fileURLWithPath: "/tmp/macenv task.log")
        )
        XCTAssertTrue(command.contains("set -m;"))
        XCTAssertTrue(command.contains("2>&1 & echo $!"))
        XCTAssertTrue(command.contains("task.sh.pid"))
        XCTAssertFalse(command.contains("nohup"))
    }

    func testPrivilegedLaunchCommandContinuesAfterLaunchingShellReturns() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("macenv-background-test-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let script = directory.appendingPathComponent("task.sh")
        let log = directory.appendingPathComponent("task.log")
        let marker = directory.appendingPathComponent("finished")
        try "#!/bin/bash\n/bin/sleep 0.2\n/usr/bin/touch \(singleQuoted(marker.path))\n".write(to: script, atomically: true, encoding: .utf8)
        try Data().write(to: log)

        let output = try await Command.run("/bin/sh", ["-c", Command.privilegedLaunchCommand(script: script, log: log)])
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "started")

        let deadline = Date().addingTimeInterval(3)
        while !fm.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(fm.fileExists(atPath: marker.path), "后台任务应在启动 shell 返回后继续运行")
    }
}

// MARK: - PATH 归属

final class PathMembershipTests: XCTestCase {
    func testIcons() {
        XCTAssertEqual(PathMembership.app.icon, "checkmark.circle.fill")
        XCTAssertEqual(PathMembership.shell.icon, "exclamationmark.circle.fill")
        XCTAssertEqual(PathMembership.none.icon, "circle")
    }
}

// MARK: - 写进 shell 配置的那一段

@MainActor
final class ShellBlockTests: XCTestCase {
    private let paths = ["/Users/fixture/.macenv/env/java", "/Users/fixture/.macenv/env/java/bin", "/Users/fixture/.macenv/env/java/sbin"]

    func testPOSIXExportsJavaHome() {
        let block = PathService.shellBlock(paths: paths, exports: [("JAVA_HOME", "/Users/fixture/.macenv/env/java")], fish: false)
        XCTAssertTrue(block.contains("export PATH='/Users/fixture/.macenv/env/java:/Users/fixture/.macenv/env/java/bin:/Users/fixture/.macenv/env/java/sbin':\"$PATH\""))
        // JAVA_HOME 必须指向 JDK Home 本身，指到 bin 会让 Maven 找不到 lib 那一层。
        XCTAssertTrue(block.contains("export JAVA_HOME='/Users/fixture/.macenv/env/java'"))
        XCTAssertTrue(block.hasPrefix("# >>> MacEnv PATH >>>"))
        XCTAssertTrue(block.hasSuffix("# <<< MacEnv PATH <<<\n"))
    }

    // fish 的 PATH 是数组，跟 POSIX 那套语法完全不同，写错一个字整条 PATH 就废了。
    func testFishUsesSetGx() {
        let block = PathService.shellBlock(paths: paths, exports: [("JAVA_HOME", "/Users/fixture/.macenv/env/java")], fish: true)
        XCTAssertTrue(block.contains("set -gx PATH '/Users/fixture/.macenv/env/java' '/Users/fixture/.macenv/env/java/bin' '/Users/fixture/.macenv/env/java/sbin' $PATH"))
        XCTAssertTrue(block.contains("set -gx JAVA_HOME '/Users/fixture/.macenv/env/java'"))
        XCTAssertFalse(block.contains("export"))
    }

    // 没启用 Java 时（env/ 下没有 java 软链）不能留一个空的 export。
    func testNoExportWithoutJava() {
        let block = PathService.shellBlock(paths: paths, exports: [], fish: false)
        XCTAssertFalse(block.contains("JAVA_HOME"))
    }
}


// MARK: - Composer 版本发现

@MainActor
final class ComposerServiceTests: XCTestCase {
    // composer 是个 phar：__HALT_COMPILER() 之后紧跟二进制清单和压缩负载，整个文件不是合法
    // UTF-8。用 String(contentsOf:encoding:.utf8) 严格解码会直接拿到 nil，候选被 guard 吃掉，
    // 用户自己装在 PATH 里的 composer 就凭空消失了。这里造一个同样形状的文件来锁住这个行为。
    func testFindsVersionInNonUTF8Phar() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macenv-composer-test-\(UUID().uuidString)")
        let bin = base.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        var data = Data("#!/usr/bin/env php\n<?php\npublic const VERSION = '9.9.9';\n__HALT_COMPILER(); ?>\n".utf8)
        data.append(contentsOf: [0x82, 0xC4, 0x00, 0x00, 0xFF, 0xFE])
        let composer = bin.appendingPathComponent("composer")
        try data.write(to: composer)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: composer.path)

        let versions = try ComposerService(root: base).installedVersions(customDirectories: [bin.path])
        XCTAssertEqual(versions.map(\.version), ["9.9.9"])
    }
}

// MARK: - Java / SDKMAN

@MainActor
final class JavaServiceTests: XCTestCase {
    // `sdk list java` 是 4 列，vendor 只在换厂商那一行出现、续行是空的，必须继承上一行。
    // 表头、分隔线和末尾那行图例列数不对，都要跳过。
    func testParseSdkmanJava() {
        let output = """
         Vendor         | Use | Version            | Identifier
        --------------------------------------------------------------------------------
         Corretto       |     | 27.0.0             | 27.0.0-amzn
                        | > * | 21.0.12            | 21.0.12-amzn
                        |     | 17.0.20            | 17.0.20-amzn
         GraalVM CE     |     | 25.4.4.1+1         | 25.4.4.1+1-graalce
         > in use   * installed   + local only
        """
        let versions = JavaService.parseSdkmanJava(output)
        XCTAssertEqual(versions.map(\.identifier), ["27.0.0-amzn", "21.0.12-amzn", "17.0.20-amzn", "25.4.4.1+1-graalce"])
        // 续行的 vendor 继承上一行的 Corretto，不是空串。
        XCTAssertEqual(versions.map(\.vendor), ["Corretto", "Corretto", "Corretto", "GraalVM CE"])
        XCTAssertTrue(versions[1].isDefault)
        XCTAssertTrue(versions[1].installed)
        XCTAssertFalse(versions[0].installed)
    }

    // JDK Home 是装着 bin/ 和 release 的那一层，Contents/Home 和裸 Home 两种落点都要认。
    func testJavaHome() {
        XCTAssertEqual(JavaService.javaHome(of: URL(fileURLWithPath: "/x/jdk/Contents/Home/bin/java")).path, "/x/jdk/Contents/Home")
        XCTAssertEqual(JavaService.javaHome(of: URL(fileURLWithPath: "/x/jdk/bin/java")).path, "/x/jdk")
    }
}

// MARK: - MacPorts 可装清单解析

@MainActor
final class PortSearchTests: XCTestCase {
    // port search --line 每行「名字\t版本\t类别\t描述」，类别可能带空格（lang www）。
    private let sample = """
    php\t8.5\tlang www\tPHP: Hypertext Preprocessor
    nginx\t1.30.5\twww mail\tHigh-performance HTTP(S) server, HTTP(S) reverse proxy and IMAP/POP3 proxy server
    redis90\t9.0\t@databases\tRedis is an open source, advanced key-value store.
    """

    func testKeepsDescriptionMatches() {
        let result = ToolService.parsePortSearch(sample, descriptions: ["High-performance HTTP(S) server"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "nginx")
        XCTAssertEqual(result.first?.version, "1.30.5")
    }

    // 版本列可能带 @（port list 的写法），解析要统一剥掉。
    func testStripsAtPrefixFromVersion() {
        let result = ToolService.parsePortSearch("redis90\t@9.0\tdatabases\tdesc", descriptions: [])
        XCTAssertEqual(result.first?.version, "9.0")
    }

    func testDropsNonMatchingAndMalformedLines() {
        XCTAssertTrue(ToolService.parsePortSearch(sample, descriptions: ["OpenJDK "]).isEmpty)
        // 没有 tab 的行（「No match for x found」）不成对，跳过。
        XCTAssertTrue(ToolService.parsePortSearch("No match for nginx found\n", descriptions: []).isEmpty)
    }
}

// MARK: - MacPorts PHP 扩展名解析

@MainActor
final class PortExtensionTests: XCTestCase {
    private let sample = """
    php84-curl\t8.4.26\tlang php net www\ta PHP interface to the curl library
    php84-fpm\t8.4.26\tlang www\tphp84 FPM SAPI
    php84\t8.4.26\tlang www\tPHP: Hypertext Preprocessor
    php84-APCu\t5.1.28\tphp www\tAPCu
    """

    // fpm/cgi 这类 SAPI 子 port（类别恰好 lang www）不是可加载的扩展，滤掉；
    // php84 本体不带前缀；curl 的类别是 lang php net www，不含连续的 lang www，保留。
    // 名字统一小写，跟 brew tap 的公式名对齐。
    func testDropsSapiSubportsAndLowercases() {
        XCTAssertEqual(PhpService.parsePortExtensionNames(sample, prefix: "php84-"), ["apcu", "curl"])
    }
}

// MARK: - MacPorts 清单缓存

@MainActor
final class PortCacheTests: XCTestCase {
    private let json = #"[{"name":"nginx","version":"1.30.5"}]"#

    // 缓存回环：catalog/port-<app>.json 里的条目要能原样读出来。
    // installed 不进缓存、按落点现判，所以这里只断言名字和版本。
    func testCacheRoundTrip() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macenv-port-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("catalog", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data(json.utf8).write(to: base.appendingPathComponent("catalog/port-nginx.json"))

        let service = ToolService(root: base)
        let items = service.portCached(app: "nginx")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "nginx")
        XCTAssertEqual(items.first?.version, "1.30.5")
    }

    // 写过缓存（mtime 在 1 小时内）算新鲜；没写过的 app 不新鲜，要真查。
    func testCacheFreshness() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macenv-port-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("catalog", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data(json.utf8).write(to: base.appendingPathComponent("catalog/port-nginx.json"))

        let service = ToolService(root: base)
        XCTAssertTrue(service.portCacheFresh(app: "nginx"))
        XCTAssertFalse(service.portCacheFresh(app: "maven"))
    }

    // composer 没有 port 目录定义，就算有缓存文件也不给列表。
    func testUnknownAppReturnsEmpty() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macenv-port-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("catalog", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data(json.utf8).write(to: base.appendingPathComponent("catalog/port-composer.json"))

        XCTAssertTrue(ToolService(root: base).portCached(app: "composer").isEmpty)
    }
}

@MainActor
final class PostgresServiceTests: XCTestCase {
    func testParseVersion() {
        XCTAssertEqual(PostgresService.parseVersion("postgres (PostgreSQL) 16.4"), "16.4")
        XCTAssertEqual(PostgresService.parseVersion("postgres (PostgreSQL) 9.6.24"), "9.6.24")
        XCTAssertNil(PostgresService.parseVersion("postgres (MySQL) 8.0"))
        XCTAssertNil(PostgresService.parseVersion(""))
    }

    func testParsePort() {
        // postgresql.conf 是「key = value」加 # 注释的标准 ini 风格。
        XCTAssertEqual(PostgresService.parsePort("#port = 1234\nport = 5433\n"), 5433)
        XCTAssertEqual(PostgresService.parsePort("port = '5432'"), nil)
        XCTAssertNil(PostgresService.parsePort(nil))
        XCTAssertNil(PostgresService.parsePort("listen_addresses = 'localhost'"))
    }

    func testContentLengthParsing() {
        // 多段响应（302 + 200）取最后一个 Content-Length；没有就 nil，跳过校验。
        let headers = "HTTP/2 302\n\nHTTP/2 200\nContent-Type: application/octet-stream\nContent-Length: 182697369\n"
        XCTAssertEqual(Command.contentLength(headers), 182697369)
        XCTAssertNil(Command.contentLength("HTTP/2 200\nTransfer-Encoding: chunked\n"))
        XCTAssertNil(Command.contentLength("HTTP/2 302\r\nContent-Length: 123\r\n\r\nHTTP/2 200\r\nTransfer-Encoding: chunked\r\n"))
        XCTAssertEqual(Command.contentLength("HTTP/2 200\ncontent-length: 123 \n"), 123)
    }

    // locale 必须显式带：GUI 环境没有 LANG/LC_*，initdb 会报「无效的区域设置」直接死。
    func testInitdbArguments() {
        let args = PostgresService.initdbArguments(URL(fileURLWithPath: "/tmp/data-18"))
        XCTAssertEqual(args, ["-D", "/tmp/data-18", "-U", "root", "--locale=en_US.UTF-8", "--encoding=UTF8"])
        XCTAssertEqual(PostgresService.initdbLocale, "en_US.UTF-8")
    }
}

@MainActor
final class BrewListRowsTests: XCTestCase {
    private func formula(_ name: String, _ installed: [String], stable: String = "") -> BrewFormulaItem {
        BrewFormulaItem(name: name, stable: stable, installedVersions: installed, linkedVersion: nil, outdated: false)
    }

    // 全表按版本号从大到小：postgresql@18 的 18.6 排在 postgresql@17 前面，没装的公式用 stable 参与排序。
    func testSortedByVersionDescending() {
        let rows = Brew.listRows([
            formula("postgresql@17", ["17.6"], stable: "17.6"),
            formula("postgresql@18", ["18.6"], stable: "18.6"),
            formula("postgresql@16", [], stable: "16.9"),
        ])
        XCTAssertEqual(rows.map { $0.version ?? $0.formula.stable }, ["18.6", "17.6", "16.9"])
    }

    // 同一公式多版本之间也按版本倒序。
    func testMultipleInstalledVersionsOfOneFormula() {
        let rows = Brew.listRows([formula("php", ["8.2.28", "8.5.1", "8.4.6"])])
        XCTAssertEqual(rows.map { $0.version ?? "" }, ["8.5.1", "8.4.6", "8.2.28"])
    }
}

@MainActor
final class ServiceManageablePolicyTests: XCTestCase {
    // 端口固定的服务：优先起勾了快捷启动的版本，没勾就用列表第一个（扫描结果已按版本从大到小排）。
    func testPreferredTargetPrefersQuickStartThenHighest() throws {
        let stub = StubManageable(keys: ["pg-17", "pg-18"])
        XCTAssertEqual(stub.preferredTarget(quickStart: ["pg-17"])?.key, "pg-17")
        XCTAssertEqual(stub.preferredTarget(quickStart: ["pg-17", "pg-18"])?.key, "pg-17")
        // 没勾任何快捷启动时回落到列表第一个（版本号最大的那个）。
        XCTAssertEqual(stub.preferredTarget(quickStart: [])?.key, "pg-17")
        XCTAssertEqual(stub.preferredTarget(quickStart: ["不存在"])?.key, "pg-17")
    }

    func testDefaultSingleInstanceAndOverrides() {
        XCTAssertTrue(StubManageable(keys: []).singleInstance)
        XCTAssertFalse(NginxOverrideStub().singleInstance)
    }
}

@MainActor
private final class StubManageable: ServiceManageable {
    let keys: [String]
    init(keys: [String]) { self.keys = keys }
    var kind: String { "stub" }
    var targets: [LaunchTarget] { keys.map { LaunchTarget(key: $0, kind: "stub", versionID: $0, title: $0) } }
    func isRunning(_ versionID: String) -> Bool { false }
    func port(_ versionID: String) -> String? { nil }
    func operate(_ action: String, _ versionID: String) async {}
    func perform(_ action: String, _ versionID: String) async throws {}
    func stopAll() async {}
    func membership(_ versionID: String) -> PathMembership { .none }
    func togglePath(_ versionID: String) {}
}

// nginx / php 这类多实例服务要能覆写 singleInstance。
private final class NginxOverrideStub: ServiceManageable {
    var singleInstance: Bool { false }
    var kind: String { "nginx-stub" }
    var targets: [LaunchTarget] { [] }
    func isRunning(_ versionID: String) -> Bool { false }
    func port(_ versionID: String) -> String? { nil }
    func operate(_ action: String, _ versionID: String) async {}
    func perform(_ action: String, _ versionID: String) async throws {}
    func stopAll() async {}
    func membership(_ versionID: String) -> PathMembership { .none }
    func togglePath(_ versionID: String) {}
}


@MainActor
final class RuntimeRegressionTests: XCTestCase {
    func testSupervisorRejectsForeignProcessAndChangedIdentity() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macenv-owner-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let foreign = Process()
        foreign.executableURL = URL(fileURLWithPath: "/bin/sleep")
        foreign.arguments = ["30"]
        try foreign.run()
        defer { Command.cancel(foreign) }
        let supervisor = ProcessSupervisor(marker: root.path)
        XCTAssertNil(supervisor.inspect(foreign.processIdentifier))
        let own = try supervisor.launch(at: URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", "/bin/sleep 30; true", root.path], directory: root, environment: [:], errorLog: root.appendingPathComponent("err"))
        defer { Command.cancel(own) }
        let target = try XCTUnwrap(supervisor.target)
        let changed = ManagedProcess(pid: target.pid, command: target.command, executable: target.executable, startedAt: target.startedAt + 1)
        try supervisor.signal(changed, SIGTERM)
        XCTAssertTrue(own.isRunning, "身份不匹配时不能发送信号")
        let adopted = ProcessSupervisor(marker: root.path)
        adopted.adopt(target)
        XCTAssertTrue(adopted.isRunning)
        try await supervisor.terminate(target, force: true)
        XCTAssertFalse(adopted.isRunning, "认领的进程退出后状态必须更新")
    }

    func testCancelledCommandStopsItsChildren() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("macenv-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task { try await Command.run("/bin/sh", ["-c", "/bin/sleep 0.8; /usr/bin/touch " + singleQuoted(marker.path)]) }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("取消应该抛出 CancellationError") }
        catch { XCTAssertTrue(error.isCancelled) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "被取消的子进程不能继续执行")
    }

    func testFailedDownloadDoesNotBecomeCache() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("macenv-download-" + UUID().uuidString)
        do { try await Command.download(file.appendingPathExtension("missing"), to: file); XCTFail("缺失源应该下载失败") }
        catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("part").path))
    }

    func testCorruptHostJSONCannotBeOverwritten() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macenv-host-json-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let service = HostService(root: root)
        XCTAssertEqual(try service.load().count, 0)
        for text in ["{invalid", ""] {
            let bytes = Data(text.utf8)
            try bytes.write(to: service.file)
            XCTAssertThrowsError(try service.load())
            XCTAssertThrowsError(try service.save([]))
            XCTAssertEqual(try Data(contentsOf: service.file), bytes)
        }
    }

    func testShellBlockPreservesLiteralSpecialCharacters() async throws {
        let path = "/tmp/space ' quote $dollar `backtick`"
        let block = PathService.shellBlock(paths: [path], exports: [("JAVA_HOME", path)], fish: false)
        let output = try await Command.run("/bin/sh", ["-c", block + "printf '%s\\n%s' \"$JAVA_HOME\" \"$PATH\""])
        XCTAssertEqual(output.status, 0)
        XCTAssertTrue(output.stdout.hasPrefix(path + "\n" + path + ":"))
    }

    func testHTTP503DoesNotMarkServiceReadyAndCancellationStopsIt() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        var requests = 0
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                connection.send(content: Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                Task { @MainActor in requests += 1 }
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel() }
        for _ in 0..<100 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        let port = try XCTUnwrap(listener.port)
        let probe = try await Command.run("/usr/bin/curl", ["-sS", "--fail", "--noproxy", "*", "--max-time", "1", "http://127.0.0.1:\(port.rawValue)"])
        XCTAssertEqual(probe.status, 22, "port=\(port.rawValue), response=\(probe.text)")
        requests = 0
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macenv-readiness-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let binary = root.appendingPathComponent("qdrant")
        try "#!/bin/bash\ntrap 'exit 0' TERM\nwhile :; do /bin/sleep 0.1; done\n".write(to: binary, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let version = QdrantVersion(version: "test", directory: root, executable: binary, source: "test")
        let service = QdrantService(root: root)
        try service.prepare(version)
        try "service:\n  http_port: \(port.rawValue)\n".write(to: service.configURL(for: version), atomically: true, encoding: .utf8)
        let task = Task { try await service.start(version) }
        defer { task.cancel() }
        for _ in 0..<200 where requests < 2 && !service.running(version) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertGreaterThanOrEqual(requests, 2, "503 应继续等待，不能提前返回启动成功")
        XCTAssertFalse(service.running(version))
        let receipt = try XCTUnwrap(fm.contentsOfDirectory(at: service.directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("process-") })
        let pid = try JSONDecoder().decode(ManagedProcess.self, from: Data(contentsOf: receipt)).pid
        XCTAssertEqual(Darwin.kill(pid, 0), 0)
        task.cancel()
        do { try await task.value; XCTFail("取消启动应该抛错") }
        catch { XCTAssertTrue(error.isCancelled) }
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "启动取消后不能留下服务进程")
    }

    func testInvalidNginxAndHostConfigRestorePreviousFiles() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/opt/nginx/bin/nginx") else { throw XCTSkip("需要本机 Nginx") }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macenv-config-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let services = Services(root: root)
        try services.nginx.prepare()
        let previous = try Data(contentsOf: services.nginx.config)
        let state = AppState()
        let nginx = NginxViewModel(state: state, services: services)
        nginx.configText = "invalid_directive;"
        nginx.saveConfig()
        for _ in 0..<300 where state.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.busy)
        XCTAssertEqual(try Data(contentsOf: services.nginx.config), previous)
        XCTAssertFalse(state.message.isEmpty)

        var host = MacEnv.Host()
        host.name = "rollback.localhost"
        host.root = root.path
        try services.hosts.write(host)
        try services.hosts.save([host])
        let config = services.hosts.nginxDirectory.appendingPathComponent(host.id + ".conf")
        let original = try Data(contentsOf: config)
        let json = try Data(contentsOf: services.hosts.file)
        let vm = HostViewModel(state: state, services: services)
        vm.hosts = [host]
        vm.saveConfig(host, "invalid_directive;")
        for _ in 0..<300 where state.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.busy)
        XCTAssertEqual(try Data(contentsOf: config), original)
        XCTAssertEqual(try Data(contentsOf: services.hosts.file), json)
        XCTAssertEqual(vm.hosts, [host])
    }

    func testAdoptedNginxCanReload() async throws {
        let executable = URL(fileURLWithPath: "/opt/homebrew/opt/nginx/bin/nginx").resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("需要本机 Nginx") }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/macenv-nginx-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let service = NginxService(root: root)
        try service.prepare()
        let socket = root.appendingPathComponent("nginx.sock")
        let config = "events {}\nhttp {\nserver {\nlisten unix:" + socket.path + ";\nreturn 200 'first';\n}\n}\n"
        try config.write(to: service.config, atomically: true, encoding: .utf8)
        let version = NginxVersion(version: "test", directory: executable.deletingLastPathComponent().deletingLastPathComponent(), executable: executable, source: "test")
        try await service.start(version)
        do {
            let adopted = NginxService(root: root)
            await adopted.adopt([version])
            XCTAssertTrue(adopted.running(version))
            try config.replacingOccurrences(of: "first", with: "second").write(to: service.config, atomically: true, encoding: .utf8)
            try await adopted.reload(version)
            var response = ""
            for _ in 0..<30 {
                response = try await Command.run("/usr/bin/curl", ["-s", "--max-time", "1", "--unix-socket", socket.path, "http://localhost/"]).stdout
                if response == "second" { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(response, "second")
            try await adopted.stop()
            XCTAssertFalse(service.running(version))
        } catch {
            try await service.stopAll()
            throw error
        }
    }

    func testPhpFpmSwitchesOnlyTheRequestedMinorVersion() async throws {
        let fm = FileManager.default
        let binary = URL(fileURLWithPath: "/opt/homebrew/opt/php/sbin/php-fpm").resolvingSymlinksInPath()
        guard fm.isExecutableFile(atPath: binary.path) else { throw XCTSkip("需要本机 PHP-FPM") }
        let root = fm.temporaryDirectory.appendingPathComponent("macenv-fpm-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let first = root.appendingPathComponent("php-fpm-first")
        let second = root.appendingPathComponent("php-fpm-second")
        try fm.copyItem(at: binary, to: first)
        try fm.copyItem(at: binary, to: second)
        let v1 = PhpVersion(version: "99.7.1", directory: root, executable: first, source: "test", formula: nil, runnable: true, fpmOverride: first)
        let v2 = PhpVersion(version: "99.7.2", directory: root, executable: second, source: "test", formula: nil, runnable: true, fpmOverride: second)
        let service = PhpFpmService(root: root)
        defer { try? fm.removeItem(atPath: service.socketPath(v1)) }
        do {
            try await service.start(v1)
            XCTAssertTrue(service.running(v1))
            XCTAssertFalse(service.running(v2))
            try await service.start(v2)
            XCTAssertFalse(service.running(v1))
            XCTAssertTrue(service.running(v2))
            try await service.stop(v1)
            XCTAssertTrue(service.running(v2), "旧版本的停止按钮不能停止新版本")
            try await service.stop(v2)
            XCTAssertFalse(service.anyRunning)
        } catch {
            try await service.stopAll()
            throw error
        }
    }

    func testLateStreamingOutputCannotPolluteNewTask() async throws {
        let state = AppState()
        var oldReport: ((String) -> Void)?
        state.runStreaming("first") { report, _ in oldReport = report }
        for _ in 0..<20 where state.taskRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        state.dismissTask()
        state.runStreaming("second") { _, _ in try await Task.sleep(nanoseconds: 100_000_000) }
        oldReport?("stale output")
        XCTAssertFalse(state.task?.log.contains("stale output") ?? true)
        state.cancelTask()
        for _ in 0..<20 where state.taskRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.taskRunning)
        state.dismissTask()
    }
}
