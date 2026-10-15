import XCTest
@testable import MacEnv

// NodeService 的纯函数与安装形状。四个部分：
//   - parseDist：nodejs.org/dist/index.json 的过滤与 LTS 提取（跑不了网络就喂样例）
//   - nodeRoot：三种包形状的版本根定位
//   - parseNvmDefault：nvm alias default 输出的解析
//   - 安装形状：官方 tar 形状（<包目录>/bin/{node,npm,npx}）走「往上退两级」落包根
@MainActor
final class NodeServiceTests: XCTestCase {

    // MARK: - parseDist

    func testParseDistFiltersArchAndMarksLts() throws {
        // 样例取自 index.json 的真实形状：files 是平台标识数组（本机 arm64 对应的
        // 标识是 osx-arm64-tar —— 不是 darwin-arm64，那个只出现在下载文件名里），
        // lts 是 false 或代号字符串。跑在 arm64 上：只有带 osx-arm64-tar 的条目留下。
        // 早期 fixture 按文件名口径写了 darwin-arm64，跟真实 index.json 对不上，
        // 测试全绿但线上列表静默全空 —— fixture 必须锁真实格式。
        let json = """
        [
          {"version":"v23.1.0","files":["osx-x64-tar","linux-x64"],"lts":false},
          {"version":"v22.11.0","files":["osx-arm64-tar","linux-arm64","src"],"lts":"Jod"},
          {"version":"v22.10.0","files":["linux-arm64"],"lts":false},
          {"version":"v20.18.1","files":["osx-arm64-tar","osx-x64-tar","headers"],"lts":"Iron"}
        ]
        """
        let entries = try JSONDecoder().decode([NodeService.DistEntry].self,
                                                from: Data(json.utf8))
        let versions = NodeService.parseDist(entries)

        XCTAssertEqual(versions.map(\.version), ["22.11.0", "20.18.1"], "只留 arm64 的条目，且按版本号降序")
        XCTAssertEqual(versions[0].name, "Node-22.11.0")
        XCTAssertEqual(versions[0].url.lastPathComponent, "node-v22.11.0-darwin-arm64.tar.gz", "文件名模板用 darwin-arch（跟 files 标识不是一个口径）")
        XCTAssertEqual(versions[0].lts, "Jod", "LTS 代号要跟着走")
        XCTAssertEqual(versions[1].lts, "Iron", "Node 20 也是 LTS（Iron），代号同样跟着走")
        // 被过滤掉的条目：x64 独占和完全没 macOS 包的
        XCTAssertFalse(versions.contains { $0.version == "23.1.0" })
        XCTAssertFalse(versions.contains { $0.version == "22.10.0" })
    }

    // MARK: - nodeRoot

    func testNodeRootLocatesPackageRoot() {
        // 官方包：<包根>/bin/node —— 退两级落在包根
        XCTAssertEqual(NodeService.nodeRoot(of: URL(fileURLWithPath: "/x/node-v22.11.0-darwin-arm64/bin/node")).lastPathComponent,
                       "node-v22.11.0-darwin-arm64")
        // 用户把目录给到只有 node 的那一层：目录本身就是版本根
        XCTAssertEqual(NodeService.nodeRoot(of: URL(fileURLWithPath: "/x/custom/node")).lastPathComponent, "custom")
        // fnm：<版本>/installation/bin/node —— PATH 单元是 installation 那一层
        // （PathService.managedPaths 给 nodeRoot 补的是它下面的 bin，installation/bin 里才有 node）
        XCTAssertEqual(NodeService.nodeRoot(of: URL(fileURLWithPath: "/x/v22.11.0/installation/bin/node")).lastPathComponent,
                       "installation")
    }

    // MARK: - parseNvmDefault

    func testParseNvmDefault() {
        // nvm alias default 的真实输出形态：`default -> v22.11.0 (-> N/A)`。
        XCTAssertEqual(NodeService.parseNvmDefault("default -> v22.11.0 (-> N/A)"), "22.11.0")
        XCTAssertEqual(NodeService.parseNvmDefault("default -> 20.18.1 (-> N/A)"), "20.18.1")
        // 没有 default 别名时输出 `N/A`，解析不出版本
        XCTAssertNil(NodeService.parseNvmDefault("N/A"))
        XCTAssertNil(NodeService.parseNvmDefault(""))
    }

    // MARK: - 安装形状

    // node 官方包是标准形状 <包目录>/bin/<二进制>，走 StaticCatalogService 的
    // 「往上退两级」落位 —— binaryNames 只认 node，npm / npx 跟 node 一起搬进 bin/，
    // 但不参与「装好了」的判定。
    func testInstallOfficialPackageShape() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macenv-node-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let package = "node-v22.11.0-darwin-arm64"
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        for path in ["\(package)/bin/node", "\(package)/bin/npm", "\(package)/bin/npx", "\(package)/lib/node_modules/npm/package.json"] {
            let file = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho fixture\n".utf8).write(to: file)
            let executable = path.contains("/bin/")
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
        }
        let zip = root.appendingPathComponent("fixture.tar")
        // 只打顶层条目，tar 里带包目录那一层（跟真实包一致）。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.currentDirectoryURL = stage
        process.arguments = ["-cf", zip.path, package]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "打 fixture tar 失败")

        let service = StaticCatalogService(root: root, app: "node", binaryNames: ["node"])
        let version = StaticVersion(name: "Node-22.11.0", version: "22.11.0",
                                    url: zip, downloaded: false, installed: false)
        try await service.install(version)

        let target = root.appendingPathComponent("server/node/versions/node-22.11.0")
        for binary in ["bin/node", "bin/npm", "bin/npx"] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.appendingPathComponent(binary).path),
                          "\(binary) 没落到位")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("lib/node_modules/npm/package.json").path),
                      "非二进制内容也该跟着搬")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(package).path),
                       "包目录那一层要被吃掉")
    }
}
