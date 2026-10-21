import XCTest
@testable import MacEnv

// RabbitMQ 接入的关键纯函数：env 文件 upsert（rabbitmq-env 直接 source）、
// ini 端口解析、OTP 策略表、版本解析。进程行为（探活 / 托管 / 停止）靠真机验证。
@MainActor
final class RabbitMQServiceTests: XCTestCase {
    // env 文件是 sh 片段：值必须引起来（数据目录在 Application Support 底下，路径带空格），
    // 已有 key 原地替换，注释行不动，没有的 key 追加。
    func testUpsertQuotesAndReplaces() {
        let content = """
        #NODENAME=old@host
        NODE_IP_ADDRESS=0.0.0.0
        """
        let result = RabbitMQService.upsert(content, [
            "NODE_IP_ADDRESS": "127.0.0.1",
            "NODENAME": "rabbit@localhost",
            "MNESIA_BASE": "/Users/x/Library/Application Support/MacEnv/server/rabbitmq/mnesia-4.0.9"
        ])
        XCTAssertTrue(result.contains("NODE_IP_ADDRESS=\"127.0.0.1\""))
        XCTAssertTrue(result.contains("#NODENAME=old@host"))
        XCTAssertTrue(result.contains("NODENAME=\"rabbit@localhost\""))
        XCTAssertTrue(result.contains("MNESIA_BASE=\"/Users/x/Library/Application Support/MacEnv/server/rabbitmq/mnesia-4.0.9\""))
        // 每个 key 只有一行活跃值
        XCTAssertEqual(result.components(separatedBy: .newlines).filter { $0.hasPrefix("NODE_IP_ADDRESS=") }.count, 1)
    }

    func testUpsertIsIdempotent() {
        let settings = ["NODENAME": "rabbit@localhost", "PLUGINS_DIR": "/opt/rabbitmq/plugins"]
        let once = RabbitMQService.upsert("", settings)
        XCTAssertEqual(RabbitMQService.upsert(once, settings), once)
    }

    // 端口写在自己的 ini 里，读它做端口列展示；注释行不算，读到脏值退回默认。
    func testParsePorts() {
        let content = """
        #listeners.tcp.default = 9999
        listeners.tcp.default = 5673
        management.tcp.port = 15673
        """
        let service = RabbitMQService(root: URL(fileURLWithPath: "/tmp/rabbitmq-tests"))
        let version = RabbitMQVersion(version: "4.0.9", directory: URL(fileURLWithPath: "/tmp/p"), executable: URL(fileURLWithPath: "/tmp/p/sbin/rabbitmq-server"), source: "Static", formula: nil)
        // 文件不存在时 ports(for:) 走默认值分支
        XCTAssertEqual(service.ports(for: version).amqp, 5672)
        XCTAssertEqual(service.ports(for: version).management, 15672)
        // IniFile.value 是端口解析的地基，直接锁行为
        XCTAssertEqual(IniFile.value("listeners.tcp.default", in: content), "5673")
        XCTAssertEqual(IniFile.value("management.tcp.port", in: content), "15673")
        XCTAssertNil(IniFile.value("listeners.tcp.default", in: "#listeners.tcp.default = 1"))
    }

    // 策略表照搬官方 which-erlang 页：4.2 锁 27，4.0/4.1 要 26 起，3.13 要 26。
    func testSupportedOtpMajors() {
        XCTAssertEqual(RabbitMQService.supportedOtpMajors("4.4.0"), [27, 28, 29])
        XCTAssertEqual(RabbitMQService.supportedOtpMajors("4.3.7"), [27, 28, 29])
        XCTAssertEqual(RabbitMQService.supportedOtpMajors("4.2.9"), [27, 28, 29])
        XCTAssertEqual(RabbitMQService.supportedOtpMajors("4.1.8"), [26, 27])
        XCTAssertEqual(RabbitMQService.supportedOtpMajors("4.0.9"), [26, 27])
        XCTAssertEqual(RabbitMQService.supportedOtpMajors("3.13.7"), [26])
        XCTAssertEqual(RabbitMQService.supportedOtpMajors("not-a-version"), [26, 27])
    }

    func testOtpMajor() {
        XCTAssertEqual(RabbitMQService.otpMajor("27"), 27)
        XCTAssertEqual(RabbitMQService.otpMajor("29.1"), 29)
        XCTAssertEqual(RabbitMQService.otpMajor(""), 0)
    }

    // rabbitmqctl version 输出 "4.0.9"；别把通知行里的数字当版本号。
    func testParseVersion() {
        XCTAssertEqual(RabbitMQService.parseVersion("4.0.9"), "4.0.9")
        XCTAssertEqual(RabbitMQService.parseVersion("4.0.9\n"), "4.0.9")
        XCTAssertEqual(RabbitMQService.parseVersion("RabbitMQ 4.1.8 on Erlang 27.1"), "4.1.8")
    }
}
