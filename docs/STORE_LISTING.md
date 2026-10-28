# SyncHM 商店上架材料（AGC 填写清单）

本文档是 AppGallery Connect（AGC）"填写发布信息"环节的逐字段素材。
占位符 `<...>` 处发布前需用户补齐。

## 1. 基本信息

| AGC 字段 | 填写内容 |
| --- | --- |
| 应用名称 | SyncHM |
| 软件包名 | `com.synchm.client`（与 AppScope/app.json5 一致，**创建后不可修改**） |
| 应用类型 | 应用（非游戏、非元服务） |
| 分类 | 应用 → 工具 → 文件管理（备选：系统 → 文件管理） |
| 默认语言 | 简体中文 |
| 版本号 | 1.01（versionName）/ versionCode 1000101 |
| 上架设备 | 仅 2in1（鸿蒙 PC，包内 deviceType 已收窄为 ["2in1"]，AGC 只要求 2in1 截图） |

## 2. 一句话简介（简介栏，≤50 字）

> 基于 Syncthing 引擎的去中心化文件同步工具，设备间点对点直连，无中转服务器。

## 3. 详细介绍

```
SyncHM 是一款鸿蒙原生的去中心化文件同步应用，同步引擎来自开源项目
Syncthing（MPL-2.0），以原生库形式运行，不是网页套壳或远程控制端。

【点对点直连】同一局域网内设备直接通过 TCP/QUIC 传输，速度只受网络带宽限制；
配合 NAT 穿透与中继，外网设备间也能建立连接。

【没有中心服务器】文件不经过任何第三方云端，数据只存在于你自己的设备之间，
全程 TLS 1.3 加密，设备之间通过设备 ID 互相认证。

【与 Syncthing 生态互通】与官方 Syncthing（Windows / macOS / Linux /
Android）完全兼容，互相添加设备 ID 即可组网。

【原生性能】哈希、压缩、增量索引全部在本机原生执行；变更事件驱动、
只传输差异部分，支持断点续传与冲突文件自动保留。

【管理界面】内置 Syncthing 完整 WebUI（应用内打开或浏览器访问
127.0.0.1:8384），可配置文件夹、设备、版本控制与忽略规则。

适用：多设备间自动同步照片库、工程目录、文档、模型文件；不信任公有云盘、
或需要在局域网内高速搬运大文件的用户。

开源许可：同步引擎 Syncthing 采用 MPL-2.0 许可证。
```

## 4. 版本说明（首次发布）

```
首个公开版本：
- 基于 Syncthing 引擎的鸿蒙原生文件同步（2in1 / PC 适配）
- 设备与文件夹管理、实时同步状态展示
- 内置 WebUI 管理界面
```

## 5. 截图（2in1 设备 3–5 张）

建议清单（真机截取，分辨率 ≥1280×720，建议 1920×1080）：

1. 设备页：显示本机设备 ID + 远程设备在线状态
2. 文件夹页：已添加同步文件夹列表与同步状态
3. 状态页：引擎版本、传输状态、"启动同步"按钮
4. WebUI 管理界面：文件夹配置视图
5. 首次启动隐私政策弹窗（可选，体现合规）

注意：截图必须来自应用真实运行画面，不得与安装后实际界面不一致（审核项）。

## 6. 隐私与合规

| AGC 字段 | 填写内容 |
| --- | --- |
| 隐私政策 URL | `<托管后隐私政策页面链接>`（文本源：`entry/src/main/resources/rawfile/privacy_policy.txt`，转 HTML 后托管到可公开访问的 URL，如 Gitee Pages / 备案域名站点；**审核时会真实打开该链接**，境内需可直连） |
| 是否收集用户信息 | 否（政策已声明不收集；权限用途与政策文本需一致） |
| 开源组件声明 | Syncthing（MPL-2.0）；Go 运行时 |
| 权限用途 | 与 module.json5 中 reason 字段一致，见 §8 |
| 测试账号 | 不需要（应用无账号体系；发布信息中注明"应用无需登录即可使用全部功能"） |

## 7. 决策点（发布前必须确认）

1. **设备范围**：✅ 已定——首发仅 2in1（module.json5 deviceTypes 已收窄为
   `["2in1"]`，APP 包已按此重新构建并经 pack.info 核验）。日后扩展平板/手机
   再改回并重新构建上传（versionCode 递增）。
2. **APP 备案**：SyncHM 有网络通信（P2P 直连 + 可选全球发现/中继），**不符合
   "单机 APP" 豁免条件**。发中国大陆区域必须先完成 APP 备案（流程见
   PUBLISH.md §3）；若暂时不备案，只能发布非中国大陆区域。
3. **联系邮箱**：privacy_policy.txt 末尾与 AGC 联系信息需填真实邮箱。

## 8. 权限清单（与 module.json5 一致，审核说明可复用）

| 权限 | 用途 |
| --- | --- |
| ohos.permission.INTERNET | 与其他同步设备建立网络连接 |
| ohos.permission.GET_NETWORK_INFO | 获取网络状态以选择连接方式 |
| ohos.permission.READ_MEDIA | 读取所选同步文件夹内容 |
| ohos.permission.WRITE_MEDIA | 写入同步文件到目标文件夹 |
| ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY | 文档目录作为同步文件夹 |
| ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY | 下载目录作为同步文件夹 |
| ohos.permission.KEEP_BACKGROUND_RUNNING | 窗口最小化时保持同步引擎运行 |
| ohos.permission.DISTRIBUTED_DATASYNC | 鸿蒙生态设备间组网发现与协同 |
