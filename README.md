# Build golang lib for OpenHarmony OS

最近在研究如何在华为鸿蒙系统上开发app并调用golang编写的lib，找到下面一篇blog，非常详尽的描述了Wingo2048的实现过程，并包含完整的源代码。
- Blog: https://harmonypc.csdn.net/6a3a2d2a10ee7a33f28113d2.html
- Source Code: https://atomgit.com/OpenHarmonyPCDeveloper/ohos_project-wingo2048

然而由于golang的限制，现行的golang版本只支持编译出适配`arm64`架构的lib，而华为DevEco Studio提供的模拟器却又只支持`x86_64`架构, 此项目只能在真机上进行部署测试。

由于手边没有华为鸿蒙真机，于是研究了以下链接，做了一个[golang patch](https://github.com/vangork/go/tree/ohos-musl)以兼容musl libc，生成了适配x86_64的`lib2048core.so`, 目前此project已支持在模拟器中完美运行。
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
