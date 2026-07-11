cmake_minimum_required(VERSION 3.5.0)
project(Game2048)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
)

# NAPI 桥接库 -> libentry.so
add_library(entry SHARED napi_init.cpp)

# Go 交叉编译产物：entry/libs/<abi>/lib2048core.so
# OHOS_ARCH 由 ohos.toolchain.cmake 提供（x86_64 / arm64-v8a / armeabi-v7a）
set(GO_LIB ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/lib2048core.so)

target_link_libraries(entry PUBLIC
    ${GO_LIB}
    libace_napi.z.so
)
