/**
 * NAPI 桥接层（C++）。
 *
 * 职责：把 Go 用 `-buildmode=c-shared` 导出的纯 C 函数包装成 ArkTS 可调用的
 * 方法。Go 侧导出函数声明见 `golang/libsyncthing.go`（//export 标记），
 * 编译后由 cgo 生成 `libsyncthing.h`，本文件的 extern "C" 声明与之对应。
 *
 * 关键点：Go runtime 在 c-shared 模式下自带一个 goroutine 调度器与 GC，
 * 它需要在自己的 OS 线程上启动。NAPI 侧只负责：
 *   1. 在首次调用时触发 Go 侧初始化（StartGo / StartSyncthing）
 *   2. 把 ArkTS 传入的 JSON 字符串搬给 Go，把返回字符串搬回
 * 不持有任何同步逻辑。
 */
#include "napi/native_api.h"
#include "hilog/log.h"
#include <string>
#include <signal.h>
#include <ucontext.h>
#include <dlfcn.h>

// —— 崩溃记录器：SIGSEGV/SIGBUS 时把 pc / 故障地址 / 模块偏移打进 hilog ——
// 作用：faultlogger 的 tombstone 无 shell 权限读取，这里自己留最小痕迹。
// 记录完把信号转交旧处理器（通常是 Go runtime / sigchain），不改变原有行为。
typedef void (*oh_log_fn)(unsigned int, unsigned int, unsigned int,
	const char*, const char*, ...);

static oh_log_fn crash_logfn() {
	static oh_log_fn fn = nullptr;
	if (!fn) {
		void* h = dlopen("libhilog_ndk.z.so", RTLD_NOW);
		if (h) fn = reinterpret_cast<oh_log_fn>(dlsym(h, "OH_LOG_Print"));
	}
	return fn;
}

static void log_crash(const char* what, siginfo_t* info, ucontext_t* uc) {
	oh_log_fn logfn = crash_logfn();
	if (!logfn || !uc) return;
	uint64_t pc = static_cast<uint64_t>(uc->uc_mcontext.pc);
	uint64_t addr = reinterpret_cast<uint64_t>(info->si_addr);
	Dl_info di = {};
	const char* mod = "unknown";
	uint64_t base = 0;
	if (dladdr(reinterpret_cast<void*>(pc), &di) && di.dli_fname) {
		mod = di.dli_fname;
		base = reinterpret_cast<uint64_t>(di.dli_fbase);
	}
	logfn(0 /*LOG_APP*/, 6 /*LOG_FATAL*/, 0x0002, "SyncHM-Crash",
		"%{public}s pc=0x%{public}llx mod=%{public}s base=0x%{public}llx off=0x%{public}llx addr=0x%{public}llx",
		what, (unsigned long long)pc, mod, (unsigned long long)base,
		(unsigned long long)(base ? pc - base : 0), (unsigned long long)addr);
}

static struct sigaction g_old_segv;
static struct sigaction g_old_bus;

static void synchm_crash_handler(int sig, siginfo_t* info, void* ctx) {
	log_crash(sig == SIGSEGV ? "SEGV" : "BUS", info, static_cast<ucontext_t*>(ctx));
	struct sigaction* old = (sig == SIGSEGV) ? &g_old_segv : &g_old_bus;
	// 转交旧处理器：恢复旧动作后重新 raise，让原有链路（Go/sigchain）接管。
	sigaction(sig, old, nullptr);
	raise(sig);
}

static void install_crash_logger() {
	struct sigaction sa = {};
	sa.sa_sigaction = synchm_crash_handler;
	sa.sa_flags = SA_SIGINFO;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGSEGV, &sa, &g_old_segv);
	sigaction(SIGBUS, &sa, &g_old_bus);
}

// —— 由 cgo 生成的导出函数声明（与 golang/libsyncthing.go 的 //export 一致）——
// 这些符号在链接 libsyncthing.so（Go c-shared 产物）后可用。
//
// 骨架模式（SYNC_LIB_MISSING 定义时）：用 __attribute__((weak)) 提供 stub，
// 让 NAPI 桥在没有 Go 库时也能编译链接通过，便于先验证 ArkTS + NAPI 骨架。
#ifdef SYNC_LIB_MISSING
#define SYNC_FUNC(ret, name, ...) \
    extern "C" __attribute__((weak)) ret name(__VA_ARGS__) { return ""; }
