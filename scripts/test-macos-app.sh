#!/bin/zsh
set -euo pipefail
root="${0:A:h}/.."
cd "$root"
xcodebuild test -project MacEnv.xcodeproj -scheme MacEnv \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox' \
  CODE_SIGN_IDENTITY=- "$@"
