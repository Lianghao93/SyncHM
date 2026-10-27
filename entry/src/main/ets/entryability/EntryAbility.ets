import { AbilityConstant, UIAbility, Want, abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { engine } from '../service/SyncEngine';

const DOMAIN: number = 0x0002;
const TAG: string = 'SyncHM';

// 鸿蒙 PC 预授权目录权限（文档/下载）。user_grant 型，必须运行时申请。
const DIR_PERMISSIONS: Array<Permissions> = [
  'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
];

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 提前加载 native 引擎，让首屏能拿到状态。加载失败会被引擎内部降级处理。
    engine.init();
    // 把应用沙箱的 filesDir 绝对路径交给引擎，供 syncthing 引擎创建数据目录。
    // 鸿蒙沙箱下 os.Getwd() 不可靠，必须用绝对路径。
    engine.setBaseDir(this.context.filesDir);
    hilog.info(DOMAIN, TAG, 'Ability onCreate, filesDir=%{public}s', this.context.filesDir);
    this.requestDirectoryPermissions();
  }

  // 申请文档/下载目录读写权限（PC 预授权目录）。被拒则同步目录只能用沙箱内路径。
  private requestDirectoryPermissions(): void {
    const atManager = abilityAccessCtrl.createAtManager();
    atManager.requestPermissionsFromUser(this.context, DIR_PERMISSIONS)
      .then((result) => {
        hilog.info(DOMAIN, TAG, 'dir perms authResults=%{public}s', JSON.stringify(result.authResults));
      })
      .catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'dir perms request failed: %{public}s', JSON.stringify(err));
      });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      try {
        const mainWindow = windowStage.getMainWindowSync();
        mainWindow.resize(1200, 800).catch((e: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'resize failed: %{public}d', e.code);
        });
        mainWindow.setWindowLimits({ minWidth: 720, minHeight: 480, maxWidth: 10000, maxHeight: 10000 })
          .catch((e: BusinessError) => {
            hilog.warn(DOMAIN, TAG, 'limits failed: %{public}d', e.code);
          });
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'window tune failed');
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
  }

  onBackground(): void {
  }
}
