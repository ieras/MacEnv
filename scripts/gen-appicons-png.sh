#!/bin/zsh
# 渲染 AppIcons/png 128×128 明暗两套图标
#
# 用法：
#   zsh scripts/gen-appicons-png.sh              # 全部
#   zsh scripts/gen-appicons-png.sh consul etcd  # 只重渲指定的几个

set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"
ASSETS="$ROOT/MacEnv/Assets.xcassets"

# (AppIcons 文件名, imageset 目录, svg 文件名)
ICONS=(
  nginx:NginxIcon:nginx.svg
  mysql:MySQLIcon:mysql.svg
  mariadb:MariaDBIcon:mariaDB.svg
  redis:RedisIcon:redis.svg
  postgresql:PostgresIcon:postgresql.svg
  clickhouse:ClickHouseIcon:clickhouse.svg
  qdrant:QdrantIcon:qdrant.svg
  minio:MinioIcon:minio.svg
  rustfs:RustFSIcon:rustfs.svg
  neo4j:Neo4jIcon:neo4j.svg
  rabbitmq:RabbitMQIcon:rabbitmq.svg
  kafka:KafkaIcon:kafka.svg
  consul:ConsulIcon:consul.svg
  etcd:EtcdIcon:etcd.svg
  php:PhpIcon:php.svg
  go:GoIcon:go.svg
  java:JavaIcon:java.svg
  python:PythonIcon:python.svg
  node:NodeIcon:nodejs.svg
  rust:RustIcon:rust.svg
  erlang:ErlangIcon:erlang-logo.svg
  maven:MavenIcon:maven.svg
  gradle:GradleIcon:gradle.svg
  macports:MacPortsIcon:macports.svg
  sdkman:SDKMANIcon:sdkman.svg
  composer:ComposerIcon:composer.svg
  swoole:SwooleIcon:swoole-cli.svg
  tools:ToolsIcon:tools.svg
  ssl:SSLIcon:sslmake.svg
  start:StartIcon:start.svg
)

# 编译渲染器
BIN="$ROOT/build/iconrender"
mkdir -p "$ROOT/build"
if [[ ! -x "$BIN" || "$ROOT/scripts/iconrender.swift" -nt "$BIN" ]]; then
  swiftc -O "$ROOT/scripts/iconrender.swift" -o "$BIN"
fi

mkdir -p "$ROOT/AppIcons/svg" "$ROOT/AppIcons/png"

for entry in "${ICONS[@]}"; do
  name="${entry%%:*}"
  rest="${entry#*:}"
  imageset="${rest%%:*}"
  file="${rest##*:}"

  if [[ $# -gt 0 && ! " ${*} " == *" $name "* ]]; then
    continue
  fi

  src="$ASSETS/$imageset.imageset/$file"
  [[ -f "$src" ]] || { echo "  跳过 $name：找不到 $src"; continue }

  cp "$src" "$ROOT/AppIcons/svg/$name.svg"
  "$BIN" template "$src" "$ROOT/AppIcons/png/$name-light.png" 128 0088FF FFFFFF
  "$BIN" template "$src" "$ROOT/AppIcons/png/$name-dark.png"  128 FFFFFF 1E1E1E
  echo "  $name"
done
