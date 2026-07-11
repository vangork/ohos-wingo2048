// NAPI 桥接层：把 Go 交叉编译出的 lib2048core.so 暴露的 C 函数
// 包装成 ArkTS 可调用的 native 模块（libentry.so）。
#include "napi/native_api.h"
#include "golib/lib2048core.h"

// 把 Go 返回的 C 字符串拷进 napi string，并调用 Go 侧 Free 释放，避免泄漏。
static napi_value WrapAndFree(napi_env env, char *s) {
    napi_value result = nullptr;
    if (s == nullptr) {
        napi_create_string_utf8(env, "{}", NAPI_AUTO_LENGTH, &result);
        return result;
    }
    napi_create_string_utf8(env, s, NAPI_AUTO_LENGTH, &result);
    Game2048Free(s);
    return result;
}

// newGame(): string —— 开新局，返回状态 JSON
static napi_value NewGame(napi_env env, napi_callback_info info) {
    return WrapAndFree(env, Game2048New());
}

// state(): string —— 返回当前状态 JSON
static napi_value State(napi_env env, napi_callback_info info) {
    return WrapAndFree(env, Game2048State());
}

// move(dir: number): string —— 按方向移动，返回新状态 JSON（0上 1右 2下 3左）
static napi_value Move(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t dir = 0;
    napi_get_value_int32(env, args[0], &dir);
    return WrapAndFree(env, Game2048Move(dir));
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"newGame", nullptr, NewGame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"move", nullptr, Move, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"state", nullptr, State, nullptr, nullptr, nullptr, napi_default, nullptr},
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
    .nm_modname = "entry",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) {
    napi_module_register(&demoModule);
}
