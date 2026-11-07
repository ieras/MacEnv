import Foundation

struct HostProxy: Codable, Hashable, Identifiable {
    var id = UUID()
    var path = "/"
    var url = ""
}

func hostID() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(13)).lowercased() }

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

    var aliases: [String] {
        let extra = alias.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return Array(Set([name] + extra.filter { !$0.isEmpty })).sorted()
    }

    var url: String { "\(useSSL ? "https" : "http")://\(name)" + (useSSL ? (sslPort == 443 ? "" : ":\(sslPort)") : (port == 80 ? "" : ":\(port)")) }

    func copy() -> Host { var item = self; item.id = hostID(); return item }
}

struct CertificateInfo: Hashable {
    let expiry: String
    let fingerprint: String
}
