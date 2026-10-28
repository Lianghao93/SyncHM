// Package main 是 SyncHM 的 Go 侧核心：把 syncthing 引擎以 c-shared 库的形式
// 导出给鸿蒙 NAPI 调用，让 MateBook Pro 上的 HAP 具备与 Windows/Linux 版
// syncthing 完全一致的文件同步能力（BEP 协议、设备发现、增量同步）。
//
// 架构：复用 syncthing 官方 `lib/syncthing` 包（与 cmd/syncthing 的 main 共用
// 同一套引擎），通过 syncthing.New() + App.Start() 启动完整引擎，再用
// App.Internals 查询状态。NAPI 侧（entry/src/main/cpp）把这些 C 导出函数
// 包装成 ArkTS 方法。
//
// 构建（见 scripts/build-golang.sh）：
//   CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC=aarch64-unknown-linux-ohos-clang \
//     go build -buildmode=c-shared -o libsyncthing.so .
//
// 已知平台坑：鸿蒙 libc 是 musl，标准 Go runtime 的 emulated TLS 在 musl 上
// 可能 dlopen 崩溃，需 Go >= 1.22（本机已装 1.27）。详见 docs/WHY-NOT.md。
package main

/*
extern void sync_hilog(const char* msg);
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/logger"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
	"github.com/syncthing/syncthing/lib/svcutil"
)

// goLog 把引擎诊断消息打进 hilog（tag SyncHM-Go），stderr 在鸿蒙应用里不可见。
func goLog(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	cmsg := C.CString(msg)
	C.sync_hilog(cmsg)
}

// defaultSyncPath 是默认同步目录：文档目录下的专用子目录
// （Documents 属鸿蒙 PC 预授权目录，应用有读写权限；沙箱外的 ~/Sync 会被 EPERM 拒绝）。
const defaultSyncPath = "/storage/Users/currentUser/Documents/SyncHM"

// traceOffset 记录 engine-trace.log 已泵送到 hilog 的字节位置。
var traceOffset int64

// pumpTraceLocked 把引擎启动追踪文件（stTrace 写入）的新增行转进 hilog。
// 应用沙箱路径 hdc shell 读不了，只能由应用自己泵出来。
func pumpTraceLocked() {
	if e.baseDir == "" {
		return
	}
	p := filepath.Join(e.baseDir, "engine-trace.log")
	f, err := os.Open(p)
	if err != nil {
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || st.Size() <= traceOffset {
		return
	}
	f.Seek(traceOffset, 0)
	buf := make([]byte, st.Size()-traceOffset)
	if _, err := io.ReadFull(f, buf); err != nil {
		return
	}
	traceOffset = st.Size()
	for _, line := range strings.Split(string(buf), "\n") {
		if line != "" {
			goLog("trace: %s", line)
		}
	}
}

func pumpTrace() {
	e.mu.Lock()
	pumpTraceLocked()
	e.mu.Unlock()
}

// startTracePump 启动独立的 trace 泵（2s 一次）。
// 之前挂在 status 轮询里，用户切到 WebUI 页面后轮询停止导致追踪断流。
func startTracePump() {
	go func() {
		for {
			time.Sleep(2 * time.Second)
			pumpTrace()
		}
	}()
}

// 引擎自己的运行日志（默认写 stdout，鸿蒙里不可见）劫持到 hilog，
// 否则 app.Start() 卡在哪一步无从判断。
func init() {
	logger.DefaultLogger.AddHandler(logger.LevelInfo, func(l logger.LogLevel, s string) {
		goLog("st: %s", s)
	})
}

// —— 引擎单例与跨 goroutine 状态 ——
type engine struct {
	mu       sync.Mutex
	app      *syncthing.App
	evLog    events.Logger
	evCancel context.CancelFunc
	wrapper  config.Wrapper
	baseDir  string
	running  bool
	version  string
	guiAddr  string
}

var e = &engine{
	version: "1.28.1-synchm",
}

var startTime time.Time

// jsonResult 是统一返回格式，ArkTS 侧直接 JSON.parse。
type jsonResult struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
	Data  string `json:"data,omitempty"`
}

func okJSON(v interface{}) *C.char {
	b, _ := json.Marshal(v)
	r, _ := json.Marshal(jsonResult{OK: true, Data: string(b)})
	return C.CString(string(r))
}

func okData(data string) *C.char {
	r, _ := json.Marshal(jsonResult{OK: true, Data: data})
	return C.CString(string(r))
}

func fail(err string) *C.char {
	r, _ := json.Marshal(jsonResult{OK: false, Error: err})
	return C.CString(string(r))
}

// resolveBaseDir 把 ArkTS 传入的相对/绝对 home 解析为引擎数据目录。
func resolveBaseDir(home string) string {
	if filepath.IsAbs(home) {
		return home
	}
	if home == "" {
		home = "syncthing"
	}
	wd, err := os.Getwd()
	if err != nil {
		return home
	}
	return filepath.Join(wd, home)
}

// syncthing_start 启动同步引擎。
// config_json 形如 {"home": "<绝对路径>"}，home 是引擎数据目录。
//
//export syncthing_start
func syncthing_start(config_json *C.char) *C.char {
	e.mu.Lock()
	defer e.mu.Unlock()
	goLog("start: enter")

	if e.running {
		return okData(`{"started":false,"reason":"already running"}`)
	}

	var req struct {
		Home string `json:"home"`
	}
	_ = json.Unmarshal([]byte(C.GoString(config_json)), &req)
	baseDir := resolveBaseDir(req.Home)
	e.baseDir = baseDir
	goLog("start: baseDir=%s", baseDir)

	if err := os.MkdirAll(baseDir, 0o700); err != nil {
		return fail(fmt.Sprintf("mkdir baseDir: %v", err))
	}

	_ = locations.SetBaseDir(locations.ConfigBaseDir, baseDir)
	_ = locations.SetBaseDir(locations.DataBaseDir, baseDir)
	goLog("start: locations set")

	cert, err := syncthing.LoadOrGenerateCertificate(
		locations.Get(locations.CertFile),
		locations.Get(locations.KeyFile),
	)
	if err != nil {
		return fail(fmt.Sprintf("certificate: %v", err))
	}
	goLog("start: cert ok")

	evLogger := events.NewLogger()
	e.evLog = evLogger

	// 官方 cmd/syncthing 把 evLogger 加进 early supervisor 里 Serve。
	// 不 Serve 的话 Subscribe 会永远阻塞在 l.funcs <- 上（引擎启动卡点根因）。
	evCtx, evCancel := context.WithCancel(context.Background())
	e.evCancel = evCancel
	go func() {
		_ = evLogger.Serve(evCtx)
	}()
	goLog("start: evlog serving")

	cfgWrapper, err := syncthing.LoadConfigAtStartup(
		locations.Get(locations.ConfigFile),
		cert,
		evLogger,
		false, // allowNewerConfig
		false, // noDefaultFolder
		true,  // skipPortProbing
	)
	if err != nil {
		return fail(fmt.Sprintf("config: %v", err))
	}
	e.wrapper = cfgWrapper

	// config wrapper 和 evLogger 同一模式：Modify/Subscribe 都走内部队列，
	// 必须有 Serve 循环消费，否则永久阻塞（官方 cmd/syncthing 也是
	// earlyService.Add(cfgWrapper)）。
	go func() {
		_ = cfgWrapper.Serve(evCtx)
	}()

	goLog("start: config loaded")

	// 强制启用 GUI（WebUI 依赖）：默认配置或旧配置里 GUI 可能是关闭的，
	// setupGUI 会静默跳过导致 8384 永不监听。
	// 注意：GUIConfiguration 的地址字段是 Addr；cfgWrapper.Modify 返回两值。
	goLog("start: gui modify enter")
	if _, merr := cfgWrapper.Modify(func(cfg *config.Configuration) {
		if !cfg.GUI.Enabled {
			cfg.GUI.Enabled = true
		}
		if cfg.GUI.RawAddress == "" {
			cfg.GUI.RawAddress = "127.0.0.1:8384"
		}
		// 「添加文件夹」对话框的默认路径 → 文档目录下的专用子目录。
		// 注意：FolderConfiguration.Path 的出厂默认值是 "~"（GUI 会拼成 ~/<folderID>，
		// 展开到不可写的 /storage/Users/currentUser），必须一并替换。
		// 只有当前值还是空的或旧默认值时才覆盖，不干扰用户自定义值。
		switch cfg.Defaults.Folder.Path {
		case "", "~", "~/Sync", "/storage/Users/currentUser/Sync",
			"/storage/Users/currentUser/Download",
			"/storage/Users/currentUser/Documents":
			cfg.Defaults.Folder.Path = defaultSyncPath
		}
		// 首次启动自动创建的「Default Folder」（id=default）一并迁到专用子目录。
		// 同样只在它还是旧默认路径时迁移，用户已改过的不动。
		for i := range cfg.Folders {
			f := &cfg.Folders[i]
			if f.ID != "default" {
				continue
			}
			switch f.Path {
			case "", "~", "~/Sync", "/storage/Users/currentUser/Sync",
				"/storage/Users/currentUser/Download",
				"/storage/Users/currentUser/Documents":
				f.Path = defaultSyncPath
			}
		}
	}); merr != nil {
		goLog("GUI enable modify failed: %v", merr)
	}
	goLog("start: gui modify done")

	// 记录 GUI 监听地址（WebUI），供 ArkTS 侧打开管理界面。
	e.guiAddr = cfgWrapper.GUI().RawAddress
	if e.guiAddr == "" {
		e.guiAddr = "127.0.0.1:8384"
	}

	ldb, err := syncthing.OpenDBBackend(
		locations.Get(locations.Database),
		cfgWrapper.Options().DatabaseTuning,
	)
	if err != nil {
		return fail(fmt.Sprintf("database: %v", err))
	}
	goLog("start: db opened")

	appOpts := syncthing.Options{
		NoUpgrade: true,
	}

	app, err := syncthing.New(cfgWrapper, ldb, evLogger, cert, appOpts)
	if err != nil {
		goLog("syncthing.New failed: %v", err)
		return fail(fmt.Sprintf("syncthing.New: %v", err))
	}
	e.app = app
	goLog("engine created, starting (gui=%s)", e.guiAddr)
	startTracePump()

	go func() {
		if err := app.Start(); err != nil {
			goLog("app.Start FAILED: %v", err)
			return
		}
		goLog("app.Start returned (engine stopped)")
	}()

	time.Sleep(500 * time.Millisecond)
	e.running = true
	startTime = time.Now()

	return okData(fmt.Sprintf(`{"started":true,"deviceID":"%s","gui":"http://%s"}`, cfgWrapper.MyID().String(), e.guiAddr))
}

//export syncthing_stop
func syncthing_stop() *C.char {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.running || e.app == nil {
		return okData(`{"stopped":false,"reason":"not running"}`)
	}
	e.app.Stop(svcutil.ExitSuccess)
	e.app = nil
	if e.evCancel != nil {
		e.evCancel()
		e.evCancel = nil
	}
	e.running = false
	return okData(`{"stopped":true}`)
}

// —— 状态查询 ——

type statusPayload struct {
	Running          bool   `json:"running"`
	Version          string `json:"version"`
	DeviceID         string `json:"deviceID"`
	UptimeSeconds    int64  `json:"uptimeSeconds"`
	ConnectedDevices int    `json:"connectedDevices"`
	TotalDevices     int    `json:"totalDevices"`
	FolderCount      int    `json:"folderCount"`
	InSync           bool   `json:"inSync"`
}

//export syncthing_status
func syncthing_status() *C.char {
	e.mu.Lock()
	defer e.mu.Unlock()

	st := statusPayload{
		Running: e.running,
		Version: e.version,
	}
	if e.wrapper != nil {
		st.DeviceID = e.wrapper.MyID().String()
		devs := e.wrapper.DeviceList()
		st.TotalDevices = len(devs)
		st.FolderCount = len(e.wrapper.FolderList())
		if e.app != nil {
			for _, d := range devs {
				if e.app != nil && e.app.Internals != nil && e.app.Internals.IsConnectedTo(d.DeviceID) {
					st.ConnectedDevices++
				}
			}
		}
	}
	if !startTime.IsZero() {
		st.UptimeSeconds = int64(time.Since(startTime).Seconds())
	}
	st.InSync = st.ConnectedDevices == st.TotalDevices
	return okJSON(st)
}

type folderPayload struct {
	ID              string `json:"id"`
	Label           string `json:"label"`
	Path            string `json:"path"`
	Type            string `json:"type"`
	Paused          bool   `json:"paused"`
	RescanIntervalS int    `json:"rescanIntervalS"`
	SyncState       string `json:"syncState"`
}

//export syncthing_folders
func syncthing_folders() *C.char {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.wrapper == nil {
		return okData(`[]`)
	}
	list := e.wrapper.FolderList()
	out := make([]folderPayload, 0, len(list))
	for _, f := range list {
		state := "idle"
		if e.app != nil && e.app.Internals != nil {
			s, _, err := e.app.Internals.FolderState(f.ID)
			if err == nil && s != "" {
				state = s
			}
		}
		out = append(out, folderPayload{
			ID:              f.ID,
			Label:           f.Label,
			Path:            f.Path,
			Type:            f.Type.String(),
			Paused:          f.Paused,
			RescanIntervalS: f.RescanIntervalS,
			SyncState:       state,
		})
	}
	b, _ := json.Marshal(out)
	return okData(string(b))
}

type devicePayload struct {
	DeviceID    string `json:"deviceID"`
	Name        string `json:"name"`
	Address     string `json:"address"`
	Compression string `json:"compression"`
	Introducer  bool   `json:"introducer"`
	Paused      bool   `json:"paused"`
	Connected   bool   `json:"connected"`
	LastSeen    string `json:"lastSeen"`
}

//export syncthing_devices
func syncthing_devices() *C.char {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.wrapper == nil {
		return okData(`[]`)
	}
	list := e.wrapper.DeviceList()
	out := make([]devicePayload, 0, len(list))
	for _, d := range list {
		connected := false
			if e.app != nil && e.app.Internals != nil {
				connected = e.app.Internals.IsConnectedTo(d.DeviceID)
			}
		addr := "dynamic"
		if len(d.Addresses) > 0 {
			addr = d.Addresses[0]
		}
		out = append(out, devicePayload{
			DeviceID:    d.DeviceID.String(),
			Name:        d.Name,
			Address:     addr,
			Compression: d.Compression.String(),
			Introducer:  d.Introducer,
			Paused:      d.Paused,
			Connected:   connected,
			LastSeen:    "",
		})
	}
	b, _ := json.Marshal(out)
	return okData(string(b))
}

// —— 配置修改 ——

type addFolderReq struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Path  string `json:"path"`
	Type  string `json:"type"`
}

//export syncthing_add_folder
func syncthing_add_folder(folder_json *C.char) *C.char {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.wrapper == nil {
		return fail("engine not running")
	}
	var req addFolderReq
	if err := json.Unmarshal([]byte(C.GoString(folder_json)), &req); err != nil {
		return fail(fmt.Sprintf("bad request: %v", err))
	}
	if req.ID == "" {
		return fail("folder id required")
	}
	if req.Path == "" {
		req.Path = filepath.Join(e.baseDir, req.ID)
	}

	folderType := config.FolderTypeSendReceive
	switch req.Type {
	case "sendonly":
		folderType = config.FolderTypeSendOnly
	case "receiveonly":
		folderType = config.FolderTypeReceiveOnly
	}

	f := config.FolderConfiguration{
		ID:              req.ID,
		Label:           req.Label,
		Path:            req.Path,
		Type:            folderType,
		RescanIntervalS: 3600,
		FSWatcherEnabled: true,
	}

	_, err := e.wrapper.Modify(func(cfg *config.Configuration) {
		cfg.SetFolder(f)
	})
	if err != nil {
		return fail(fmt.Sprintf("set folder: %v", err))
	}
	if e.app != nil && e.app.Internals != nil {
		e.app.Internals.ScanFolders()
	}
	return okData(`{"added":true}`)
}

type addDeviceReq struct {
	DeviceID string `json:"deviceID"`
	Name     string `json:"name"`
	Address  string `json:"address"`
}

//export syncthing_add_device
func syncthing_add_device(device_json *C.char) *C.char {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.wrapper == nil {
		return fail("engine not running")
	}
	var req addDeviceReq
	if err := json.Unmarshal([]byte(C.GoString(device_json)), &req); err != nil {
		return fail(fmt.Sprintf("bad request: %v", err))
	}
	devID, err := protocol.DeviceIDFromString(req.DeviceID)
	if err != nil {
		return fail(fmt.Sprintf("invalid device id: %v", err))
	}
	addrs := []string{"dynamic"}
	if req.Address != "" {
		addrs = []string{req.Address}
	}

	d := config.DeviceConfiguration{
		DeviceID:    devID,
		Name:        req.Name,
		Addresses:   addrs,
		Compression: protocol.CompressionMetadata,
	}

	_, err = e.wrapper.Modify(func(cfg *config.Configuration) {
		cfg.SetDevice(d)
	})
	if err != nil {
		return fail(fmt.Sprintf("set device: %v", err))
	}
	return okData(`{"added":true}`)
}

//export syncthing_remove_folder
func syncthing_remove_folder(folder_id *C.char) *C.char {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.wrapper == nil {
		return fail("engine not running")
	}
	_, err := e.wrapper.RemoveFolder(C.GoString(folder_id))
	if err != nil {
		return fail(fmt.Sprintf("remove folder: %v", err))
	}
	return okData(`{"removed":true}`)
}

//export syncthing_remove_device
func syncthing_remove_device(device_id *C.char) *C.char {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.wrapper == nil {
		return fail("engine not running")
	}
	devID, err := protocol.DeviceIDFromString(C.GoString(device_id))
	if err != nil {
		return fail(fmt.Sprintf("invalid device id: %v", err))
	}
	_, err = e.wrapper.RemoveDevice(devID)
	if err != nil {
		return fail(fmt.Sprintf("remove device: %v", err))
	}
	return okData(`{"removed":true}`)
}

//export syncthing_version
func syncthing_version() *C.char {
	return okData(e.version)
}

//export syncthing_gui_url
func syncthing_gui_url() *C.char {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.guiAddr == "" {
		return okData("http://127.0.0.1:8384")
	}
	return okData(fmt.Sprintf("http://%s", e.guiAddr))
}

// main 必须存在（cgo c-shared 要求），但不会被调用。
func main() {}

// 保证 context 包被引用（App.Start 内部使用，避免未使用导入报错）。
var _ = context.Background
