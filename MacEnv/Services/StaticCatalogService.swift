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
    // one-env 对 mkcert 这类工具直接给裸二进制（没有扩展名、不是压缩包），拷到 bin/ 下就算装完。
    let rawBinary: Bool
    // 自定义取货源。one-env 对某些 app 给不出货（python 就是空数组），这时候换一家的源，
    // 但下载 / 解包 / 落位 / installed 判定那条链路一行都不用改 —— 它们只认 StaticVersion。
    // nil 表示走 one-env；customEndpoint 也只对 one-env 生效，自定义源没有「换镜像」这回事。
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

    // 下载缓存的落点。裸二进制没有扩展名，别拼出个 "xxx.tar." 来。
    private func archiveURL(_ version: StaticVersion) -> URL {
        archives.appendingPathComponent("static-\(app)-\(version.version)\(rawBinary ? "" : ".tar." + version.url.pathExtension)")
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
        let versions: [StaticVersion]
        if let source {
            versions = try await source()
        } else {
            versions = try await oneEnv(customEndpoint)
        }
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(versions).write(to: cache, options: .atomic)
        return updateFlags(versions)
    }

    // one-env 的接口：POST 一个 app/os/arch 的 JSON，回一串 url+version。
    private func oneEnv(_ customEndpoint: String) async throws -> [StaticVersion] {
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
        // 必须排除目录：Go 官方包的顶层目录就叫 go，跟 bin/go 同名，
        // 而 isExecutableFile 对目录也返回 true（有搜索权限就算），不排掉会先把 staging/go 认成二进制，
        // 后面「往上退两级」就退成了 staging 自己，整个 versions 目录被搬走。
        guard let binary = fm.enumerator(at: staging, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL }).first(where: {
            binaryNames.contains($0.lastPathComponent) && fm.isExecutableFile(atPath: $0.path)
                && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) == false
        }) else {
            try fm.removeItem(at: archive)
            throw CommandError(message: L("error.binaryMissing") + displayName)
        }
        try Task.checkCancellation()
        let parent = binary.deletingLastPathComponent()
        // 落点分三种形状（对照测试 StaticCatalogInstallTests）：
        // ① 裸二进制      staging/<bin>           —— qdrant 的 tar.gz，没有包目录
        // ② 包目录直放    staging/<pkg>/<bin>     —— etcd 的官方 zip，二进制摆在包目录顶层
        // ③ 常规包        staging/<pkg>/bin/<bin> —— go / python / gradle / maven / swoole-cli
        // ① 和 ② 只看二进制是不是直接躺在 staging 根上（② 的父目录是 <pkg> 而非 staging）；
        // ② 和 ③ 只看父目录叫不叫 bin。`.path` 比较会因 isDirectory 带来的尾斜杠不一致翻车，统一 trim。
        if parent.standardizedFileURL == staging.standardizedFileURL {
            // ① 裸二进制：造 staging/bin/ 把唯一二进制放进去。
            let bin = staging.appendingPathComponent("bin", isDirectory: true)
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try fm.moveItem(at: binary, to: bin.appendingPathComponent(binary.lastPathComponent))
            try fm.replaceDirectory(at: target, with: staging)
        } else if ["bin", "sbin"].contains(parent.lastPathComponent) {
            // ③ 常规：二进制已经在 <pkg>/bin/ 里，整包（含 bin/）搬过去就行。
            try fm.replaceDirectory(at: target, with: parent.deletingLastPathComponent())
        } else {
            // ② etcd：二进制直接摆在包目录顶层、没有 bin/。先给包目录补 bin/，把顶层可执行文件
            // 搬进去（README / LICENSE / 子目录留在原地），再整体落位到 target ——
            // 全项目「二进制一定在 bin/」这个约定不破，下游 updateFlags / installedVersions 一行都不用改。
            let bin = parent.appendingPathComponent("bin", isDirectory: true)
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            // 只搬「文件 + 有可执行位」的条目：README / LICENSE 留在原地，目录（含刚建的 bin）跳过。
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
