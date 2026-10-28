/**
 * SyncHM 主界面。
 *
 * 四个标签页：设备 / 文件夹 / 状态 / 设置。首屏顶部显示引擎就绪状态和
 * 本机设备 ID，底部提供启动/停止控制。
 */
import { engine } from '../service/SyncEngine';
import { Device, Folder, EngineStatus } from '../model/Types';
import { webview } from '@kit.ArkWeb';
import { common, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent, { WantAgent } from '@ohos.wantAgent';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { PrivacyConsent } from '../service/PrivacyConsent';

const DOMAIN: number = 0x0002;
const TAG: string = 'SyncHM';

// 鸿蒙 PC 预授权目录权限（文档/下载）。与 EntryAbility 中保持一致。
const DIR_PERMISSIONS: Array<Permissions> = [
  'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
];

@Entry
@Component
struct Index {
  @State currentTab: number = 0;
  @State engineReady: boolean = false;
  @State loadError: string = '';
  @State running: boolean = false;
  @State showWeb: boolean = false;
  @State guiUrl: string = 'http://127.0.0.1:8384';
  // 隐私政策弹窗：默认展示，已同意过的用户在 aboutToAppear 中关闭。
  @State showPrivacy: boolean = true;
  @State policyText: string = '';
  @State status: EngineStatus = {
    running: false, version: '-', deviceID: '', uptimeSeconds: 0,
    connectedDevices: 0, totalDevices: 0, folderCount: 0, inSync: false
  };
  @State devices: Device[] = [];
  @State folders: Folder[] = [];
  private refreshTimer: number = -1;
  private bgTaskActive: boolean = false;

  private readonly tabs: string[] = ['设备', '文件夹', '状态', '设置'];

  aboutToAppear(): void {
    this.engineReady = engine.isReady();
    this.loadError = engine.getLoadError();
    this.refresh();
    // 每 3 秒刷新一次状态（syncthing 状态变化频繁）
    this.refreshTimer = setInterval(() => {
      this.refresh();
    }, 3000);
    this.loadPrivacyState();
  }

  /** 读取隐私同意状态与政策全文（rawfile）。 */
  private async loadPrivacyState(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    if (PrivacyConsent.isAgreed(ctx)) {
      this.showPrivacy = false;
    }
    try {
      const data = await ctx.resourceManager.getRawFileContent('privacy_policy.txt');
      const decoder = util.TextDecoder.create('utf-8');
      this.policyText = decoder.decodeToString(data);
    } catch (e) {
      // rawfile 缺失时的兜底摘要（正常构建不会走到）
      this.policyText =
        'SyncHM 不收集任何个人数据：无账号体系、无开发者服务器，文件仅在你的设备之间点对点同步。\n\n' +
        '为实现同步功能，应用将申请网络、文件夹读写、后台运行等系统权限，' +
        '并按你的配置与其他 Syncthing 设备直连通信。完整政策见应用内说明与上架页面。';
    }
  }

  /** 同意隐私政策：记录状态，并触发目录权限申请（权限必须在同意之后申请）。 */
  private onPrivacyAgree(): void {
    PrivacyConsent.setAgreed(getContext(this) as common.UIAbilityContext);
    this.showPrivacy = false;
    this.requestDirPermissions();
  }

  /** 拒绝隐私政策：应用无法使用，退出。 */
  private onPrivacyDisagree(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    ctx.terminateSelf();
  }

  private requestDirPermissions(): void {
    const atManager = abilityAccessCtrl.createAtManager();
    atManager.requestPermissionsFromUser(getContext(this) as common.UIAbilityContext, DIR_PERMISSIONS)
      .then((result) => {
        console.info(`dir perms authResults=${JSON.stringify(result.authResults)}`);
      })
      .catch((err: BusinessError) => {
        console.error(`dir perms request failed: ${JSON.stringify(err)}`);
      });
  }

  @Builder
  private privacyOverlay() {
    Column({ space: 12 }) {
      Text('隐私政策')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)

      Column() {
        Scroll() {
          Text(this.policyText)
            .fontSize(13)
            .fontColor('#374151')
            .lineHeight(20)
        }
        .scrollBar(BarState.Auto)
        .layoutWeight(1)
      }
      .layoutWeight(1)
      .width('100%')
      .padding(12)
      .borderRadius(8)
      .backgroundColor('#F5F6F8')

      Text('使用 SyncHM 前请阅读并同意以上政策。我们不会收集你的任何个人数据，文件仅在 你自己的设备之间同步。')
        .fontSize(12)
        .fontColor('#6B7280')
        .width('100%')

      Row({ space: 12 }) {
        Button('不同意')
          .layoutWeight(1)
          .backgroundColor('#E5E7EB')
          .fontColor('#374151')
          .onClick(() => { this.onPrivacyDisagree(); })
        Button('同意并继续')
          .layoutWeight(2)
          .backgroundColor('#2E8B57')
          .fontColor('#FFFFFF')
          .onClick(() => { this.onPrivacyAgree(); })
      }
      .width('100%')
    }
    .width('86%')
    .height('70%')
    .padding(20)
    .borderRadius(12)
    .backgroundColor('#FFFFFF')
    .alignItems(HorizontalAlign.Center)
  }

  aboutToDisappear(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
    }
  }

  private refresh(): void {
    this.status = engine.getStatus();
    this.running = this.status.running;
    this.devices = engine.getDevices();
    this.folders = engine.getFolders();
  }

  private onStart(): void {
    // 数据目录放在应用沙箱 filesDir 下
    const cfg = JSON.stringify({ home: 'syncthing' });
    const r = engine.start(cfg);
    if (!r.ok) {
      this.loadError = r.error ?? 'start failed';
    } else {
      // 引擎跑起来了 → 申请长时任务，关闭窗口后引擎继续后台同步。
      this.startBgTask();
    }
    this.refresh();
  }

  private onStop(): void {
    engine.stop();
    this.stopBgTask();
    this.refresh();
  }

  /**
   * 申请长时任务（TASK_KEEPING，仅 PC/2in1 支持，无需进度上报）。
   * 配合 EntryAbility.onPrepareToTerminate 的关窗拦截实现后台驻留。
   */
  private async startBgTask(): Promise<void> {
    if (this.bgTaskActive) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const wa: WantAgent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: 'com.synchm.client',
          abilityName: 'EntryAbility'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      });
      await backgroundTaskManager.startBackgroundRunning(
        ctx, backgroundTaskManager.BackgroundMode.TASK_KEEPING, wa);
      this.bgTaskActive = true;
      hilog.info(DOMAIN, TAG, 'continuous task started (taskKeeping)');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'startBackgroundRunning failed: %{public}d %{public}s', err.code, err.message);
    }
  }

  private async stopBgTask(): Promise<void> {
    if (!this.bgTaskActive) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      this.bgTaskActive = false;
      hilog.info(DOMAIN, TAG, 'continuous task stopped');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'stopBackgroundRunning failed: %{public}s', (e as BusinessError).message);
    }
  }

  private onOpenWeb(): void {
    this.guiUrl = engine.getGuiUrl();
    this.showWeb = true;
  }

  @Builder
  private header() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Text('SyncHM')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#2E8B57')
        Blank()
        Text(this.engineReady ? (this.running ? '同步中' : '已就绪') : '引擎未就绪')
          .fontSize(13)
          .fontColor(this.engineReady ? '#2E8B57' : '#D9534F')
      }
      .width('100%')

      if (!this.engineReady) {
        Text(this.loadError !== '' ? this.loadError : '未找到原生引擎（libsyncthingbridge.so）')
          .fontSize(12)
          .fontColor('#D9534F')
          .width('100%')
      }

      if (this.status.deviceID !== '') {
        Column({ space: 4 }) {
          Text('本机设备 ID')
            .fontSize(11)
            .fontColor('#6B7280')
          Text(this.status.deviceID)
            .fontSize(11)
            .fontFamily('monospace')
            .fontColor('#1A1A1A')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#F5F6F8')
  }

  @Builder
  private deviceTab() {
    Column({ space: 12 }) {
      if (this.devices.length === 0) {
        Text('暂无设备。启动引擎后添加远程设备以开始同步。')
          .fontSize(13)
          .fontColor('#6B7280')
      }
      ForEach(this.devices, (d: Device) => {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text(d.name !== '' ? d.name : d.deviceID.slice(0, 7))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
            Text(d.deviceID)
              .fontSize(10)
              .fontFamily('monospace')
              .fontColor('#6B7280')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text(d.connected ? '在线' : '离线')
            .fontSize(12)
            .fontColor(d.connected ? '#2E8B57' : '#9CA3AF')
        }
        .width('100%')
        .padding(12)
        .borderRadius(8)
        .backgroundColor('#FFFFFF')
      }, (d: Device) => d.deviceID)
    }
    .width('100%')
    .padding(16)
  }

  @Builder
  private folderTab() {
    Column({ space: 12 }) {
      if (this.folders.length === 0) {
        Text('暂无同步文件夹。')
          .fontSize(13)
          .fontColor('#6B7280')
      }
      ForEach(this.folders, (f: Folder) => {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text(f.label !== '' ? f.label : f.id)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
            Text(f.path)
              .fontSize(11)
              .fontColor('#6B7280')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text(f.syncState)
            .fontSize(12)
            .fontColor(f.syncState === 'syncing' ? '#2E8B57' : '#6B7280')
        }
        .width('100%')
        .padding(12)
        .borderRadius(8)
        .backgroundColor('#FFFFFF')
      }, (f: Folder) => f.id)
    }
    .width('100%')
    .padding(16)
  }

  @Builder
  private statusTab() {
    Column({ space: 14 }) {
      Text(`引擎版本：${this.status.version}`).fontSize(14)
      Text(`运行时长：${this.status.uptimeSeconds}s`).fontSize(14)
      Text(`已连接设备：${this.status.connectedDevices}/${this.status.totalDevices}`).fontSize(14)
      Text(`同步文件夹：${this.status.folderCount}`).fontSize(14)
      Text(`全局同步状态：${this.status.inSync ? '已同步' : '同步中/待同步'}`).fontSize(14)
      Button(this.running ? '停止同步' : '启动同步')
        .onClick(() => { this.running ? this.onStop() : this.onStart(); })
        .backgroundColor('#2E8B57')
        .fontColor('#FFFFFF')
        .margin({ top: 8 })
      Button('打开 WebUI 管理界面')
        .onClick(() => { this.onOpenWeb(); })
        .backgroundColor('#1E6BB8')
        .fontColor('#FFFFFF')
        .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
  }

  @Builder
  private settingsTab() {
    Column({ space: 14 }) {
      Text('SyncHM 设置').fontSize(16).fontWeight(FontWeight.Bold)
      Text('文件夹、设备等高级设置请在 WebUI 中完成。')
        .fontSize(13)
        .fontColor('#6B7280')
      Button('打开 WebUI 管理界面')
        .backgroundColor('#2E8B57')
        .fontColor('#FFFFFF')
        .onClick(() => { this.onOpenWeb(); })
      Text('数据目录：应用沙箱 filesDir/syncthing')
        .fontSize(12)
        .fontColor('#6B7280')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
  }

  build() {
    Stack() {
      if (this.showWeb) {
        Column() {
          Row({ space: 8 }) {
            Button('返回')
              .onClick(() => { this.showWeb = false; })
              .fontColor('#FFFFFF')
              .backgroundColor('#2E8B57')
            Text('WebUI 管理界面').fontSize(15).fontWeight(FontWeight.Medium)
            Blank()
            Text(this.guiUrl).fontSize(12).fontColor('#6B7280')
          }
          .width('100%')
          .padding(10)
          .backgroundColor('#F5F6F8')

          Web({ src: this.guiUrl, controller: new webview.WebviewController() })
            .width('100%')
            .layoutWeight(1)
            .domStorageAccess(true)
            .javaScriptAccess(true)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#FFFFFF')
      } else {
        Column() {
          this.header()
          Tabs({ barPosition: BarPosition.Start, index: this.currentTab }) {
            TabContent() { this.deviceTab() }.tabBar(this.tabs[0])
            TabContent() { this.folderTab() }.tabBar(this.tabs[1])
            TabContent() { this.statusTab() }.tabBar(this.tabs[2])
            TabContent() { this.settingsTab() }.tabBar(this.tabs[3])
          }
          .onChange((index: number) => { this.currentTab = index; })
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#FFFFFF')
      }

      // 首次启动隐私政策弹窗：遮挡全部内容，同意后才能使用应用。
      if (this.showPrivacy) {
        Column() {
          this.privacyOverlay()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.45)')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
  }
}
