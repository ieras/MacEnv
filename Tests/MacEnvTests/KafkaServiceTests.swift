import XCTest
@testable import MacEnv

@MainActor
final class KafkaServiceTests: XCTestCase {
    func testParseDirectory() {
        let html = """
        <a href="4.1.2/">4.1.2/</a>
        <a href="4.2.1/">4.2.1/</a>
        <a href="0.10.0.0/">old</a>
        <a href="KEYS">KEYS</a>
        """
        XCTAssertEqual(KafkaService.parseDirectory(html), ["4.1.2", "4.2.1"])
    }

    func testParseCatalogKeepsNewestPatchPerMinor() {
        let current = #"<a href="4.1.2/">x</a><a href="4.2.1/">x</a><a href="4.2.2/">x</a>"#
        let archive = #"<a href="3.9.1/">x</a><a href="3.4.0/">x</a><a href="4.2.2/">x</a>"#
        let result = KafkaService.parseCatalog([
            (KafkaService.mirrors[0], current),
            (KafkaService.mirrors[1], archive)
        ])
        XCTAssertEqual(result.map(\.version), ["4.2.2", "4.1.2", "3.9.1"])
        XCTAssertEqual(result[0].url.absoluteString, "https://downloads.apache.org/kafka/4.2.2/kafka_2.13-4.2.2.tgz")
        XCTAssertEqual(result[2].url.absoluteString, "https://archive.apache.org/dist/kafka/3.9.1/kafka_2.13-3.9.1.tgz")
    }

    func testParsePorts() {
        let config = """
        #listeners=PLAINTEXT://127.0.0.1:19092,CONTROLLER://127.0.0.1:19093
        listeners=PLAINTEXT://127.0.0.1:29092,CONTROLLER://127.0.0.1:29093
        """
        let ports = KafkaService.parsePorts(config)
        XCTAssertEqual(ports.broker, 29092)
        XCTAssertEqual(ports.controller, 29093)
        XCTAssertEqual(KafkaService.parsePorts("").broker, 9092)
        XCTAssertEqual(KafkaService.parsePorts("").controller, 9093)
    }

    func testSupportsJava() {
        XCTAssertFalse(KafkaService.supportsJava("1.8.0_402"))
        XCTAssertFalse(KafkaService.supportsJava("11.0.2"))
        XCTAssertTrue(KafkaService.supportsJava("17.0.9"))
        XCTAssertTrue(KafkaService.supportsJava("21.0.1"))
        XCTAssertFalse(KafkaService.supportsJava(""))
    }

    func testParseVersion() {
        XCTAssertEqual(KafkaService.parseVersion("4.1.2\n"), "4.1.2")
        XCTAssertNil(KafkaService.parseVersion("SLF4J: warning\n"))
    }

    func testPrepareKeepsUserEdits() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macenv-kafka-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let service = KafkaService(root: root)
        let executable = root.appendingPathComponent("server/kafka/versions/kafka-4.1.2/bin/kafka-server-start.sh")
        let version = KafkaVersion(version: "4.1.2",
                                   directory: executable.deletingLastPathComponent().deletingLastPathComponent(),
                                   executable: executable, source: "Static")
        try service.prepare(version)
        let file = service.configURL(for: version)
        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(content.contains("process.roles=broker,controller"))
        XCTAssertTrue(content.contains("controller.quorum.voters=1@127.0.0.1:9093"))
        XCTAssertTrue(content.contains("log.dirs=" + service.dataURL(for: version).path))
        XCTAssertTrue(content.contains("transaction.state.log.min.isr=1"))
        let edited = "listeners=PLAINTEXT://127.0.0.1:19092,CONTROLLER://127.0.0.1:19093"
        try edited.write(to: file, atomically: true, encoding: .utf8)
        try service.prepare(version)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited)
    }
}
