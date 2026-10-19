#!/bin/bash
# 打包未签名 IPA（放在工程目录内，与该目录一起持久保存）
# 未签名 IPA 交给 Sideloadly / AltStore 用免费 Apple ID 签名安装到 iPhone。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"      # .../ShortDramaBox
ROOT="$(dirname "$HERE")"
# 记录调用时的目录：入参若为相对路径，必须按调用目录解析，
# 否则会在打包阶段的临时目录里生成 IPA，随后被删掉。
START_PWD="$PWD"
OUT="${1:-$ROOT/ShortDramaBox-unsigned.ipa}"
case "$OUT" in
  /*) ;;
  *) OUT="$START_PWD/$OUT" ;;
esac
DD="$ROOT/build-dd"

cd "$HERE"
if command -v xcodegen >/dev/null; then xcodegen generate >/dev/null; fi

# xcodegen 2.46 会写出 objectVersion=77（Xcode 16 格式），
# 而 CI 的 macos-14 runner 默认是 Xcode 15.4，读不了新格式。
# 本工程只用了经典节区，没有 Xcode 16 专有构造，降级到 56 是安全的。
PBX="ShortDramaBox.xcodeproj/project.pbxproj"
if [ -f "$PBX" ] && grep -q "objectVersion = 77" "$PBX"; then
  sed -i.bak 's/objectVersion = 77;/objectVersion = 56;/' "$PBX"
  sed -i.bak '/preferredProjectObjectVersion = 77;/d' "$PBX"
  rm -f "$PBX.bak"
  echo "==> 已把工程格式从 77 降到 56（兼容 Xcode 15.4）"
fi

echo "==> 编译（未签名 Release）"
xcodebuild \
  -project ShortDramaBox.xcodeproj \
  -scheme ShortDramaBox \
  -sdk iphoneos \
  -configuration Release \
  -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" \
  build

APP="$DD/Build/Products/Release-iphoneos/ShortDramaBox.app"
[ -d "$APP" ] || { echo "找不到 $APP"; exit 1; }

echo "==> 打包 IPA"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
rm -f "$OUT"
( cd "$STAGE" && zip -qry "$OUT" Payload )
rm -rf "$STAGE"

echo "完成: $OUT ($(du -h "$OUT" | cut -f1))"
