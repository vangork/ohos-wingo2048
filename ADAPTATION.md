# 用 Go 实现游戏逻辑 + ArkTS 做界面，在 HarmonyOS 上跑 2048 —— 完整适配记录

本文档记录从空环境到「Go 写核心逻辑、ArkTS 写界面、跑在鸿蒙模拟器」的全过程，
包括环境安装、Go→鸿蒙交叉编译工具链的搭建、NAPI 桥接、踩过的坑与排查。

> 平台：Windows 11 + PowerShell；目标：HarmonyOS 6.1.1 (API 24) 模拟器。

---

## 0. 总体架构

```
┌─────────────────────────────────────────────┐
│ ArkTS UI (Index.ets)                          │  界面 / 手势
│   import { newGame, move, state } from         │
│          'libentry.so'                         │
└───────────────┬───────────────────────────────┘
                │ NAPI (Node-API)
┌───────────────▼───────────────────────────────┐
│ libentry.so  (napi_init.cpp, C++)              │  桥接层
│   newGame()/move(dir)/state() → C 函数          │
└───────────────┬───────────────────────────────┘
                │ C ABI (extern "C")
┌───────────────▼───────────────────────────────┐
│ lib2048core.so  (game2048.go, Go c-shared)     │  游戏逻辑（全部）
│   Game2048New / Game2048Move / Game2048Free    │
└─────────────────────────────────────────────────┘
```

- **游戏逻辑 100% 在 Go**：棋盘、滑动合并、随机生成、胜负判定。
- Go 以 `-buildmode=c-shared` 编成 `.so`，导出纯 C 函数（CGO `//export`）。
- C++ NAPI 层只做「调用 Go 函数 + 字符串/内存搬运」，不含游戏规则。
- ArkTS 只负责渲染状态 JSON 和把滑动方向传给 Go。

**关键认知**：不需要为鸿蒙新写一个 Go 编译器后端。Go 官方工具链已能生成
arm64/x86_64 机器码，鸿蒙内核是 Linux 系（libc 用 musl）。缺的只是
「用鸿蒙 NDK 的 clang + sysroot 做 CGO 交叉编译」这一层封装——见第 4 节，
这就是本项目所谓的“Go 鸿蒙编译器”。

---

## 1. 环境清单与安装

| 组件 | 版本 | 说明 |
|---|---|---|
| ark-cli | 0.1.2 | 鸿蒙命令行脚手架（内嵌 hdc） |
| 鸿蒙统一运行时 | API 24 | SDK + Emulator + hvigor + ohpm + node + hdc |
| Go | 1.26.4 | `winget install GoLang.Go` |
| NDK clang | 15.0.4 (OHOS) | 随 SDK 提供，CGO 交叉编译用 |

### 1.1 ark-cli 简介

`ark`（二进制名 `ark-cli`）是轻量级的 HarmonyOS/OpenHarmony 命令行脚手架，
一条命令覆盖**设备调试、应用构建运行、模拟器管理、统一运行时安装**，并内嵌
`hdc`，**无需安装完整的 DevEco Studio** 即可完成开发闭环。本项目从环境准备到
构建、部署、看日志，全程只用 `ark` 一把梭。

核心概念：

