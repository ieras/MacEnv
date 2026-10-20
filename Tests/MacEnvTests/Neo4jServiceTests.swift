import XCTest
@testable import MacEnv

// Neo4j 接入的三个关键纯函数：conf upsert（重复声明会直接启动失败）、
// 端口解析、Java 策略表。进程行为（探活 / 托管）靠真机验证，不写在这里。
@MainActor
final class Neo4jServiceTests: XCTestCase {
    // 发行版 conf 里 server.directories.import 是未注释的，重复声明直接启动失败
    // （实测 "declared multiple times"），必须原地替换而不是追加。
    func testUpsertReplacesActiveLine() {
        let content = """
        # server.directories
        server.directories.import=import
        server.http.listen_address=:7474
        """
        let result = Neo4jService.upsert(content, [
            "server.directories.import": "/data/import",
            "server.directories.data": "/data/data",
            "server.http.listen_address": "127.0.0.1:7474"
        ])
        XCTAssertEqual(result.components(separatedBy: .newlines).filter { $0.hasPrefix("server.directories.import=") }.count, 1)
        XCTAssertTrue(result.contains("server.directories.import=/data/import"))
        XCTAssertTrue(result.contains("server.http.listen_address=127.0.0.1:7474"))
        // 没有的 key 追加，注释行原样保留
        XCTAssertTrue(result.contains("server.directories.data=/data/data"))
        XCTAssertTrue(result.contains("# server.directories"))
    }

    // 注释行不能被激活：取消注释等于替用户改上游语义。
    func testUpsertKeepsCommentsUntouched() {
        let result = Neo4jService.upsert("#server.directories.logs=logs\n", ["server.directories.logs": "/data/logs"])
        XCTAssertTrue(result.contains("#server.directories.logs=logs"))
        XCTAssertTrue(result.contains("server.directories.logs=/data/logs"))
        XCTAssertEqual(result.components(separatedBy: .newlines).filter { $0.hasPrefix("server.directories.logs=") && !$0.hasPrefix("#") }.count, 1)
    }

    func testUpsertIsIdempotent() {
        let settings = ["server.directories.data": "/data/data", "server.directories.logs": "/data/logs"]
        let once = Neo4jService.upsert("", settings)
        XCTAssertEqual(Neo4jService.upsert(once, settings), once)
    }

    // 端口值是 ":7474" / "0.0.0.0:7474" 两种形态，注释行不算。
    func testParsePort() {
        XCTAssertEqual(Neo4jService.parsePort("server.http.listen_address=:7474", "server.http.listen_address"), 7474)
        XCTAssertEqual(Neo4jService.parsePort("server.bolt.listen_address=0.0.0.0:7687\n", "server.bolt.listen_address"), 7687)
        XCTAssertEqual(Neo4jService.parsePort("#server.https.listen_address=:7473", "server.https.listen_address"), nil)
        XCTAssertEqual(Neo4jService.parsePort("server.default_listen_address=127.0.0.1", "server.http.listen_address"), nil)
    }

    // 策略表照搬 FlyEnv（neo4j-policy.ts）：不同年月的 Neo4j 要不同大版本 JDK。
    func testSupportedJavaMajors() {
        XCTAssertEqual(Neo4jService.supportedJavaMajors("2026.09.0"), [21, 25])
        XCTAssertEqual(Neo4jService.supportedJavaMajors("2025.10.0"), [21, 25])
        XCTAssertEqual(Neo4jService.supportedJavaMajors("2025.05.0"), [21])
        XCTAssertEqual(Neo4jService.supportedJavaMajors("2024.11.0"), [17, 21])
        XCTAssertEqual(Neo4jService.supportedJavaMajors("not-a-version"), [17, 21])
    }

    func testJavaMajor() {
        XCTAssertEqual(Neo4jService.javaMajor("21.0.12"), 21)
        XCTAssertEqual(Neo4jService.javaMajor("17.0.8"), 17)
        XCTAssertEqual(Neo4jService.javaMajor(""), 0)
    }

    // bin/neo4j version 输出 "neo4j 2026.09.0"；无关输出不能扫出一个版本。
    func testParseVersion() {
        XCTAssertEqual(Neo4jService.parseVersion("neo4j 2026.09.0"), "2026.09.0")
        XCTAssertEqual(Neo4jService.parseVersion("Neo4j 5.23.0\n"), "5.23.0")
        XCTAssertNil(Neo4jService.parseVersion("Error: JAVA_HOME is not defined correctly."))
    }
}
