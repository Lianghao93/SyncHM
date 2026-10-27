#!/usr/bin/env bash
# 交叉编译 syncthing 核心 -> libsyncthing.so（鸿蒙 arm64）。
#
# 产出：entry/libs/arm64-v8a/libsyncthing.so 和 libsyncthing.h（cgo 生成）。
#
# 前置（关键！）：
#   本机需有一套支持 GOOS=openharmony 的 Go 工具链，即 OpenHarmony-SIG
#   维护的 Go fork（github/gitcode: openharmony-sig/ohos_golang_go，
#   release-branch.go1.24，版本 go1.24.5）。
#
#   为什么必须用 fork 而不是标准 Go：
#     标准 Go 的 -buildmode=c-shared 用 initial-exec (IE) TLS 模型访问
#     goroutine 指针 tlsg（产物里是 R_AARCH64_TLS_TPREL64 重定位）。鸿蒙
#     libc 是 musl，musl 的 dlopen 拒绝加载带 IE-TLS 重定位的共享库
#     （报 "initial-exec TLS resolves to dynamic definition"），导致
#     libsyncthingbridge.so 加载失败、ArkTS import 拿到 undefined。
#     OpenHarmony fork 给 arm64 补了 TLSDESC（R_AARCH64_TLSDESC），这是
#     musl 能正常 dlopen 的动态 TLS 模型。
#
#   构建 fork 工具链的方法（见 docs/IMPLEMENTATION.md）：
#     1. git clone --depth 1 -b release-branch.go1.24 \
#          https://gitcode.com/openharmony-sig/ohos_golang_go.git
#     2. cd <src>/src && cmd //c make.bat   （Windows，GOROOT_BOOTSTRAP 指向标准 Go）
#     3. 完成后把 <src>/bin 加到 PATH，或设 OHOS_GO 指向它。
#
# 本脚本通过 OHOS_GO 环境变量定位 fork 工具链；未设置时回退到 PATH 里的 go。
#
# 其他关键点：
#   - GOOS=openharmony GOARCH=arm64：鸿蒙内核是 Linux 系，MateBook Pro 是 arm64。
#   - CC 指向鸿蒙 SDK 的 clang.exe（通过无空格 junction C:/ohos-llvm）。
#   - sysroot 通过无空格 junction C:/ohos-sysroot 传入。
#   - 不使用 noassets tag：让 Web GUI 资源（auto.Assets()）嵌入 libsyncthing.so，
#     使 ArkTS 侧能通过内嵌 WebView 打开 syncthing 内置 WebUI 管理界面。
#     （需先运行 genassets 生成 lib/api/auto/gui.files.go，见下方 AUTO_GEN 步骤）
#   - -buildmode=c-shared：导出 C ABI 动态库，NAPI 直接 dlopen。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
GO_SRC="$PROJECT_ROOT/golang"
OUT_DIR="$PROJECT_ROOT/entry/libs/arm64-v8a"

# —— 定位 OpenHarmony Go fork 工具链 ——
if [ -n "${OHOS_GO:-}" ] && [ -x "$OHOS_GO/go" ]; then
  GO_BIN="$OHOS_GO/go"
elif [ -n "${OHOS_GO:-}" ] && [ -x "$OHOS_GO/go.exe" ]; then
  GO_BIN="$OHOS_GO/go.exe"
elif command -v go >/dev/null 2>&1; then
  GO_BIN="$(command -v go)"
else
  echo "错误：找不到 Go 工具链。请设置 OHOS_GO 指向 OpenHarmony Go fork 的 bin 目录。" >&2
  exit 1
fi

# 校验工具链支持 openharmony（标准 Go 会在这里报错，避免产出带 IE-TLS 的坏库）
if ! GOOS=openharmony GOARCH=arm64 "$GO_BIN" env GOOS >/dev/null 2>&1; then
  echo "错误：当前 Go 工具链不支持 GOOS=openharmony。请使用 OpenHarmony-SIG Go fork。" >&2
  echo "  参考 https://gitcode.com/openharmony-sig/ohos_golang_go" >&2
  exit 1
fi

DS_WIN="${DEVECO_HOME:-D:/Program Files/DevEco Studio}"
LLVM_SRC="$DS_WIN/sdk/default/openharmony/native/llvm"
SYSROOT_SRC="$DS_WIN/sdk/default/openharmony/native/sysroot"

