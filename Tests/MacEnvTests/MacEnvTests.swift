import XCTest
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
        XCTAssertEqual(command, "/bin/bash '/tmp/macenv task.sh' < /dev/null > '/tmp/macenv task.log' 2>&1 & echo started")
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
    private let paths = ["$HOME/.macenv/env/java", "$HOME/.macenv/env/java/bin", "$HOME/.macenv/env/java/sbin"]

    func testPOSIXExportsJavaHome() {
        let block = PathService.shellBlock(paths: paths, exports: [("JAVA_HOME", "$HOME/.macenv/env/java")], fish: false)
        XCTAssertTrue(block.contains("export PATH=\"$HOME/.macenv/env/java:$HOME/.macenv/env/java/bin:$HOME/.macenv/env/java/sbin:$PATH\""))
        // JAVA_HOME 必须指向 JDK Home 本身，指到 bin 会让 Maven 找不到 lib 那一层。
        XCTAssertTrue(block.contains("export JAVA_HOME=\"$HOME/.macenv/env/java\""))
        XCTAssertTrue(block.hasPrefix("# >>> MacEnv PATH >>>"))
        XCTAssertTrue(block.hasSuffix("# <<< MacEnv PATH <<<\n"))
    }

    // fish 的 PATH 是数组，跟 POSIX 那套语法完全不同，写错一个字整条 PATH 就废了。
    func testFishUsesSetGx() {
        let block = PathService.shellBlock(paths: paths, exports: [("JAVA_HOME", "$HOME/.macenv/env/java")], fish: true)
        XCTAssertTrue(block.contains("set -gx PATH \"$HOME/.macenv/env/java\" \"$HOME/.macenv/env/java/bin\" \"$HOME/.macenv/env/java/sbin\" $PATH"))
        XCTAssertTrue(block.contains("set -gx JAVA_HOME \"$HOME/.macenv/env/java\""))
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
