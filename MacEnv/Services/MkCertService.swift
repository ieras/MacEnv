import Foundation

// 对应 FlyEnv 的 MkCert 模块（fork/module/MkCert）。
//
// mkcert 是**一次性 CLI**，不是常驻服务：没有端口、没有配置文件、没有日志
// （FlyEnv 的 getConfigFiles / getLogFiles 都返回 []），所以这里没有任何进程托管，
// 也不进 serviceEntries / 快捷启动。
//
// 它只干两件事：
//   · mkcert -install   把自带的根 CA 装进系统钥匙串（幂等，重复跑只是提示 already installed）
//   · mkcert -CAROOT    打印根 CA 的存放目录
// 站点证书的签发在 HostService.issue(_:withMkcert:)，因为那一步要连 vhost 一起重写。
@MainActor
final class MkCertService {
    let root: URL

    init(root: URL) { self.root = root }

    var versionsDirectory: URL { root.appendingPathComponent("server/mkcert/versions", isDirectory: true) }

    // 最近一次扫描到的 mkcert（版本号最大的那个）。保存站点时「自动签发证书」要问
    // 「有没有 mkcert」，但重扫一遍要跑 brew info，几百毫秒起步，所以扫描结果在这里留一份。
    // 还没扫过就是 nil，调用方回落内置 openssl 自签。
    private(set) var defaultVersion: MkCertVersion?

    // Homebrew / Static / MacPorts / 自定义目录。写法照 RedisService.installedVersions。
    func installedVersions(customDirectories: [String] = []) async throws -> [MkCertVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String, String?)] = []
        if let brew = Brew.executable {
            for formula in try await Brew.formulae("mkcert") {
                for version in formula.installedVersions {
                    for cellar in ["/opt/homebrew/Cellar", "/usr/local/Cellar"] {
                        let file = URL(fileURLWithPath: cellar).appendingPathComponent(formula.name).appendingPathComponent(version).appendingPathComponent("bin/mkcert")
                        if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Homebrew", formula.name)) }
                    }
                }
                let prefix = try await Command.run(brew, ["--prefix", formula.name], environment: Command.brewEnvironment)
                if prefix.status == 0 {
                    let file = URL(fileURLWithPath: prefix.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent("bin/mkcert")
                    if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Homebrew", formula.name)) }
                }
            }
        }
        if let items = try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items {
                for path in ["bin/mkcert", "mkcert"] {
                    let file = item.appendingPathComponent(path)
                    if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static", nil)); break }
                }
            }
        }
        for directory in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["mkcert", "bin/mkcert"] {
                let file = directory.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static", nil)) }
            }
        }
        // mkcert 是 Go 编的单文件，MacPorts 直接落在 /opt/local/bin（同 redis，不在 lib/<name>/bin 下）。
        let macPorts = URL(fileURLWithPath: "/opt/local/bin/mkcert")
        if fm.isExecutableFile(atPath: macPorts.path) { candidates.append((macPorts, "MacPorts", nil)) }

        var seen = Set<String>()
        var result: [MkCertVersion] = []
        for (file, source, formula) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            // mkcert --version 输出：v1.4.4
            let output = try await Command.run(executable.path, ["--version"])
            guard let version = firstCapture(#"v(\d+(?:\.\d+){1,3})"#, in: output.text) else { continue }
            result.append(MkCertVersion(version: version,
                                        directory: executable.deletingLastPathComponent().deletingLastPathComponent(),
                                        executable: executable, source: source, formula: formula))
        }
        result.sort { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        defaultVersion = result.first
        return result
    }

    func brewFormulae() async throws -> [BrewFormulaItem] { try await Brew.formulae("mkcert") }

    // mkcert -CAROOT 打印根 CA 目录（默认 ~/Library/Application Support/mkcert）。
    func caroot(_ version: MkCertVersion) async -> String {
        ((try? await Command.run(version.executable.path, ["-CAROOT"]))?.stdout ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 装根 CA。mkcert 自己会弹系统授权框，所以**不要**包 privileged()，否则会弹两次。
    // 幂等：重复跑只是打印 already installed。
    func installCA(_ version: MkCertVersion) async throws {
        let output = try await Command.run(version.executable.path, ["-install"])
        guard output.status == 0 else { throw CommandError(message: output.text) }
    }
}
