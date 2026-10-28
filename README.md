# SyncHM

鸿蒙电脑（HarmonyOS 6 / 7，`deviceTypes: 2in1`）上的 **Syncthing 同步客户端**，
面向 MateBook Pro（arm64）。

**它是 syncthing 的鸿蒙移植，不是网页版或远程控制端。** 同步引擎 = syncthing 的
Go 核心，交叉编译成 `libsyncthing.so`，通过鸿蒙 NAPI 桥接给 ArkTS 外壳调用。
这与 syncthing-android 复用核心的做法完全一致，差别只在桥接层从 JNI 换成 NAPI。

## 架构

```
┌─────────────────────────────────────────────┐
│  ArkTS 外壳 (ArkUI)                          │
│  pages/Index.ets      设备/文件夹/状态/设置    │
│  service/SyncEngine.ets  引擎桥接单例          │
└───────────────┬─────────────────────────────┘
                │ loadLibrary("syncthingbridge")
┌───────────────▼─────────────────────────────┐
│  C++ NAPI 桥 (libsyncthingbridge.so)          │
│  entry/src/main/cpp/napi_init.cpp             │
│  把 Go 导出的 C 函数包装成 ArkTS 方法          │
└───────────────┬─────────────────────────────┘
                │ 动态链接
┌───────────────▼─────────────────────────────┐
│  Go 核心 (libsyncthing.so, c-shared)          │
│  golang/libsyncthing.go  //export 导出        │
│  = syncthing 的 lib/model、lib/config 等      │
└─────────────────────────────────────────────┘
```

## 目录

```
AppScope/                       应用级配置与图标
entry/src/main/
├── ets/
│   ├── entryability/EntryAbility.ets   窗口与生命周期
│   ├── model/Types.ets                 数据模型
│   ├── service/SyncEngine.ets          引擎桥接单例
│   └── pages/Index.ets                 主界面
├── cpp/
│   ├── CMakeLists.txt                  NAPI 模块构建
│   ├── napi_init.cpp                   C++ NAPI 桥
│   └── types/libsyncthingbridge/       native 模块类型声明（.d.ts + oh-package.json5）
└── libs/arm64-v8a/                     libsyncthing.so 打包位置（模块级）
golang/
├── libsyncthing.go                     Go 核心封装（//export）
└── go.mod
scripts/
├── build-golang.sh                     交叉编译 Go 核心（需 OpenHarmony Go fork）
└── build.sh                            构建 HAP
scripts/build-app.sh                    构建上架用 Release APP 包（.app）
docs/                                   技术论证与安装手册（PUBLISH.md=上架手册，STORE_LISTING.md=填报素材）
dist/                                   HAP 与 APP 产物
```

## 构建

```bash
# 1. 交叉编译 syncthing 核心（需 OpenHarmony-SIG Go fork，见 docs/IMPLEMENTATION.md）
export OHOS_GO=/c/ohos-go-toolchain/go-src/bin   # fork 工具链 bin 目录
bash scripts/build-golang.sh

# 2. 构建 HAP（真实引擎模式）
bash scripts/build.sh          # debug
bash scripts/build.sh release  # release
```

产物：`dist/SyncHM-1.0.1-unsigned.hap`

详见 [docs/INSTALL.md](docs/INSTALL.md) 与 [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md)。

## 关键风险

1. ~~**鸿蒙 musl TLS 兼容**~~：✅ 已解决。鸿蒙 libc 是 musl（两级间接 TLS），
   标准 Go 的一级间接 TLS 在多线程时 `tls_g` 读错导致 SIGSEGV 闪退；已改
   `TLSG_IS_VARIABLE` + 两级间接 load_g/save_g + `inittls` 探测 TSD 槽位。
   详见 [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md) 的「关键坑」章节。
2. **后台保活**：鸿蒙对后台应用有严格限制，同步引擎要保持常驻需申请
   `KEEP_BACKGROUND_RUNNING` 权限（长时任务），MVP 未做完整处理。
3. **文件访问范围**：应用沙箱限制可同步的目录。MVP 先同步应用沙箱内数据，
   要同步外部目录需用户授权（picker 授权持久化）。

## 许可

应用外壳与桥接层 MPL-2.0（与 syncthing 一致）。syncthing 核心版权归 Syncthing
项目所有，作为 Go module 依赖引入。
