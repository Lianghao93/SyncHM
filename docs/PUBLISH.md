# SyncHM 发布到华为应用市场（AppGallery）操作手册

依据官方现行流程（DevEco Studio 26.0.0+ 简化签名流程，原
`ide-publish-app` 指南已迁移至 developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-publish-app）。

## 0. 当前状态

| 项 | 状态 |
| --- | --- |
| Release APP 包 | ✅ `dist/SyncHM-1.01-release.app`（`bash scripts/build-app.sh` 产出） |
| 签名 | ✅ 无需本地证书：DevEco 26+ 上传时由 AGC 云端自动重签（云管理证书） |
| 首启隐私政策弹窗 | ✅ 已实现（同意前不申请权限、不展示主界面） |
| 目录权限申请时序 | ✅ 已改为同意隐私政策之后触发 |
| 上架材料 | ✅ `docs/STORE_LISTING.md`（逐字段素材） |
| 开发者账号 | ❌ **待用户完成**（注册 + 实名认证） |
| AGC 建应用 | ❌ 待账号就绪后创建（包名 `com.synchm.client`） |
| APP 备案 | ❌ **关键路径**，见 §3 |
| 真机验证 | ✅ 已真机验证（用户确认：隐私弹窗/引擎/图标均正常，2026-10-28） |
| 设备范围 | ✅ 已收窄为仅 2in1（pack.info 核验通过） |

## 1. 流程总览

```
注册账号+实名 ──► AGC 创建应用 ──► APP 备案（大陆分发）──► 构建/上传 .app
                                                            │
        上架生效 ◄── 审核通过 ◄── 提交审核 ◄── 填写发布信息 ◄─┘
        （1–3 工作日，多数 24h 内）
```

## 2. 分步操作

### Step 1 开发者账号（仅用户可做）
1. 注册华为开发者账号：developer.huawei.com（用华为手机号/邮箱）。
2. 实名认证：AGC → 账号中心 → 认证。个人开发者选"个人"，需身份证 + 人脸核验；
   企业账号需营业执照 + 对公打款验证。**个人账号即可上架工具类应用**。
3. 实名通过后 AGC 才能创建应用、申请备案。

### Step 2 AGC 创建应用（⚠️ 包名创建后不可改）
1. 登录 AppGallery Connect（developer.huawei.com/consumer/cn/service/josp/agc/index.html）。
2. APP与元服务 → HarmonyOS → **新建发布**。
3. 填写：应用名称 `SyncHM`（系统校验唯一性，重名会被阻止）；软件包名
   `com.synchm.client`（必须与 AppScope/app.json5 完全一致）；类型=应用；
   分类=应用/工具；默认语言=简体中文。
4. 决策点：名称 "SyncHM" 若被占用，需换名称并同步改 app.json5 的 label 后重新构建。

### Step 3 APP 备案（关键路径，大陆分发必须）
SyncHM 存在真实网络通信（P2P 直连、可选全球发现/中继），**不能勾选"单机 APP"豁免**
（虚假勾选审核会被识别并驳回）。

**备案分两段（2026-10-28 实测确认）：**

1. **备案申请不在 AGC 发起**——去你云服务商的备案系统提交（服务器/主机在哪家：
   华为云 / 阿里云 / 腾讯云等），由接入商初审后报工信部，审核通过拿到**备案号**。
   个人主体需：身份信息 + 已 ICP 备案的域名；整体 1–2 周。
2. **AGC 只是"录入 + 校验"备案结果**：应用管理 → SyncHM → 左侧"分发 > 应用上架 >
   **版本信息 → 准备提交**"页面里的 **"备案信息"区域**：
   - 三选一：APP服务器在中国大陆（需备案）/ 不在中国大陆（免备案）/ 单机APP（免备案）；
   - 填主办单位类型（个人）、主体证件号，点"**校验证件号**"（每天有验证次数上限）；
   - **应用名称、包名必须与备案信息逐字一致**（SyncHM / com.synchm.client）。

**注意**：该"备案信息"区域在**发布版本尚未选择软件包时不显示**——先到
"软件包管理"上传 .app 并在"准备提交"页选定发布版本后，区域才会出现。
（官方 FAQ：若申请过 APP 备案白名单入口也会隐藏，本应用无此情况。）

**SyncHM 的现实选择**：
- A（发中国大陆）：个人主体 + 已备案域名，走云服务商完成 App 备案 → AGC 录入校验。
  P2P 无自有服务器，备案表单的"服务器信息"按 AGC/接入商引导填写，拿不准走工单确认。
- B（暂不备案）：准备提交页备案信息勾"您的APP服务器不在中国大陆"，发布区域**排除
  中国大陆**——国行 MateBook Pro 用户暂时搜不到，备案完成后再次发版补上大陆区域。

时效提醒：备案通过后**再等 1 个工作日**再提审（数据同步延迟会导致校验失败）。

### Step 4 构建上传包（本仓库已就绪，须本地签名）
```bash
bash scripts/build-app.sh        # assembleApp + hap-sign-tool 签名 → dist/SyncHM-<版本>-release.app
```
- **AGC 网页上传必须签名包，未签名报错 991**（"上传时云签"仅适用于 DevEco Studio
  的 Build > Upload Product 直传）。
- DevEco 26 的 build-profile 密码字段要求 IDE 加密串，纯命令行写明文会在
  SignHap 阶段报"密码长度不足 32"——因此签名放在构建后用 hap-sign-tool 完成：
  `sign-app -appCertFile ... -profileFile ... -keystoreFile ...`（注意子命令是
  sign-app 不是 sign-hap，密码参数是 -keystorePwd/-keyPwd）。
