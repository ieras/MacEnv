import Foundation

@MainActor
final class HostService {
    let root: URL

    init(root: URL) { self.root = root }

    var directory: URL { root.appendingPathComponent("vhost", isDirectory: true) }
    var nginxDirectory: URL { directory.appendingPathComponent("nginx", isDirectory: true) }
    var rewriteDirectory: URL { directory.appendingPathComponent("rewrite", isDirectory: true) }
    var logsDirectory: URL { directory.appendingPathComponent("logs", isDirectory: true) }
    var templateDirectory: URL { root.appendingPathComponent("VhostTemplate", isDirectory: true) }
    var file: URL { root.appendingPathComponent("host.json") }
    var hostsFile: URL { root.appendingPathComponent("app.hosts.txt") }
    var caDirectory: URL { root.appendingPathComponent("CA", isDirectory: true) }
    var rootCertificate: URL { caDirectory.appendingPathComponent("MacEnv-Root-CA.crt") }

    func prepare() throws {
        let fm = FileManager.default
        for url in [directory, nginxDirectory, rewriteDirectory, logsDirectory, templateDirectory, caDirectory] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - host.json

    func load() throws -> [Host] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        do { return try JSONDecoder().decode([Host].self, from: data) }
        catch {
            try? data.write(to: file.appendingPathExtension("bak"), options: .atomic)
            throw error
        }
    }

    func save(_ hosts: [Host]) throws {
        _ = try load()
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(hosts).write(to: file, options: .atomic)
    }

    // MARK: - 伪静态自动填充

    func autoFillRewrite(_ host: inout Host) {
        guard host.rewrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !host.root.isEmpty else { return }
        let root = URL(fileURLWithPath: host.root, isDirectory: true)
        let has: (String) -> Bool = { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }

        if has("wp-admin") && has("wp-content") && has("wp-includes") {
            host.rewrite = """
            location /
            {
            \t try_files $uri $uri/ /index.php?$args;
            }

            rewrite /wp-admin$ $scheme://$host$uri/ permanent;
            """
            return
        }
        if has("vendor/laravel") {
            host.rewrite = "location / {\n\ttry_files $uri $uri/ /index.php$is_args$query_string;\n}"
            host.root = descend(root, to: "public")
            return
        }
        if has("vendor/yiisoft") {
            host.rewrite = "location / {\n    try_files $uri $uri/ /index.php?$args;\n  }"
            host.root = descend(root, to: "web")
            return
        }
        if has("thinkphp") || has("vendor/topthink") {
            host.rewrite = "location / {\n\tif (!-e $request_filename){\n\t\trewrite  ^(.*)$  /index.php?s=$1  last;   break;\n\t}\n}"
            host.root = descend(root, to: "public")
        }
    }

    private func descend(_ root: URL, to name: String) -> String {
        let target = root.appendingPathComponent(name, isDirectory: true)
        guard root.lastPathComponent != name, FileManager.default.fileExists(atPath: target.path) else { return root.path }
        return target.path
    }

    // MARK: - vhost

