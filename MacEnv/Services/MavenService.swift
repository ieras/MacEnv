import Foundation

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

    private var defaultParents: [(URL, String)] {
        [ (tools.sdkmanRoot.appendingPathComponent("candidates/maven", isDirectory: true), "SDKMAN"),
          (URL(fileURLWithPath: "/opt/local/share/java", isDirectory: true), "MacPorts") ]
    }

    private var defaultHomes: [(URL, String)] {
        ["/opt/homebrew/opt/maven", "/usr/local/opt/maven"].map { (URL(fileURLWithPath: $0, isDirectory: true), "Homebrew") }
    }

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

    func sdkman(_ action: String, identifier: String,
                report: @escaping (String) -> Void, onStart: @escaping (Process) -> Void) async throws {
        let command = "source \(singleQuoted(tools.sdkmanInitScript.path)) && sdk \(action) maven \(singleQuoted(identifier))"
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
