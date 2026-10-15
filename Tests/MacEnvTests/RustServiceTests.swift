import XCTest
@testable import MacEnv

// RustService 的纯函数与安装形状。四个部分：
//   - parseVersions：版本列表换成本机架构的下载地址（one-env 只给 x86_64 那份）
//   - parseVersion：rustc --version 输出的版本号提取
//   - parseActiveToolchain：rustup show active-toolchain 的输出解析
//   - rustRoot：三种来源的版本根定位
//   - 安装形状：官方包二进制在 rustc/bin/ 下，必须跑包内 install.sh 才落成标准 bin/
@MainActor
final class RustServiceTests: XCTestCase {

    // MARK: - parseVersions

    func testParseVersionsRewritesDownloadURLToLocalHost() {
        // one-env 对 rust 一律回 x86_64-apple-darwin（传 arch=arm 也一样），
        // 所以地址必须整个换掉 —— 只改文件名后缀是不够的，那两个平台的包不能混用。
        let entries = [
            StaticVersion(name: "Rust-1.99.0", version: "1.99.0",
                          url: URL(string: "https://static.rust-lang.org/dist/rust-1.99.0-x86_64-apple-darwin.tar.xz")!,
                          downloaded: false, installed: false),
            StaticVersion(name: "Rust-1.83.0", version: "1.83.0",
                          url: URL(string: "https://static.rust-lang.org/dist/rust-1.83.0-x86_64-apple-darwin.tar.xz")!,
                          downloaded: false, installed: false)
        ]
        let versions = RustService.parseVersions(entries, host: "aarch64-apple-darwin")

        XCTAssertEqual(versions.map(\.version), ["1.99.0", "1.83.0"], "版本号与顺序原样继承")
        XCTAssertEqual(versions[0].name, "Rust-1.99.0")
        XCTAssertEqual(versions[0].url.absoluteString,
                       "https://static.rust-lang.org/dist/rust-1.99.0-aarch64-apple-darwin.tar.xz")
        XCTAssertEqual(versions[1].url.absoluteString,
                       "https://static.rust-lang.org/dist/rust-1.83.0-aarch64-apple-darwin.tar.xz")
    }

    func testCurrentHostMatchesBuildArch() {
        // 包名后缀必须是官方那个三元组，写错一个字母就是 404。
        #if arch(arm64)
        XCTAssertEqual(RustService.currentHost, "aarch64-apple-darwin")
        #else
        XCTAssertEqual(RustService.currentHost, "x86_64-apple-darwin")
        #endif
    }

    // MARK: - parseVersion

    func testParseVersion() {
        // rustc --version 的真实形态：`rustc 1.83.0 (90b35a623 2024-11-26)`。
        XCTAssertEqual(RustService.parseVersion("rustc 1.83.0 (90b35a623 2024-11-26)"), "1.83.0")
        XCTAssertEqual(RustService.parseVersion("rustc 1.99.0 (5f94df478 2026-08-27)"), "1.99.0")
        // 预发布版（1.85.0-nightly）只取三段式，跟工具链名里的版本号口径一致
        XCTAssertEqual(RustService.parseVersion("rustc 1.85.0-nightly (abc 2025-01-01)"), "1.85.0")
        XCTAssertNil(RustService.parseVersion(""))
        XCTAssertNil(RustService.parseVersion("error: no rustc found"))
    }

    // MARK: - parseActiveToolchain

    func testParseActiveToolchain() {
        // 设了默认：`stable-aarch64-apple-darwin (default)`
        XCTAssertEqual(RustService.parseActiveToolchain("stable-aarch64-apple-darwin (default)"),
                       "stable-aarch64-apple-darwin")
        XCTAssertEqual(RustService.parseActiveToolchain("1.83.0-aarch64-apple-darwin\n"),
                       "1.83.0-aarch64-apple-darwin")
        // 没设默认时 rustup 打的是 error 行，不能当成工具链名
        XCTAssertNil(RustService.parseActiveToolchain("error: no active toolchain"))
        XCTAssertNil(RustService.parseActiveToolchain(""))
    }

    // MARK: - rustRoot

    func testRustRootLocatesVersionRoot() {
        // 静态包跑完 install.sh：<版本根>/bin/rustc —— 退两级落在版本根
        XCTAssertEqual(RustService.rustRoot(of: URL(fileURLWithPath: "/x/rust-1.83.0/bin/rustc")).lastPathComponent,
                       "rust-1.83.0")
        // rustup 的工具链：<工具链>/bin/rustc —— 同样退两级
        XCTAssertEqual(RustService.rustRoot(of: URL(fileURLWithPath: "/x/toolchains/stable-aarch64-apple-darwin/bin/rustc")).lastPathComponent,
                       "stable-aarch64-apple-darwin")
        // 用户把目录给到只有 rustc 的那一层：目录本身就是版本根
        XCTAssertEqual(RustService.rustRoot(of: URL(fileURLWithPath: "/x/custom/rustc")).lastPathComponent, "custom")
    }