    func write(_ host: Host) throws {
        try prepare()
        let fm = FileManager.default
        let name = host.useSSL && !host.sslCert.isEmpty ? "nginxSSL.vhost" : "nginx.vhost"
        let custom = templateDirectory.appendingPathComponent(name)
        guard let defaults = Bundle.main.url(forResource: "HostDefaults", withExtension: nil) else {
            throw CommandError(message: L("error.hostDefaultsMissing"))
        }
        var content = try String(contentsOf: fm.fileExists(atPath: custom.path) ? custom : defaults.appendingPathComponent(name), encoding: .utf8)

        content = content
            .replacingOccurrences(of: "#Server_Alias#", with: host.aliases.joined(separator: " "))
            .replacingOccurrences(of: "#Server_Root#", with: nginxQuotedContent(host.root))
            .replacingOccurrences(of: "#Rewrite_Path#", with: nginxQuotedContent(rewriteDirectory.path))
            .replacingOccurrences(of: "#Server_Name#", with: host.id)
            .replacingOccurrences(of: "#Log_Path#", with: nginxQuotedContent(logsDirectory.path))
            .replacingOccurrences(of: "#Server_Cert#", with: nginxQuotedContent(host.sslCert))
            .replacingOccurrences(of: "#Server_CertKey#", with: nginxQuotedContent(host.sslKey))
            .replacingOccurrences(of: "#Port_Nginx#", with: "\(host.port)")
            .replacingOccurrences(of: "#Port_Nginx_SSL#", with: "\(host.sslPort)")
        content = content.replacingOccurrences(of: "include enable-php.conf;",
                                                with: host.phpVersion.isEmpty ? "##Static Site Nginx##" : "include enable-php-\(host.phpVersion).conf;")

        if !host.reverseProxy.isEmpty {
            var block = ["#PWS-REVERSE-PROXY-BEGIN#"]
            for item in host.reverseProxy where !item.url.isEmpty {
                block.append("""
                location ^~ \(item.path) {
                      proxy_pass \(item.url);
                      proxy_set_header Host $http_host;
                      proxy_set_header X-Real-IP $remote_addr;
                      proxy_set_header X-Real-Port $remote_port;
                      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                      proxy_set_header X-Forwarded-Proto $scheme;
                      proxy_set_header X-Forwarded-Host $host;
                      proxy_set_header X-Forwarded-Port $server_port;
                      proxy_set_header REMOTE-HOST $remote_addr;
                      proxy_connect_timeout 60s;
                      proxy_send_timeout 600s;
                      proxy_read_timeout 600s;
                      proxy_http_version 1.1;
                      proxy_set_header Upgrade $http_upgrade;
                    }
                """)
            }
            block.append("#PWS-REVERSE-PROXY-END#")
            content = content.replacingOccurrences(of: "#REWRITE-END", with: "#REWRITE-END\n" + block.joined(separator: "\n") + "\n")
        }

        try fm.createDirectory(at: URL(fileURLWithPath: host.root, isDirectory: true), withIntermediateDirectories: true)
        try content.write(to: nginxDirectory.appendingPathComponent("\(host.id).conf"), atomically: true, encoding: .utf8)
        try host.rewrite.trimmingCharacters(in: .whitespacesAndNewlines)
            .write(to: rewriteDirectory.appendingPathComponent("\(host.id).conf"), atomically: true, encoding: .utf8)
    }

    func delete(_ host: Host) {
        let fm = FileManager.default
        for base in [host.id] {
            for url in [nginxDirectory.appendingPathComponent("\(base).conf"),
                        rewriteDirectory.appendingPathComponent("\(base).conf"),
                        logsDirectory.appendingPathComponent("\(base).log"),
                        logsDirectory.appendingPathComponent("\(base).error.log")] {
                try? fm.removeItem(at: url)
            }
        }
        try? fm.removeItem(at: caDirectory.appendingPathComponent(host.id))
    }

    func log(_ host: Host, kind: String) -> String {
        readLogTail(logsDirectory.appendingPathComponent("\(host.id).\(kind == "error" ? "error.log" : "log")"))
    }

    // MARK: - 系统 hosts

    func hostsBlock(_ hosts: [Host]) -> String {
        let isLoopback: (String) -> Bool = { name in
            let value = name.trimmingCharacters(in: .whitespaces).lowercased()
            return value == "localhost" || value.hasSuffix(".localhost") || value == "127.0.0.1" || value == "::1"
        }
        let lines = hosts.flatMap(\.aliases).filter { !$0.isEmpty && !isLoopback($0) }.map { "127.0.0.1     \($0)" }
        return lines.isEmpty ? "" : "#X-HOSTS-BEGIN#\n" + lines.joined(separator: "\n") + "\n#X-HOSTS-END#\n"
    }

    @discardableResult
    func syncHosts(_ hosts: [Host]) async throws -> Bool {
        try prepare()
        let block = hostsBlock(hosts)
        try block.write(to: hostsFile, atomically: true, encoding: .utf8)
        let path = "/etc/hosts"
        let current = try String(contentsOfFile: path, encoding: .utf8)
        let outside = current.replacingOccurrences(of: "(?s)#X-HOSTS-BEGIN#.*?#X-HOSTS-END#\\n?", with: "", options: .regularExpression)
        let next = block.isEmpty ? outside : outside + (outside.isEmpty || outside.hasSuffix("\n") ? "" : "\n") + block
        guard next != current else { return false }
        let temporary = root.appendingPathComponent("hosts.tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try next.write(to: temporary, atomically: true, encoding: .utf8)
        try await privileged("cat \(singleQuoted(temporary.path)) > \(path) || exit 1; dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null; exit 0")
        return true
    }

    // MARK: - 自签证书

    func certificatePaths(_ host: Host) -> (cert: String, key: String) {
        let base = caDirectory.appendingPathComponent(host.id).appendingPathComponent("CA-\(host.id)")
        return (base.path + ".crt", base.path + ".key")
    }

    func issue(_ host: inout Host, withMkcert version: MkCertVersion) async throws {
        let paths = certificatePaths(host)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: paths.cert).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let output = try await Command.run(version.executable.path,
                                           ["-cert-file", paths.cert, "-key-file", paths.key] + host.aliases)
        guard output.status == 0 else { throw CommandError(message: output.text) }
        host.sslCert = paths.cert
        host.sslKey = paths.key
        host.useSSL = true
    }

