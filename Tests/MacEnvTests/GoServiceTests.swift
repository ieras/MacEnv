import XCTest
@testable import MacEnv

// MARK: - Go / GVM

// GoService 是 @MainActor 的，静态成员也算隔离在 MainActor 上，测试类得跟着标。
@MainActor
final class GoServiceTests: XCTestCase {
    // listall 给可装列表，list 给已装列表（=> 打头的是 default）。
    // 装过的版本如果官方下架了，listall 里就没有，但仍要显示成已安装。
    func testMergeGvmVersions() {
        let available = "go1.25.0\ngo1.24.4\ngo1.23.2\n"
        let installed = "=>  go1.24.4\n    go1.23.2\n    go1.20.14\n"
        let result = GoService.mergeGvm(available: available, installed: installed)
        let byName = Dictionary(uniqueKeysWithValues: result.map { ($0.name, $0) })
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(byName["go1.24.4"]?.version, "1.24.4")
        XCTAssertEqual(byName["go1.24.4"]?.installed, true)
        XCTAssertEqual(byName["go1.24.4"]?.isDefault, true)
        XCTAssertEqual(byName["go1.23.2"]?.installed, true)
        XCTAssertEqual(byName["go1.23.2"]?.isDefault, false)
        XCTAssertEqual(byName["go1.25.0"]?.installed, false)
        XCTAssertEqual(byName["go1.20.14"]?.installed, true)
    }

    // gvm 的输出里混着标题行和空行，不能把它们当成版本号。
    func testMergeGvmIgnoresNoise() {
        XCTAssertTrue(GoService.mergeGvm(available: "gvm gos (installed)\n\n", installed: "").isEmpty)
        XCTAssertTrue(GoService.mergeGvm(available: "go1.24rc1\n", installed: "").isEmpty)
    }

    func testGoRoot() {
        XCTAssertEqual(GoService.goRoot(of: URL(fileURLWithPath: "/tmp/gos/go1.24.4/bin/go")).path, "/tmp/gos/go1.24.4")
        // 二进制直接躺在版本目录里（没有 bin 这一层）时，GOROOT 就是它所在的那层。
        XCTAssertEqual(GoService.goRoot(of: URL(fileURLWithPath: "/tmp/go1.24.4/go")).path, "/tmp/go1.24.4")
    }

    // 路径可能带空格或单引号，拼进 shell 命令前必须用 singleQuoted 包好。
    func testShellQuote() {
        XCTAssertEqual(singleQuoted("/Users/a b/.gvm/scripts/gvm"), "'/Users/a b/.gvm/scripts/gvm'")
        XCTAssertEqual(singleQuoted("/Users/a'b"), "'/Users/a'\\''b'")
    }
}
