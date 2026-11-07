import Foundation

private struct OneEnvResponse: Decodable {
    let code: Int
    let msg: String
    let data: [OneEnvVersion]
}

private struct OneEnvVersion: Decodable {
    let url: URL
    let version: String
}

@MainActor
final class StaticCatalogService {
    let root: URL
    let app: String
    let binaryNames: [String]
    let displayName: String
    let rawBinary: Bool
    let source: (() async throws -> [StaticVersion])?
    static let defaultEndpoint = URL(string: "https://api.one-env.com/api/version/fetch")!
    private var cache: URL { root.appendingPathComponent("catalog/static-\(app).json") }
    private var archives: URL { root.appendingPathComponent("cache", isDirectory: true) }
    private var versionsDirectory: URL { root.appendingPathComponent("server/\(app)/versions", isDirectory: true) }
    private static let refreshInterval: TimeInterval = 3600

    init(root: URL, app: String = "nginx", binaryNames: [String] = ["nginx"], displayName: String? = nil,
         rawBinary: Bool = false, source: (() async throws -> [StaticVersion])? = nil) {
        self.root = root
        self.app = app
        self.binaryNames = binaryNames
        self.displayName = displayName ?? app.capitalized
        self.rawBinary = rawBinary
        self.source = source
    }

    private func archiveURL(_ version: StaticVersion) -> URL {
        archives.appendingPathComponent("static-\(app)-\(version.version)\(rawBinary ? "" : ".tar." + version.url.pathExtension)")
    }

    func cached() -> [StaticVersion] {
        guard let data = try? Data(contentsOf: cache) else { return [] }
        return updateFlags((try? JSONDecoder().decode([StaticVersion].self, from: data)) ?? [])
    }

    func fetch(customEndpoint: String = "", force: Bool = false) async throws -> [StaticVersion] {
        let modified = (try? FileManager.default.attributesOfItem(atPath: cache.path))?[.modificationDate] as? Date
        let age = modified.map { Date().timeIntervalSince($0) } ?? .infinity
        if !force, age < Self.refreshInterval { return cached() }
        let versions: [StaticVersion]
        if let source {
            versions = try await source()
        } else {
            versions = try await Self.oneEnv(app: app, displayName: displayName, customEndpoint: customEndpoint)
        }
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(versions).write(to: cache, options: .atomic)
        return updateFlags(versions)
    }

    static func oneEnv(app: String, displayName: String, customEndpoint: String = "") async throws -> [StaticVersion] {
        let url = URL(string: customEndpoint).flatMap { customEndpoint.isEmpty ? nil : $0 } ?? Self.defaultEndpoint
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        #if arch(arm64)
        let arch = "arm"
        #else
        let arch = "x86"
        #endif
        request.httpBody = try JSONSerialization.data(withJSONObject: ["app": app, "os": "mac", "arch": arch])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw CommandError(message: L("error.catalogRequestFailed") + "（HTTP \(status)）")
        }
        let result = try JSONDecoder().decode(OneEnvResponse.self, from: data)
        guard result.code == 200 else { throw CommandError(message: result.msg) }
        return result.data.map { StaticVersion(name: "\(displayName)-\($0.version)", version: $0.version, url: $0.url, downloaded: false, installed: false) }
    }

    func install(_ version: StaticVersion, report: @escaping (String) -> Void = { _ in }, onStart: ((Process) -> Void)? = nil) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: archives, withIntermediateDirectories: true)
        try fm.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        let archive = archiveURL(version)
        if !fm.fileExists(atPath: archive.path) {
            try await Command.download(version.url, to: archive, report: report, onStart: onStart)
        }
        let target = versionsDirectory.appendingPathComponent("\(app)-\(version.version)", isDirectory: true)
        let staging = versionsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        if rawBinary {
            let bin = staging.appendingPathComponent("bin", isDirectory: true)
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let file = bin.appendingPathComponent(binaryNames[0])
            try fm.copyItem(at: archive, to: file)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            _ = try await Command.run("/usr/bin/xattr", ["-cr", file.path])
            try Task.checkCancellation()
            try fm.replaceDirectory(at: target, with: staging)
            return
        }
        let status: Int32
        if version.url.pathExtension == "zip" {
            status = try await Command.stream("/usr/bin/unzip", ["-q", archive.path, "-d", staging.path], onStart: onStart, onOutput: report)
        } else {
            status = try await Command.stream("/usr/bin/tar", [version.url.pathExtension == "gz" ? "-xzf" : "-xJf", archive.path, "-C", staging.path], onStart: onStart, onOutput: report)
        }
        guard status == 0 else {
            try fm.removeItem(at: archive)
            throw CommandError(message: L("error.unpackFailed") + "（\(status)）")
        }
        guard let binary = fm.enumerator(at: staging, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL }).first(where: {
            binaryNames.contains($0.lastPathComponent) && fm.isExecutableFile(atPath: $0.path)
                && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) == false
        }) else {
            try fm.removeItem(at: archive)
            throw CommandError(message: L("error.binaryMissing") + displayName)
        }
        try Task.checkCancellation()
        let parent = binary.deletingLastPathComponent()
        if parent.standardizedFileURL == staging.standardizedFileURL {
            let bin = staging.appendingPathComponent("bin", isDirectory: true)
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try fm.moveItem(at: binary, to: bin.appendingPathComponent(binary.lastPathComponent))
            try fm.replaceDirectory(at: target, with: staging)
        } else if ["bin", "sbin"].contains(parent.lastPathComponent) {
            try fm.replaceDirectory(at: target, with: parent.deletingLastPathComponent())
        } else {
            let bin = parent.appendingPathComponent("bin", isDirectory: true)
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            for entry in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard !isDirectory, fm.isExecutableFile(atPath: entry.path) else { continue }
                try fm.moveItem(at: entry, to: bin.appendingPathComponent(entry.lastPathComponent))
            }
            try fm.replaceDirectory(at: target, with: parent)
        }
    }

    func uninstall(_ version: StaticVersion) throws {
        try FileManager.default.removeItem(at: versionsDirectory.appendingPathComponent("\(app)-\(version.version)"))
    }

    private func updateFlags(_ versions: [StaticVersion]) -> [StaticVersion] {
        let fm = FileManager.default
        return versions.map {
            var version = $0
            version.downloaded = fm.fileExists(atPath: archiveURL(version).path)
            version.installed = binaryNames.contains { name in
                fm.isExecutableFile(atPath: versionsDirectory.appendingPathComponent("\(app)-\(version.version)/sbin/\(name)").path) ||
                    fm.isExecutableFile(atPath: versionsDirectory.appendingPathComponent("\(app)-\(version.version)/bin/\(name)").path)
            }
            return version
        }
    }
}
