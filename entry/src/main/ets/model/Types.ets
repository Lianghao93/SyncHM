/**
 * SyncHM 数据模型。
 *
 * 这些模型对应 syncthing 核心暴露的 JSON 结构（经由 REST 风格的内置 API 或
 * NAPI 桥接返回），ArkTS 侧只做展示与交互，不含同步逻辑。
 */

/** 一个远程设备（peer） */
export interface Device {
  deviceID: string;      // 64 字符的 syncthing 设备 ID（SHA256 证书指纹）
  name: string;
  address: string;       // tcp://host:port 或 dynamic
  compression: string;   // metadata | always | never
  introducer: boolean;
  paused: boolean;
  connected: boolean;
  lastSeen: string;      // ISO 时间或 '从未'
}

/** 一个被同步的文件夹 */
export interface Folder {
  id: string;            // 文件夹唯一 ID（默认目录名）
  label: string;         // 展示名
  path: string;          // 本机绝对路径
  type: string;          // sendreceive | sendonly | receiveonly
  paused: boolean;
  devices: string[];     // 共享给哪些设备 ID
  rescanIntervalS: number;
  syncState: string;     // idle | syncing | error
  inSyncBytes: number;
  globalBytes: number;
}

/** 引擎运行时状态摘要 */
export interface EngineStatus {
  running: boolean;
  version: string;
  deviceID: string;
  uptimeSeconds: number;
  connectedDevices: number;
  totalDevices: number;
  folderCount: number;
  inSync: boolean;
}

/** 引擎返回的通用结果 */
export interface EngineResult {
  ok: boolean;
  error?: string;
  data?: string;        // JSON 字符串
}
