/**
 * SyncEngine —— 鸿蒙 ArkTS 与 syncthing Go 原生核心之间的桥接层。
 *
 * 设计要点：
 *  - 真正的同步逻辑全部在 Go（libsyncthing.so）里，通过 cgo `//export` 导出
 *    一组纯 C 函数；C++ NAPI 层（entry/src/main/cpp）把 C 函数包装成
 *    ArkTS 可调用的 JS 对象方法。
 *  - ArkTS 侧通过命名空间导入 `import * as bridge from 'libsyncthingbridge.so'`
 *    拿到 native 模块的 exports 对象（上面挂着 version/start/stop/... 方法），
 *    再调用 bridge.version() / bridge.start() / ...。
 *    （OpenHarmony NAPI 不支持真正的 ES 默认导出，exports 上无 default 属性；
 *     用 export const + namespace import 是与 napi_define_properties 注册名一一
 *     对应、语义最清晰的写法，可避免拿到 undefined。）
 *  - 所有返回值统一为 JSON 字符串，避免在 NAPI 边界做复杂类型转换。
 *  - 引擎加载失败时降级：返回明确的错误状态，UI 显示“引擎未就绪”，而不是崩溃。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { EngineStatus, EngineResult, Folder, Device } from '../model/Types';
import * as bridge from 'libsyncthingbridge.so';

const DOMAIN: number = 0x0002;
const TAG: string = 'SyncEngine';

/** Go 侧统一返回的外层包装结构。 */
interface UnpackedResult {
  ok: boolean;
  data: string;
  error: string;
}

export class SyncEngine {
  private loaded: boolean = false;
  private loadError: string = '';
  private running: boolean = false;
  private baseDir: string = '';

  /** 设置引擎数据目录的绝对路径（由 EntryAbility 传入 filesDir）。 */
  setBaseDir(dir: string): void {
    this.baseDir = dir;
  }

  /** 尝试加载原生库。失败不抛出，记录原因供 UI 显示。 */
  init(): void {
    try {
      // 触发一次 native 调用，验证模块确实可用（拿到真实版本号）
      const r = this.unpack(bridge.version());
      if (!r.ok) {
        this.loadError = `loadLibrary failed: ${r.error}`;
        this.loaded = false;
        hilog.error(DOMAIN, TAG, 'native bridge load failed: %{public}s', this.loadError);
        return;
      }
      this.loaded = true;
      hilog.info(DOMAIN, TAG, 'native bridge loaded, version: %{public}s', r.data);
    } catch (e) {
      const err = e as Error;
      this.loadError = `loadLibrary failed: ${err.message}`;
      this.loaded = false;
      hilog.error(DOMAIN, TAG, 'native bridge load failed: %{public}s', this.loadError);
    }
  }

  isReady(): boolean {
    return this.loaded;
  }

  getLoadError(): string {
    return this.loadError;
  }

  /** 获取 WebUI 地址（如 http://127.0.0.1:8384）。引擎未启动时返回默认地址。 */
  getGuiUrl(): string {
    if (!this.loaded) {
      return 'http://127.0.0.1:8384';
    }
    try {
      const r = this.unpack(bridge.guiUrl());
      return (r.ok && r.data !== '') ? r.data : 'http://127.0.0.1:8384';
    } catch (e) {
      return 'http://127.0.0.1:8384';
    }
  }

  /**
   * 解析 Go 侧统一返回格式：{"ok":bool,"data":"<json字符串>","error":"..."}。
   * 返回外层结果对象；调用方再从 .data 里二次 JSON.parse 得到真实数据。
   */
  private unpack(raw: string): UnpackedResult {
    try {
      const outer = JSON.parse(raw) as UnpackedResult;
      const result: UnpackedResult = {
        ok: outer.ok === true,
        data: outer.data ?? '',
        error: outer.error ?? ''
      };
      return result;
    } catch (e) {
      const result: UnpackedResult = {
        ok: false,
        data: '',
        error: `bad json: ${(e as Error).message}`
      };
      return result;
    }
  }

  /** 启动同步引擎。用绝对路径（filesDir/syncthing）作为引擎数据目录。 */
  start(configJson: string): EngineResult {
    if (!this.loaded) {
      return { ok: false, error: this.loadError || 'engine not loaded' };
    }
    try {
      // 若调用方未提供绝对 home，则回退到 filesDir/syncthing。
      let cfg = configJson;
      if (this.baseDir !== '') {
        const home = `${this.baseDir}/syncthing`;
        cfg = JSON.stringify({ home });
      }
      const r = this.unpack(bridge.start(cfg));
      this.running = r.ok;
      return r.ok ? { ok: true, data: r.data } : { ok: false, error: r.error };
    } catch (e) {
      return { ok: false, error: (e as Error).message };
    }
  }

  stop(): EngineResult {
    if (!this.loaded) {
      return { ok: false, error: this.loadError || 'engine not loaded' };
    }
    try {
      const r = this.unpack(bridge.stop());
      this.running = false;
      return r.ok ? { ok: true, data: r.data } : { ok: false, error: r.error };
    } catch (e) {
      return { ok: false, error: (e as Error).message };
    }
  }

  getStatus(): EngineStatus {
    if (!this.loaded) {
      return this.emptyStatus();
    }
    try {
      const r = this.unpack(bridge.getStatus());
      if (!r.ok) {
        return this.emptyStatus();
      }
      return JSON.parse(r.data) as EngineStatus;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getStatus parse failed: %{public}s', (e as Error).message);
      return this.emptyStatus();
    }
  }

  getFolders(): Folder[] {
    if (!this.loaded) {
      return [];
    }
    try {
      const r = this.unpack(bridge.getFolders());
      if (!r.ok) {
        return [];
      }
      const arr = JSON.parse(r.data) as Folder[];
      return (arr !== null && typeof arr === 'object' && Array.isArray(arr)) ? arr : [];
    } catch (e) {
      return [];
    }
  }

  getDevices(): Device[] {
    if (!this.loaded) {
      return [];
    }
    try {
      const r = this.unpack(bridge.getDevices());
      if (!r.ok) {
        return [];
      }
      const arr = JSON.parse(r.data) as Device[];
      return (arr !== null && typeof arr === 'object' && Array.isArray(arr)) ? arr : [];
    } catch (e) {
      return [];
    }
  }

  addFolder(folderJson: string): EngineResult {
    if (!this.loaded) {
      return { ok: false, error: 'engine not loaded' };
    }
    try {
      const r = this.unpack(bridge.addFolder(folderJson));
      return r.ok ? { ok: true, data: r.data } : { ok: false, error: r.error };
    } catch (e) {
      return { ok: false, error: (e as Error).message };
    }
  }

  addDevice(deviceJson: string): EngineResult {
    if (!this.loaded) {
      return { ok: false, error: 'engine not loaded' };
    }
    try {
      const r = this.unpack(bridge.addDevice(deviceJson));
      return r.ok ? { ok: true, data: r.data } : { ok: false, error: r.error };
    } catch (e) {
      return { ok: false, error: (e as Error).message };
    }
  }

  private emptyStatus(): EngineStatus {
    return {
      running: this.running,
      version: 'unavailable',
      deviceID: '',
      uptimeSeconds: 0,
      connectedDevices: 0,
      totalDevices: 0,
      folderCount: 0,
      inSync: false
    };
  }
}

/** 全局单例，避免多处重复加载 native 库 */
export const engine: SyncEngine = new SyncEngine();
