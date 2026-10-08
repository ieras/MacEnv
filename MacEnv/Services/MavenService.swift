import Foundation

// 对应 FlyEnv 的 Maven 模块。Maven 没有常驻进程，只管「机器上有哪些、把哪个放进 PATH」，
// 跟 Java / Go 同构。版本管理来源：Static（官方包）、Homebrew、MacPorts、SDKMAN。
// 跟 Java 不同：mvn 自己会沿 PATH 找 java 或退到 /usr/libexec/java_home，所以 PATH 里
// 放好 bin 就够了，不需要额外 export MAVEN_HOME。
@MainActor
final class MavenService {
    let root: URL
    let tools: ToolService

    init(root: URL, tools: ToolService) {
        self.root = root
        self.tools = tools
    }

    var versionsDirectory: URL { root.appendingPathComponent("server/maven/versions", isDirectory: true) }

    func installedVersions(customDirectories: [String] = []) async -> [MavenVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        for item in (try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            candidates.append((item.appendingPathComponent("bin/mvn"), "Static"))
        }
        for (parent, source) in defaultParents {
            for item in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                candidates.append((item.appendingPathComponent("bin/mvn"), source))
            }
        }
        for (home, source) in defaultHomes {
            candidates.append((home.appendingPathComponent("bin/mvn"), source))
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            candidates += ["mvn", "bin/mvn"].map { (item.appendingPathComponent($0), L("source.custom")) }
        }
        var seen = Set<String>()
        var result: [MavenVersion] = []
        for (file, source) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            var found = versionFromDirectory(executable)
            if found == nil { found = await probe(executable) }
            guard let version = found else { continue }
            result.append(MavenVersion(version: version,
                                       directory: executable.deletingLastPathComponent().deletingLastPathComponent(),
                                       executable: executable,
                                       source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    // MacPorts 的 maven 端口落在 /opt/local/share/java/<端口名>/bin/mvn，端口名带版本号，
    // 所以那一层是**父目录**、得枚举一层；Homebrew 的 /opt/homebrew/opt/maven 反过来
    // **自己就是包根**，bin/mvn 就在它下面。两种混进一个数组统一多枚举一层，Homebrew 就废了。
    private var defaultParents: [(URL, String)] {
        [ (tools.sdkmanRoot.appendingPathComponent("candidates/maven", isDirectory: true), "SDKMAN"),
          (URL(fileURLWithPath: "/opt/local/share/java", isDirectory: true), "MacPorts") ]
    }

    private var defaultHomes: [(URL, String)] {
        ["/opt/homebrew/opt/maven", "/usr/local/opt/maven"].map { (URL(fileURLWithPath: $0, isDirectory: true), "Homebrew") }
    }

    // 跑 `mvn -v` 最准，但没 JDK 时脚本会提前退出、连版本都不打印，所以目录名能抠出版本就先抠，
    // 免得白起一个进程（maven-3.9.16 / SDKMAN 的 3.9.16 都带版本号）。
    private func probe(_ executable: URL) async -> String? {
        let output = try? await Command.run(executable.path, ["-v"])
        return firstCapture(#"Apache Maven ([0-9][^ ]*)"#, in: output?.text ?? "")
    }

    private func versionFromDirectory(_ executable: URL) -> String? {
        let name = executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return firstCapture(#"(?:maven-)?([0-9][0-9.]*[0-9])"#, in: name)
    }

    func clearQuarantine(_ version: StaticVersion) async {
        let target = versionsDirectory.appendingPathComponent("maven-\(version.version)")
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", target.path])
    }

    // MARK: - SDKMAN

    // 装没装不看 `sdk list maven` 的标记 —— 它只列当前渠道能下载的版本，已装老版本可能已下架。
    // 直接扫 candidates/maven 目录，再拿 current 软链判默认。
    func sdkmanMavenVersions() async throws -> [SdkmanVersion] {
        guard tools.sdkmanInstalled else { throw CommandError(message: L("error.sdkmanMissing")) }
        let command = "source \(singleQuoted(tools.sdkmanInitScript.path)) && sdk list maven"
        let output = try await Command.run("/bin/zsh", ["-c", command])
        let installed = sdkmanInstalled("maven")
        let current = sdkmanDefault("maven")
        return Self.parseSdkmanOther(output.stdout).map {
            SdkmanVersion(vendor: "", library: "Maven", version: $0, identifier: $0, installed: installed.contains($0), isDefault: current == $0)
        }
    }

    // install / uninstall / default 三个动作语法一样，只写一份。
    func sdkman(_ action: String, identifier: String,
                report: @escaping (String) -> Void, onStart: @escaping (Process) -> Void) async throws {
        let command = "source \(singleQuoted(tools.sdkmanInitScript.path)) && sdk \(action) maven \(singleQuoted(identifier))"
        let status = try await Command.stream("/bin/zsh", ["-c", command], onStart: onStart, onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.toolCommandFailed") + "（\(status)）") }
    }

    // `sdk list maven` 是平铺的版本号（每行若干 token，可能有 > / * 标记），不按 4 列表格排。
    // 已安装 / 默认改扫目录判，不信输出里的标记（格式一变就废）。
    static func parseSdkmanOther(_ output: String) -> [String] {
        output.split(separator: "\n").flatMap { line in
            line.split(whereSeparator: \.isWhitespace).compactMap { token -> String? in
                let text = String(token)
                return text.first?.isNumber == true ? text : nil
            }
        }
    }

    private func sdkmanInstalled(_ candidate: String) -> Set<String> {
        let directory = tools.sdkmanRoot.appendingPathComponent("candidates/\(candidate)", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return Set(entries.map(\.lastPathComponent).filter { $0 != "current" })
    }

    private func sdkmanDefault(_ candidate: String) -> String? {
        let link = tools.sdkmanRoot.appendingPathComponent("candidates/\(candidate)/current")
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)).map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}
