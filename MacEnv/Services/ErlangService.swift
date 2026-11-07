import Foundation

@MainActor
final class ErlangService {
    let root: URL

    init(root: URL) { self.root = root }

    func installedVersions(customDirectories: [String] = []) async -> [ErlangVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        for (file, _) in (try? await Brew.installedBinaries("erlang", binary: "erl")) ?? [] {
            candidates.append((file, "Homebrew"))
        }
        let port = URL(fileURLWithPath: "/opt/local/lib/erlang/bin/erl")
        if fm.isExecutableFile(atPath: port.path) { candidates.append((port, "MacPorts")) }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            if let found = Self.findErl(in: item) { candidates.append((found, L("source.custom"))) }
        }
        var seen = Set<String>()
        var result: [ErlangVersion] = []
        for (file, source) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            guard let version = try? await probe(executable) else { continue }
            result.append(ErlangVersion(version: version, directory: Self.erlRoot(of: executable), executable: executable, source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    private static func findErl(in directory: URL) -> URL? {
        for path in ["bin/erl", "erl"] {
            let file = directory.appendingPathComponent(path)
            if FileManager.default.isExecutableFile(atPath: file.path), !isDirectory(file) { return file }
        }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    static func erlRoot(of executable: URL) -> URL {
        let bin = executable.deletingLastPathComponent()
        return bin.lastPathComponent == "bin" ? bin.deletingLastPathComponent() : bin
    }

    private func probe(_ executable: URL) async throws -> String {
        let output = try await Command.run(executable.path, ["-noshell", "-eval", #"io:format("~s",[erlang:system_info(otp_release)]),halt()."#],
                                           environment: ["HOME": FileManager.default.homeDirectoryForCurrentUser.path])
        guard let version = Self.parseOtpRelease(output.stdout) else { throw CommandError(message: output.text) }
        return version
    }

    static func parseOtpRelease(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return firstCapture(#"^(\d{1,3})$"#, in: trimmed) ?? firstCapture(#"\b(\d{2,3})\b(?!\.\d)"#, in: trimmed)
    }
}
