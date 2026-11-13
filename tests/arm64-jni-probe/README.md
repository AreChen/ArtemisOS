# ARM64 JNI 冒烟测试

该测试构建一个只含 `arm64-v8a` 原生库的小型 APK，安装到明确指定的模拟器，启动后调用 JNI 并验证返回值。它用于检查基本的应用级 ARM64 转译，不能代替真实 APP、图形或媒体兼容性测试。

需要 Windows、JDK、Android SDK 的 API 35 平台、Build Tools、NDK 和 `rtk`。默认 SDK 位于 `%LOCALAPPDATA%\Android\Sdk`，也可通过 `-SdkPath` 指定。使用目标模拟器正在连接的 adb；`-AdbPath` 可显式指定。

```powershell
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\arm64-jni-probe\Run-Probe.ps1 -Serial emulator-5582 -AdbPath E:\AndroidOfflineEmu\sdk\platform-tools\adb.exe
```

测试只接受 `emulator-数字` 形式的设备标识，且要求该实例已完成启动。脚本会在该实例安装并保留 `internal.artemis.abilab` 测试应用，产物和测试签名保存在项目的 `build/arm64-jni-probe`，不用于正式发布。请选用独立测试实例；如果安装冲突，脚本会报错，不会自动删除其他应用。
