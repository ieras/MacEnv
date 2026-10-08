import Foundation

struct CommandOutput {
    let status: Int32
    let stdout: String
    let stderr: String
    var text: String { (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines) }
}

// 单元测试会以宿主进程方式加载本 app。这种情况下不要拦截退出，
// 也不要做真实的系统扫描 —— 否则测试会去跑 brew、zsh，既慢又跟测试无关。
var isTesting: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

// 界面上展示本机路径时，把家目录缩成 ~：/Users/ieras/Sites/laravel → ~/Sites/laravel。
// 只用于「显示」。任何真正拿去读写文件、拼 nginx 配置、执行命令的地方，都必须用原始绝对路径 ——
// 除了 shell 和 Finder 的「前往文件夹」，没人会替你把 ~ 展开。
func tilde(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard path != home else { return "~" }
    // 必须连着分隔符一起比，否则 /Users/ieras2 会被当成 /Users/ieras 底下的路径截掉。
    return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
}

// tilde 的逆运算。站点编辑框允许用户直接写 ~/Sites/myapp（占位符就是这么提示的），
// 但模型里和 nginx 配置里必须存绝对路径，所以输入的时候就得展开回去。
func expandTilde(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" { return home }
    return path.hasPrefix("~/") ? home + String(path.dropFirst(1)) : path
}

// MacEnv 的数据根目录：~/Library/Application Support/MacEnv。服务和设置都落在这里。
let macEnvDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("MacEnv", isDirectory: true)

// 登录钥匙串。security add-trusted-cert 不带 -k 只会写信任设置、证书不落进任何钥匙串，
// 所以装根 CA 时必须显式指到用户钥匙串上 —— 指到它就走**用户信任域**，不需要管理员授权。
let loginKeychainPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Keychains/login.keychain-db").path

// AppleScript 和配置文件的双引号字符串；shell 命令的字面量要用 singleQuoted。
func doubleQuoted(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

// 单引号包裹。shell 里唯一「一个字面量都不解释」的写法，脚本里的路径优先用它 ——
// 双引号里 $ ` \ 都还会展开，用户目录名里带个 $ 就出事。
func singleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// 日志跑久了能有几百 MB，整个读进来会把界面卡住 —— 统一只读尾部 512KB。
// 文件不存在或读不了都返回空串，界面上显示空就行，不值得为它弹个错。
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

// 各服务版本模型的公共面：能「显示版本号 + 点开目录 + 拿到可执行文件」的最小集合。
// GvmVersion 不参与 —— 它只是 gvm 列表里的一行，没有本地目录。
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
    // PG 的数据目录按主版本分：小版本升级官方承诺数据兼容，不必像 MySQL 那样每小版本一套。
    var major: String { String(version.split(separator: ".").first ?? Substring(version)) }
}

// ClickHouse 没有 Homebrew 公式（官方只有 cask）、MacPorts 也没有 port，
// 所以来源只有静态包一条路，形不上 formula 那个字段。
struct ClickHouseVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

// Qdrant 跟 ClickHouse 一样：官方没发 brew 公式（brew 公式接口查不到 qdrant）、MacPorts
// 也没有 port（FlyEnv 的 brewinfo / portinfo 都返回空），来源只有静态包一条路，没有 formula。
struct QdrantVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

extension QdrantVersion: ServiceVersion {}

// Consul 是服务治理组件（服务发现 + 健康检查 + KV + 自带的 Web UI），不是数据库。
// 官方包是**单个平铺的裸二进制**（zip 里只有 consul 一个条目，解压后 182MB），
// Homebrew 只有 cask / hashicorp tap（本机那个 tap 未信任，加载直接报错）、
// homebrew/core 里根本没有 consul 公式，所以来源只有 Static（one-env 的 zip）和 MacPorts 两条路。
struct ConsulVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
    // 配置、数据目录、日志都按主版本分：Consul 的 raft 存储格式跨大版本不保证兼容，
    // 1.x 的数据目录直接给 2.x 起会起不来（跟 PG 按主版本分数据目录是同一个道理）。
    var major: String { String(version.split(separator: ".").first ?? Substring(version)) }
}

