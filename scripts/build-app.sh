#!/usr/bin/env bash
# 构建用于上架华为应用市场的 Release APP 包（.app，本地签名）。
#
# 流程：
#   1. 镜像源码到纯 ASCII 路径（hvigor 拒绝 CJK 工程路径；Git Bash PATH 规避）
#   2. hvigorw assembleApp（release，未签名）
#   3. hap-sign-tool 对 .app 本地签名（DevEco 26 的 build-profile 密码字段要求
#      IDE 加密串，纯命令行只能走 hapsigntool；AGC 网页上传必须签名包，未签名报 991）
#
# 签名材料在 signing/（.p12/.cer/.p7b），密码见 SIGN_STORE_PASSWORD 环境变量
# 或脚本内默认值。私钥 (.p12) 一旦丢失无法补发，务必备份。
#
# 用法：
#   bash scripts/build-app.sh          # 产出 dist/SyncHM-<版本>-release.app（已签名）
set -euo pipefail

SRC="${SRC:-E:/鸿蒙/SyncHM}"
BUILD_WIN="${BUILD:-E:/synchm-build}"
DS_WIN="${DEVECO_HOME:-D:/Program Files/DevEco Studio}"
SIGN_DIR="$SRC/signing"
SIGN_ALIAS="${SIGN_ALIAS:-synchm_release}"
SIGN_STORE_PASSWORD="${SIGN_STORE_PASSWORD:-Synchm#2026Release}"

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
  --mode project -p product=default -p buildMode=release assembleApp --no-daemon

# 产物位置：工程级 build/outputs/{product}/*.app（assembleApp 是工程级任务）
UNSIGNED_APP="$(find build/outputs entry/build -name '*.app' -type f 2>/dev/null | head -n 1)"
[ -n "$UNSIGNED_APP" ] || { echo "ERROR: 未找到未签名 .app 产物" >&2; exit 1; }

SIGNED_APP="${UNSIGNED_APP%.app}-signed.app"
# 注意：DevEco 26 内置 hap-sign-tool 的子命令是 sign-app（不是 sign-hap），
# 证书参数名是 -appCertFile，密码参数是 -keystorePwd/-keyPwd。
java -jar "$DS_WIN/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar" sign-app \
  -keyAlias "$SIGN_ALIAS" \
  -signAlg "SHA256withECDSA" \
  -mode localSign \
  -appCertFile "$SIGN_DIR/synchm_release.cer" \
  -profileFile "$SIGN_DIR/synchm_release_profileRelease.p7b" \
  -inFile "$UNSIGNED_APP" \
  -keystoreFile "$SIGN_DIR/synchm_release.p12" \
  -keystorePwd "$SIGN_STORE_PASSWORD" \
  -keyPwd "$SIGN_STORE_PASSWORD" \
  -outFile "$SIGNED_APP"

VERSION="$(grep -oP '"versionName"\s*:\s*"\K[^"]+' AppScope/app.json5 || echo 1.01)"
mkdir -p "$SRC/dist"
cp "$SIGNED_APP" "$SRC/dist/SyncHM-${VERSION}-release.app"
echo "APP -> $SRC/dist/SyncHM-${VERSION}-release.app（已签名）"
