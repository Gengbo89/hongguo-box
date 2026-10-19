#!/bin/bash
# 打包未签名 IPA（放在工程目录内，与该目录一起持久保存）
# 未签名 IPA 交给 Sideloadly / AltStore 用免费 Apple ID 签名安装到 iPhone。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"      # .../ShortDramaBox
ROOT="$(dirname "$HERE")"
OUT="${1:-$ROOT/ShortDramaBox-unsigned.ipa}"
DD="$ROOT/build-dd"

cd "$HERE"
if command -v xcodegen >/dev/null; then xcodegen generate >/dev/null; fi

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
