/**
 * SyncHM 主界面。
 *
 * 四个标签页：设备 / 文件夹 / 状态 / 设置。首屏顶部显示引擎就绪状态和
 * 本机设备 ID，底部提供启动/停止控制。
 */
import { engine } from '../service/SyncEngine';
import { Device, Folder, EngineStatus } from '../model/Types';
import { webview } from '@kit.ArkWeb';

@Entry
@Component
struct Index {
  @State currentTab: number = 0;
  @State engineReady: boolean = false;
  @State loadError: string = '';
  @State running: boolean = false;
  @State showWeb: boolean = false;
  @State guiUrl: string = 'http://127.0.0.1:8384';
  @State status: EngineStatus = {
    running: false, version: '-', deviceID: '', uptimeSeconds: 0,
    connectedDevices: 0, totalDevices: 0, folderCount: 0, inSync: false
  };
  @State devices: Device[] = [];
  @State folders: Folder[] = [];
  private refreshTimer: number = -1;

  private readonly tabs: string[] = ['设备', '文件夹', '状态', '设置'];

  aboutToAppear(): void {
    this.engineReady = engine.isReady();
    this.loadError = engine.getLoadError();
    this.refresh();
    // 每 3 秒刷新一次状态（syncthing 状态变化频繁）
    this.refreshTimer = setInterval(() => {
      this.refresh();
    }, 3000);
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
    }
    this.refresh();
  }

  private onStop(): void {
    engine.stop();
    this.refresh();
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
  }
}
