#!/bin/sh
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Products/Release/MacEnv.app"

# Release 包侧栏点击验收
[ -d "$app" ] || { echo "没有 Release 包，先跑 scripts/build-release-app.sh"; exit 1; }
binary="$app/Contents/MacOS/MacEnv"
size=$(stat -f%z "$binary")
[ "$size" -gt 1000000 ] || { echo "主程序仅 ${size} 字节，不是 Release 独立 Mach-O"; exit 1; }

running=$(ps -axo args= | grep '[M]acEnv.app/Contents/MacOS/MacEnv' | head -1 || true)
if [ -n "$running" ] && [ "$running" != "$binary" ]; then
  echo "当前运行的是另一个 MacEnv：$running"
  echo "先退出它再跑本工具（本工具只验收 $app）"
  exit 1
fi
if [ -z "$running" ]; then
  open "$app"
  sleep 5
fi

bin="${TMPDIR:-/tmp}/macenv-verify-sidebar"
swiftc -O "$root/scripts/verify-sidebar-hit.swift" -o "$bin"
"$bin"
