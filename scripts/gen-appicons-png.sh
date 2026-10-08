#!/bin/zsh
# 渲染 AppIcons/png 下的 128×128 明暗两套图标。
#
# 一个图标三步：
#   1. 从 MacEnv/Assets.xcassets/<X>Icon.imageset/<名字>.svg 拷一份到 AppIcons/svg/
#   2. 用 iconrender（CoreSVG / NSImage，跟 asset catalog 同一个解码器）渲染 128px 浅色版
#   3. 同一条再渲染深色版
#
# 只处理**单色剪影**图标（app 里走 template 渲染的那批）。Homebrew / 菜单栏 / GVM 三套字标
# 是 original 渲染、自带配色，不归这个脚本管 —— 它们在 ICONS 里没有条目，别往里加。
#
# 用法：
#   zsh scripts/gen-appicons-png.sh              # 全部
#   zsh scripts/gen-appicons-png.sh consul etcd  # 只重渲指定的几个
#
# ⚠️ 渲染引擎必须走 iconrender，不要用 qlmanage。qlmanage 出来是白底 RGBA、alpha 全 255，
#    只能拿亮度取反当遮罩 —— 源 SVG 里带彩色 fill（Nginx 是 #1677e8）或白色 fill（SDKMAN）
#    的会直接渲错。iconrender 取的是真正的 alpha 通道，跟 SwiftUI 的 template 渲染一致。
# ⚠️ 源 SVG 一律原样使用：不收紧 viewBox、不删 width/height。渲染器只用 SVG 的固有尺寸定
#    长宽比，不拿它当缩放系数，所以 width="32" 和 width="1024" 出来一模一样。

set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"
ASSETS="$ROOT/MacEnv/Assets.xcassets"

# (AppIcons 里的文件名, imageset 目录, imageset 里的 svg 文件名)
# 顺序对齐 AppIcons/README.md 的分节顺序。
ICONS=(
  nginx:NginxIcon:nginx.svg
  mysql:MySQLIcon:mysql.svg
  mariadb:MariaDBIcon:mariaDB.svg
  redis:RedisIcon:redis.svg
  postgresql:PostgresIcon:postgresql.svg
  clickhouse:ClickHouseIcon:clickhouse.svg
  qdrant:QdrantIcon:qdrant.svg
  consul:ConsulIcon:consul.svg
  etcd:EtcdIcon:etcd.svg
  php:PhpIcon:php.svg
  go:GoIcon:go.svg
  java:JavaIcon:java.svg
  python:PythonIcon:python.svg
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

# 编译渲染器（改了 .swift 会自动重编）
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
