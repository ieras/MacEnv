import Foundation

@MainActor
final class JavaService {
    let root: URL
    let tools: ToolService

    init(root: URL, tools: ToolService) {
        self.root = root
        self.tools = tools
    }

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

    private var defaultParents: [(URL, String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines", isDirectory: true), L("source.system")),
            (home.appendingPathComponent("Library/Java/JavaVirtualMachines", isDirectory: true), L("source.system")),
            (tools.sdkmanRoot.appendingPathComponent("candidates/java", isDirectory: true), "SDKMAN"),
            (URL(fileURLWithPath: "/opt/local/Library/Java/JavaVirtualMachines", isDirectory: true), "MacPorts"),
        ]
    }

    private var defaultHomes: [(URL, String)] {
        let entries = ["/opt/homebrew/opt", "/usr/local/opt"].flatMap {
            (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: $0), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        return entries.filter { $0.lastPathComponent.hasPrefix("openjdk") }.map { ($0, "Homebrew") }
    }

    private static let javaPaths = ["java", "Contents/Home/bin/java", "bin/java", "libexec/openjdk.jdk/Contents/Home/bin/java"]

    private static func findJava(in directory: URL) -> URL? {
        for path in javaPaths {
            let file = directory.appendingPathComponent(path)
            if FileManager.default.isExecutableFile(atPath: file.path) { return file }
        }
        return nil
    }

    static func javaHome(of executable: URL) -> URL {
        let bin = executable.deletingLastPathComponent()
        return bin.lastPathComponent == "bin" ? bin.deletingLastPathComponent() : bin
    }

    private func probe(_ executable: URL) async -> (String, String)? {
        let text = (try? String(contentsOf: Self.javaHome(of: executable).appendingPathComponent("release"), encoding: .utf8)) ?? ""
        let vendor = firstCapture(#"IMPLEMENTOR="([^"]*)""#, in: text) ?? ""
        if let version = firstCapture(#"JAVA_VERSION="([^"]*)""#, in: text) { return (version, vendor) }
        let output = try? await Command.run(executable.path, ["-version"])
        guard let version = firstCapture(#"version "([^"]+)""#, in: output?.text ?? "") else { return nil }
        return (version, vendor)
    }

    func clearQuarantine(_ version: StaticVersion) async {
        let target = versionsDirectory.appendingPathComponent("java-\(version.version)")
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", target.path])
    }

    // MARK: - SDKMAN

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

    private func sdkmanJavaInstalled() -> Set<String> {
        let directory = tools.sdkmanRoot.appendingPathComponent("candidates/java", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return Set(entries.map(\.lastPathComponent).filter { $0 != "current" })
    }

    private func sdkmanJavaDefault() -> String? {
        let link = tools.sdkmanRoot.appendingPathComponent("candidates/java/current")
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)).map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    func sdkmanJava(_ action: String, identifier: String,
                    report: @escaping (String) -> Void, onStart: @escaping (Process) -> Void) async throws {
        let command = "source \(singleQuoted(tools.sdkmanInitScript.path)) && sdk \(action) java \(singleQuoted(identifier))"
        let status = try await Command.stream("/bin/zsh", ["-c", command], onStart: onStart, onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.toolCommandFailed") + "（\(status)）") }
    }

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
