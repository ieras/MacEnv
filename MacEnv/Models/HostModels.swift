import Foundation

// 反向代理的一条：路径前缀 → 上游地址。
struct HostProxy: Codable, Hashable, Identifiable {
    var id = UUID()
    var path = "/"
    var url = ""
}

func hostID() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(13)).lowercased() }

// 一个站点。port / ssl / nginx 相关字段直接拍平在顶层：MacEnv 只有 nginx 一种
// 服务端，少一层嵌套取值路径，JSON 也短一半。
//
// 文件名一律用 host.id 而不是 name：多个 localhost 站点同名会互相覆盖。
// id 在改名时不变，所以改名不需要搬文件。
struct Host: Codable, Hashable, Identifiable {
    var id = hostID()
    var name = ""
    var alias = ""
    var mark = ""
    var root = ""
    var phpVersion = ""
    var port = 80
    var useSSL = false
    var sslPort = 443
    var autoSSL = false
    var sslCert = ""
    var sslKey = ""
    var rewrite = ""
    var reverseProxy: [HostProxy] = []
    var isTop = false

    // 主域名 + 别名，去重后排序。写 vhost 的 server_name 和
    // 系统 hosts 都吃这一份。
    var aliases: [String] {
        let extra = alias.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return Array(Set([name] + extra.filter { !$0.isEmpty })).sorted()
    }

    var url: String { "\(useSSL ? "https" : "http")://\(name)" + (useSSL ? (sslPort == 443 ? "" : ":\(sslPort)") : (port == 80 ? "" : ":\(port)")) }

    // 同配置、换一个新 id 的副本。Park 展开子目录时每个站点都要一份自己的 id，
    // 否则它们会共用同一个 vhost 文件互相覆盖。
    func copy() -> Host { var item = self; item.id = hostID(); return item }
}

// 已签发证书的到期时间和指纹，openssl x509 读出来的。没签发过就没有这一项。
struct CertificateInfo: Hashable {
    let expiry: String
    let fingerprint: String
}
