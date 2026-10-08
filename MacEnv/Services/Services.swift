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
    let qdrant: QdrantService
    let postgres: PostgresService
    let clickhouse: ClickHouseService
    let consul: ConsulService
    let etcd: EtcdService
    let mkcert: MkCertService
    let php: PhpService
    let phpFpm: PhpFpmService
    let swoole: SwooleService
    let composer: ComposerService
    let go: GoService
    let java: JavaService
    let python: PythonService
    let maven: MavenService
    let gradle: GradleService
    let hosts: HostService
    let tools: ToolService
    private let catalogs: [String: StaticCatalogService]

    init(root: URL = macEnvDirectory) {
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
            // one-env 对 python 只回一个空数组，所以走 python-build-standalone。解压后是
            // python/bin/python3，「往上退两级」正好落在安装根，跟 one-env 那批包完全一致。
            "python": StaticCatalogService(root: root, app: "python", binaryNames: ["python3"], displayName: "Python",
                                          source: { try await PythonService.standaloneVersions() }),
            "maven": StaticCatalogService(root: root, app: "maven", binaryNames: ["mvn"], displayName: "Maven"),
            "gradle": StaticCatalogService(root: root, app: "gradle", binaryNames: ["gradle"], displayName: "Gradle"),
            // one-env 对 clickhouse 给的是裸二进制（clickhouse-macos-aarch64，182MB），同 mkcert。
            "clickhouse": StaticCatalogService(root: root, app: "clickhouse", binaryNames: ["clickhouse"],
                                              displayName: "ClickHouse", rawBinary: true),
            // qdrant 的 tar.gz 里就一个裸 qdrant 二进制（不是裸二进制下载，外面裹了层 tar，
            // 所以不能用 rawBinary）。官方没发 brew 公式、MacPorts 也没 port —— 只有静态包一条路。
            "qdrant": StaticCatalogService(root: root, app: "qdrant", binaryNames: ["qdrant"], displayName: "Qdrant"),
            // consul 的 zip 里只有单个平铺的 consul 二进制（没有目录层），走 install 里
            // 「包顶就一个裸二进制」那条分支落到 bin/consul —— 同 qdrant，不用 rawBinary。
            "consul": StaticCatalogService(root: root, app: "consul", binaryNames: ["consul"], displayName: "Consul"),
            // etcd 的 zip 是 <包目录>/{etcd,etcdctl,etcdutl}，二进制直接摆在包目录顶层、没有 bin/，
            // 走 install 里「顶层二进制补 bin/」那条分支。注意 binaryNames 只给 etcd ——
            // etcdctl / etcdutl 会被那条分支一起搬进 bin/，但不参与「这个包算不算装好了」的判断。
            "etcd": StaticCatalogService(root: root, app: "etcd", binaryNames: ["etcd"], displayName: "etcd")
        ]
        nginx = NginxService(root: root)
        paths = PathService(root: root)
        mysql = DatabaseService(kind: .mysql, root: root)
        mariadb = DatabaseService(kind: .mariadb, root: root)
        redis = RedisService(root: root)
        qdrant = QdrantService(root: root)
        postgres = PostgresService(root: root)
        clickhouse = ClickHouseService(root: root)
        consul = ConsulService(root: root)
        etcd = EtcdService(root: root)
        mkcert = MkCertService(root: root)
        php = PhpService(root: root)
        phpFpm = PhpFpmService(root: root)
        swoole = SwooleService(root: root)
        composer = ComposerService(root: root)
        go = GoService(root: root)
        python = PythonService(root: root)
        hosts = HostService(root: root)
        tools = ToolService(root: root)
        // Java 复用工具页的 SDKMAN 检测，所以必须排在 tools 后面。
        java = JavaService(root: root, tools: tools)
        maven = MavenService(root: root, tools: tools)
        gradle = GradleService(root: root, tools: tools)
    }

    func database(_ kind: DatabaseKind) -> DatabaseService { kind == .mysql ? mysql : mariadb }

    func catalog(_ app: String) -> StaticCatalogService {
        guard let catalog = catalogs[app] else { preconditionFailure("Unregistered catalog: " + app) }
        return catalog
    }
}
