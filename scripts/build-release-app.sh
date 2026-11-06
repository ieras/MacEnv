#!/bin/zsh
set -euo pipefail
root="${0:A:h}/.."
cd "$root"
# 发布包必须走 Release。Debug 产物是几十 KB 的 stub + MacEnv.debug.dylib，
# 窗口标题栏形态、sidebar 的 top safe area inset 跟正式版不一样 —— 拿 Debug 包验收 UI
# 会漏掉「视觉行整体下移、点击热区留在原位」这类只在正式版出现的错位。
# clean 是必须的：单元测试会把 MacEnvTests.xctest 装进 app 的 Contents/PlugIns。
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

# 产物形态校验：确认这次真的出的是独立 Release 可执行文件，不是 Debug 的 stub。
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
