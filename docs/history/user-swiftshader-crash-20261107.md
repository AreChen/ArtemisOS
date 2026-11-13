# 用户端 SwiftShader 崩溃：2026-11-07

状态：完成报告与随包二进制的只读分析；没有在故障电脑复现，没有修改产品、用户配置或 OTA。

## 资料与版本边界

- 用户报告：`G:\Download\artemis_emulator_crash_analysis_20261107_005427.md`，99 行；其中的 WER、ARTEMIS trace 路径属于故障电脑，在当前开发电脑不存在。
- 故障时间：2026-11-07 00:54:27，北京时间。
- 测试应用：移动爱家，`com.cmri.universalapp`。
- 报告中的 ARTEMIS 2.8.0 是测试工具版本。报告没有给出 ArtemisOS 版本、Emulator 完整构建号、DLL SHA-256、实际分辨率或虚拟内存档位。
- 当前开发电脑的 Emulator 为 37.3.6.0 / build 16696583；不能直接当作故障电脑版本。

## 已有证据

| 项目 | 报告记录 | 能支持的结论 |
| --- | --- | --- |
| Windows 应用错误 | `qemu-system-x86_64.exe`，故障模块 `lib64\gles_swiftshader\libGLESv2.dll`，版本 4.0.0.1 | 宿主 QEMU 进程崩溃，异常位置落在 SwiftShader 软件渲染库 |
| 异常位置 | `0xc0000409`，偏移 `0x15b05d`；WER P9 为 7 | 需要结合二进制、异常参数及调用栈解释；不能仅凭异常码宣称栈溢出、内存泄漏或显卡故障 |
| 应用 ANR | 00:53:16、00:53:33；之后强关并重开应用 | 应用无响应先于宿主崩溃，尚无证据证明两者共用根因 |
| 最后业务操作 | 00:54:15 点击设备唤醒，12 秒后 QEMU 崩溃 | 唤醒、媒体资源重建是值得复测的场景；单次时间相关不证明因果 |
| 自动化结果 | 设备消失、截图失败、重试后受阻、批次暂停 | 符合 QEMU 退出后的连锁表现，不能当成业务断言失败 |

这份报告没有提供显卡驱动 DLL 崩溃的证据。它也没有证明此前硬件渲染下的高提交内存问题已在软件渲染中复现；两次故障需分别归档。

## 新增二进制核对：有条件的机制判断

以下三个文件的 SHA-256 相同：

- `E:\ArtemisOS15\sdk\emulator\lib64\gles_swiftshader\libGLESv2.dll`
- `releases\1.0.0\sdk\emulator\lib64\gles_swiftshader\libGLESv2.dll`
- `releases\1.0.0-sd-fixed\sdk\emulator\lib64\gles_swiftshader\libGLESv2.dll`

大小：7,254,680 字节；SHA-256：

```text
c8f75f46db7bd9b7358e646a36e9181fa0ce77a952ad023059679ae952c4957b
```

使用本机 pefile、Capstone 只读检查 PE 异常表并从函数起始地址反汇编。相关代码：

```text
0x15b058  mov ecx, 7
0x15b05d  int 0x29
```

依据 [Microsoft __fastfail 文档](https://learn.microsoft.com/en-us/cpp/intrinsics/fastfail?view=msvc-170)，x64 的 `int 0x29` 与 RCX 参数对应快速终止请求，产生 `0xc0000409`。

**条件：故障电脑 DLL 必须与上述文件一致。** 若哈希一致，报告的偏移正好落在快速终止指令上，支持软件库进入主动终止路径的解释。报告中的版本号相同仍不足以证明文件完全一致。尚无调用栈，不能确定是谁、因何进入终止路径，也不能据此将原因归为某个着色器函数、内存分配失败或特定 SwiftShader 缺陷。

## 内存判断

- 00:52:31，主机物理内存 15.38 GiB，空闲 1.28 GiB；存在物理内存压力。
- 同时系统提交量 30.86 / 40.38 GiB，距提交上限约 9.52 GiB；该快照不能证明提交内存耗尽。
- 00:54:49，系统提交量为 24.63 GiB。与前一快照相差 6.23 GiB，但两张快照相隔约 2 分 19 秒，不能把全部下降归给 QEMU。
- 缺少 QEMU 进程提交内存连续曲线。报告没有足够证据确认或排除泄漏，物理内存压力也不能直接解释此次快速终止。

## 建议的最小复测

1. 在故障电脑核对 ArtemisOS、Emulator 构建号、启动参数、实际渲染日志、DLL 哈希和分辨率；保留原始 WER 记录。
2. 保存原配置，关闭模拟器，在配置中选择“软件 ANGLE + SwiftShader（备用）”，从**普通启动快捷方式**启动；其余配置、应用版本和用例保持一致。
3. 这仍是软件渲染。Android [官方图形后端文档](https://developer.android.com/studio/run/emulator-acceleration)将 `swangle` 定义为 ANGLE 后端配合 SwiftShader 软件驱动。当前安装中包含 `gles_angle` 所需文件；是否绕开本次故障并保持长时间稳定，仍待故障电脑验证。
4. 不要用“软件渲染”快捷方式做上述对照：`stage/start-software.vbs` 传入固定 `-Graphics swiftshader`，`stage/settings.ps1` 的 `Get-ArtemisGraphics` 会覆盖已保存选择。
5. 执行同一设备唤醒、直播开启/停止及原批次；运行 `tools/diagnostics/start-diagnostics.cmd`，记录故障时间，保留连续 QEMU 私有提交量、系统提交余量与 CPU 指标。分辨率或内存档位如需比较，另开独立对照。
6. 若仍崩溃，需要进一步取得崩溃线程调用栈。现有内存采集器不采集转储；缺少调用栈时，继续猜测具体库缺陷收益有限。转储可能包含应用数据，取得后应先在用户侧分析，避免直接传完整转储。

配置入口及备用后端已经存在；本次不需要为了试用备用后端而先发布 OTA。上述对照尚未执行，不能宣称修复。

## 上游版本核查

2026-11-07 查询 Android [Emulator 37 修复记录](https://developer.android.com/studio/releases/fixed-bugs/emulator/37)：37.3.7、37.3.8 Canary 仅列出一般性修复说明，没有明确列出与此 DLL、偏移或快速终止相匹配的修复。不能据此保证升级即可解决，也没有本次证据支持立即更改全体用户默认后端。