extension ConsulVersion: ServiceVersion {}

// etcd 也是服务治理组件（分布式 KV + watch + 租约，K8s 的配置底座），跟 Consul 同一个分类。
// 跟 Consul 的两处不同：
//   · 来源多了 Homebrew —— homebrew/core 里有正式公式（3.7.2 bottled），MacPorts 反而没有 port；
//   · 官方包是 zip 且**二进制直接摆在包目录顶层**（etcd-v3.7.2-darwin-arm64/{etcd,etcdctl,etcdutl}），
//     没有 bin/ 那一层，所以 StaticCatalogService 里多了一条「顶层二进制补 bin/」的分支。
// 有 formula 字段是因为 Homebrew 那一栏要拿公式名去装/卸。
struct EtcdVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String
    let formula: String?

    var id: String { executable.path }
    // 按主版本分（3.5/3.6/3.7 共用 etcd-3-data）。注意 etcd 的存储格式是「小版本单向」的：
    // 3.5→3.6 要跑 etcdutl migrate，3.7 降回 3.5 会直接拒绝启动。用户真降级了得自己清目录。
    var major: String { String(version.split(separator: ".").first ?? Substring(version)) }
}

extension EtcdVersion: ServiceVersion {}

// mkcert 是一次性 CLI，没有常驻进程，所以这里没有 pid / 端口 / 配置那套东西，
// 只有「哪个二进制、什么版本、从哪来」。
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
    // php -v 跑不跑得起来。本机那三个 Homebrew PHP 缺 dylib，一执行就 SIGABRT，
    // 而且每次崩溃系统都往 DiagnosticReports 里丢一份报告。扫描时既然已经知道结果了，
    // 就别让后面的 php -i / php -m 再崩一遍 —— 探测类调用先看这个标志直接跳过。
    let runnable: Bool
    // MacPorts 的 fpm 叫 php-fpm<NN>、躺在 /opt/local/sbin，不符合
    // 「directory/sbin/php-fpm」的布局，扫描时把真实路径带进来。
    var fpmOverride: URL? = nil

    var id: String { "\(source):\(executable.path)" }
    var fpm: URL { fpmOverride ?? directory.appendingPathComponent("sbin/php-fpm") }
    // 8.4.15 → 8.4。扩展公式名（apcu@8.4）和 ini 路径（etc/php/8.4）都按大版本号分组。
    var majorMinor: String { version.split(separator: ".").prefix(2).joined(separator: ".") }
}

// php.ini 是纯文本，改一个配置项就是「找到那一行替换，没有就插一行」。
// 逐行扫而不是抄 FlyEnv 的三个正则（IniParse.ts）：它为了兼容缩进和行尾写得很绕，
// 逐行判注释前缀反而更短，也不会误伤用户注释掉的同名行。
enum IniFile {
    // 只认「非注释 + 有等号」的行。
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

    // 同一个键可能有很多行（php.ini 里十几条 extension= 是常态），全都取出来。
    static func values(_ key: String, in text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            guard let (name, value) = pair(line), name == key else { return nil }
            return value
        }
    }

    // 只改第一个匹配行；没有就插到文件头。注释掉的同名行原样留着 —— 那是用户自己写的笔记。
    static func set(_ key: String, to value: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { pair($0)?.0 == key }) {
            lines[index] = "\(key) = \(value)"
        } else {
            lines.insert("\(key) = \(value)", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    // 删掉所有匹配的非注释行。
    static func remove(_ key: String, from text: String) -> String {
        text.components(separatedBy: "\n").filter { pair($0)?.0 != key }.joined(separator: "\n")
    }

    // 只删「键匹配 且 值里带着 needle」的行。按整键删会把别人的配置一起清掉 ——
    // 摘掉 xdebug 的时候不能顺手把 mysqli、pdo_mysql 也删了。
    static func remove(_ key: String, containing needle: String, from text: String) -> String {
        text.components(separatedBy: "\n").filter { line in
            guard let (name, value) = pair(line), name == key else { return true }
            return !value.contains(needle)
        }.joined(separator: "\n")
    }
}

// 一个可安装的 PHP 扩展。installed 和 enabled 是两件独立的事：
// brew 装没装（keg 在不在）、.so 拷没拷进扩展目录、php.ini 里写没写，是三件事，
// 界面得让用户看见中间那种「文件在但没启用」的状态。
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
    // 内置列表里的删不掉；用户自己加的、以及从 php.ini 里读出来的可以删。
    let removable: Bool

    var id: String { name }
}

