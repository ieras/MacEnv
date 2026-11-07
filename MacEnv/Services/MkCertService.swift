import Foundation

@MainActor
final class MkCertService {
    let root: URL

    init(root: URL) { self.root = root }

    var versionsDirectory: URL { root.appendingPathComponent("server/mkcert/versions", isDirectory: true) }

    private(set) var defaultVersion: MkCertVersion?

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
        let macPorts = URL(fileURLWithPath: "/opt/local/bin/mkcert")
        if fm.isExecutableFile(atPath: macPorts.path) { candidates.append((macPorts, "MacPorts", nil)) }

        var seen = Set<String>()
        var result: [MkCertVersion] = []
        for (file, source, formula) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
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

    func caroot(_ version: MkCertVersion) async -> String {
        ((try? await Command.run(version.executable.path, ["-CAROOT"]))?.stdout ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rootPEM(_ version: MkCertVersion) async -> String {
        URL(fileURLWithPath: await caroot(version)).appendingPathComponent("rootCA.pem").path
    }

    func caExists(_ version: MkCertVersion) async -> Bool {
        let pem = await rootPEM(version)
        return FileManager.default.fileExists(atPath: pem)
    }

    func caTrusted(_ version: MkCertVersion) async -> Bool {
        let pem = await rootPEM(version)
        guard FileManager.default.fileExists(atPath: pem) else { return false }
        return (try? await Command.run("/usr/bin/security", ["verify-cert", "-c", pem]))?.status == 0
    }

    func installCA(_ version: MkCertVersion) async throws {
        let pem = await rootPEM(version)
        if !FileManager.default.fileExists(atPath: pem) {
            _ = try? await Command.run(version.executable.path, ["-install"])
        }
        let output = try await Command.run("/usr/bin/security",
                                           ["add-trusted-cert", "-r", "trustRoot", "-k", loginKeychainPath, pem])
        guard output.status == 0 else { throw CommandError(message: output.text) }
    }

    func uninstallCA(_ version: MkCertVersion) async throws {
        let pem = await rootPEM(version)
        let fm = FileManager.default
        guard fm.fileExists(atPath: pem) else { return }
        _ = try? await Command.run("/usr/bin/security", ["remove-trusted-cert", pem])
        if let fingerprint = try? await Command.run("/usr/bin/openssl", ["x509", "-in", pem, "-noout", "-fingerprint", "-sha1"]),
           let sha1 = firstCapture(#"Fingerprint=([0-9A-Fa-f:]+)"#, in: fingerprint.text) {
            _ = try? await Command.run("/usr/bin/security",
                                       ["delete-certificate", "-Z", sha1.replacingOccurrences(of: ":", with: "").lowercased(),
                                        loginKeychainPath])
        }
        let directory = URL(fileURLWithPath: pem).deletingLastPathComponent()
        try? fm.removeItem(at: directory.appendingPathComponent("rootCA-key.pem"))
        try? fm.removeItem(at: URL(fileURLWithPath: pem))
        try? fm.removeItem(at: directory)
    }
}
