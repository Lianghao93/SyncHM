/**
 * PrivacyConsent —— 隐私政策同意状态管理。
 *
 * 华为应用市场审核要求：首次启动必须先展示隐私政策，用户同意后才能
 * 申请权限 / 联网采集数据。同意状态持久化在应用沙箱 preferences 中，
 * 键名带版本号（privacy_agreed_v1），未来隐私政策大版本更新时换键即可
 * 重新弹窗。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME: string = 'synchm_prefs';
const KEY_AGREED: string = 'privacy_agreed_v1';

export class PrivacyConsent {
  /** 是否已同意当前版本的隐私政策。 */
  static isAgreed(context: common.UIAbilityContext): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: PREF_NAME });
      return prefs.getSync(KEY_AGREED, false) as boolean;
    } catch (e) {
      return false;
    }
  }

  /** 记录"已同意"。 */
  static setAgreed(context: common.UIAbilityContext): void {
    const prefs = preferences.getPreferencesSync(context, { name: PREF_NAME });
    prefs.putSync(KEY_AGREED, true);
    prefs.flushSync();
  }
}
