# 1.0.6 显示运行时第三方分发记录

核查日期：2026-11-12。范围限于新增 scrcpy 显示运行时；不代表对既有 SDK、AOSP 或整套安装器作许可审计。

## 已冻结的交付物

- `stage/update/frontend/third-party/`：59 文件，470,400 bytes。完整许可、通知、实际构建证据、原始构建脚本及逐文件 SHA-256。不含大型源码归档。
- `third-party/scrcpy-4.1/dist/ArtemisOS15-Display-Sources-1.0.6.zip`：32,253,040 bytes；SHA-256 `5f323434aad8d3343485f8cc587cf39cfff472ea6a1e87ccfcd03b3205875ca8`。
- 公开相对路径：`sources/ArtemisOS15-Display-Sources-1.0.6.zip`。与 1.0.5 相同的公开分发 share，完整下载地址：<https://cloudx.playones.com/sd/YCsIY2UB/sources/ArtemisOS15-Display-Sources-1.0.6.zip?d>。
- `tools/Prepare-FrontendRuntime.ps1` 只按 manifest 复制轻量材料，验证独立源码 ZIP 的大小及校验和，不向 OTA 或普通安装目录复制 `source-archives/`、`dist/`。

源码 ZIP 已由发布流程上传。本次使用上述公开 URL 匿名完整下载，实际读回 32,253,040 bytes，SHA-256 与上述值完全一致；`sources.json` 已记为 `publicAvailabilityVerified=true`。本地 ZIP 也恢复为这一已公开文件的完全相同字节。该来源先于完整安装包及 OTA 公开，发布后应持续保留等价访问。

最终客户端额外补入 FFmpeg `libavutil/x86/x86inc.asm` 的原始 ISC 版权、许可和免责声明；完整源码 ZIP 内本来已经含有该原文，因此不改变已公开 ZIP。相对首次冻结，仅 `FFmpeg-permissive-notices.txt` 和 `sources.json` 有变化；源码包内部 manifest 从已公开 ZIP 原样恢复。

| 最终 stage 文件 | SHA-256 |
| --- | --- |
| `FFmpeg-permissive-notices.txt` | `6ff8f7d5e7a0e710f7559702386958220a5d6ed237706c62c4b4f381ec2e2717` |
| `sources.json` | `8a7d897f32cae63ec989d3fe0079180dffe417e1b653d57208d2a8f996f403af` |
| `source-package-manifest.json`（描述原始公开源码 ZIP） | `ede280e8cd6fc1e24436a489f89cbc61f5d0a1d4117bd834931efd89b702b4d6` |

## 实际二进制及构建证据

