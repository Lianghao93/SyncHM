# 安装与构建手册

## 环境依赖

| 依赖 | 版本 | 本机状态 | 用途 |
| --- | --- | --- | --- |
| DevEco Studio | 26.0（SDK API 26） | ✅ 已装 | ArkTS 编译、hvigor 打包 |
| Node | >= 18 | ✅ v22 | hvigor 运行时 |
| JDK (jbr) | DevEco 自带 | ✅ | hvigor |
| Go | >= 1.22 | ✅ **已装 1.27** | 交叉编译 syncthing 核心 |

## 第一步：交叉编译 Go 核心

```bash
bash scripts/build-golang.sh
```

产出：
- `entry/libs/arm64-v8a/libsyncthing.so`（~43MB，完整 syncthing 引擎）
- `entry/libs/arm64-v8a/libsyncthing.h`（cgo 生成）

> 脚本会自动建 `C:/ohos-llvm`、`C:/ohos-sysroot` 两个无空格 junction 指向鸿蒙
> SDK 的 clang/sysroot（cgo 无法处理含空格路径）。若报错找不到 clang，设置
> `DEVECO_HOME` 指向 DevEco Studio 安装目录。

## 第二步：构建 HAP

```bash
bash scripts/build.sh          # debug
bash scripts/build.sh release  # release
```

产物：`dist/SyncHM-1.0.0-unsigned.hap`（~23.5MB，含 libsyncthing.so）

> **路径必须是纯 ASCII**。hvigor 拒绝含中文字符的路径，脚本会自动把源码镜像到
> `E:/synchm-build` 再编译，产物回拷到 `dist/`。

## 第三步：签名与安装

鸿蒙电脑**不支持免签名侧载**，必须用华为开发者账号签名：

1. 在 DevEco Studio 里配置自动签名（File → Project Structure → Signing Configs）；
2. 在 AGC 注册你 MateBook Pro 的 UDID（调试证书绑定设备，上限 100 台）；
3. `hdc install` 或 DevEco 直接运行。

## 故障排查

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| 加载库即闪退 / 段错误 | Go runtime 与鸿蒙 musl TLS 不兼容 | 升级 Go 到最新，或按 docs/WHY-NOT.md 打 runtime patch |
| `loadLibrary failed` | libsyncthing.so 未编译/未打包 | 先跑 build-golang.sh |
| hvigor 报 `Specification Limit Violation` | 工程路径含中文 | 用 scripts/build.sh 自动镜像到 ASCII 路径 |
| 后台同步被系统杀掉 | 缺长时任务授权 | 申请 KEEP_BACKGROUND_RUNNING 并实现长时任务 |
| 交叉编译报 `undefined: auto.Assets` | 忘了 noassets tag | build-golang.sh 已加 `-tags noassets`，勿手改 |