SYNC_FUNC(const char*, syncthing_start, const char* config_json)
SYNC_FUNC(const char*, syncthing_stop, void)
SYNC_FUNC(const char*, syncthing_status, void)
SYNC_FUNC(const char*, syncthing_folders, void)
SYNC_FUNC(const char*, syncthing_devices, void)
SYNC_FUNC(const char*, syncthing_add_folder, const char* folder_json)
SYNC_FUNC(const char*, syncthing_add_device, const char* device_json)
SYNC_FUNC(const char*, syncthing_remove_folder, const char* folder_id)
SYNC_FUNC(const char*, syncthing_remove_device, const char* device_id)
SYNC_FUNC(const char*, syncthing_version, void)
SYNC_FUNC(const char*, syncthing_gui_url, void)
#else
extern "C" {
    const char* syncthing_start(const char* config_json);
    const char* syncthing_stop();
    const char* syncthing_status();
    const char* syncthing_folders();
    const char* syncthing_devices();
    const char* syncthing_add_folder(const char* folder_json);
    const char* syncthing_add_device(const char* device_json);
    const char* syncthing_remove_folder(const char* folder_id);
    const char* syncthing_remove_device(const char* device_id);
    const char* syncthing_version();
    const char* syncthing_gui_url();
}
#endif

#define LOG_TAG "SyncHMNative"
#define LOG_DOMAIN 0x0002

// —— 工具：从 NAPI 取一个字符串参数（可为空返回 ""）——
static std::string GetStringArg(napi_env env, napi_callback_info info, size_t idx) {
    size_t argc = idx + 1;
    napi_value args[8];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc <= idx) {
        return "";
    }
    napi_valuetype t;
    napi_typeof(env, args[idx], &t);
    if (t != napi_string) {
        return "";
    }
    size_t len = 0;
    napi_get_value_string_utf8(env, args[idx], nullptr, 0, &len);
    std::string out(len, '\0');
    napi_get_value_string_utf8(env, args[idx], &out[0], len + 1, &len);
    return out;
}

// —— 工具：把 const char* 结果包装成 napi string ——
static napi_value MakeString(napi_env env, const char* s) {
    napi_value v;
    napi_create_string_utf8(env, s ? s : "", NAPI_AUTO_LENGTH, &v);
    return v;
}

// —— 工具：包装一个「1 个 string 入参、返回 string」的 Go 调用 ——
template <const char* (*Fn)(const char*)>
static napi_value WrapString(napi_env env, napi_callback_info info) {
    std::string arg = GetStringArg(env, info, 0);
    return MakeString(env, Fn(arg.c_str()));
}

// —— 工具：包装一个「0 入参、返回 string」的 Go 调用 ——
template <const char* (*Fn)()>
static napi_value WrapVoid(napi_env env, napi_callback_info info) {
    return MakeString(env, Fn());
}

// —— 各导出方法 ——
static napi_value Start(napi_env env, napi_callback_info info) {
    std::string arg = GetStringArg(env, info, 0);
    return MakeString(env, syncthing_start(arg.c_str()));
}
static napi_value Stop(napi_env env, napi_callback_info info) {
    return MakeString(env, syncthing_stop());
}
static napi_value Status(napi_env env, napi_callback_info info) {
    return MakeString(env, syncthing_status());
}
static napi_value Folders(napi_env env, napi_callback_info info) {
    return MakeString(env, syncthing_folders());
}
static napi_value Devices(napi_env env, napi_callback_info info) {
    return MakeString(env, syncthing_devices());
}
static napi_value AddFolder(napi_env env, napi_callback_info info) {
    std::string arg = GetStringArg(env, info, 0);
    return MakeString(env, syncthing_add_folder(arg.c_str()));
}
static napi_value AddDevice(napi_env env, napi_callback_info info) {
    std::string arg = GetStringArg(env, info, 0);
    return MakeString(env, syncthing_add_device(arg.c_str()));
}
static napi_value RemoveFolder(napi_env env, napi_callback_info info) {
    std::string arg = GetStringArg(env, info, 0);
    return MakeString(env, syncthing_remove_folder(arg.c_str()));
}
static napi_value RemoveDevice(napi_env env, napi_callback_info info) {
    std::string arg = GetStringArg(env, info, 0);
    return MakeString(env, syncthing_remove_device(arg.c_str()));
}
static napi_value Version(napi_env env, napi_callback_info info) {
    return MakeString(env, syncthing_version());
}
static napi_value GuiUrl(napi_env env, napi_callback_info info) {
    return MakeString(env, syncthing_gui_url());
}

// —— 模块初始化 ——
EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        { "start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getStatus", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getFolders", nullptr, Folders, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getDevices", nullptr, Devices, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "addFolder", nullptr, AddFolder, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "addDevice", nullptr, AddDevice, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "removeFolder", nullptr, RemoveFolder, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "removeDevice", nullptr, RemoveDevice, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "guiUrl", nullptr, GuiUrl, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "syncthingbridge",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterSyncthingBridge(void) {
	install_crash_logger();
	napi_module_register(&demoModule);
}
