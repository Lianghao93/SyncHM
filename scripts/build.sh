#!/usr/bin/env bash
# 构建 SyncHM 的 HAP 包。
#
# 与 ungoogled-chromium 的 build.sh 相同逻辑：
#   1. hvigor 拒绝含 CJK 字符的工程路径，所以把源码镜像到纯 ASCII 路径再编译。
#   2. Git Bash 会弄乱 "D:/Program Files/..." 形式的 PATH，需转成 /d/... 形式。
#
# 用法：
#   bash scripts/build.sh          # debug（默认）
#   bash scripts/build.sh release  # release
set -euo pipefail

SRC="${SRC:-E:/鸿蒙/SyncHM}"
BUILD_WIN="${BUILD:-E:/synchm-build}"
DS_WIN="${DEVECO_HOME:-D:/Program Files/DevEco Studio}"
MODE="${1:-debug}"

BUILD="$(cd "$(dirname "$BUILD_WIN")" && pwd)/$(basename "$BUILD_WIN")"
DS="$(cd "$DS_WIN" && pwd)"

mkdir -p "$BUILD"
for item in AppScope entry hvigor build-profile.json5 oh-package.json5 hvigorfile.ts; do
  [ -e "$SRC/$item" ] && cp -r "$SRC/$item" "$BUILD/"
done

cd "$BUILD"
export DEVECO_SDK_HOME="$DS_WIN/sdk"
export JAVA_HOME="$DS_WIN/jbr"
export PATH="$DS/jbr/bin:$DS/tools/node:$PATH"

node "$DS_WIN/tools/hvigor/bin/hvigorw.js" \
  --mode module -p product=default -p buildMode="$MODE" assembleHap --no-daemon

OUT="$BUILD/entry/build/default/outputs/default/entry-default-unsigned.hap"
if [ -f "$OUT" ]; then
  mkdir -p "$SRC/dist"
  cp "$OUT" "$SRC/dist/SyncHM-1.03-unsigned.hap"
  echo "HAP -> $SRC/dist/SyncHM-1.03-unsigned.hap"
fi
