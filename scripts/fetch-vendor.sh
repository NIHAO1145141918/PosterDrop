#!/usr/bin/env bash
#
# 下载 AirliftFFI.xcframework（Airlift 的 Rust 核心静态库）。
#
# PosterDrop 只做「壁纸导入 + 注入」这一层，底层与 ATC/AirTraffic 通信、
# 配对握手、沙盒逃逸的实现来自 AirCard-iOS 仓库里预编译好的
# AirliftFFI.xcframework（MIT License，作者 @mak5er，底层为 @0xjohnnydev 的 Airlift）。
#
# 用法：
#   ./scripts/fetch-vendor.sh            # 下载到 Vendor/AirliftFFI.xcframework
#   AIRLIFT_REPO=... AIRLIFT_REF=... ./scripts/fetch-vendor.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/AirliftFFI.xcframework"
REPO="${AIRLIFT_REPO:-Mak5er/AirCard-iOS}"
REF="${AIRLIFT_REF:-40640c4d827aeab8d798285b57d24fcf6be070d0}"

if [ -d "$DEST" ]; then
  echo "==> Vendor/AirliftFFI.xcframework 已存在，跳过下载"
  exit 0
fi

if [ -n "${AIRLIFT_LOCAL_SRC:-}" ] && [ -d "${AIRLIFT_LOCAL_SRC:-}" ]; then
  echo "==> 从本地路径复制：$AIRLIFT_LOCAL_SRC"
  mkdir -p "$ROOT/Vendor"
  cp -R "$AIRLIFT_LOCAL_SRC" "$DEST"
  exit 0
fi

echo "==> 下载 $REPO@$REF 的源码包以提取 AirliftFFI.xcframework"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 5 --retry-delay 3 --retry-all-errors \
  -o "$TMP/src.tar.gz" \
  "https://codeload.github.com/$REPO/tar.gz/$REF"

mkdir -p "$TMP/unpack"
tar -xzf "$TMP/src.tar.gz" -C "$TMP/unpack"

SRC="$(find "$TMP/unpack" -maxdepth 3 -type d -name 'AirliftFFI.xcframework' | head -n 1)"
if [ -z "$SRC" ]; then
  echo "!! 没有在源码包里找到 AirliftFFI.xcframework" >&2
  exit 1
fi

mkdir -p "$ROOT/Vendor"
cp -R "$SRC" "$DEST"

echo "==> 完成：$(du -sh "$DEST" | cut -f1)  -> $DEST"
ls "$DEST"
