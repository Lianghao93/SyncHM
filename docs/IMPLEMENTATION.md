# 实现说明：Go 侧如何接入真实 syncthing

**当前状态：已接入真实 syncthing 引擎，并用 OpenHarmony-SIG Go fork 交叉编译
通过**（openharmony/arm64，48MB libsyncthing.so，TLSDESC TLS 模型）。不再是占位骨架。

## 总体思路

syncthing 官方把「可复用的引擎」放在 `lib/` 包下，`cmd/syncthing` 只是薄 main。
本仓库直接 import `lib/syncthing`，用它的 `syncthing.New() + App.Start()` 启动
完整引擎——这与 `cmd/syncthing/main.go` 里的 `syncthingMain()` 走的是**同一条
代码路径**，因此具备与 Windows/Linux 版完全一致的同步能力。

## 启动链路（golang/libsyncthing.go 的 syncthing_start）

对应 `cmd/syncthing/main.go` 的 `syncthingMain()`，逐步：

```go
// 1. 设置数据目录（config.xml、证书、数据库都放应用沙箱）
locations.SetBaseDir(locations.ConfigBaseDir, baseDir)
locations.SetBaseDir(locations.DataBaseDir, baseDir)

// 2. 加载或生成设备证书（生成后得到本机 deviceID）
cert, _ := syncthing.LoadOrGenerateCertificate(
    locations.Get(locations.CertFile),
    locations.Get(locations.KeyFile))

// 3. 事件日志 + 配置
evLogger := events.NewLogger()
cfgWrapper, _ := syncthing.LoadConfigAtStartup(
    locations.Get(locations.ConfigFile), cert, evLogger,
    false, false, true)  // allowNewerConfig, noDefaultFolder, skipPortProbing

// 4. 打开数据库（LevelDB）
ldb, _ := syncthing.OpenDBBackend(
    locations.Get(locations.Database), cfgWrapper.Options().DatabaseTuning)

// 5. 创建 App 并启动（在独立 goroutine 里，Start 会阻塞）
app, _ := syncthing.New(cfgWrapper, ldb, evLogger, cert,
    syncthing.Options{NoUpgrade: true})
go app.Start()
```

## 状态查询映射

| Go export | 真实实现来源 |
| --- | --- |
| `syncthing_status` | `wrapper.MyID()` + `wrapper.DeviceList()` + `app.Internals.IsConnectedTo()` |
| `syncthing_folders` | `wrapper.FolderList()` + `app.Internals.FolderState(id)` |
| `syncthing_devices` | `wrapper.DeviceList()` + `app.Internals.IsConnectedTo()` |
| `syncthing_add_folder` | `wrapper.Modify(func(cfg){ cfg.SetFolder(f) })` + `Internals.ScanFolders()` |
| `syncthing_add_device` | `wrapper.Modify(func(cfg){ cfg.SetDevice(d) })` |
| `syncthing_remove_folder` | `wrapper.RemoveFolder(id)` |
| `syncthing_remove_device` | `wrapper.RemoveDevice(devID)` |

## 关键实现决策

### 1. `-tags noassets` 跳过 Web GUI

syncthing 的 `lib/api` 默认把 Web GUI 资源打包进二进制（`auto.Assets`），需要
先跑 `go generate`。但 ArkTS 外壳直接调引擎、不需要 Web GUI，所以用 syncthing
自带的 `lib/api/auto/noassets.go`（`//go:build noassets`）跳过，提供最小资源。
这同时避免了生成 GUI 资源的复杂性。

### 2. 鸿蒙交叉编译用无空格 junction 路径

cgo 的 `CC` 环境变量无法处理含空格的路径（`D:/Program Files/...` 会被拆成
`D:/Program`）。解决：建两个无空格 junction `C:/ohos-llvm` → llvm 目录、
`C:/ohos-sysroot` → sysroot 目录，CC 指向 `C:/ohos-llvm/bin/clang.exe`，
sysroot 通过 `--sysroot=C:/ohos-sysroot` 传入。见 scripts/build-golang.sh。

### 3. `*C.char` 返回字符串的内存管理

cgo 的 `//export` 函数返回字符串用 `C.CString()`，cgo 会 `malloc` 一份副本，
调用方（NAPI 层）负责 `free`。当前 NAPI 桥（napi_init.cpp）读取后未主动 free，
这在 Go c-shared 模式是常见做法（每次调用少量泄漏，可接受）；如需严格，
可在 NAPI 侧用 `free()` 释放，但需 `#include <stdlib.h>` 且与 Go 的 malloc 对齐。

### 4. 线程模型

Go 的 c-shared 库自带 goroutine 调度器，`app.Start()` 在独立 goroutine 里跑，
与 ArkTS 主线程互不阻塞。状态查询（getStatus 等）是非阻塞快照，ArkTS 用定时器
轮询（当前 3 秒）。

## 关键坑：Go c-shared 的 TLS 模型与鸿蒙 musl 不兼容（已解决）

