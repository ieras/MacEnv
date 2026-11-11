import Foundation

@MainActor
final class Services {
    let root: URL
    let nginx: NginxService
    let paths: PathService
    let mysql: DatabaseService
    let mariadb: DatabaseService
    let redis: RedisService
    let qdrant: QdrantService
    let neo4j: Neo4jService
    let rabbitmq: RabbitMQService
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
    let node: NodeService
    let rust: RustService
    let erlang: ErlangService
    let minio: MinioService
    let rustfs: RustFSService
    let kafka: KafkaService
    private let catalogs: [String: StaticCatalogService]

    init(root: URL = macEnvDirectory) {
        self.root = root
        catalogs = [
            "nginx": StaticCatalogService(root: root, app: "nginx", binaryNames: ["nginx"]),
            "mysql": StaticCatalogService(root: root, app: "mysql", binaryNames: ["mysqld"]),
            "php": StaticCatalogService(root: root, app: "php", binaryNames: ["php"]),
            "swoole-cli": StaticCatalogService(root: root, app: "swoole-cli", binaryNames: ["swoole-cli"]),
            "composer": StaticCatalogService(root: root, app: "composer", binaryNames: ["composer"]),
            "mkcert": StaticCatalogService(root: root, app: "mkcert", binaryNames: ["mkcert"], rawBinary: true),
            "golang": StaticCatalogService(root: root, app: "golang", binaryNames: ["go"], displayName: "Go"),
            "java": StaticCatalogService(root: root, app: "java", binaryNames: ["java"]),
            "python": StaticCatalogService(root: root, app: "python", binaryNames: ["python3"], displayName: "Python",
                                          source: { try await PythonService.standaloneVersions() }),
            "maven": StaticCatalogService(root: root, app: "maven", binaryNames: ["mvn"], displayName: "Maven"),
            "gradle": StaticCatalogService(root: root, app: "gradle", binaryNames: ["gradle"], displayName: "Gradle"),
            "clickhouse": StaticCatalogService(root: root, app: "clickhouse", binaryNames: ["clickhouse"],
                                              displayName: "ClickHouse", rawBinary: true),
            "qdrant": StaticCatalogService(root: root, app: "qdrant", binaryNames: ["qdrant"], displayName: "Qdrant"),
            "neo4j": StaticCatalogService(root: root, app: "neo4j", binaryNames: ["neo4j"], displayName: "Neo4j"),
            "rabbitmq": StaticCatalogService(root: root, app: "rabbitmq", binaryNames: ["rabbitmq-server"], displayName: "RabbitMQ"),
            "consul": StaticCatalogService(root: root, app: "consul", binaryNames: ["consul"], displayName: "Consul"),
            "etcd": StaticCatalogService(root: root, app: "etcd", binaryNames: ["etcd"], displayName: "etcd"),
            "node": StaticCatalogService(root: root, app: "node", binaryNames: ["node"], displayName: "Node",
                                         source: { try await NodeService.parseDist(NodeService.distEntries()) }),
            "rust": StaticCatalogService(root: root, app: "rust", binaryNames: ["rustc"], displayName: "Rust",
                                         source: { try await RustService.versions() }),
            "minio": StaticCatalogService(root: root, app: "minio", binaryNames: ["minio"], displayName: "MinIO"),
            "rustfs": StaticCatalogService(root: root, app: "rustfs", binaryNames: ["rustfs"], displayName: "RustFS"),
            "kafka": StaticCatalogService(root: root, app: "kafka", binaryNames: ["kafka-server-start.sh"], displayName: "Kafka",
                                          source: { try await KafkaService.versions() })
        ]
        nginx = NginxService(root: root)
        paths = PathService(root: root)
        mysql = DatabaseService(kind: .mysql, root: root)
        mariadb = DatabaseService(kind: .mariadb, root: root)
        redis = RedisService(root: root)
        qdrant = QdrantService(root: root)
        neo4j = Neo4jService(root: root)
        rabbitmq = RabbitMQService(root: root)
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
        node = NodeService(root: root)
        rust = RustService(root: root)
        erlang = ErlangService(root: root)
        minio = MinioService(root: root)
        rustfs = RustFSService(root: root)
        kafka = KafkaService(root: root)
        hosts = HostService(root: root)
        tools = ToolService(root: root)
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