- **统一运行时目录** `~/.ark-cli/runtime/`（Windows 为 `C:\Users\<用户>\.ark-cli\runtime\`）：
  SDK、hvigor/ohpm/node、Emulator 全部安装于此。
- **配置文件** `~/.ark-cli/config.toml`：记录各组件路径，`ark runtime status` 会自愈失效路径。
- **内嵌 hdc**：`ark hdc <args>` 是对 hdc 的完全透传（如 `ark hdc shell uname -m`）。

常用命令一览：

| 命令 | 作用 |
|---|---|
| `ark runtime <install\|status>` | 安装/查看统一运行时（SDK + 工具链 + 模拟器） |
| `ark devices [--json]` | 列出已连接设备 |
| `ark build [-m debug\|release]` | 构建鸿蒙工程（HAP） |
| `ark run [--monitor]` | 构建 → 安装 → 启动（可附带看日志） |
| `ark install <hap> [-r]` | 安装/覆盖安装 HAP |
| `ark logcat [-l -t]` | 实时日志 |
| `ark emulator <子命令>` | 模拟器实例与系统镜像管理 |
| `ark hdc <args...>` | hdc 命令完全透传 |

### 1.2 安装 ark-cli

ark-cli 用 Rust 编写，从源码仓库编译安装。

**方式一：克隆仓库安装（推荐）**

```bash
git clone https://atomgit.com/nutpi/ark-cli.git
cd ark-cli
bash scripts/install.sh        # 仓库自带脚本：编译并装入 PATH，创建 ark 软链
```

**方式二：从源码手动构建**

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # 无 Rust 时先装
git clone https://atomgit.com/nutpi/ark-cli.git && cd ark-cli
cargo build --release
cp target/release/ark-cli /usr/local/bin/
ln -sf /usr/local/bin/ark-cli /usr/local/bin/ark
```

**方式三：预编译二进制**

