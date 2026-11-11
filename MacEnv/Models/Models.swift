import Foundation

struct CommandOutput {
    let status: Int32
    let stdout: String
    let stderr: String
    var text: String { (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines) }
}

var isTesting: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

func tilde(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard path != home else { return "~" }
    return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
}

func expandTilde(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" { return home }
    return path.hasPrefix("~/") ? home + String(path.dropFirst(1)) : path
}

let macEnvDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("MacEnv", isDirectory: true)

let loginKeychainPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Keychains/login.keychain-db").path

func doubleQuoted(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func singleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func readLogTail(_ url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else { return "" }
    defer { try? handle.close() }
    try? handle.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
    return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
}

struct CommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol ServiceVersion: Identifiable {
    var version: String { get }
    var directory: URL { get }
    var executable: URL { get }
}

extension NginxVersion: ServiceVersion {}
extension DatabaseVersion: ServiceVersion {}
extension RedisVersion: ServiceVersion {}
extension PostgresVersion: ServiceVersion {}
extension ClickHouseVersion: ServiceVersion {}
extension MkCertVersion: ServiceVersion {}
extension PhpVersion: ServiceVersion {}
extension SwooleVersion: ServiceVersion {}
extension GoVersion: ServiceVersion {}
extension ComposerVersion: ServiceVersion {}
extension JavaVersion: ServiceVersion {}
extension MavenVersion: ServiceVersion {}
extension GradleVersion: ServiceVersion {}
extension RustVersion: ServiceVersion {}

struct NginxVersion: Identifiable, Hashable {
    var id: String { executable.path }
    let version: String
    let directory: URL
    let executable: URL
    let source: String
}

struct BrewFormula {
    let version: String
    let installedVersions: [String]
    let linkedVersion: String?
    let outdated: Bool
    let versionedFormulae: [String]
}

struct StaticVersion: Codable, Hashable, Identifiable {
    var id: String { version }
    let name: String
    let version: String
    let url: URL
    var downloaded: Bool
    var installed: Bool
    var lts: String? = nil
}

struct ServiceAlias: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
}

enum DatabaseKind: String, CaseIterable, Identifiable, Hashable, Codable {
    case mysql, mariadb

    var id: String { rawValue }
    var title: String { rawValue == "mysql" ? "MySQL" : "MariaDB" }
    var binaryName: String { rawValue == "mysql" ? "mysqld" : "mariadbd" }
    var adminBinaryName: String { rawValue == "mysql" ? "mysqladmin" : "mariadb-admin" }
    var configSection: String { rawValue == "mysql" ? "mysqld" : "mariadbd" }
    var defaultPort: Int { rawValue == "mysql" ? 3306 : 3307 }
    var socketPath: String { "/tmp/\(rawValue).socket" }
}

struct DatabaseVersion: Identifiable, Hashable {
    let kind: DatabaseKind
    let version: String
    let directory: URL
    let executable: URL
    let source: String
    let formula: String?

    var id: String { "\(kind.rawValue):\(executable.path)" }
    var majorMinor: String { version.split(separator: ".").prefix(2).joined(separator: ".") }
}

struct RedisVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String
    let formula: String?

    var id: String { executable.path }
    var majorMinor: String { version.split(separator: ".").prefix(2).joined(separator: ".") }
}

struct PostgresVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String
    let formula: String?

    var id: String { executable.path }
    var major: String { String(version.split(separator: ".").first ?? Substring(version)) }
}

struct ClickHouseVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

struct QdrantVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

extension QdrantVersion: ServiceVersion {}

struct RustFSVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

extension RustFSVersion: ServiceVersion {}

struct MinioVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

extension MinioVersion: ServiceVersion {}

struct Neo4jVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

extension Neo4jVersion: ServiceVersion {}

struct KafkaVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

extension KafkaVersion: ServiceVersion {}

struct RabbitMQVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String
    let formula: String?

    var id: String { executable.path }
}

extension RabbitMQVersion: ServiceVersion {}

struct ConsulVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
    var major: String { String(version.split(separator: ".").first ?? Substring(version)) }
}

extension ConsulVersion: ServiceVersion {}

struct EtcdVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String
    let formula: String?

    var id: String { executable.path }
    var major: String { String(version.split(separator: ".").first ?? Substring(version)) }
}

