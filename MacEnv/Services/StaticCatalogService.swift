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
    // 列表里显示的名字前缀。默认是 app 首字母大写，但 one-env 的接口名不总是好看的那个
    // （golang → "Golang-1.27.1"，而 Go 官方和 FlyEnv 都写 "Go-1.27.1"）。
    let displayName: String
    static let defaultEndpoint = URL(string: "https://api.one-env.com/api/version/fetch")!
    private var cache: URL { root.appendingPathComponent("catalog/static-\(app).json") }
    private var archives: URL { root.appendingPathComponent("cache", isDirectory: true) }
    private var versionsDirectory: URL { root.appendingPathComponent("server/\(app)/versions", isDirectory: true) }
    private static let refreshInterval: TimeInterval = 3600

    init(root: URL, app: String = "nginx", binaryNames: [String] = ["nginx"], displayName: String? = nil) {
        self.root = root
        self.app = app
        self.binaryNames = binaryNames
        self.displayName = displayName ?? app.capitalized
    }

    // 上次请求结果永久保存在磁盘，界面任何时候都能先显示它。
    func cached() -> [StaticVersion] {
        guard let data = try? Data(contentsOf: cache) else { return [] }
        return updateFlags((try? JSONDecoder().decode([StaticVersion].self, from: data)) ?? [])
    }

    // 距上次成功请求超过一小时或手动刷新才打网络；请求失败保留旧结果。
    func fetch(customEndpoint: String = "", force: Bool = false) async throws -> [StaticVersion] {
        let modified = (try? FileManager.default.attributesOfItem(atPath: cache.path))?[.modificationDate] as? Date
        let age = modified.map { Date().timeIntervalSince($0) } ?? .infinity
        if !force, age < Self.refreshInterval { return cached() }
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
        let versions = result.data.map { StaticVersion(name: "\(displayName)-\($0.version)", version: $0.version, url: $0.url, downloaded: false, installed: false) }
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(versions).write(to: cache, options: .atomic)
        return updateFlags(versions)
    }

    func install(_ version: StaticVersion) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: archives, withIntermediateDirectories: true)
        try fm.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        let archive = archives.appendingPathComponent("static-\(app)-\(version.version).tar.\(version.url.pathExtension)")
        if !fm.fileExists(atPath: archive.path) {
            let (temporary, response) = try await URLSession.shared.download(from: version.url)
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                throw CommandError(message: L("error.downloadFailed") + "（HTTP \(status)）")
            }
            try? fm.removeItem(at: archive)
            try fm.moveItem(at: temporary, to: archive)
        }
        let staging = versionsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let output = try await Command.run("/usr/bin/tar", [version.url.pathExtension == "gz" ? "-xzf" : "-xJf", archive.path, "-C", staging.path])
        guard output.status == 0 else {
            try? fm.removeItem(at: staging)
            throw CommandError(message: output.text)
        }
        // 必须排除目录：Go 官方包的顶层目录就叫 go，跟 bin/go 同名，
        // 而 isExecutableFile 对目录也返回 true（有搜索权限就算），不排掉会先把 staging/go 认成二进制，
        // 后面「往上退两级」就退成了 staging 自己，整个 versions 目录被搬走。
        guard let binary = fm.enumerator(at: staging, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL }).first(where: {
            binaryNames.contains($0.lastPathComponent) && fm.isExecutableFile(atPath: $0.path)
                && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) == false
        }) else {
            try? fm.removeItem(at: staging)
            throw CommandError(message: L("error.binaryMissing") + displayName)
        }
        let target = versionsDirectory.appendingPathComponent("\(app)-\(version.version)", isDirectory: true)
        try? fm.removeItem(at: target)
        let packageRoot = binary.deletingLastPathComponent().deletingLastPathComponent()
        try fm.moveItem(at: packageRoot, to: target)
        if packageRoot.path != staging.path { try? fm.removeItem(at: staging) }
    }

    func uninstall(_ version: StaticVersion) throws {
        try FileManager.default.removeItem(at: versionsDirectory.appendingPathComponent("\(app)-\(version.version)"))
    }

    private func updateFlags(_ versions: [StaticVersion]) -> [StaticVersion] {
        let fm = FileManager.default
        return versions.map {
            var version = $0
            version.downloaded = fm.fileExists(atPath: archives.appendingPathComponent("static-\(app)-\(version.version).tar.\($0.url.pathExtension)").path)
            version.installed = binaryNames.contains { name in
                fm.isExecutableFile(atPath: versionsDirectory.appendingPathComponent("\(app)-\(version.version)/sbin/\(name)").path) ||
                    fm.isExecutableFile(atPath: versionsDirectory.appendingPathComponent("\(app)-\(version.version)/bin/\(name)").path)
            }
            return version
        }
    }
}