独立下载的[官方 scrcpy 4.1 Windows x64 发布包](https://github.com/Genymobile/scrcpy/releases/tag/v4.1) SHA-256 为 `5b12172b3264b2889f4583ee64752ce832e29bc8b1089dca81093459697165db`，与 GitHub 资产 digest、官方校验文件一致。所有 10 个复制的二进制、许可和原始图片条目与 WinGet 缓存逐一相同；未重编译或修改上游运行时。官方 ZIP 的 ADB 未被复制，前端沿用已有 SDK ADB。

实际[官方构建 run](https://github.com/Genymobile/scrcpy/actions/runs/29188298263) 使用 commit `fa57d7c6b47139797a8e103f87719740718887d4`；最终 v4.1 tag 指向 `2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0`。两份完整源码均已归档。两者差异仅为版本文档、发布链接和校验和；客户端、服务端、依赖配方和 workflow 未变化。对应 API 元数据、比较结果、官方校验文件及实际 DLL 识别字符串均保存在轻量 `evidence/`。

| 实际组件 | 版本及许可 | 已提供材料 |
| --- | --- | --- |
| scrcpy 客户端及 Android server | 4.1，Apache-2.0 | 实际构建 commit 和最终 tag 的完整源码、完整许可、发布构建脚本 |
| FFmpeg shared DLLs | 8.1.2，LGPL-2.1-or-later | 完整 8.1.2 源码，原始交叉构建配方、完整 LGPL 和源码许可说明 |
| libusb shared DLL | 1.0.30，LGPL-2.1-or-later | 完整源码、原始构建配方、完整 LGPL |
| SDL shared DLL | 3.4.12，zlib | 完整源码和许可；保留 HIDAPI BSD 选择及原始选择通知、yuv2rgb 和其他 permissive 注释通知 |
| dav1d，静态进入 FFmpeg | 1.5.3，BSD-2-Clause | 完整源码、原始构建配方、完整版权及许可 |
| zlib，静态进入 FFmpeg | 1.3.1，zlib | 完整源码及许可；实际 DLL 含 inflate 1.3.1 标识 |
| MinGW/GCC 运行时支持 | 实际字符串 GCC 13-win32 | MinGW-w64 原始版权/许可/免责声明及 GCC GPLv3、Runtime Library Exception 3.1 全文 |

实际 FFmpeg configuration 含 `--enable-shared`、`--disable-static`、`--enable-libdav1d`、`--enable-zlib`，未开启 `--enable-gpl` 或 `--enable-nonfree`，DLL 自报 LGPL 2.1 或更新版本。dav1d 的原始配方即使最后参数为 shared 仍生成静态库。对应源码配方无 ArtemisOS 补丁；四个直接依赖源码包均与原始配方 SHA-256 一致。

MinGW/zlib 的精确 Ubuntu 软件包修订号和原 runner 镜像未从资产中取得；没有声称位级可复现。MinGW 原始通知取自上游 v12.0.0，GCC 许可及 exception 取自 13.3.0，精确来源记录于 manifest。系统编译工具与完整 LGPL 库源码交付是不同范围。保留了官方 OpenPGP detached signature，但未独立验证签名，不作已验证声明。

## 对应源码的独立下载方式

[LGPL 2.1 第 4 节和第 6(d) 节](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html) 的同一指定位置等价源码访问方式允许把源码作为可选下载：二进制取得处必须同样提供完整对应源码的等价访问，用户无需强制下载源码。这里采用同一公开 share 同时分发；不以仅给上游链接、未上传的本地 ZIP 或三年书面提供承诺替代实际源码可用性。

客户端保留完整许可和通知、源码地址、manifest、原始构建脚本与校验和。与它们同址的独立源码 ZIP 提供上述全部源码归档、构建资料和其内部 manifest。共享 DLL 可被兼容的用户修改版本替换；ArtemisOS 没有对其增加运行时 hash 锁，并明确允许为调试 LGPL 修改而进行逆向工程。scrcpy 自身的完整 Apache 源码也已提供，可以重编译/重新链接。原生 Shell 通过进程、ADB 和窗口管理与 scrcpy 通信，没有链接这些 LGPL DLL。

未发现要求每位 OTA 用户强制取得所有大型源码归档的条款；必须随客户端保留的完整许可、版权及免责声明均已作为轻量材料打包。BSD/MIT 类源码内嵌通知另作保守的超集保留，包含未编译平台代码。源 ZIP 应保持公开可取，访问条件不得比二进制更严格。

## 已执行验证

- 官方 ZIP 全包 digest、全部复制条目的独立字节身份核对。
- 四个原始依赖配方与缓存源码归档 SHA-256 核对。
- 首次冻结（即最终保持公开）的源 ZIP 每个源码及轻量条目的解压流 SHA-256 与内部 manifest 核对。
- 59 个 stage 通知材料逐文件读回，与最终 manifest 来源逐字节核对。
- `Prepare-FrontendRuntime.ps1` PowerShell AST 语法校验通过；独立 source bundle 生成器在 Windows PowerShell 成功执行。
- 同一公开 source URL 的匿名完整读回 hash 通过；最终客户端通知和逐文件 manifest 再次读回全部通过。

未运行或修改本机 Android/GUI；未执行下载所得上游 shell 构建脚本；未重新下载 SDK/AOSP。
