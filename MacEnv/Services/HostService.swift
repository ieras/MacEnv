import Foundation

// 对应 FlyEnv 的 Host 模块（fork/module/Host + fork/module/Nginx/Host）。
//
// MacEnv 只做 nginx 一套 vhost，所以这里比 FlyEnv 少了一大半：
//   · 砍掉 apache / caddy / frankenphp 三套 conf 生成
//   · 砍掉 java / node / go / python / tomcat 五种站点类型
//   · 砍掉商业授权锁（FlyEnv 免费版第 3 个站点就拦）
//   · 砍掉 host.json 的 RSA 加密存盘（明文 JSON，反正没有 license 要保护）
//   · 砍掉 updateNginxConf 那张 60 行的增量替换表 —— 改站点时直接从模板重生成一份，
//     行为可预测得多，也不会有「改了端口但 listen 没跟着变」这类漏项
//
// 保留的核心机制：
//   · vhost / rewrite / log 文件名一律用 host.id（FlyEnv #700）
//   · 系统 hosts 用 #X-HOSTS-BEGIN# 标记块整块替换，loopback 名字跳过
//   · include enable-php-<两位版本>.conf 接线（NginxService.prepare 已经铺好）
//   · 四个框架的伪静态自动填充 + 入口目录自动下探
//   · 自签根 CA + 站点证书
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

    func load() -> [Host] {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return [] }
        if let list = try? JSONDecoder().decode([Host].self, from: data) { return list }
        // 解不出来就别装作没事：留一份原文，用户还能自己捞。
        try? data.write(to: file.appendingPathExtension("bak"), options: .atomic)
        return []
    }

    func save(_ hosts: [Host]) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(hosts).write(to: file, options: .atomic)
    }

    // MARK: - 伪静态自动填充

    // 对应 FlyEnv autoFillNginxRewrite。只在用户没写过 rewrite 的时候动手。
    // FlyEnv 在 park 时才把 root 下探到 public/web，正常新建反而不下探 —— 结果是 Laravel
    // 站点 root 停在项目根，try_files 找不到 index.php，直接 404。这里两种路径都下探。
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

    // 生成 vhost/nginx/<id>.conf 与 vhost/rewrite/<id>.conf。
    func write(_ host: Host) throws {
        try prepare()
        let fm = FileManager.default
        let name = host.useSSL && !host.sslCert.isEmpty ? "nginxSSL.vhost" : "nginx.vhost"
        // 站点模板管理：BaseDir/VhostTemplate/ 下的同名文件优先，跟 FlyEnv 一个规矩。
        let custom = templateDirectory.appendingPathComponent(name)
        guard let defaults = Bundle.main.url(forResource: "HostDefaults", withExtension: nil) else {
            throw CommandError(message: L("error.hostDefaultsMissing"))
        }
        var content = try String(contentsOf: fm.fileExists(atPath: custom.path) ? custom : defaults.appendingPathComponent(name), encoding: .utf8)

        content = content
            .replacingOccurrences(of: "#Server_Alias#", with: host.aliases.joined(separator: " "))
            .replacingOccurrences(of: "#Server_Root#", with: host.root)
            .replacingOccurrences(of: "#Rewrite_Path#", with: rewriteDirectory.path)
            .replacingOccurrences(of: "#Server_Name#", with: host.id)
            .replacingOccurrences(of: "#Log_Path#", with: logsDirectory.path)
            .replacingOccurrences(of: "#Server_Cert#", with: host.sslCert)
            .replacingOccurrences(of: "#Server_CertKey#", with: host.sslKey)
            .replacingOccurrences(of: "#Port_Nginx#", with: "\(host.port)")
            .replacingOccurrences(of: "#Port_Nginx_SSL#", with: "\(host.sslPort)")
        // 有 PHP 版本就 include 那一份 enable-php-<两位版本>.conf（NginxService.prepare 铺的），
        // 没有就留个注释标记，对应 FlyEnv 的 ##Static Site Nginx##。
        content = content.replacingOccurrences(of: "include enable-php.conf;",
                                                with: host.phpVersion.isEmpty ? "##Static Site Nginx##" : "include enable-php-\(host.phpVersion).conf;")

        // 反向代理块，插在 #REWRITE-END 之后。模板每次重生成，不存在旧块要摘，省掉 FlyEnv
        // handleReverseProxy 里那两行正则删除。
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
        // 顺带清掉按 name 命名的历史文件：那些文件会让 nginx 加载到重复的 server 块。
        for base in [host.id, host.name] where !base.isEmpty {
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

    // 标记块的内容。loopback 名字由系统自己解析，写进去只会白弹一次授权框（FlyEnv #700）。
    // 不写 ::1 —— nginx 的 `listen 80;` 只监听 IPv4，浏览器走 ::1 会连不上。
    func hostsBlock(_ hosts: [Host]) -> String {
        let isLoopback: (String) -> Bool = { name in
            let value = name.trimmingCharacters(in: .whitespaces).lowercased()
            return value == "localhost" || value.hasSuffix(".localhost") || value == "127.0.0.1" || value == "::1"
        }
        let lines = hosts.flatMap(\.aliases).filter { !$0.isEmpty && !isLoopback($0) }.map { "127.0.0.1     \($0)" }
        return lines.isEmpty ? "" : "#X-HOSTS-BEGIN#\n" + lines.joined(separator: "\n") + "\n#X-HOSTS-END#\n"
    }

    // 把标记块写进 /etc/hosts。返回 true 表示真的动了系统文件。
    @discardableResult
    func syncHosts(_ hosts: [Host]) async throws -> Bool {
        try prepare()
        let block = hostsBlock(hosts)
        try block.write(to: hostsFile, atomically: true, encoding: .utf8)
        let path = "/etc/hosts"
        let current = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        // 块外的内容一个字节都不动，只把标记块整段换掉。
        let outside = current.replacingOccurrences(of: "(?s)#X-HOSTS-BEGIN#.*?#X-HOSTS-END#\\n?", with: "", options: .regularExpression)
        let next = block.isEmpty ? outside : outside + (outside.isEmpty || outside.hasSuffix("\n") ? "" : "\n") + block
        guard next != current else { return false }
        let temporary = root.appendingPathComponent("hosts.tmp")
        try next.write(to: temporary, atomically: true, encoding: .utf8)
        try await privileged("cat '\(temporary.path)' > \(path) || exit 1; dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null; exit 0")
        try? FileManager.default.removeItem(at: temporary)
        return true
    }

    // MARK: - 自签证书

    // 站点要 https 时确保 sslCert / sslKey 就绪。根 CA 只在第一次生成并装进系统钥匙串。
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

        let hostDirectory = caDirectory.appendingPathComponent(host.id, isDirectory: true)
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
        host.sslCert = name.path + ".crt"
        host.sslKey = name.path + ".key"
    }

    // 把根 CA 加进系统钥匙串。要一次管理员授权；CA 已经生成过就不会再走到这里。
    func trustRootCertificate() async throws {
        guard FileManager.default.fileExists(atPath: rootCertificate.path) else { return }
        try await privileged("security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain '\(rootCertificate.path)'")
    }

    // MARK: - 子进程

    private func openssl(_ arguments: [String]) async throws {
        let output = try await Command.run("/usr/bin/openssl", arguments)
        guard output.status == 0 else { throw CommandError(message: output.text) }
    }
}
