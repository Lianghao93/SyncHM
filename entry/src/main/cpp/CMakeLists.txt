# SyncHM NAPI 桥接模块构建脚本
#
# 编译产物：libsyncthingbridge.so —— 一个 NAPI 模块，内部链接 Go 编译出的
# libsyncthing.so（syncthing 核心），把 Go 导出的 C 函数包装成 ArkTS 可调用方法。
#
# 两个库的关系：
#   libsyncthingbridge.so (NAPI, C++)  ->  动态链接  ->  libsyncthing.so (Go c-shared)
#
# Go 库的构建见 golang/ 目录与 scripts/build-golang.sh，产出的 .so 放入
# entry/src/main/resources/base/libs/arm64-v8a/，随 HAP 一起打包。

cmake_minimum_required(VERSION 3.5.0)
project(syncthingbridge)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# —— NAPI 头文件（鸿蒙 SDK 自带）——
include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(syncthingbridge SHARED napi_init.cpp)

# —— 链接 Go 编译的 syncthing 核心库 ——
# 路径指向模块级 libs 目录（entry/libs/arm64-v8a/libsyncthing.so），
# hvigor 会把该目录下的 .so 自动打包进 HAP。
# 若尚未编译出 libsyncthing.so，可设 SYNC_LIB_MISSING=ON 仅编译空壳桥
# （用于验证 NAPI 骨架）。但注意：空壳桥缺少 syncthing_* 符号，链接会失败，
# 所以骨架模式需要一并提供 stub 符号，见下方 SYNC_LIB_MISSING 分支。
option(SYNC_LIB_MISSING "Build bridge without Go core (skeleton only)" OFF)

if(NOT SYNC_LIB_MISSING)
    set(SYNCTHING_LIB_DIR ${NATIVERENDER_ROOT_PATH}/../../../libs/arm64-v8a)
    target_link_libraries(syncthingbridge PUBLIC
        ${SYNCTHING_LIB_DIR}/libsyncthing.so)
    target_link_directories(syncthingbridge PUBLIC ${SYNCTHING_LIB_DIR})
else()
    # 骨架模式：提供 stub 符号，让 NAPI 桥能独立编译链接通过。
    # 这些 stub 返回空字符串，实际运行时会由 Go 库替换。
    target_compile_definitions(syncthingbridge PRIVATE SYNC_LIB_MISSING)
endif()

# —— 鸿蒙 native 日志库 + NAPI 运行时 ——
target_link_libraries(syncthingbridge PUBLIC libhilog_ndk.z.so libace_napi.z.so)