// SwooleCli 是自包含运行时：同一个二进制既能当 swoole-cli 也能当 php，
// 所以版本里得同时记住 swoole 版本和它内置的 PHP 版本。
struct SwooleVersion: Identifiable, Hashable {
    let version: String
    let phpVersion: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

// Go 没有常驻进程，一个版本要记的就是 GOROOT（directory）和 go 二进制本身。
// source 只用来在界面上区分它从哪来：我们自己装的静态包 / 用户加的目录 / GVM。
struct GoVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

// Python 同构于 Go / Java：没有常驻进程，一个版本就是「Python Home + 解释器二进制」。
// Home 是装着 bin/ 的那一级 —— Homebrew 的 keg 根、framework 的 Versions/3.12 都算。
struct PythonVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

// GVM 里的一个版本。name 是 gvm 自己的标识符（go1.24.4），version 是去掉前缀给人看的。
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

// Java 跟 Go 同构：没有常驻进程，一个版本要记的就是 JDK Home（directory）和 java 二进制。
// vendor 从 <Home>/release 里读，用来区分 Microsoft / Oracle / Amazon 这些发行版。
struct JavaVersion: Identifiable, Hashable {
    let version: String
    let vendor: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

// SDKMAN 的 `sdk list java` 一行。identifier 是 sdk 自己的安装标识（21.0.12-amzn），
// vendor 只在换厂商那一行出现，续行是空的 —— 解析时要继承上一行。
struct SdkmanVersion: Identifiable, Hashable {
    let vendor: String
    let library: String
    let version: String
    let identifier: String
    let installed: Bool
    let isDefault: Bool

    var id: String { identifier }
}

// Maven / Gradle 跟 Go 同构：没有常驻进程，一个版本记 Maven Home（含 bin/）和 mvn / gradle 二进制。
// source 只用来在界面上区分它从哪来：我们自己装的静态包 / 用户加的目录 / SDKMAN / Homebrew / MacPorts。
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

// composer 就是一个 .phar，装完只有版本号、路径和来源三件事要记。
struct ComposerVersion: Identifiable, Hashable {
    let version: String
    let directory: URL
    let executable: URL
    let source: String

    var id: String { executable.path }
}

// 正则取第一个捕获组。swoole-cli 和 composer 的版本号都只能从命令输出或文件内容里抠出来。
func firstCapture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

// 长任务浮层的标题，例如「安装 nginx」。brew 的四个动作名在七个模块的版本管理页里都要
// 翻成动词，所以 action 走 L("action.<动作>")，别把 install / uninstall 直接怼到界面上。
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

enum PathMembership: Equatable {
    case app, shell, none

    var icon: String {
        switch self {
        case .app: return "checkmark.circle.fill"
        case .shell: return "exclamationmark.circle.fill"
        case .none: return "circle"
        }
    }
}

// 模板已有双引号；路径里的特殊字符必须保留为字面量，避免变成 nginx 变量或指令。
func nginxQuotedContent(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$")
}

// 多种安装器共用同一落位方式：完整新包准备好后才替换，失败时原版本仍在。
extension FileManager {
    func replaceDirectory(at target: URL, with source: URL) throws {
        if fileExists(atPath: target.path) { _ = try replaceItemAt(target, withItemAt: source) }
        else { try moveItem(at: source, to: target) }
    }
}