从 [Releases](https://atomgit.com/nutpi/ark-cli/releases) 下载对应平台压缩包，
解压后把 `ark-cli` 放入 PATH。

### 1.3 安装统一运行时（关键）

ark-cli 本体装好后**必须再装统一运行时**（SDK + hvigor/ohpm/node + Emulator），
否则 build/run/emulator 都无法工作：

```powershell
ark runtime install   # 自动识别平台，下载 command-line-tools 到 ~/.ark-cli/runtime/
ark runtime status    # 确认 SDK / Emulator / hvigorw / ohpm / node / hdc 均 OK
ark --version         # 验证本体
ark devices           # 验证 hdc 与设备连接
```
本机运行时目录：`C:\Users\<用户>\.ark-cli\runtime\`
SDK 根目录：`...\runtime\sdk\default\openharmony`

> 易错点：`--os-version` 等含括号的值（如 `"HarmonyOS 6.1.1(24)"`）在 zsh 下**必须加引号**，
> 否则 `(24)` 会被当成通配符报错。

### 1.4 安装 Go

```powershell
winget install --id GoLang.Go -e --accept-package-agreements --accept-source-agreements
# 安装到 C:\Program Files\Go ；验证：
& "C:\Program Files\Go\bin\go.exe" version   # go version go1.26.4 windows/amd64
```

---

## 2. 探查鸿蒙 NDK 工具链（交叉编译的前提）

SDK 自带 LLVM 与 sysroot：

```
<SDK>\native\llvm\bin\clang.exe                       # 编译器（x86_64-w64-windows-gnu 宿主）
<SDK>\native\sysroot\usr\include\                     # 头文件（stdlib.h / pthread.h ...）
<SDK>\native\sysroot\usr\include\x86_64-linux-ohos\   # 架构相关头
<SDK>\native\sysroot\usr\lib\x86_64-linux-ohos\       # 库（libace_napi.z.so ...）
<SDK>\native\build\cmake\ohos.toolchain.cmake         # CMake 工具链文件
```

`<SDK>\native\llvm\bin\` 下的 `aarch64-unknown-linux-ohos-clang` 是 `#!/bin/sh`
wrapper（Windows 跑不了），其本体就是：
```sh
clang -target aarch64-linux-ohos --sysroot=<sysroot> -D__MUSL__ "$@"
```
所以在 Windows 上我们直接调 `clang.exe` 并手动带上这三组参数即可。

各 ABI 对应关系（本项目用到的映射）：

| ABI | GOARCH | clang target triple |
|---|---|---|
| arm64-v8a | arm64 | aarch64-linux-ohos |
| x86_64 | amd64 | x86_64-linux-ohos |
| armeabi-v7a | arm | arm-linux-ohos |

---

## 3. 确认模拟器架构（极其重要）

native `.so` 的架构必须与设备一致，否则安装后加载失败。先确认模拟器 CPU：

```powershell
ark hdc shell uname -m                              # -> x86_64
ark hdc shell param get const.product.cpu.abilist  # -> x86_64
```

> 结论：本机 HarmonyOS 模拟器是 **x86_64**（不是 arm64）。
> 因此 Go 必须编成 `x86_64-linux-ohos`，`abiFilters` 也只放 `x86_64`。
> 上真机（arm64 手机）时改成 `arm64-v8a` 重新编译并改 abiFilters 即可。

---

## 4. Go → 鸿蒙交叉编译工具链（“Go 鸿蒙编译器”）

核心配方（环境变量）：

```
CGO_ENABLED = 1
GOOS        = linux
GOARCH      = amd64                      # 按 ABI 取值
CC          = <SDK>\native\llvm\bin\clang.exe
CGO_CFLAGS  = -target x86_64-linux-ohos --sysroot=<sysroot 正斜杠> -D__MUSL__
CGO_LDFLAGS = -target x86_64-linux-ohos --sysroot=<sysroot 正斜杠>
```
然后：
```
go build -buildmode=c-shared -trimpath -o lib2048core.so .
```

已封装为脚本 **`tools/build-go-hos.ps1`**，自动完成「设环境 → 编译 → 把
`.so` 拷到 `entry/libs/<abi>/`、`.h` 拷到 `entry/src/main/cpp/golib/`」：

```powershell
# 模拟器（x86_64）
& tools\build-go-hos.ps1 `
    -Src     Game2048\entry\src\main\cpp\go `
    -OutName lib2048core `
    -Abi     x86_64 `
    -LibsDir   Game2048\entry\libs\x86_64 `
    -HeaderDir Game2048\entry\src\main\cpp\golib

# 真机（arm64）只需改两个参数
& tools\build-go-hos.ps1 -Src ... -Abi arm64-v8a -LibsDir Game2048\entry\libs\arm64-v8a -HeaderDir ...
```

生成的头文件 `lib2048core.h` 暴露：
```c
extern char* Game2048New(void);
extern char* Game2048Move(int dir);
extern char* Game2048State(void);
extern void  Game2048Free(char* p);
```

### 踩坑记录（交叉编译）

1. **`'stdlib.h' file not found`（坑一：sysroot 带引号）**
   一开始把 `--sysroot="<path>"` 的引号写进 `CGO_CFLAGS`。Go 会把
   `CGO_CFLAGS` 按空格再拆分传给 clang，引号被当成路径的一部分 → 找不到头文件。
   **修复**：sysroot 不要加引号（鸿蒙 runtime 目录默认无空格）。

2. **`'stdlib.h' file not found`（坑二：Windows 反斜杠路径）**
   去掉引号后，PowerShell 里用反斜杠 `--sysroot=C:\Users\...`，经 Go 二次处理后
   clang 仍解析不到头文件搜索路径；而直接命令行调 clang（反斜杠）却正常。
   **修复**：把 sysroot 路径统一转成正斜杠 `C:/Users/...`。脚本里用
   `$sysroot -replace '\\','/'` 处理。用 `go build -x` 打印真实 clang 命令是定位此坑的关键。

3. 验证工具链本身没问题的最快办法：直接 `clang -target x86_64-linux-ohos --sysroot=... -E -x c -v /dev/null`
   看 `#include <...> search starts here`，确认 `usr/include` 在列。

---

## 5. NAPI 桥接层（C++）

- `entry/src/main/cpp/napi_init.cpp`：注册 `newGame/move/state` 三个方法，
  每次把 Go 返回的 C 字符串拷进 napi string 后立即 `Game2048Free` 释放。
- `entry/src/main/cpp/CMakeLists.txt`：
  ```cmake
  add_library(entry SHARED napi_init.cpp)
  set(GO_LIB ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/lib2048core.so)
  target_link_libraries(entry PUBLIC ${GO_LIB} libace_napi.z.so)
  ```
  `OHOS_ARCH` 由 `ohos.toolchain.cmake` 注入。`libentry.so` 运行时通过
  DT_NEEDED 找同目录的 `lib2048core.so`（二者都会被打进 HAP 的 libs/<abi>）。
- 类型声明：`entry/src/main/cpp/types/libentry/{Index.d.ts, oh-package.json5}`，
  包名 `libentry.so`，供 ArkTS `import ... from 'libentry.so'`。

---

## 6. 工程接线

- `entry/build-profile.json5` 增加：
  ```json5
  "externalNativeOptions": {
    "path": "./src/main/cpp/CMakeLists.txt",
    "abiFilters": ["x86_64"]
  }
  ```
- `entry/oh-package.json5` 增加依赖：
  ```json5
  "dependencies": { "libentry.so": "file:./src/main/cpp/types/libentry" }
  ```
- `entry/src/main/ets/pages/Index.ets`：4×4 棋盘渲染 + `PanGesture` 判定
  滑动方向（取位移较大的轴），调用 native `move(dir)`。

---

## 7. 构建与运行

```powershell
# 1) 先编 Go .so（见第 4 节）
& tools\build-go-hos.ps1 -Src Game2048\entry\src\main\cpp\go -Abi x86_64 `
    -LibsDir Game2048\entry\libs\x86_64 -HeaderDir Game2048\entry\src\main\cpp\golib

# 2) 构建 HAP（hvigor 跑 CMake 编 NAPI + 编 ArkTS）
cd Game2048
ark build --mode debug

# 3) 起模拟器（x86_64 phone）并部署
ark emulator start phone24      # 或已有运行中的实例
ark devices                     # 确认上线
ark run --monitor               # 构建→安装→启动→看日志
```

修改 Go 逻辑后：重跑第 1 步 → 再 `ark build` / `ark run`。

---

## 9. 运行时拦路虎：Go c-shared 的 TLS 模型 vs 鸿蒙 musl（关键）

构建/签名/安装/启动全成功，但应用**一启动就闪退**。崩溃日志（jscrash）定位：

```
Error relocating .../lib2048core.so: initial-exec TLS resolves to dynamic definition
→ load module libentry failed
→ export objects of native so is undefined   （所以 ArkTS 侧 game 是 undefined）
```

### 根因
- Go 主线编译器对 goroutine 指针 `g` 的 TLS 访问，在 c-shared 下**写死 initial-exec (IE) 模型**，并给 `.so` 打 `STATIC_TLS` 标志（`llvm-readelf -d` 可见 `STATIC_TLS`，`-r` 可见 `R_X86_64_TPOFF64`）。
- 鸿蒙 libc 是 **musl 系**，**拒绝**在 `dlopen` 进来的库里解析 IE 模型 TLS（glibc 容忍，musl 不容忍）。
- 即 Go issue [#54805](https://github.com/golang/go/issues/54805)；鸿蒙同款见 [sing-box #3681](https://github.com/SagerNet/sing-box/issues/3681)。
- 修复在 Go PR [#75048](https://github.com/golang/go/pull/75048)（新增 `-tls=GD`，amd64/arm64 用 TLSDESC），**未进 Go 1.26.4**（`go tool link` 无 `-tls`）。

### 试过且无效 / 已排除
1. `CGO_CFLAGS` 加 `-ftls-model=global-dynamic`：无效。IE 来自 Go runtime 自身（`runtime.tlsg`），非 C 侧。
2. `GOOS=android` 借用 Android 的 `runtime.tls_g` 全局变量 TLS 方案：编译失败，`gcc_android.c` 需 bionic 的 `android/log.h`（OHOS sysroot 没有）。
3. 移植 Android 的轻量 `tls_g` hack 到 linux：**实测不可行**。Android 靠 bionic 预留的 `TLS_SLOT_APP` 或内联 TSD 槽，用「`pthread_setspecific` 写魔数 + 扫描线程指针固定偏移」定位 g 槽。但：
   - OHOS sysroot **无** `TLS_SLOT_APP` 之类预留槽；
   - 写了个最小 C 程序在设备上实测：`pthread_setspecific` 的值在线程指针 TP 的 `[-512,512]` 偏移内**扫不到**（musl 的 TSD 是独立分配、指针间接，不在 TP 固定偏移处）。
   - 结论：musl 上拿不到「相对 FS 的固定偏移 g 槽」，Android hack 失效。

### 为什么不能像 ohos-rust 那样"零改源码"
Rust 用 LLVM 做后端，LLVM 早已支持 `*-unknown-linux-ohos` 目标（含正确的 TLSDESC/GD TLS 代码生成），所以 "ohos-rust" 只需 target spec + 指定 ohos clang 当 linker，编译器本身不用改。
而 **Go 用自己的编译器/链接器后端（非 LLVM）**，TLS 模型按 GOOS 写死在后端里，没有外部 target spec 开关。要让 Go 输出 TLSDESC，**必须改 Go 源码**。所以"做一个 ohos-go"本质上 = 给 Go 打一次源码补丁做成 fork。

### 最终方案：官方 ohos-go fork（OpenHarmony-SIG/ohos_golang_go）
鸿蒙官方 SIG 已经做了这个 fork（即"ohos-go"），加了 `GOOS=openharmony` 目标并用 **TLSDESC** 解决 TLS。步骤：

```bash
# 1) 克隆并用本机 stock Go 作 bootstrap 构建这套工具链
git clone --depth 1 -b release-branch.go1.24 \
    https://gitcode.com/openharmony-sig/ohos_golang_go  F:/code/2048-go/ohos-go
cd F:/code/2048-go/ohos-go/src
set "GOROOT_BOOTSTRAP=C:\Program Files\Go" && .\make.bat   # 产出 ohos-go\bin\go.exe

# 2) 用 fork 交叉编译（tools/build-go-hos.ps1 已默认指向该 fork）
#    GOROOT=ohos-go  GOOS=openharmony  CC=鸿蒙 clang
& tools\build-go-hos.ps1 -Src ...\cpp\go -Abi arm64-v8a -LibsDir ...\libs\arm64-v8a -HeaderDir ...
```

验证产物已彻底干净（`llvm-readelf`）：
- `-d`：**无 STATIC_TLS 标志**，仅 `NEEDED libc.so`；
- `-r`：TLS 重定位为 **`R_AARCH64_TLSDESC`**（musl 对 dlopen 库完全支持）。

### 重要限制：架构
- 该 fork **只支持 `openharmony/arm64`**（`go tool dist list` 仅列出 arm64）。原因：arm64 用 `MRS TPIDR_EL0` 硬件指令直接读线程指针 + 寄存器存 g，几乎不依赖会触发 IE 重定位的 TLS；而 **amd64 没有空闲寄存器，访问 g 必须走 `FS:偏移` 的 IE/GOT TLS**，正是 musl 拒绝的形态，需要完整 amd64 TLSDESC 移植（上游 PR #75048 未释出）。
- 因此：**真机(arm64) 可直接点亮**；**x86_64 模拟器(amd64) 不被 fork 支持**，且 x86_64 host 也开不出 arm64 模拟器。
- 排查过程中还在设备上实测确认：Android 的"`pthread_setspecific` 写魔数 + 扫描线程指针固定偏移"轻量 hack 在 OHOS musl 上**找不到固定偏移槽**（扫描 TP `[-512,512]` 无果），故 amd64 无捷径。

> 结论：面向 **arm64 真机** 时，本项目 Go→ArkTS→2048 完整链路可用。工程已切到 arm64-v8a 并用 fork 编好 `.so`，连真机 `ark run` 即可。

---

## 8. 目录结构

```
2048-go/
├─ ADAPTATION.md                 # 本文档
├─ tools/
│  └─ build-go-hos.ps1           # Go→鸿蒙交叉编译器（封装器）
└─ Game2048/                     # 鸿蒙工程
   └─ entry/
      ├─ build-profile.json5     # +externalNativeOptions/abiFilters
      ├─ oh-package.json5        # +libentry.so 依赖
      ├─ libs/x86_64/lib2048core.so   # Go 编译产物（打进 HAP）
      └─ src/main/
         ├─ ets/pages/Index.ets  # ArkTS 界面
         └─ cpp/
            ├─ CMakeLists.txt
            ├─ napi_init.cpp     # NAPI 桥
            ├─ golib/lib2048core.h
            ├─ go/               # Go 源码
            │  ├─ go.mod
            │  └─ game2048.go    # 全部游戏逻辑
            └─ types/libentry/   # .d.ts 类型声明
```
