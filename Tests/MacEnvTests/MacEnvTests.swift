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
}

// MARK: - PATH 归属

final class PathMembershipTests: XCTestCase {
    func testIcons() {
        XCTAssertEqual(PathMembership.app.icon, "checkmark.circle.fill")
        XCTAssertEqual(PathMembership.shell.icon, "exclamationmark.circle.fill")
        XCTAssertEqual(PathMembership.none.icon, "circle")
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
