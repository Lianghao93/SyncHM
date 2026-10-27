/**
 * libsyncthingbridge 的 NAPI 类型声明。
 *
 * 关键：OpenHarmony 的 NAPI 模块「默认导入」语义是——`import bridge from 'libxxx.so'`
 * 拿到的 `bridge` 是 native `Init` 返回的 **exports 对象本身**（上面挂着
 * version/start/... 这些属性），而 NOT 一个 `{ default: ... }` 包装。
 *
 * 因此这里必须用 `export const` 逐个声明方法（对应 C++ 侧 napi_define_properties
 * 注册的属性名），**不要**使用 `export default`——否则 ArkTS 编译器会生成
 * `exports.default` 的取值，而 exports 上没有 default，导致拿到 undefined。
 */
export const start: (configJson: string) => string;
export const stop: () => string;
export const getStatus: () => string;
export const getFolders: () => string;
export const getDevices: () => string;
export const addFolder: (folderJson: string) => string;
export const addDevice: (deviceJson: string) => string;
export const removeFolder: (folderId: string) => string;
export const removeDevice: (deviceId: string) => string;
export const version: () => string;
export const guiUrl: () => string;
