#!/bin/zsh
set -euo pipefail
root="${0:A:h}/.."
cd "$root"
# 单元测试会把 MacEnvTests.xctest 装进 app 的 Contents/PlugIns，
# 所以每次构建前先 clean，保证发布产物里没有测试代码。
xcodebuild -project MacEnv.xcodeproj -scheme MacEnv -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox' \
  CODE_SIGN_IDENTITY=- clean build
app="$root/build/Products/Debug/MacEnv.app"
missing=0
for item in Contents/Resources/Assets.car Contents/Resources/AppIcon.icns Contents/Resources/NginxDefaults \
            Contents/Resources/PhpDefaults Contents/Resources/HostDefaults Contents/Resources/RewriteDefaults \
            Contents/Resources/en.lproj Contents/Resources/zh-Hans.lproj Contents/Resources/zh-Hant.lproj Contents/Resources/ja.lproj; do
  if [ ! -e "$app/$item" ]; then echo "资源缺失：$item"; missing=1; fi
done
if [ -e "$app/Contents/PlugIns" ]; then echo "产物含测试 bundle：Contents/PlugIns"; missing=1; fi
if [ "$missing" -eq 1 ]; then
  echo "资源校验：FAILED（检查 project.pbxproj 的 PBXResourcesBuildPhase 是否列全）"
  exit 1
fi
echo "资源校验：PASS"
printf '%s\n' "$root/build/Products/Debug/MacEnv.app"
