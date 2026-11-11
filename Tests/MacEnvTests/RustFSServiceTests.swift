import XCTest
@testable import MacEnv

@MainActor
final class RustFSServiceTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macenv-rustfs-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "macenv.rustfs.dataDirs")
        try? FileManager.default.removeItem(at: root)
    }

    func testParseConf() {
        let text = """
        # RUSTFS_ADDRESS=:9999
        RUSTFS_ADDRESS=:9000
        RUSTFS_CONSOLE_ADDRESS=":9015"
        RUSTFS_ACCESS_KEY='key=with=equals'
        RUSTFS_CONSOLE_ENABLE=true
        NOT_RUSTFS=ignored

        """
        let conf = RustFSService.parseConf(text)
        XCTAssertEqual(conf.count, 4)
        XCTAssertEqual(conf["RUSTFS_ADDRESS"], ":9000")
        XCTAssertEqual(conf["RUSTFS_CONSOLE_ADDRESS"], ":9015")
        XCTAssertEqual(conf["RUSTFS_ACCESS_KEY"], "key=with=equals")
        XCTAssertEqual(conf["RUSTFS_CONSOLE_ENABLE"], "true")
    }

    func testDefaultConfigIsFullyCommented() {
        XCTAssertTrue(RustFSService.parseConf(RustFSService.defaultConfig).isEmpty)
    }

    func testParseVersion() {
        let output = """
        rustfs 1.0.4
        build time   : 2026-10-25 14:13:47 +00:00
        rust version : rustc 1.99.1
        """
        XCTAssertEqual(RustFSService.parseVersion(output), "1.0.4")
        XCTAssertEqual(RustFSService.parseVersion("rustfs v1.2.3"), "1.2.3")
        XCTAssertNil(RustFSService.parseVersion("no version here"))
    }

    func testPorts() throws {
        let service = RustFSService(root: root)
        XCTAssertEqual(service.ports().api, 9000)
        XCTAssertEqual(service.ports().console, 9001)
        try FileManager.default.createDirectory(at: service.directory, withIntermediateDirectories: true)
        try "RUSTFS_ADDRESS=:19000\nRUSTFS_CONSOLE_ADDRESS=127.0.0.1:19001\n".write(to: service.configURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(service.ports().api, 19000)
        XCTAssertEqual(service.ports().console, 19001)
    }

    func testDataDirectoryAndLogNames() {
        let service = RustFSService(root: root)
        let version = RustFSVersion(version: "1.0.4", directory: root,
                                    executable: root.appendingPathComponent("bin/rustfs"), source: "Static")
        XCTAssertEqual(service.dataURL(for: version).path, service.defaultDataURL.path)
        service.setDataURL(URL(fileURLWithPath: "/tmp/custom-rustfs", isDirectory: true), for: version)
        XCTAssertEqual(service.dataURL(for: version).path, "/tmp/custom-rustfs")
        XCTAssertEqual(service.logURL(version, error: false).lastPathComponent, "rustfs-1.0.4-start-out.log")
        XCTAssertEqual(service.logURL(version, error: true).lastPathComponent, "rustfs-1.0.4-start-error.log")
    }

    func testDefaultDataDirectorySkipsSpaces() {
        let service = RustFSService(root: root.appendingPathComponent("Application Support/MacEnv"))
        XCTAssertTrue(service.defaultDataURL.path.hasSuffix("/.rustfs/data"))
        XCTAssertFalse(service.defaultDataURL.path.contains(" "))
    }

    func testPrepareWritesDefaultConfig() throws {
        let service = RustFSService(root: root)
        try service.prepare()
        let text = try String(contentsOf: service.configURL, encoding: .utf8)
        XCTAssertEqual(text, RustFSService.defaultConfig)
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.defaultDataURL.path))
        try "RUSTFS_ADDRESS=:19000\n".write(to: service.configURL, atomically: true, encoding: .utf8)
        try service.prepare()
        XCTAssertEqual(try String(contentsOf: service.configURL, encoding: .utf8), "RUSTFS_ADDRESS=:19000\n")
    }
}