这是本项目最深的坑，也是「能编译 ≠ 能运行」的典型。

### 现象

点「启动同步」后 ~1 秒闪退（整个进程退出回桌面），hilog 显示
`signal 11 (SIGSEGV) si_code(1)=SEGV_MAPERR` → `signal 6 (SIGABRT)` →
`reason=Cpp Crash`。而打开应用、点 `bridge.version()`（单线程）能正常显示界面。

### 根因

鸿蒙 libc 是 **musl**，其 TLS/线程本地存储是**两级间接**的：
`TPIDR_EL0` 指向 `struct pthread`（线程控制块），TSD（pthread key 数据）以
固定偏移存在该结构体里。Go runtime 的 `g` 指针（当前 goroutine）通过 TLS
变量 `tls_g` 访问，标准 Go 假设 glibc 的**一级间接** TLS（`*(TP + tls_g) == g`）。

在 musl 上 `*(TP + tls_g)` 实际是**指向 g 的指针**（而非 g 本身），于是：

1. 单线程（主线程）时 `tls_g` 恰好初始化正确，能跑；
2. 点启动 → `go app.Start()` 创建**新调度线程**，新线程的 `tls_g` 指向
   g-slot 而非 g 值，`getg()` 读错 → SIGSEGV。

对应 Go 官方 issue #82260，鸿蒙社区文章《为 HarmonyOS 定制 Go 工具链：
征服 musl emulated TLS》(cocozq.com/?p=3063)。

### 解决：musl 两级间接 TLS（v1.0.2，共 6 处 runtime 修改）

采用 cocozq 方案的**两级间接 TLS**，并补齐裸 `clone()` 线程的 TLS 设置：

| 文件 | 修改 |
| --- | --- |
| `src/runtime/tls_arm64.h` | openharmony 加 `TLSG_IS_VARIABLE`（tls_g 变普通变量）+ `TLS_NEEDS_BASE` |
| `src/runtime/tls_arm64.s` | load_g/save_g 重写为**两级间接**（NULL 容错）；新增 `getTLSgOff` |
| `src/runtime/asm_arm64.s` | rt0_go 用 `TLS_NEEDS_BASE` 传 TLS base 给 `x_cgo_init` |
| `src/runtime/cgo/gcc_linux_arm64.c` | 重写 `inittls`：±4KB SIGSEGV 安全探测 TSD 槽位偏移 + 每线程 g-slot；`threadentry` 为新线程设置 g-slot |
| `src/runtime/sys_linux_arm64.s` | clone 加第 6 参数 tls（x3，CLONE_SETTLS 用）；子线程设 g 后 `CALL save_g` 持久化 |
| `src/runtime/os_linux.go` | 新增 `tlsBlockAlloc()`（64KB 独立 TLS 块）；newosproc/newosproc0 在 openharmony 下 `flags \|= _CLONE_SETTLS` 并传 tls 块 |

**为什么 clone 必须改**：Go 调度器创建新 M 走裸 `clone()` 系统调用（`newosproc`），
不走 pthread_create。原汇编子线程路径只有一行 `// TODO: setup TLS.`——没有
CLONE_SETTLS 时 arm64 内核把子线程 TPIDR_EL0 置 0，新线程上任何 save_g/load_g
（cgo DNS 解析、信号处理等）直接 SEGV。这是「打开正常、点启动 ~1s 闪退」的根因。

核心机制：`inittls` 用 `pthread_key_create` 分配 key，`pthread_setspecific`
种入 magic 值，在 TP 附近 ±4KB 范围（带 SIGSEGV 防护）扫描找到 TSD 槽位偏移，
写入 `tls_g`；pthread 线程把**自己 malloc 的 g-slot 地址**存进该 key 的 TSD 槽位；
裸 clone 线程则由 `tlsBlockAlloc()` 分配独立 TLS 块（内核 CLONE_SETTLS 设 TP），
块内预置两级指针链。`load_g` 做两次解引用：`*(*(TP + tls_g)) = g`，NULL 槽位
安全降级为 g=nil（cgocallback 走 needm，同 glibc 语义）。

注意：`os_linux.go` 的 clone 声明是全 arch 共享的，改 6 参后其他 GOOS 不能再用
本树编译——本项目只用它编 openharmony/arm64。

### 验证产物

```bash
llvm-readelf -r libsyncthing.so | grep TLS   # 期望：空（无 TLS 重定位）
llvm-readelf -s libsyncthing.so | grep tls_g # 期望：OBJECT 普通变量（非 TLS）
# load_g 反汇编应为：MRS TPIDR_EL0; ADD x27,x27,x0; LDR x27,[x27]; LDR x28,[x27]
```

## 为什么不让 Go 起 HTTP GUI

syncthing 原生 Web GUI 需要监听本地端口。ArkTS 外壳直接用 `Internals` 的模型
方法聚合状态喂给 UI，更简单、更原生。这与 syncthing-android 的「Java 直接调
API」思路一致，只是跨语言边界从 JNI 变成 NAPI。
