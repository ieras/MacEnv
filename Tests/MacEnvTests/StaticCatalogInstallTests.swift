import XCTest
@testable import MacEnv

// MARK: - StaticCatalogService.install 落位规则
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

    private func makeArchive(entries: [(path: String, mode: Int)], tgz: Bool = false) throws -> URL {
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        for entry in entries {
            let file = stage.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho fixture\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: entry.mode], ofItemAtPath: file.path)
        }
        let tops = Array(Set(entries.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path }))
        let archive = root.appendingPathComponent(tgz ? "fixture.tgz" : "fixture.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tgz ? "/usr/bin/tar" : "/usr/bin/zip")
        process.currentDirectoryURL = stage
        if tgz { process.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { _, new in new } }
        process.arguments = (tgz ? ["-czf"] : ["-qr"]) + [archive.path] + tops
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "打 fixture 归档失败")
        return archive
    }

    private func install(app: String, binary: String, zip: URL, version: String = "9.9.9") async throws {
        let service = StaticCatalogService(root: root, app: app, binaryNames: [binary])
        try await service.install(StaticVersion(name: "\(app)-\(version)", version: version,
                                               url: zip, downloaded: false, installed: false))
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(path).path)
    }

    func testPackageWithBinariesAtRootGetsBinDirectory() async throws {
        let zip = try makeArchive(entries: [
            ("pkg/mybin", 0o755),
            ("pkg/mybin-ctl", 0o755),
            ("pkg/README.md", 0o644),
        ])
        try await install(app: "fixture", binary: "mybin", zip: zip)

        XCTAssertTrue(exists("server/fixture/versions/fixture-9.9.9/bin/mybin"), "主二进制没落到 bin/")
        XCTAssertTrue(exists("server/fixture/versions/fixture-9.9.9/bin/mybin-ctl"), "同目录的其它可执行文件没一起搬")
        XCTAssertFalse(exists("server/fixture/versions/fixture-9.9.9/mybin"), "顶层不该还留着二进制")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("server/fixture/versions/fixture-9.9.9/README.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("server/fixture/versions/fixture-9.9.9/pkg").path))
    }

    func testRegularPackageKeepsPackageRoot() async throws {
        let zip = try makeArchive(entries: [
            ("pkg/bin/mybin", 0o755),
            ("pkg/lib/data.txt", 0o644),
        ])
        try await install(app: "regular", binary: "mybin", zip: zip)

        XCTAssertTrue(exists("server/regular/versions/regular-9.9.9/bin/mybin"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("server/regular/versions/regular-9.9.9/lib/data.txt").path))
        XCTAssertFalse(exists("server/regular/versions/regular-9.9.9/bin/bin/mybin"))
    }

    func testBareBinaryAtArchiveRoot() async throws {
        let zip = try makeArchive(entries: [("mybin", 0o755)])
        try await install(app: "bare", binary: "mybin", zip: zip)

        XCTAssertTrue(exists("server/bare/versions/bare-9.9.9/bin/mybin"))
    }
    func testSbinPackageKeepsLibrariesAndCanBeReplaced() async throws {
        let zip = try makeArchive(entries: [("pkg/sbin/mybin", 0o755), ("pkg/lib/data.txt", 0o644)])
        try await install(app: "sbin", binary: "mybin", zip: zip)
        try await install(app: "sbin", binary: "mybin", zip: zip)
        XCTAssertTrue(exists("server/sbin/versions/sbin-9.9.9/sbin/mybin"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("server/sbin/versions/sbin-9.9.9/lib/data.txt").path))
    }

    func testInvalidPackagePreservesExistingInstallationAndCleansStaging() async throws {
        let service = StaticCatalogService(root: root, app: "failed", binaryNames: ["mybin"])
        let zip = try makeArchive(entries: [("pkg/bin/mybin", 0o755)])
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

    func testTgzPackageUsesGzipAndKeepsBinDirectory() async throws {
        let tgz = try makeArchive(entries: [
            ("kafka_2.13-9.9.9/bin/kafka-server-start.sh", 0o755),
            ("kafka_2.13-9.9.9/libs/kafka.jar", 0o644),
        ], tgz: true)
        try await install(app: "kafka", binary: "kafka-server-start.sh", zip: tgz)
        XCTAssertTrue(exists("server/kafka/versions/kafka-9.9.9/bin/kafka-server-start.sh"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("server/kafka/versions/kafka-9.9.9/libs/kafka.jar").path))
    }
}
