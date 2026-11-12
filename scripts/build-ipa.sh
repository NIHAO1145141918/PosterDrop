#!/usr/bin/env bash
#
# 构建未签名 IPA（用于 SideStore / AltStore / TrollStore / Sideloadly 自签安装）。
#
# 用法： ./scripts/build-ipa.sh [Release|Debug]
#
set -euo pipefail

CONFIG="${1:-Release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="PosterDrop"
BUILD_DIR="build"

if [ ! -d "$APP_NAME.xcodeproj" ]; then
  echo "==> 生成 Xcode 工程"
  xcodegen generate
fi

echo "==> 清理旧产物"
rm -rf "$BUILD_DIR/DerivedData" "$BUILD_DIR/Payload" "$BUILD_DIR/$APP_NAME.app" "$BUILD_DIR/$APP_NAME.ipa"
mkdir -p "$BUILD_DIR"

echo "==> 编译 $APP_NAME ($CONFIG)"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  -destination 'generic/platform=iOS' \
  -quiet \
  clean build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO

APP_PATH="$(find "$BUILD_DIR/DerivedData/Build/Products" -maxdepth 3 -name "$APP_NAME.app" -type d | head -n 1)"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "!! 没有找到 $APP_NAME.app，编译可能失败" >&2
  exit 1
fi

echo "==> 打包 IPA"
cp -R "$APP_PATH" "$BUILD_DIR/$APP_NAME.app"
rm -rf "$BUILD_DIR/$APP_NAME.app/_CodeSignature"
rm -f  "$BUILD_DIR/$APP_NAME.app/embedded.mobileprovision"

# 嵌一份 App Groups entitlement 再做 ad-hoc 签名：
# SideStore / AltStore 重签时会读取并保留它，worse_query 才有跳板。
if [ -f "Config/PosterDrop.entitlements" ]; then
  echo "==> ad-hoc 签名（带 App Groups entitlement）"
  codesign --force --sign - --timestamp=none \
    --entitlements "Config/PosterDrop.entitlements" \
    "$BUILD_DIR/$APP_NAME.app"
  codesign --display --entitlements :- "$BUILD_DIR/$APP_NAME.app" 2>/dev/null | head -n 20 || true
fi

mkdir -p "$BUILD_DIR/Payload"
cp -R "$BUILD_DIR/$APP_NAME.app" "$BUILD_DIR/Payload/$APP_NAME.app"

# IPA 就是「根目录下带 Payload/ 的 zip」；-y 保留符号链接
(cd "$BUILD_DIR" && zip -qry "$APP_NAME.ipa" "Payload")

rm -rf "$BUILD_DIR/Payload" "$BUILD_DIR/$APP_NAME.app"

echo "==> 完成：$ROOT/$BUILD_DIR/$APP_NAME.ipa"
ls -lh "$BUILD_DIR/$APP_NAME.ipa"
unzip -l "$BUILD_DIR/$APP_NAME.ipa" | head -n 12
