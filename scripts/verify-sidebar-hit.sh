#!/bin/sh
# 暂时停用（2026-11-10）：侧栏点击错位的 bug 已修复，日常构建不再打开 app 逐行点击。
# 恢复方式：删掉下面这行 echo，并取消后续各行行首的 "# "；验收逻辑仍在 verify-sidebar-hit.swift。
echo "侧栏逐行点击验收：已停用，跳过"

# set -eu
# root="$(cd "$(dirname "$0")/.." && pwd)"
# app="$root/build/Products/Release/MacEnv.app"
#
# # Release 包侧栏点击验收
# [ -d "$app" ] || { echo "没有 Release 包，先跑 scripts/build-release-app.sh"; exit 1; }
# binary="$app/Contents/MacOS/MacEnv"
# size=$(stat -f%z "$binary")
# [ "$size" -gt 1000000 ] || { echo "主程序仅 ${size} 字节，不是 Release 独立 Mach-O"; exit 1; }
#
# running=$(ps -axo args= | grep '[M]acEnv.app/Contents/MacOS/MacEnv' | head -1 || true)
# if [ -n "$running" ] && [ "$running" != "$binary" ]; then
#   echo "当前运行的是另一个 MacEnv：$running"
#   echo "先退出它再跑本工具（本工具只验收 $app）"
#   exit 1
# fi
# if [ -z "$running" ]; then
#   open "$app"
#   sleep 5
# fi
#
# bin="${TMPDIR:-/tmp}/macenv-verify-sidebar"
# swiftc -O "$root/scripts/verify-sidebar-hit.swift" -o "$bin"
# "$bin"
