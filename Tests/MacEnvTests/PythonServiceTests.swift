import XCTest
@testable import MacEnv

// MARK: - Python

// PythonService 是 @MainActor 的，纯函数都标了 nonisolated 或者本身就是静态方法，
// 测试类跟着标 MainActor 才能调到那些没标的实例成员。
@MainActor
final class PythonServiceTests: XCTestCase {
    // Python 2 把 --version 写到 stderr，CommandOutput.text 已经把两路合并 —— 都能解析。
    func testParseVersion() {
        XCTAssertEqual(PythonService.parseVersion("Python 3.12.15\n"), "3.12.15")
        XCTAssertEqual(PythonService.parseVersion("Python 2.7.18"), "2.7.18")
        XCTAssertEqual(PythonService.parseVersion("Python 3.13.0rc1"), "3.13.0rc1")
        XCTAssertNil(PythonService.parseVersion("pyenv shim 1.0"))
        XCTAssertNil(PythonService.parseVersion(""))
    }

    // Python 2 不应该有 python3 这个名字 —— 建一条指到 2.7 是误导用户。
    func testShimNames() {
        XCTAssertEqual(PythonService.shimNames("3.12.15"), ["python", "python3", "python3.12"])
        XCTAssertEqual(PythonService.shimNames("3.9.0"), ["python", "python3", "python3.9"])
        XCTAssertEqual(PythonService.shimNames("3.10"), ["python", "python3", "python3.10"])
        XCTAssertEqual(PythonService.shimNames("2.7.18"), ["python"])
    }

    // MacPorts 的 port 名是 python312 不带点，framework 目录名要 3.12。
    func testMacPortsVersion() {
        XCTAssertEqual(PythonService.macPortsVersion("python312"), "3.12")
        XCTAssertEqual(PythonService.macPortsVersion("python27"), "2.7")
        XCTAssertEqual(PythonService.macPortsVersion("python39"), "3.9")
        XCTAssertNil(PythonService.macPortsVersion("python"))
        XCTAssertNil(PythonService.macPortsVersion("python3x"))   // 非数字
        XCTAssertNil(PythonService.macPortsVersion("python-yq"))   // 同前缀但不是版本
    }

    // python-build-standalone 的资产名规整，正则一抓就出 —— 同时验证只挑本机架构 + install_only。
    func testParseStandalone() {
        let arm = URL(string: "https://github.com/a/b/cpython-3.12.15%2B20261003-aarch64-apple-darwin-install_only.tar.gz")!
        let x86 = URL(string: "https://github.com/a/b/cpython-3.10.22%2B20261003-x86_64-apple-darwin-install_only.tar.gz")!
        let linux = URL(string: "https://github.com/a/b/cpython-3.12.15%2B20261003-x86_64-unknown-linux-gnu-install_only.tar.gz")!
        let assets = [
            ("cpython-3.12.15+20261003-aarch64-apple-darwin-install_only.tar.gz", arm),
            ("cpython-3.10.22+20261003-aarch64-apple-darwin-install_only.tar.gz", x86),
            // 不匹配：Linux / 非 install_only
            ("cpython-3.12.15+20261003-x86_64-unknown-linux-gnu-install_only.tar.gz", linux),
            ("cpython-3.12.15+20261003-aarch64-apple-darwin.tar.gz", arm),
            ("sha256sums.txt", x86),
        ]
        let parsed = PythonService.parseStandalone(assets)
        // arm64 机器上只挑 aarch64 的两条；x86 上相反。用 #if 自动适配 —— 这里按 arm64 期望。
        #if arch(arm64)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(Set(parsed.map(\.version)), ["3.10.22", "3.12.15"])
        XCTAssertEqual(parsed.first(where: { $0.version == "3.12.15" })?.name, "Python-3.12.15")
        #else
        XCTAssertEqual(parsed.count, 0)
        #endif
    }

    // Homebrew 的 keg 里解释器藏在 libexec/bin 下 —— 退两级时 libexec 那层得跳过，
    // 否则 Home 退成 python@3.12/libexec（没有 bin/，PATH 写进去等于失效）。
    func testPythonHome() {
        XCTAssertEqual(PythonService.pythonHome(of: URL(fileURLWithPath: "/opt/homebrew/opt/python@3.12/bin/python3")).path, "/opt/homebrew/opt/python@3.12")
        XCTAssertEqual(PythonService.pythonHome(of: URL(fileURLWithPath: "/opt/homebrew/opt/python@3.12/libexec/bin/python")).path, "/opt/homebrew/opt/python@3.12")
        XCTAssertEqual(PythonService.pythonHome(of: URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12")).path, "/Library/Frameworks/Python.framework/Versions/3.12")
        XCTAssertEqual(PythonService.pythonHome(of: URL(fileURLWithPath: "/usr/bin/python3")).path, "/usr")
    }

    // 摘要必须稳定 —— String.hashValue 自带随机种子，重启就漂，软链路径就不能这么定。
    func testFnv1aStable() {
        let a = PythonService.fnv1a("/opt/homebrew/opt/python@3.12/bin/python3")
        let b = PythonService.fnv1a("/opt/homebrew/opt/python@3.12/bin/python3")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, PythonService.fnv1a("/opt/homebrew/opt/python@3.13/bin/python3"))
    }
    func testDiscoversInterpreterDirectlyInPATHDirectory() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macenv-python-path-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let python = root.appendingPathComponent("python3.99")
        try "#!/bin/sh\necho 'Python 3.99.1'\n".write(to: python, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let versions = await PythonService(root: root).installedVersions(customDirectories: [root.path])
        XCTAssertTrue(versions.contains { $0.executable.resolvingSymlinksInPath() == python.resolvingSymlinksInPath() && $0.version == "3.99.1" })
    }

}