extension EtcdVersion: ServiceVersion {}

struct MkCertVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String
    let formula: String?

    var id: String { executable.path }
}

struct BrewFormulaItem: Identifiable, Hashable {
    let name: String
    let stable: String
    let installedVersions: [String]
    let linkedVersion: String?
    let outdated: Bool

    var id: String { name }
}

struct PhpVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String
    let formula: String?
    let runnable: Bool
    var fpmOverride: URL? = nil

    var id: String { "\(source):\(executable.path)" }
    var fpm: URL { fpmOverride ?? directory.appendingPathComponent("sbin/php-fpm") }
    var majorMinor: String { version.split(separator: ".").prefix(2).joined(separator: ".") }
}

enum IniFile {
    private static func pair(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#"), let mark = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<mark].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, trimmed[trimmed.index(after: mark)...].trimmingCharacters(in: .whitespaces))
    }

    static func value(_ key: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            if let (name, value) = pair(line), name == key { return value }
        }
        return nil
    }

    static func values(_ key: String, in text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            guard let (name, value) = pair(line), name == key else { return nil }
            return value
        }
    }

    static func set(_ key: String, to value: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { pair($0)?.0 == key }) {
            lines[index] = "\(key) = \(value)"
        } else {
            lines.insert("\(key) = \(value)", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    static func remove(_ key: String, from text: String) -> String {
        text.components(separatedBy: "\n").filter { pair($0)?.0 != key }.joined(separator: "\n")
    }

    static func remove(_ key: String, containing needle: String, from text: String) -> String {
        text.components(separatedBy: "\n").filter { line in
            guard let (name, value) = pair(line), name == key else { return true }
            return !value.contains(needle)
        }.joined(separator: "\n")
    }
}

struct PhpExtension: Identifiable, Hashable {
    let name: String
    let soname: String
    let installed: Bool
    let enabled: Bool

    var id: String { name }
}

struct PhpDisableFunction: Identifiable, Hashable {
    let name: String
    let disabled: Bool
    let removable: Bool

    var id: String { name }
}

struct SwooleVersion: Identifiable, Hashable {
    let version: String
    let phpVersion: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

struct GoVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

struct PythonVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

struct NodeVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String
    var isNvmDefault = false
    var isFnmDefault = false

    var id: String { executable.path }
}

struct RustVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String
    var isRustupDefault = false

    var id: String { executable.path }
}

struct GvmVersion: Identifiable, Hashable {
    let name: String
    let version: String
    let installed: Bool
    let isDefault: Bool

    var id: String { name }
}

enum GvmAction {
    case install, uninstall, useDefault
}

struct JavaVersion: Identifiable, Hashable {
    let version: String
    let vendor: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

struct ErlangVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

extension ErlangVersion: ServiceVersion {}

struct SdkmanVersion: Identifiable, Hashable {
    let vendor: String
    let library: String
    let version: String
    let identifier: String
    let installed: Bool
    let isDefault: Bool

    var id: String { identifier }
}

struct MavenVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

struct GradleVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

struct ComposerVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

func firstCapture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

func taskTitle(_ action: String, _ formula: String) -> String {
    String(format: L("message.taskTitle"), L("action." + action), formula)
}

struct LaunchTarget: Hashable, Identifiable {
    let key: String
    let kind: String
    let versionID: String
    let title: String
    var id: String { key }
}

struct PathMembership: Equatable {
    enum State: Equatable { case app, shell, none }

    let state: State
    let source: String?

    static let app = Self(state: .app)
    static let shell = Self(state: .shell)
    static let none = Self(state: .none)

    init(state: State, source: String? = nil) {
        self.state = state
        self.source = source
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.state == rhs.state }

    var icon: String {
        switch state {
        case .app: return "checkmark.circle.fill"
        case .shell: return "exclamationmark.circle.fill"
        case .none: return "circle"
        }
    }
}

func nginxQuotedContent(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$")
}

extension FileManager {
    func replaceDirectory(at target: URL, with source: URL) throws {
        if fileExists(atPath: target.path) { _ = try replaceItemAt(target, withItemAt: source) }
        else { try moveItem(at: source, to: target) }
    }
}
