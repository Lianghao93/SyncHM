# 为什么 syncthing 不能「直接」跑在鸿蒙上

结论先给：**不能把 syncthing 的独立 ELF 可执行文件直接塞进 HAP 运行**，但**能**把它的
Go 核心作为库编进去。这两者差别是本质性的，本仓库选后者。

## 1. 鸿蒙应用沙箱禁止 exec 独立 ELF 二进制

syncthing 官方的 Linux 发行形态是一个 Go 编译的独立可执行文件 `syncthing`，
启动后监听 `127.0.0.1:8384` 提供 Web GUI。

鸿蒙应用运行在受限沙箱里，**没有能力 fork/exec 一个任意 Linux ELF 可执行文件**。
HAP 里能加载的原生代码只有两种：

- 通过 NAPI 注册的 `.so` 动态库（由系统 dlopen，进应用进程地址空间）；
- 系统组件（如 ArkWeb 内核），应用无权替换。

所以「把 syncthing 二进制放进去跑」这条路，在普通第三方应用身份下走不通。
需要系统签名 / root 才能 exec 任意二进制，等同放弃了侧载分发。

## 2. 但 Go 核心可以编成库，这是 syncthing-android 验证过的路

syncthing 的代码结构是「库 + 薄 main」：

```
syncthing/
├── cmd/syncthing/     ← 只有几十行的 main，负责读配置、起 HTTP GUI
└── lib/               ← 真正的引擎：model、config、protocol、api、...
    ├── model/         同步模型（扫描、哈希、传输协调）
    ├── config/        配置读写
    ├── protocol/      BEP 协议（设备间通信）
    └── api/           REST API（Web GUI 背后就是它）
```

syncthing-android（官方 Android 客户端，已归档但思路仍在）**从不运行独立二进制**，
而是把 `lib/` 编成 `libsyncthing.so`，用 JNI 拉起一个 Go goroutine 跑同步核心，
Java 层通过本地 socket 连它的 REST API。这正是本仓库做的事，只是 JNI 换成 NAPI。

## 3. 鸿蒙特有的坑：musl 与 Go runtime 的 TLS 模型

鸿蒙的 libc 是 **musl**（不是 glibc）。Go 在 `linux/arm64` 上默认按 glibc 的
TLS（线程本地存储）模型编译。musl 用的是 emulated TLS，寻址方式不同，导致
`-buildmode=c-shared` 的 Go 库在 dlopen 时，`.init_array` 里的 runtime 初始化
（`_rt0_arm64_linux_lib`）可能直接段错误。

这不是本仓库独有的问题，社区已有完整实践：

- Go 1.22+ 对 musl 的兼容性已明显改善；
- 极端情况下需要对 Go runtime 源码打少量 patch（clone 系统调用、TLS 寻址重写）。

所以本方案把「Go 版本 >= 1.22」列为硬性前提，并在 `build-golang.sh` 里用鸿蒙
SDK 自带的 `aarch64-unknown-linux-ohos-clang` + sysroot 做 CGO 交叉编译。

## 4. 为什么不选「融合开发引擎跑 Linux 版 syncthing」

鸿蒙电脑有一种「融合开发引擎」能跑 Linux GUI 应用（类似容器），理论上能在里面
跑原生 syncthing。但：

- 性能差、包体积大，且依赖系统是否预置该引擎；
- 不产出标准的 HAP，分发和签名链不同；
- 无法用 ArkUI 做原生交互。

对「要一个标准 HAP、能上架/侧载」的目标，这条是死路。

---

## 那能做什么

| 方案 | 引擎形态 | 是否真 syncthing | 可行性 |
| --- | --- | --- | --- |
| **本仓库：NAPI + Go c-shared 库** | libsyncthing.so | 是（lib/ 核心） | ✅ 目标路径，需 Go 工具链 + musl TLS 验证 |
| 独立 ELF 二进制 + exec | 可执行文件 | 是 | ❌ 沙箱禁止 exec |
| 融合开发引擎跑 Linux 版 | 容器内 ELF | 是 | ⚠️ 非标准 HAP，依赖系统引擎 |
| 远程控制已有实例 | 无本地引擎 | 否（代理） | ✅ 但不算「本机同步」 |

真正的阻塞点只有一个：**Go 工具链 + 鸿蒙 musl TLS 的兼容性验证**。工程骨架、NAPI
桥、Go export 封装都已就绪，装上 Go 即可进入编译验证阶段。