# —— 创建无空格 junction（Windows 专用）——
_os="$(uname -s)"
case "$_os" in
  MINGW*|MSYS*|CYGWIN*)
    for pair in "C:/ohos-llvm|$LLVM_SRC" "C:/ohos-sysroot|$SYSROOT_SRC"; do
      dst="${pair%%|*}"; src="${pair##*|}"
      if [ ! -e "$dst" ]; then
        cmd //c mklink //J "$(cygpath -w "$dst")" "$(cygpath -w "$src")" >/dev/null 2>&1 || \
          echo "提示：无法自动建 junction $dst，请手动创建后重试"
      fi
    done
    CLANG="C:/ohos-llvm/bin/clang.exe"
    SYSROOT="C:/ohos-sysroot"
    ;;
  *)
    CLANG="$LLVM_SRC/bin/clang"
    SYSROOT="$SYSROOT_SRC"
    ;;
esac

if [ ! -f "$CLANG" ]; then
  echo "错误：找不到鸿蒙 clang 交叉编译器：$CLANG" >&2
  echo "请设置 DEVECO_HOME 指向 DevEco Studio 安装目录。" >&2
  exit 1
fi

export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

echo "== 用 OpenHarmony Go fork 交叉编译 syncthing 核心 =="
echo "  Go 工具链   : $("$GO_BIN" version)"
echo "  GOOS/GOARCH : openharmony/arm64"
echo "  CC          : $CLANG"
echo "  sysroot     : $SYSROOT"
echo "  输出        : $OUT_DIR/libsyncthing.so"

cd "$GO_SRC"

# 确保依赖完整
"$GO_BIN" mod tidy

# —— 生成 Web GUI 资源（auto.Assets()）——
# syncthing 的 Web UI 资源通过 lib/api/auto/gui.files.go 以 go:generate 方式嵌入，
# 官方发布版里该文件已生成，但 go mod 下载的是原始源码（只有 noassets 空壳）。
# 这里用 syncthing 自带的 genassets.go 手动生成到依赖包的 api/auto 目录，
# 从而让去除 -tags noassets 后能嵌入完整 Web UI。
SYNC_MOD_DIR="$("$GO_BIN" env GOMODCACHE)/github.com/syncthing/syncthing@v1.28.1"
GUI_FILES="$SYNC_MOD_DIR/lib/api/auto/gui.files.go"
if [ ! -f "$GUI_FILES" ]; then
  echo "== 生成 Web GUI 资源 gui.files.go =="
  "$GO_BIN" run "$SYNC_MOD_DIR/script/genassets.go" -o "$GUI_FILES" "$SYNC_MOD_DIR/gui"
fi

CGO_ENABLED=1 \
GOOS=openharmony \
GOARCH=arm64 \
CC="$CLANG" \
CGO_CFLAGS="-target aarch64-linux-ohos --sysroot=$SYSROOT" \
CGO_LDFLAGS="-target aarch64-linux-ohos --sysroot=$SYSROOT $SYSROOT/usr/lib/aarch64-linux-ohos/libhilog_ndk.z.so" \
  "$GO_BIN" build -buildmode=c-shared -o "$OUT_DIR/libsyncthing.so" .
BUILD_RC=$?
if [ $BUILD_RC -ne 0 ]; then
  echo ""
  echo "FATAL: go build 失败 (exit $BUILD_RC)，产物未更新！"
  echo "FATAL: 旧 libsyncthing.so 仍在 $OUT_DIR —— 打包前必须先修复编译错误"
  exit 1
fi

echo ""
echo "完成。产物："
echo "  $OUT_DIR/libsyncthing.so  ($(du -h "$OUT_DIR/libsyncthing.so" | cut -f1))"
echo "  $OUT_DIR/libsyncthing.h   (cgo 生成，供 NAPI 对齐函数声明)"
echo ""
echo "验证 TLS 模型（openharmony 已适配 musl：tls_g 为普通变量 + inittls 探测，"
echo "应无 R_AARCH64_TLS* 重定位，load_g/save_g 走一级间接）："
echo "  llvm-readelf -r $OUT_DIR/libsyncthing.so | grep TLS"
