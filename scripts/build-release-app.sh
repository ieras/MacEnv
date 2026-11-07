#!/bin/zsh
set -euo pipefail
root="${0:A:h}/.."
cd "$root"
# 发布构建（Release）
xcodebuild -project MacEnv.xcodeproj -scheme MacEnv -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/ReleaseDerivedData \
  OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox' \
  CODE_SIGN_IDENTITY=- clean build
app="$root/build/Products/Release/MacEnv.app"
missing=0
for item in Contents/Resources/Assets.car Contents/Resources/AppIcon.icns Contents/Resources/NginxDefaults \
            Contents/Resources/PhpDefaults Contents/Resources/HostDefaults Contents/Resources/RewriteDefaults \
            Contents/Resources/en.lproj Contents/Resources/zh-Hans.lproj Contents/Resources/zh-Hant.lproj Contents/Resources/ja.lproj; do
  if [ ! -e "$app/$item" ]; then echo "资源缺失：$item"; missing=1; fi
done
if [ -e "$app/Contents/PlugIns" ]; then echo "产物含测试 bundle：Contents/PlugIns"; missing=1; fi

# 产物形态校验
binary="$app/Contents/MacOS/MacEnv"
if [ ! -f "$binary" ]; then
  echo "主程序不存在：$binary"
  exit 1
fi
size=$(stat -f%z "$binary")
if [ "$size" -lt 1000000 ]; then echo "产物形态异常：主程序仅 ${size} 字节，疑似 Debug stub"; missing=1; fi
for junk in MacEnv.debug.dylib __preview.dylib; do
  if [ -e "$app/Contents/MacOS/$junk" ]; then echo "产物含调试动态库：$junk"; missing=1; fi
done
if otool -L "$binary" | grep -q 'MacEnv.debug.dylib'; then
  echo "产物形态异常：主程序仍依赖 MacEnv.debug.dylib"; missing=1
fi

if [ "$missing" -eq 1 ]; then
  echo "Release 产物校验：FAILED"
  exit 1
fi
echo "Release 产物校验：PASS（主程序 ${size} 字节，独立 Mach-O）"
printf '%s\n' "$app"
