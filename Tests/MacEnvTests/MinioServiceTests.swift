import XCTest
@testable import MacEnv

@MainActor
final class MinioServiceTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macenv-minio-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testParseConf() {
        let text = """
        # comment
        MINIO_ADDRESS=:9000
        MINIO_CONSOLE_ADDRESS=":9015"
        MINIO_ROOT_PASSWORD='s3cr=t'
        NOT_MINIO=ignored
        MINIO_BROWSER=on
        """
        let conf = MinioService.parseConf(text)
        XCTAssertEqual(conf.count, 4)
        XCTAssertEqual(conf["MINIO_ADDRESS"], ":9000")
        XCTAssertEqual(conf["MINIO_CONSOLE_ADDRESS"], ":9015")
        XCTAssertEqual(conf["MINIO_ROOT_PASSWORD"], "s3cr=t")
        XCTAssertEqual(conf["MINIO_BROWSER"], "on")
    }

    func testNormalizeAddress() {
        let fallback = "127.0.0.1:9001"
        XCTAssertEqual(MinioService.normalizeAddress("", fallback: fallback), fallback)
        XCTAssertEqual(MinioService.normalizeAddress("9015", fallback: fallback), "127.0.0.1:9015")
        XCTAssertEqual(MinioService.normalizeAddress(":9015", fallback: fallback), "127.0.0.1:9015")
        XCTAssertEqual(MinioService.normalizeAddress("0.0.0.0:9015", fallback: fallback), "0.0.0.0:9015")
        XCTAssertEqual(MinioService.normalizeAddress("garbage", fallback: fallback), fallback)
    }

    func testPort() {
        XCTAssertEqual(MinioService.port(":9000", fallback: 9000), 9000)
        XCTAssertEqual(MinioService.port("127.0.0.1:9015", fallback: 9001), 9015)
        XCTAssertEqual(MinioService.port("9015", fallback: 9001), 9015)
        XCTAssertEqual(MinioService.port("", fallback: 9000), 9000)
    }

    func testParseVersion() {
        XCTAssertEqual(MinioService.parseVersion("minio version RELEASE.2026-08-04T00-00-00Z"),
                       "RELEASE.2026-08-04T00-00-00Z")
        XCTAssertNil(MinioService.parseVersion("no version here"))
    }

    func testTarGzLandsInBin() async throws {
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let binary = stage.appendingPathComponent("minio")
        try Data("#!/bin/sh\necho minio\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try Data("readme\n".utf8).write(to: stage.appendingPathComponent("README.md"))
        let archive = root.appendingPathComponent("fixture.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.currentDirectoryURL = stage
        process.arguments = ["-czf", archive.path, "minio", "README.md"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "打 fixture tar.gz 失败")

        let catalog = StaticCatalogService(root: root, app: "minio", binaryNames: ["minio"], displayName: "MinIO")
        let version = StaticVersion(name: "MinIO-9.9.9", version: "9.9.9", url: archive,
                                    downloaded: false, installed: false)
        try await catalog.install(version)

        let package = root.appendingPathComponent("server/minio/versions/minio-9.9.9", isDirectory: true)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: package.appendingPathComponent("bin/minio").path))
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: package.appendingPathComponent("minio").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("README.md").path))
    }
}
