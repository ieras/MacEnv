import XCTest
@testable import MacEnv

// Erlang 接入的关键纯函数：OTP release 解析（显示口径）、ERL_ROOT 推导。
// 扫描 / 探测是进程行为，靠真机验证，不写在这里。
@MainActor
final class ErlangServiceTests: XCTestCase {
    // erl -noshell -eval '...otp_release...' 的输出就是 "27"（无换行噪音时）。
    func testParseOtpReleasePlain() {
        XCTAssertEqual(ErlangService.parseOtpRelease("27"), "27")
        XCTAssertEqual(ErlangService.parseOtpRelease("28"), "28")
        XCTAssertEqual(ErlangService.parseOtpRelease("29\n"), "29")
    }

    // 有的发行版会往标准输出混告警行，宽松兜底取两三位独立数字；
    // ERTS 版本（15.x）不是 OTP release，一位 / 四位数字都不能当版本号。
    func testParseOtpReleaseFallback() {
        XCTAssertEqual(ErlangService.parseOtpRelease("warning: something\n27"), "27")
        XCTAssertNil(ErlangService.parseOtpRelease("version 15.2.1.2"))
        XCTAssertNil(ErlangService.parseOtpRelease(""))
    }

    // ERL_ROOT = 装着 bin/ 的那一层：brew keg 根、/opt/local/lib/erlang 都对。
    func testErlRoot() {
        XCTAssertEqual(ErlangService.erlRoot(of: URL(fileURLWithPath: "/opt/homebrew/Cellar/erlang/29.1.2/bin/erl")).path,
                       "/opt/homebrew/Cellar/erlang/29.1.2")
        XCTAssertEqual(ErlangService.erlRoot(of: URL(fileURLWithPath: "/opt/local/lib/erlang/bin/erl")).path,
                       "/opt/local/lib/erlang")
        // 目录直接给到只有 erl 的那一层时，它自己就是根。
        XCTAssertEqual(ErlangService.erlRoot(of: URL(fileURLWithPath: "/opt/erlang/bin/erl")).path,
                       "/opt/erlang")
    }
}
