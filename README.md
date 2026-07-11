# Build golang lib for OpenHarmony OS

目前在研究如何在华为鸿蒙系统上使用golang编写的lib，学习到下面的Blog实现的Wingo2048，非常详尽。
Blog: https://harmonypc.csdn.net/6a3a2d2a10ee7a33f28113d2.html
Source Code: https://atomgit.com/OpenHarmonyPCDeveloper/ohos_project-wingo2048

由于手边没有华为鸿蒙真机，而华为DevEco Studio提供的模拟器却又只支持`x86_64`ABI。

于是研究了已下链接，patch了golang兼容了musl libc，生成了适配x86_64的`lib2048core.so`, 目前此project已支持在模拟器中完美运行。
1. https://gitcode.com/openharmony-sig/ohos_golang_go
2. https://gitcode.com/lycodestore1/thirdpartydocs/wiki/go%E5%BA%94%E7%94%A8%E9%80%82%E9%85%8D%E9%B8%BF%E8%92%99PC%E6%8C%87%E5%8D%97.md
3. https://github.com/golang/go/pull/75048


### For development

1. ABI 和 triple 的对应关系:
| ABI | GOARCH | clang target triple |
|---|---|---|
| arm64-v8a | arm64 | aarch64-linux-ohos |
| armeabi-v7a | arm | arm-linux-ohos |
| x86_64 | amd64 | x86_64-linux-ohos |

2. To build on Windows with `cmd`, set the environment variables as following(change the SDK PATH accordingly):
   ```
   set CGO_ENABLED=1
   set CC=C:\OHOS\Sdk\23\native\llvm\bin\clang.exe
   set CGO_CFLAGS=-target x86_64-linux-ohos --sysroot=C:/OHOS/Sdk/23/native/sysroot -D__MUSL__
   set CXX=C:\OHOS\Sdk\23\native\llvm\bin\clang++.exe
   set CGO_CXXFLAGS=-target x86_64-linux-ohos --sysroot=C:/OHOS/Sdk/23/native/sysroot -D__MUSL__
   set CGO_LDFLAGS=-target x86_64-linux-ohos --sysroot=C:/OHOS/Sdk/23/native/sysroot
   ```

   Then build:
   ```
   set GOOS=openharmony
   go build -buildmode=c-shared -trimpath -o lib2048core_amd64.so .
   ```
