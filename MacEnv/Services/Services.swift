import Foundation

// 所有服务的持有者，供 ViewModel 注入。
@MainActor
final class Services {
    let root: URL
    let nginx: NginxService
    let paths: PathService
    let mysql: DatabaseService
    let mariadb: DatabaseService
    let redis: RedisService
    let mkcert: MkCertService
    let php: PhpService
    let phpFpm: PhpFpmService
    let swoole: SwooleService
    let composer: ComposerService
    let go: GoService
    let java: JavaService
    let maven: MavenService
    let gradle: GradleService
    let hosts: HostService
    let tools: ToolService
    private let catalogs: [String: StaticCatalogService]

    init() {
        let root = macEnvDirectory
        self.root = root
        catalogs = [
            "nginx": StaticCatalogService(root: root, app: "nginx", binaryNames: ["nginx"]),
            "mysql": StaticCatalogService(root: root, app: "mysql", binaryNames: ["mysqld"]),
            "php": StaticCatalogService(root: root, app: "php", binaryNames: ["php"]),
            "swoole-cli": StaticCatalogService(root: root, app: "swoole-cli", binaryNames: ["swoole-cli"]),
            "composer": StaticCatalogService(root: root, app: "composer", binaryNames: ["composer"]),
            // one-env 对 mkcert 直接给裸二进制（不是压缩包），所以要 rawBinary。
            "mkcert": StaticCatalogService(root: root, app: "mkcert", binaryNames: ["mkcert"], rawBinary: true),
            // one-env 的目录接口只认 "golang"，传 "go" 它会回 400（app 类型错误）。
            "golang": StaticCatalogService(root: root, app: "golang", binaryNames: ["go"], displayName: "Go"),
            // JDK 的 tarball 里是 Contents/Home/bin/java，「往上退两级」正好落在 Home 这一层。
            "java": StaticCatalogService(root: root, app: "java", binaryNames: ["java"]),
            "maven": StaticCatalogService(root: root, app: "maven", binaryNames: ["mvn"], displayName: "Maven"),
            "gradle": StaticCatalogService(root: root, app: "gradle", binaryNames: ["gradle"], displayName: "Gradle")
        ]
        nginx = NginxService(root: root)
        paths = PathService(root: root)
        mysql = DatabaseService(kind: .mysql, root: root)
        mariadb = DatabaseService(kind: .mariadb, root: root)
        redis = RedisService(root: root)
        mkcert = MkCertService(root: root)
        php = PhpService(root: root)
        phpFpm = PhpFpmService(root: root)
        swoole = SwooleService(root: root)
        composer = ComposerService(root: root)
        go = GoService(root: root)
        hosts = HostService(root: root)
        tools = ToolService(root: root)
        // Java 复用工具页的 SDKMAN 检测，所以必须排在 tools 后面。
        java = JavaService(root: root, tools: tools)
        maven = MavenService(root: root, tools: tools)
        gradle = GradleService(root: root, tools: tools)
    }

    func database(_ kind: DatabaseKind) -> DatabaseService { kind == .mysql ? mysql : mariadb }

    func catalog(_ app: String) -> StaticCatalogService { catalogs[app] ?? catalogs["nginx"]! }
}