    // MARK: - 安装形状

    // 官方包的二进制在 rustc/bin/、cargo/bin/ 下，**不在**标准 bin/ —— 这是 rust 跟
    // go / python / gradle 那批包最大的不同，也是它不能复用 StaticCatalogService.install 的原因
    // （那个按「二进制往上退两级」找包根，在 rust 包上退出来的是包根没错，但落位后
    // bin/rustc 根本不存在，装完等于没装）。所以这里必须跑包内的 install.sh 重排布局。
    func testInstallRunsBundledInstaller() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macenv-rust-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let package = "rust-1.83.0-aarch64-apple-darwin"
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        // 官方包形状：各组件的二进制各自躺在 <组件>/bin/ 下，包根摆一个 install.sh。
        for path in ["\(package)/rustc/bin/rustc", "\(package)/cargo/bin/cargo", "\(package)/rust-std-aarch64-apple-darwin/lib/rustlib/libstd.rlib"] {
            let file = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho fixture\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: path.contains("/bin/") ? 0o755 : 0o644],
                                                  ofItemAtPath: file.path)
        }
        // 模拟 rust-installer：把各组件 bin/ 下的东西汇总到 --destdir 的 bin/。
        // 参数写法跟官方一致（--prefix=/ --destdir=<dir>），RustService 就是这么调的。
        let installer = stage.appendingPathComponent("\(package)/install.sh")
        try Data("""
        #!/bin/sh
        for arg in "$@"; do
          case "$arg" in
            --destdir=*) destdir="${arg#--destdir=}" ;;
          esac
        done
        here="$(cd "$(dirname "$0")" && pwd)"
        mkdir -p "$destdir/bin" "$destdir/lib"
        cp "$here/rustc/bin/rustc" "$destdir/bin/rustc"
        cp "$here/cargo/bin/cargo" "$destdir/bin/cargo"
        cp "$here/rust-std-aarch64-apple-darwin/lib/rustlib/libstd.rlib" "$destdir/lib/libstd.rlib"
        chmod 755 "$destdir/bin/rustc" "$destdir/bin/cargo"
        """.utf8).write(to: installer)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installer.path)

        // 打成 tar.xz，直接摆进下载缓存的位置 —— install() 见缓存命中就跳过下载，
        // 测试不必真去 static.rust-lang.org 拉 150MB。
        let archive = root.appendingPathComponent("cache/static-rust-1.83.0.tar.xz")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = stage
        tar.arguments = ["-cJf", archive.path, package]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0, "打 fixture tar.xz 失败")

        let service = RustService(root: root)
        let version = StaticVersion(name: "Rust-1.83.0", version: "1.83.0", url: archive,
                                    downloaded: true, installed: false)
        try await service.install(version)

        let target = root.appendingPathComponent("server/rust/versions/rust-1.83.0")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.appendingPathComponent("bin/rustc").path),
                      "install.sh 跑完后 rustc 必须落在标准 bin/ 下")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.appendingPathComponent("bin/cargo").path),
                      "cargo 跟着一起落位")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("lib/libstd.rlib").path),
                      "非二进制内容也该跟着搬")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("rustc/bin/rustc").path),
                       "包内那层组件目录不该出现在版本根下")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("install.sh").path),
                       "install.sh 只用来安装，不留在产物里")
    }

    // 包根没有 install.sh 时要明确报错，不能静默落一个空版本出去。
    func testInstallRejectsArchiveWithoutInstaller() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macenv-rust-bad-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let stage = root.appendingPathComponent("stage/rust-1.83.0-aarch64-apple-darwin/rustc/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: stage.appendingPathComponent("rustc"))

        let archive = root.appendingPathComponent("cache/static-rust-1.83.0.tar.xz")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root.appendingPathComponent("stage")
        tar.arguments = ["-cJf", archive.path, "rust-1.83.0-aarch64-apple-darwin"]
        try tar.run()
        tar.waitUntilExit()

        let service = RustService(root: root)
        let version = StaticVersion(name: "Rust-1.83.0", version: "1.83.0", url: archive,
                                    downloaded: true, installed: false)
        do {
            try await service.install(version)
            XCTFail("缺 install.sh 的包不该装成功")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rustc"), "报错要指出缺的是什么：\(error.localizedDescription)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("server/rust/versions/rust-1.83.0").path),
                       "失败时不能留下半成品版本目录")
    }
}
