import Foundation

// 对应 FlyEnv 的 Gradle 模块。没有常驻进程，只管「机器上有哪些、把哪个放进 PATH」，跟 Maven 同构。
// 版本管理来源：Static（官方包）、Homebrew、MacPorts、SDKMAN。gradle 自带 gradlew 封装，
// 只把 bin 放进 PATH 即可，不需要额外 export GRADLE_HOME。
@MainActor
final class GradleService {
    let root: URL
    let tools: ToolService

    init(root: URL, tools: ToolService) {
        self.root = root
        self.tools = tools
    }

    var versionsDirectory: URL { root.appendingPathComponent("server/gradle/versions", isDirectory: true) }

    func installedVersions(customDirectories: [String] = []) async -> [GradleVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        for item in (try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            candidates.append((item.appendingPathComponent("bin/gradle"), "Static"))
        }
        for (parent, source) in defaultParents {
            for item in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                candidates.append((item.appendingPathComponent("bin/gradle"), source))
            }
        }
        for (home, source) in defaultHomes {
            candidates.append((home.appendingPathComponent("bin/gradle"), source))
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            candidates += ["gradle", "bin/gradle"].map { (item.appendingPathComponent($0), L("source.custom")) }
        }
        var seen = Set<String>()
        var result: [GradleVersion] = []
        for (file, source) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            var found = versionFromDirectory(executable)
            if found == nil { found = await probe(executable) }
            guard let version = found else { continue }
            result.append(GradleVersion(version: version,
                                         directory: executable.deletingLastPathComponent().deletingLastPathComponent(),
                                         executable: executable,
                                         source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    // MacPorts 的 gradle 端口按 java PortGroup 装在 /opt/local/share/java/<端口名>/bin/gradle
    // （端口名带版本号，gradle / gradle8 各一份；/opt/local/bin/gradle 只是它的一条软链），
    // 所以那一层是**父目录**、得枚举一层；Homebrew 的 /opt/homebrew/opt/gradle 反过来
    // **自己就是包根**，bin/gradle 就在它下面。两种混进一个数组统一多枚举一层，Homebrew 就废了。
    private var defaultParents: [(URL, String)] {
        [ (tools.sdkmanRoot.appendingPathComponent("candidates/gradle", isDirectory: true), "SDKMAN"),
          (URL(fileURLWithPath: "/opt/local/share/java", isDirectory: true), "MacPorts") ]
    }

    private var defaultHomes: [(URL, String)] {
        ["/opt/homebrew/opt/gradle", "/usr/local/opt/gradle"].map { (URL(fileURLWithPath: $0, isDirectory: true), "Homebrew") }
    }

    // 跑 `gradle -v` 打印首行「Gradle 9.8.0」，没 JDK 时 gradle 起不来，所以目录名能抠出色版本就先抠
    // （gradle-9.8.0 / SDKMAN 的 9.8.0 都带版本号）。
    private func probe(_ executable: URL) async -> String? {
        let output = try? await Command.run(executable.path, ["-v"])
        return firstCapture(#"Gradle ([0-9][^ ]*)"#, in: output?.text ?? "")
    }

    private func versionFromDirectory(_ executable: URL) -> String? {
        let name = executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return firstCapture(#"(?:gradle-)?([0-9][0-9.]*[0-9])"#, in: name)
    }

    func clearQuarantine(_ version: StaticVersion) async {
        let target = versionsDirectory.appendingPathComponent("gradle-\(version.version)")
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", target.path])
    }

    // MARK: - SDKMAN

    func sdkmanGradleVersions() async throws -> [SdkmanVersion] {
        guard tools.sdkmanInstalled else { throw CommandError(message: L("error.sdkmanMissing")) }
        let command = "source \(singleQuoted(tools.sdkmanInitScript.path)) && sdk list gradle"
        let output = try await Command.run("/bin/zsh", ["-c", command])
        let installed = sdkmanInstalled("gradle")
        let current = sdkmanDefault("gradle")
        return Self.parseSdkmanOther(output.stdout).map {
            SdkmanVersion(vendor: "", library: "Gradle", version: $0, identifier: $0, installed: installed.contains($0), isDefault: current == $0)
        }
    }

    func sdkman(_ action: String, identifier: String,
                report: @escaping (String) -> Void, onStart: @escaping (Process) -> Void) async throws {
        let command = "source \(singleQuoted(tools.sdkmanInitScript.path)) && sdk \(action) gradle \(singleQuoted(identifier))"
        let status = try await Command.stream("/bin/zsh", ["-c", command], onStart: onStart, onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.toolCommandFailed") + "（\(status)）") }
    }

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