- 签名三件套在 `signing/`（**私钥 .p12 丢失无法补发，务必备份**）：
  - 密钥库 `synchm_release.p12`，别名 `synchm_release`，密码 `Synchm#2026Release`
  - 发布证书 `synchm_release.cer`（AGC 用户与访问 → 证书，有效期至 2029-10-28）
  - 发布 Profile `synchm_release_profileRelease.p7b`（绑定 com.synchm.client）
- 版本要求：AppScope/app.json5 中 versionCode **严格递增**（当前 1.03/1000103），
  同版本Code重传需先在软件包管理删除旧包。

### Step 4.5 受限 ACL 权限（包与 Profile 必须一致，否则检测不通过）
SyncHM 使用 `READ_WRITE_DOCUMENTS_DIRECTORY` / `READ_WRITE_DOWNLOAD_DIRECTORY`
（PC 预授权目录，属受限开放权限），必须在 AGC 走两步：
1. **应用管理 → SyncHM → 基础信息 → "ACL权限" tab**：勾"我已知晓"→ 搜索权限名 →
   勾选（点权限名称文字可勾选）→ 申请 → 每个权限填 ≤256 字申请理由
   （关键词：原生引擎按文件系统路径后台读写，Picker 单次 URI 授权覆盖不了）→ 提交。
   实测**即时通过**，ACL 状态列显示"已通过"。
2. **重建发布 Profile** 并勾选"申请权限：受限ACL权限"（"已获取权限将会全部写入
   Profile"）→ 下载新 .p7b → 用它重新签名打包。
- 验证方法：p7b 是 PKCS7，内嵌明文 JSON，可用 Python 提取检查
  `acls.allowed-acls` 是否包含两条权限（为空则必定卡在"ACL权限声明一致性"检测项）。
- 检测项"ACL权限声明一致性"会逐个比对**软件包内权限** vs **Profile 内 acls**；
  缺一条都算不通过（得分 55/100，其余 4 项全通过）。

### Step 5 上传软件包
方式 A（推荐，AGC 网页）：我的项目 → 选择应用 → 版本管理（软件包管理）→
上传软件包 → 选择 dist/ 下的 .app。
方式 B（IDE 直传）：DevEco Studio → Build → Upload Product（需登录开发者账号）。

上传后自动执行**合法性检测**（必选）；建议点击"操作 → 启动自检"跑一遍云测试
（兼容性/稳定性/性能/隐私自动检测），报告问题先修再提审。

### Step 6 填写发布信息
逐项对照 `docs/STORE_LISTING.md`：应用基础信息、发布区域（与备案范围一致！）、
资费（免费）、隐私相关信息、开源组件声明（Syncthing MPL-2.0）、资质材料
（工具类一般无需行业资质）、备案信息、联系信息、上架时间（可选定时上架）。

### Step 7 提交审核
确认版本号无误 → 提交审核。1–3 个工作日，多数 24 小时内完成。
驳回后按驳回原因修改，**versionCode +1 重新构建上传**，可对紧急情况申请审核加急。

### Step 8 上架后可见性自查
搜不到时依次检查：设备系统版本（HarmonyOS 5+）、设备 API 版本是否在适配范围
（本包 compatibleSdkVersion 6.0.0(20)）、设备类型是否在发布范围、是否定时上架。

## 3. 高频驳回项 → SyncHM 对策

| 官方高频驳回 | SyncHM 现状/对策 |
| --- | --- |
| 首启无隐私政策弹窗 / 权限在同意前申请 | ✅ 已修复（Index.ets 弹窗 + EntryAbility 门控），提审前真机确认一次 |
| APP 备案校验失败 | 名称/包名与备案信息必须逐字一致；备案后隔 1 个工作日再提审 |
| 单机 APP 判定不符 | ❌ 不可勾选（有网络功能），走正式备案 |
| 图标不一致 / 默认图标 | 提交图标、桌面图标、最近任务图标需一致（layered_image）；提审前真机核对 |
| 权限过多 | 8 个权限均有 reason 与场景声明，与隐私政策文本一致；审核问询按 STORE_LISTING §8 答复 |
| 应用名称相似/侵权 | "SyncHM" 与 "Syncthing" 有区分度；如被质询权属，说明为 MPL-2.0 开源引擎的移植实现并附仓库链接 |
| 截图与实际不符 | 截图必须真机截取（STORE_LISTING §5 清单） |
| 设备类型声明过宽 | ✅ 已收窄为仅 2in1，AGC 审核范围最小化 |

## 4. 本次合规改造的仓库变更

| 文件 | 变更 |
| --- | --- |
| `entry/src/main/ets/service/PrivacyConsent.ets` | 新增：隐私同意状态持久化（preferences，键 privacy_agreed_v1） |
| `entry/src/main/resources/rawfile/privacy_policy.txt` | 新增：隐私政策全文（弹窗展示 + 托管源文本，邮箱占位待填） |
| `entry/src/main/ets/pages/Index.ets` | 新增首启隐私政策弹窗（不同意即退出）；同意后触发目录权限申请 |
| `entry/src/main/ets/entryability/EntryAbility.ets` | onCreate 的目录权限申请改为仅"已同意"时触发 |
| `scripts/build-app.sh` | 新增：工程级 `assembleApp` release 构建，产出 dist/*.app |
| `docs/STORE_LISTING.md` | 新增：AGC 填报素材清单 |
| `docs/PUBLISH.md` | 本文档 |

## 5. 遗留风险

1. **备案域名**：个人主体 APP 备案需要已备案域名，若无需提前办理（1–2 周，关键路径）。
2. **发现/中继服务的合规表述**：隐私政策已如实披露 Syncthing 公共发现服务与中继；
   若审核对境外公共基础设施通信有问询，答复口径：用户可选关闭全球发现与中继，
   关闭后仅局域网直连。