    func issue(_ host: inout Host) async throws {
        let fm = FileManager.default
        try prepare()
        let base = caDirectory.appendingPathComponent("MacEnv-Root-CA")
        if !fm.fileExists(atPath: rootCertificate.path) {
            try fm.createDirectory(at: caDirectory, withIntermediateDirectories: true)
            let cnf = base.appendingPathExtension("cnf")
            try "basicConstraints = critical,CA:TRUE\nkeyUsage = critical,keyCertSign,cRLSign\nsubjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid:always,issuer\n"
                .write(to: cnf, atomically: true, encoding: .utf8)
            try await openssl(["genrsa", "-out", base.path + ".key", "2048"])
            try await openssl(["req", "-new", "-key", base.path + ".key", "-out", base.path + ".csr", "-sha256", "-subj", "/CN=MacEnv-Root-CA"])
            try await openssl(["x509", "-req", "-in", base.path + ".csr", "-signkey", base.path + ".key",
                               "-out", rootCertificate.path, "-extfile", cnf.path, "-sha256", "-days", "3650"])
            try await trustRootCertificate()
        }

        let paths = certificatePaths(host)
        let hostDirectory = URL(fileURLWithPath: paths.cert).deletingLastPathComponent()
        try? fm.removeItem(at: hostDirectory)
        try fm.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        let name = hostDirectory.appendingPathComponent("CA-\(host.id)")
        var ext = "authorityKeyIdentifier=keyid,issuer\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment\nsubjectAltName=@alt_names\n\n[alt_names]\n"
        for (index, alias) in host.aliases.enumerated() { ext += "DNS.\(index + 1) = \(alias)\n" }
        ext += "IP.1 = 127.0.0.1\n"
        try ext.write(to: name.appendingPathExtension("ext"), atomically: true, encoding: .utf8)

        try await openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", name.path + ".key",
                           "-out", name.path + ".csr", "-sha256", "-subj", "/CN=CA-\(host.id)"])
        try await openssl(["x509", "-req", "-in", name.path + ".csr", "-out", name.path + ".crt",
                           "-extfile", name.path + ".ext", "-CA", rootCertificate.path, "-CAkey", base.path + ".key",
                           "-CAcreateserial", "-CAserial", base.path + ".srl", "-sha256", "-days", "3650"])
        host.sslCert = paths.cert
        host.sslKey = paths.key
    }

    func certificateInfo(_ host: Host) async -> CertificateInfo? {
        let path = certificatePaths(host).cert
        guard FileManager.default.fileExists(atPath: path),
              let output = try? await Command.run("/usr/bin/openssl",
                                                  ["x509", "-noout", "-enddate", "-fingerprint", "-sha256", "-in", path]),
              output.status == 0 else { return nil }
        return CertificateInfo(
            expiry: firstCapture(#"notAfter=(.+)"#, in: output.text)?.split(separator: " ").joined(separator: " ") ?? "",
            fingerprint: firstCapture(#"Fingerprint=([0-9A-Fa-f:]+)"#, in: output.text) ?? "")
    }

    func rootCATrusted() async -> Bool {
        guard FileManager.default.fileExists(atPath: rootCertificate.path) else { return false }
        return (try? await Command.run("/usr/bin/security", ["verify-cert", "-c", rootCertificate.path]))?.status == 0
    }

    func trustRootCertificate() async throws {
        guard FileManager.default.fileExists(atPath: rootCertificate.path) else { return }
        let output = try await Command.run("/usr/bin/security",
                                           ["add-trusted-cert", "-r", "trustRoot", "-k", loginKeychainPath, rootCertificate.path])
        guard output.status == 0 else { throw CommandError(message: output.text) }
    }

    // MARK: - 子进程

    private func openssl(_ arguments: [String]) async throws {
        let output = try await Command.run("/usr/bin/openssl", arguments)
        guard output.status == 0 else { throw CommandError(message: output.text) }
    }
}
