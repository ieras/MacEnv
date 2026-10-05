import Foundation

// 所有服务的持有者，供 ViewModel 注入。
@MainActor
final class Services {
    let root: URL
    let nginx: NginxService
    let paths: PathService
    let mysql: DatabaseService
    let mariadb: DatabaseService
    let php: PhpService
    let phpFpm: PhpFpmService
    let swoole: SwooleService
    let composer: ComposerService
    let go: GoService
    let hosts: HostService
    private let catalogs: [String: StaticCatalogService]

    init() {
        let root = macEnvDirectory
        self.root = root
        catalogs = [
            "nginx": StaticCatalogService(root: root, app: "nginx", binaryNames: ["nginx"]),
            "mysql": StaticCatalogService(root: root, app: "mysql", binaryNames: ["mysqld"]),
            "mariadb": StaticCatalogService(root: root, app: "mariadb", binaryNames: ["mariadbd"]),
            "php": StaticCatalogService(root: root, app: "php", binaryNames: ["php"]),
            "swoole-cli": StaticCatalogService(root: root, app: "swoole-cli", binaryNames: ["swoole-cli"]),
            "composer": StaticCatalogService(root: root, app: "composer", binaryNames: ["composer"]),
            // one-env 的目录接口只认 "golang"，传 "go" 它会回 400（app 类型错误）。
            "golang": StaticCatalogService(root: root, app: "golang", binaryNames: ["go"], displayName: "Go")
        ]
        nginx = NginxService(root: root)
        paths = PathService(root: root)
        mysql = DatabaseService(kind: .mysql, root: root)
        mariadb = DatabaseService(kind: .mariadb, root: root)
        php = PhpService(root: root)
        phpFpm = PhpFpmService(root: root)
        swoole = SwooleService(root: root)
        composer = ComposerService(root: root)
        go = GoService(root: root)
        hosts = HostService(root: root)
    }

    func database(_ kind: DatabaseKind) -> DatabaseService { kind == .mysql ? mysql : mariadb }

    func catalog(_ app: String) -> StaticCatalogService { catalogs[app] ?? catalogs["nginx"]! }
}
