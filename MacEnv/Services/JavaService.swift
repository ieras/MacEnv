import Foundation

// 对应 FlyEnv 的 Java 模块（src/fork/module/Java/index.ts）。
// Java 跟 Go 同构：没有常驻进程，只管两件事 —— 机器上有哪些 JDK、把哪个放进 PATH。
//
// 跟 FlyEnv 最大的差别在扫描范围：它只扫 /Library/Java/JavaVirtualMachines 和
// ~/.sdkman/candidates/java，前者在本机是空的，用户级的 ~/Library/Java/JavaVirtualMachines
// 才是 macOS 上 .pkg / IDE 自带 JDK 真正落地的地方 —— 照抄会一个都扫不到。
@MainActor
final class JavaService {
    let root: URL
    let tools: ToolService

    init(root: URL, tools: ToolService) {
        self.root = root
        self.tools = tools
    }

    // 必须跟 StaticCatalogService(app: "java") 算出来的完全一致，
    // 否则版本管理刚装完的 JDK，已安装列表扫不到 —— 两边指的不是同一个地方。
    var versionsDirectory: URL { root.appendingPathComponent("server/java/versions", isDirectory: true) }

    // MARK: - 已安装

    func installedVersions(customDirectories: [String] = []) async -> [JavaVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        for item in (try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            if let found = Self.findJava(in: item) { candidates.append((found, "Static")) }
        }
        for (parent, source) in defaultParents {
            for item in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                if let found = Self.findJava(in: item) { candidates.append((found, source)) }
            }
        }
        for (home, source) in defaultHomes {
            if let found = Self.findJava(in: home) { candidates.append((found, source)) }
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            // 用户加的既可能是一个 JDK Home，也可能是「装着若干 JDK 的目录」，两种都认。
            if let found = Self.findJava(in: item) {
                candidates.append((found, L("source.custom")))
            } else {
                for child in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                    if let found = Self.findJava(in: child) { candidates.append((found, L("source.custom"))) }
                }
            }
        }
        var seen = Set<String>()
        var result: [JavaVersion] = []
        for (file, source) in candidates {
            // brew / macports / sdkman 的 current 都是软链，解析到真身再判重，否则同一个 JDK 出现两行。
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            guard let (version, vendor) = await probe(executable) else { continue }
            result.append(JavaVersion(version: version,
                                      vendor: vendor,
                                      directory: Self.javaHome(of: executable),
                                      executable: executable,
                                      source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    // 这几个是约定俗成的落点，不进用户的「自定义路径」列表 —— 免得他们想删一条自己没加过的目录。
    //
    // 「装着若干 JDK 的目录」和「自己就是 JDK Home 的目录」是两回事，必须分开列。混进一个数组、
    // 调用点统一多枚举一层，Homebrew 的 keg 就会被整条跳过去（它底下是 libexec/bin，没有 JDK）。
    private var defaultParents: [(URL, String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines", isDirectory: true), L("source.system")),
            (home.appendingPathComponent("Library/Java/JavaVirtualMachines", isDirectory: true), L("source.system")),
            (tools.sdkmanRoot.appendingPathComponent("candidates/java", isDirectory: true), "SDKMAN"),
            (URL(fileURLWithPath: "/opt/local/Library/Java/JavaVirtualMachines", isDirectory: true), "MacPorts"),
        ]
    }

    // Homebrew 的 openjdk 公式按「openjdk / openjdk@21」这种名字链接到 /opt/homebrew/opt，
    // 每个 keg 根**本身就是 JDK Home**（java 在 bin/ 和 libexec/openjdk.jdk/Contents/Home/bin/ 下），
    // 不能再往下枚举一层。目录名带版本号只能前缀挑 —— 整个 opt 目录不能扫，那底下全是别的公式。
    private var defaultHomes: [(URL, String)] {
        let entries = ["/opt/homebrew/opt", "/usr/local/opt"].flatMap {
            (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: $0), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        return entries.filter { $0.lastPathComponent.hasPrefix("openjdk") }.map { ($0, "Homebrew") }
    }

    // JDK 的落点就这几种：官方 .pkg（Contents/Home）、裸 Home、Homebrew 的 keg（libexec 下再嵌一层）。
    private static let javaPaths = ["java", "Contents/Home/bin/java", "bin/java", "libexec/openjdk.jdk/Contents/Home/bin/java"]

    private static func findJava(in directory: URL) -> URL? {
        for path in javaPaths {
            let file = directory.appendingPathComponent(path)
            if FileManager.default.isExecutableFile(atPath: file.path) { return file }
        }
        return nil
    }

    // JDK Home = 装着 bin/ 和 release 的那一层。
    static func javaHome(of executable: URL) -> URL {
        let bin = executable.deletingLastPathComponent()
        return bin.lastPathComponent == "bin" ? bin.deletingLastPathComponent() : bin
    }

    // 版本和厂商从 <Home>/release 里读，不起进程。java -version 的输出**全在 stderr**，
    // 还得解析带引号的字符串；release 是 JDK 自带的纯 key="value" 文件，一次读全拿到。
    private func probe(_ executable: URL) async -> (String, String)? {
        let text = (try? String(contentsOf: Self.javaHome(of: executable).appendingPathComponent("release"), encoding: .utf8)) ?? ""
        let vendor = firstCapture(#"IMPLEMENTOR="([^"]*)""#, in: text) ?? ""
        if let version = firstCapture(#"JAVA_VERSION="([^"]*)""#, in: text) { return (version, vendor) }
        // 手工拷进来的 JDK 可能没有 release 文件，退回跑一次 java -version（用拼好的 text）。
        let output = try? await Command.run(executable.path, ["-version"])
        guard let version = firstCapture(#"version "([^"]+)""#, in: output?.text ?? "") else { return nil }
        return (version, vendor)
    }

    // 静态包解完要清 Gatekeeper 的隔离标记：不清的话第一次跑 java 系统直接弹「无法打开」。
    func clearQuarantine(_ version: StaticVersion) async {
        let target = versionsDirectory.appendingPathComponent("java-\(version.version)")
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", target.path])
    }

    // MARK: - SDKMAN

    // 装没装不看 `sdk list java` 的 Use 列 —— 它只列当前渠道还能下载的版本，
    // 用户装过的老版本可能已经下架、压根不在列表里（跟 GVM 的 listall vs list 是同一个坑）。
    // 直接扫 candidates/java 目录，再拿 current 软链判默认。
    func sdkmanJavaVersions() async throws -> [SdkmanVersion] {
        guard tools.sdkmanInstalled else { throw CommandError(message: L("error.sdkmanMissing")) }
        let command = "source \(singleQuoted(tools.sdkmanInitScript.path)) && sdk list java"
        let output = try await Command.run("/bin/zsh", ["-c", command])
        let installed = sdkmanJavaInstalled()
        let current = sdkmanJavaDefault()
        return Self.parseSdkmanJava(output.stdout).map {
            SdkmanVersion(vendor: $0.vendor, library: "Java", version: $0.version, identifier: $0.identifier,
                          installed: installed.contains($0.identifier), isDefault: current == $0.identifier)
        }
    }

    // 目录名就是 identifier（21.0.12-amzn）；current 是软链，不算一个版本。
    private func sdkmanJavaInstalled() -> Set<String> {
        let directory = tools.sdkmanRoot.appendingPathComponent("candidates/java", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return Set(entries.map(\.lastPathComponent).filter { $0 != "current" })
    }

    private func sdkmanJavaDefault() -> String? {
        let link = tools.sdkmanRoot.appendingPathComponent("candidates/java/current")
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)).map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    // `sdk` 是 sdkman-init.sh 里定义的 shell 函数，不在 PATH 上，必须先 source 才调得到。
    // install / uninstall / default 三个动作的语法完全一样，所以只写一份。
    func sdkmanJava(_ action: String, identifier: String,
                    report: @escaping (String) -> Void, onStart: @escaping (Process) -> Void) async throws {
        let command = "source \(singleQuoted(tools.sdkmanInitScript.path)) && sdk \(action) java \(singleQuoted(identifier))"
        let status = try await Command.stream("/bin/zsh", ["-c", command], onStart: onStart, onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.toolCommandFailed") + "（\(status)）") }
    }

    // 4 列：Vendor | Use | Version | Identifier。Use 列 > 是当前默认、* 是已安装、+ 是仅本地有。
    // vendor 只在换厂商那一行出现、续行是空的，所以要继承上一行；表头和分隔线列数不对，直接跳过。
    static func parseSdkmanJava(_ output: String) -> [SdkmanVersion] {
        var result: [SdkmanVersion] = []
        var vendor = ""
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 4, !parts[3].isEmpty, parts[3] != "Identifier" else { continue }
            if !parts[0].isEmpty { vendor = parts[0] }
            result.append(SdkmanVersion(vendor: vendor, library: "Java", version: parts[2], identifier: parts[3],
                                        installed: parts[1].contains("*"), isDefault: parts[1].contains(">")))
        }
        return result
    }
}
