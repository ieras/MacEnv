#!/bin/sh
set -eu

echo "Swift: $(swift --version | head -1)"
if command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version >/tmp/macenv-xcodebuild-version 2>/tmp/macenv-xcodebuild-error; then
  cat /tmp/macenv-xcodebuild-version
else
  echo "xcodebuild: unavailable or unusable (install matching Xcode for a full SwiftUI build)"
fi
echo "SDK: $(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo unavailable)"
cache_dir="${TMPDIR:-/tmp}/macenv-swift-module-cache"
mkdir -p "$cache_dir"
if CLANG_MODULE_CACHE_PATH="$cache_dir" find MacEnv -name '*.swift' -print0 | xargs -0 swiftc -parse; then
  echo "Swift parse: PASS"
else
  echo "Swift parse: BLOCKED"
  exit 1
fi
