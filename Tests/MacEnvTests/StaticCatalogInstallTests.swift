import XCTest
@testable import MacEnv

// StaticCatalogService.install 的落位规则。三种包形状各一条：
//   ① 顶层裸二进制        qdrant 的 tar.gz（只有一个 qdrant 文件，没有包目录）
//   ② <包目录>/<二进制>   etcd 的官方 zip（etcd / etcdctl / etcdutl 直接摆在包目录顶层）
//   ③ <包目录>/bin/<二进制> go / python / gradle / maven / swoole-cli 这些常规包
//
// ② 是 2026-10-07 加 etcd 时才发现的：原来的「往上退两级」对它会退到 staging 自己，
// 落成 versions/etcd-x/etcd-vX-darwin-arm64/etcd —— 多一层目录，而且 updateFlags 只认
// bin/ 和 sbin/，装完界面会显示成「未安装」。这条测试就是钉住它。
//
// 用合成的小包（几个几字节的 shell 脚本）直接打 Swift 代码，不去下 22MB 的真实包。
@MainActor
final class StaticCatalogInstallTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macenv-catalog-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 在 stage/ 下按 entries 造文件，再把 entries 里列出的顶层条目打成 zip。
    /// `mode` 是 posix 权限：可执行的给 0o755，普通文件给 0o644。
    private func makeZip(entries: [(path: String, mode: Int)]) throws -> URL {
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        for entry in entries {
            let file = stage.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho fixture\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: entry.mode], ofItemAtPath: file.path)
        }
        // 只打顶层条目，zip 里才会带包目录那一层（跟真实包一致）。
        let tops = Array(Set(entries.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path }))
        let zip = root.appendingPathComponent("fixture.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = stage
        process.arguments = ["-qr", zip.path] + tops
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "打 fixture zip 失败")
        return zip
    }

    private func install(app: String, binary: String, zip: URL, version: String = "9.9.9") async throws {
        let service = StaticCatalogService(root: root, app: app, binaryNames: [binary])
        try await service.install(StaticVersion(name: "\(app)-\(version)", version: version,
                                               url: zip, downloaded: false, installed: false))
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(path).path)
    }

    // ② etcd 形状：包目录里直接放二进制，没有 bin/。
    // 期望：补出 bin/ 并把顶层可执行文件搬进去；README 之类的非可执行文件留在根。
    func testPackageWithBinariesAtRootGetsBinDirectory() async throws {
        let zip = try makeZip(entries: [
            ("pkg/mybin", 0o755),
            ("pkg/mybin-ctl", 0o755),
            ("pkg/README.md", 0o644),
        ])
        try await install(app: "fixture", binary: "mybin", zip: zip)

        XCTAssertTrue(exists("server/fixture/versions/fixture-9.9.9/bin/mybin"), "主二进制没落到 bin/")
        XCTAssertTrue(exists("server/fixture/versions/fixture-9.9.9/bin/mybin-ctl"), "同目录的其它可执行文件没一起搬")
        XCTAssertFalse(exists("server/fixture/versions/fixture-9.9.9/mybin"), "顶层不该还留着二进制")
        // 非可执行文件不搬 —— 判定条件是「文件 + 有可执行位」，README 该留在原地。
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("server/fixture/versions/fixture-9.9.9/README.md").path))
        // 包目录那一层要被吃掉，不能变成 versions/fixture-9.9.9/pkg/...
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("server/fixture/versions/fixture-9.9.9/pkg").path))
    }

    // ③ 常规形状：<包目录>/bin/<二进制>。这条一直是对的，加新分支别把它改坏。
    func testRegularPackageKeepsPackageRoot() async throws {
        let zip = try makeZip(entries: [
            ("pkg/bin/mybin", 0o755),
            ("pkg/lib/data.txt", 0o644),
        ])
        try await install(app: "regular", binary: "mybin", zip: zip)

        XCTAssertTrue(exists("server/regular/versions/regular-9.9.9/bin/mybin"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("server/regular/versions/regular-9.9.9/lib/data.txt").path))
        // 不该多补一层 bin/bin。
        XCTAssertFalse(exists("server/regular/versions/regular-9.9.9/bin/bin/mybin"))
    }

    // ① 顶层裸二进制：没有包目录，直接躺在 zip 根上。
    func testBareBinaryAtArchiveRoot() async throws {
        let zip = try makeZip(entries: [("mybin", 0o755)])
        try await install(app: "bare", binary: "mybin", zip: zip)

        XCTAssertTrue(exists("server/bare/versions/bare-9.9.9/bin/mybin"))
    }
    func testSbinPackageKeepsLibrariesAndCanBeReplaced() async throws {
        let zip = try makeZip(entries: [("pkg/sbin/mybin", 0o755), ("pkg/lib/data.txt", 0o644)])
        try await install(app: "sbin", binary: "mybin", zip: zip)
        try await install(app: "sbin", binary: "mybin", zip: zip)
        XCTAssertTrue(exists("server/sbin/versions/sbin-9.9.9/sbin/mybin"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("server/sbin/versions/sbin-9.9.9/lib/data.txt").path))
    }

    func testInvalidPackagePreservesExistingInstallationAndCleansStaging() async throws {
        let service = StaticCatalogService(root: root, app: "failed", binaryNames: ["mybin"])
        let zip = try makeZip(entries: [("pkg/bin/mybin", 0o755)])
        let version = StaticVersion(name: "failed", version: "9.9.9", url: zip, downloaded: false, installed: false)
        try await service.install(version)
        let original = try Data(contentsOf: root.appendingPathComponent("server/failed/versions/failed-9.9.9/bin/mybin"))
        try Data("invalid archive".utf8).write(to: root.appendingPathComponent("cache/static-failed-9.9.9.tar.zip"))
        do { try await service.install(version); XCTFail("损坏的压缩包不能成功安装") } catch { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("server/failed/versions/failed-9.9.9/bin/mybin")), original)
        let children = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("server/failed/versions"), includingPropertiesForKeys: nil)
        XCTAssertFalse(children.contains { $0.lastPathComponent.hasPrefix(".staging-") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache/static-failed-9.9.9.tar.zip").path))
    }

}
