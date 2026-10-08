import Foundation

// 对应 FlyEnv 的 MkCert 模块（fork/module/MkCert）。
//
// mkcert 是**一次性 CLI**，不是常驻服务：没有端口、没有配置文件、没有日志
// （FlyEnv 的 getConfigFiles / getLogFiles 都返回 []），所以这里没有任何进程托管，
// 也不进 serviceEntries / 快捷启动。
//
// 它只干三件事：
//   · 把自带的根 CA 装进钥匙串 —— mkcert 自己的 -install 内部是 `sudo security add-trusted-cert`，
//     sudo 要靠终端读密码，我们没有终端，所以只借它生成 CA、装钥匙串那一步自己做（见 installCA）
//   · 卸掉根 CA（见 uninstallCA）—— mkcert 的 -uninstall 同样走 sudo，一样用不了
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
        for (file, formula) in try await Brew.installedBinaries("mkcert", binary: "mkcert") {
            candidates.append((file, "Homebrew", formula))
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

    // 根 CA 证书文件。mkcert -CAROOT 给的是目录，证书固定叫 rootCA.pem。
    private func rootPEM(_ version: MkCertVersion) async -> String {
        URL(fileURLWithPath: await caroot(version)).appendingPathComponent("rootCA.pem").path
    }

    // 根 CA 文件在不在。没信任也可能是装了一半（比如被人手动 remove-trusted-cert 过），
    // 卸载按钮靠它决定显不显示 —— 光看 caTrusted 的话这种残留就清不掉了。
    func caExists(_ version: MkCertVersion) async -> Bool {
        let pem = await rootPEM(version)
        return FileManager.default.fileExists(atPath: pem)
    }

    // 根 CA 是否已被系统信任。mkcert 自己也是这么判的（`caCert.Verify`），
    // 对应到命令行就是 security verify-cert —— 没信任时退 1 并打印 CSSMERR_TP_NOT_TRUSTED。
    func caTrusted(_ version: MkCertVersion) async -> Bool {
        let pem = await rootPEM(version)
        guard FileManager.default.fileExists(atPath: pem) else { return false }
        return (try? await Command.run("/usr/bin/security", ["verify-cert", "-c", pem]))?.status == 0
    }

    // 装根 CA。走**用户信任域**，不提权 —— 试过的三条路里只有这条通：
    //   · 原样跑 `mkcert -install`：它内部是 `sudo security add-trusted-cert`，sudo 要 TTY 读密码，
    //     而我们是普通 GUI 进程，没有终端，直接报「a terminal is required to read the password」
    //   · 把 `mkcert -install` 整个包进 privileged()：mkcert 的 CAROOT 取 `$CAROOT` →
    //     `$HOME/Library/Application Support`，root 的 HOME 是 /var/root，CA 会落到那儿；
    //     而且 root 建出来的 rootCA-key.pem 是 0400 root，之后用户自己签证书读不了
    //   · 包 privileged() 用 -d 装 admin 域：osascript 拉起的 root 拿不到 Authorization Services
    //     的交互授权，报「SecTrustSettingsSetTrustSettings: The authorization was denied
    //     since no user interaction was possible」
    // 重复装是幂等的：钥匙串按证书本身（签发者 + 序列号）去重，实测连装三次仍只有一条条目，
    // 所以不用「先卸再装」那套。界面那边会在已信任时把安装按钮收掉，纯粹是为了不白弹授权框。
    //
    // 用户域的信任对 SSL 全局生效。Firefox 走自己的 NSS 库，覆盖不到
    //（mkcert 本来也处理不了，它只装 system / user 两个 macOS 信任库）。
    func installCA(_ version: MkCertVersion) async throws {
        let pem = await rootPEM(version)
        // mkcert 生成 CA 在前、装钥匙串在后，所以没 TTY 时它会「失败但留下 CA」—— 只认文件。
        if !FileManager.default.fileExists(atPath: pem) {
            _ = try? await Command.run(version.executable.path, ["-install"])
        }
        let output = try await Command.run("/usr/bin/security",
                                           ["add-trusted-cert", "-r", "trustRoot", "-k", loginKeychainPath, pem])
        guard output.status == 0 else { throw CommandError(message: output.text) }
    }

    // 卸根 CA：撤信任设置 + 把证书从登录钥匙串删掉 + 删 CA 文件，不留垃圾。
    // 跟 installCA 对称，同样不提权。删了 CA 文件之后已签发的站点证书就失效了，
    // 界面那边要先确认一次（HostService.issue 会拿这份 CA 重新签）。
    func uninstallCA(_ version: MkCertVersion) async throws {
        let pem = await rootPEM(version)
        let fm = FileManager.default
        guard fm.fileExists(atPath: pem) else { return }
        // 没装过时这两条会退非零（找不到信任设置 / 钥匙串里没这条），不影响结果，忽略即可。
        _ = try? await Command.run("/usr/bin/security", ["remove-trusted-cert", pem])
        if let fingerprint = try? await Command.run("/usr/bin/openssl", ["x509", "-in", pem, "-noout", "-fingerprint", "-sha1"]),
           let sha1 = firstCapture(#"Fingerprint=([0-9A-Fa-f:]+)"#, in: fingerprint.text) {
            _ = try? await Command.run("/usr/bin/security",
                                       ["delete-certificate", "-Z", sha1.replacingOccurrences(of: ":", with: "").lowercased(),
                                        loginKeychainPath])
        }
        // CAROOT 里就 rootCA.pem / rootCA-key.pem 两个文件，一起删；目录空了才删得掉。
        let directory = URL(fileURLWithPath: pem).deletingLastPathComponent()
        try? fm.removeItem(at: directory.appendingPathComponent("rootCA-key.pem"))
        try? fm.removeItem(at: URL(fileURLWithPath: pem))
        try? fm.removeItem(at: directory)
    }
}
