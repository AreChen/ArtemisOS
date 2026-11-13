# 雷电 14 与 ArtemisOS：镜像体积、可观察内容和测试画像

调查日期：2026-10-31。本文用于确定后续研究方向，不是产品性能排名。数据采集限于本机文件元数据、VDI 头部和 Android 系统包等只读查询；曾临时启动并关闭原有雷电实例，并为排除端口冲突暂时关闭、恢复原先正在运行的 ArtemisOS。雷电已恢复为原先的关闭状态，ArtemisOS 已按原 AVD、参数和端口恢复运行并确认启动完成。模拟器的正常启动可能更新运行数据；未提取、复制或替换商业镜像、程序和翻译库，也未读取个人应用数据。前一轮运行观察见[系统参数对比与镜像实验](../history/系统参数对比与镜像实验-20261031.md)和[图形渲染、分辨率与传感器](../history/图形渲染分辨率与传感器-20261031.md)。

## 可以确定什么

本机注册的雷电是 **14.0.32.1**，厂商标注 ChangZhi Co., Ltd.；注册卸载程序位于 `E:\leidian\LDPlayer14`。项目的最新本地安装包为 **ArtemisOS 15 0.3.4 精简版**。两者未使用相同 Android 版本、磁盘格式、编译配置和交付内容，不能按一个数字断定哪一方的 Android 源码或实际运行性能更好。

| 指标 | 雷电 14 | ArtemisOS 15 | 可比性与证据 |
| --- | ---: | ---: | --- |
| 本地安装包字节数 | 744,719,848 B，约 710.22 MiB | 1,563,813,636 B，约 1,491.37 MiB | 各自 Windows `.exe` 文件长度，差约 781.15 MiB；未逐项验证雷电安装程序全部资源是否离线包含，不能直接归因于镜像。 |
| 已安装系统镜像文件长度 | `system.vdi`：1,957,691,392 B，约 1,867 MiB | 精简版 `system.img`：3,576,692,736 B，约 3,411 MiB | VDI 动态分配容器与原始磁盘格式不同，文件长度不等于客体已用容量或分区实际内容；两者镜像包含的分区也未证实相同。 |
| 虚拟磁盘容量 | VDI 头声明 2,697,942,016 B，约 2,572.96 MiB | 原始镜像文件长度为 3,576,692,736 B | 格式不同，只是各自虚拟磁盘容量/文件长度，不代表真实磁盘块占用或安装包的压缩大小。 |
| Android / API | 本轮实例报告 Android 14 / API 34 | 本轮当前已安装实例报告 Android 15 / API 35 | 版本不同会影响框架、权限、应用兼容性和镜像规模。 |
| ABI | 前一轮实例报告 `x86_64, arm64-v8a, x86, armeabi-v7a, armeabi` | 当前已安装实例报告 `x86_64, arm64-v8a` | ABI 声明不等于所有 APK 都可执行；两者底层 ARM 转译实现、授权和兼容性需分别验证。 |
| 图形 | 前一轮实例报告 Adreno、OpenGL ES 3.1 | 前一轮实例报告 Android Emulator OpenGL ES Translator、OpenGL ES 3.1 | 系统报告字符串并不证明物理 GPU 型号、驱动实现或性能。 |
| 虚拟 CPU、内存、屏幕 | 前一轮为 6 核、约 5.8 GiB 可见内存、1920×1080 / 280 dpi | 前一轮为 4 核、约 3.8 GiB 可见内存、720×1600 / 320 dpi | 两台实例负载和配置不同，不能比较启动速度或资源效率；这些是之前实例配置，不是软件最低要求。 |

VDI 头部前 392 B 的只读解析结果：签名 `0xBEDA107F`、版本 `0x00010001`、镜像类型 `1`、块大小 1,048,576 B、可寻址块 2,573、标记已分配块 1,865。[QEMU 的 VDI 驱动源码](https://github.com/qemu/qemu/blob/master/block/vdi.c)将类型 1 定义为动态镜像，字段按小端读取；本地观察与其结构一致。该镜像文件会将未分配块与文件长度区别开：**1,867 MiB 文件不表示虚拟盘总容量只有 1,867 MiB，也不能据此算出系统应用合计大小。**[VirtualBox 官方手册](https://download.virtualbox.org/virtualbox/7.1.6/UserManual.pdf)对动态分配文件的增长行为有一般性说明；不能仅凭该格式推断雷电虚拟机底层实现、所有镜像的分配模式或性能。

本机只读复测 VDI 1.1 头部的方式如下，仅输出格式字段，不读取或解析虚拟磁盘中的 Android 文件：

```powershell
$imagePath = 'E:\leidian\LDPlayer14\system.vdi'
$stream = [IO.File]::Open($imagePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
try {
    $header = New-Object byte[] 392
    if ($stream.Read($header, 0, $header.Length) -ne $header.Length) { throw 'VDI header too short' }
    if ([BitConverter]::ToUInt32($header, 64) -ne [Convert]::ToUInt32('BEDA107F', 16) -or
        [BitConverter]::ToUInt32($header, 68) -ne 0x00010001) { throw 'Not the expected VDI 1.1 format' }
    [pscustomobject]@{
        ImageType = [BitConverter]::ToUInt32($header, 76)
        VirtualDiskBytes = [BitConverter]::ToUInt64($header, 368)
        BlockSize = [BitConverter]::ToUInt32($header, 376)
        BlocksTotal = [BitConverter]::ToUInt32($header, 384)
        BlocksAllocated = [BitConverter]::ToUInt32($header, 388)
    }
} finally { $stream.Dispose() }
```

本项目已经完成的可复现精简是另一件可明确量化的事：原完整安装包 1,928,754,435 B，0.3.4 精简包 1,563,813,636 B，减少 364,940,799 B（约 348 MiB）；新装镜像移除了 Drive、Gmail、Maps、YouTube、YouTube Music 和 Photos，并裁去宿主端不用的非 x86_64 QEMU 程序；ARM64 翻译基础测试通过。详见[0.3.4 验证记录](../history/release-0.3.4-validation.md)。其 `system.img` 的文件长度仍保持 3,576,692,736 B，因此包大小下降不能直接等同安装后文件长度同幅下降。

## 现有实例系统包的实测差异

本次各对一个**已有实例**运行 `pm list packages -s`，规范化去重后得到雷电 **96** 个、当前 ArtemisOS **241** 个系统包名；其中同名 **55** 个，雷电侧独有 **41** 个、ArtemisOS 侧独有 **186** 个。数字含服务、资源覆盖等，不等于可见 APP 数量，也不能量化体积、运行性能或“删掉了多少”。不同 Android 版本和 Google/AOSP 系统组件命名差异，会使同类组件被算作两个不同包；同名亦不保证实现和版本相同。

可复核的规范化系统包名记录：[雷电 Android 14](evidence/ldplayer-14-android14-system-packages-20261031.txt)、[当前 ArtemisOS Android 15](evidence/artemisos-current-android15-system-packages-20261031.txt)。文件仅含本轮 `-s` 输出中的包名，不含设备标识、个人应用数据或运行日志；不保证其他实例、版本或用户具有相同结果。

**采集的 ArtemisOS 是本机现有运行实例，仍列出了完整镜像里的 Gmail、Drive 等应用，不能将其作为 0.3.4 全新精简安装的包清单。**[0.3.4 验证记录](../history/release-0.3.4-validation.md)另行确认该版本全新安装镜像移除了六个 Google 可选应用；本轮没有重启那个独立验证实例。以下“列出/未列出”只指本次指定实例、默认用户的 `pm list packages -s` 输出，并非断言软件一定不存在于所有分区、其他用户或普通用户应用中，也不证明功能正常。

| 代表性包名或类别 | 雷电 14 系统包输出 | 当前 ArtemisOS 15 系统包输出 | 本次可确认的内容 |
| --- | --- | --- | --- |
| `com.google.android.gm`、`com.google.android.apps.docs`、`com.google.android.apps.maps` | 均未列出 | 均列出 | 分别是常见 Gmail、Drive、Maps 包名；此对比不证明雷电从什么基线中删除了它们。 |
| `com.google.android.youtube`、`com.google.android.apps.youtube.music`、`com.google.android.apps.photos` | 均未列出 | 均列出 | 对应常见 YouTube、YouTube Music 和 Photos 包名；不是全部版本和实例的安装结论。 |
| `com.google.android.gms`、`com.google.android.gsf`、`com.android.vending` | 均未列出 | 均列出 | 这三个包名的输出状态有差异；不能据此断定所有 Google 服务能力或兼容性。 |
| `com.google.android.webview` | 列出 | 列出 | 两个系统包列表均含此包名，不能仅靠包名认定版本或网页兼容性相同。 |
| `com.android.phone`、`com.android.settings`、`com.android.systemui` | 均列出 | 均列出 | 都列出了这些基础系统包名；不能单靠包名判断电话、设置和界面功能完整性。 |
| `com.android.browser`、`com.android.gallery3d`、`com.android.inputmethod.pinyin` | 均列出 | 均未列出 | 只记录包名与输出差异，功能实现和替代关系需进一步测试。 |
| `com.android.networkstack` / `com.google.android.networkstack` | 前者列出，后者未列出 | 前者未列出，后者列出 | 展示系统组件不同命名；不能以不同包名直接推断某一方删除了网络能力。 |
| `com.android.internal.emulation.pixel_*`、`com.android.systemui.emulation.pixel_*` | 未列出匹配包 | 分别列出 23、22 个匹配包 | 当前 ArtemisOS 中有 45 个与 Pixel 仿真相关的包名；资源大小、依赖和能否安全移除均待测。 |

获取证据时先记录原运行状态。雷电 0 号实例与 Android Emulator 首个实例发生了 ADB 端口冲突：同时运行时雷电官方 `ldconsole adb --index 0` 返回的其实是 ArtemisOS Android 15。为避免串台，本次先只读采集 ArtemisOS，退出两个实例后启动雷电，**核对 `ro.build.version.release=14` 和 `ro.build.version.sdk=34`**，再采集其系统包。完成后退出雷电，以原启动参数恢复 ArtemisOS 并确认 Android 15 启动完成。没有把首次误指向 ArtemisOS 的输出作为雷电数据。雷电官方 [ADB 使用指南](https://help.ldmnq.com/docs/lei-dian-mo-ni-qi-ADB-ming-ling-shi-yong-shuo-ming/800187326)也提示其不同版本的 0 号实例可能因端口竞争导致后启动者不可见；本机与 ArtemisOS 的冲突是另一次实测，不能将厂商的同产品提示外推为所有端口问题的根因。

## 不能从这些数据推出的结论

1. 没有雷电的原始产品配置、构建清单及其对应未修改镜像，无法证明它从某个基线“删除了哪些包”；不同 Android 版本的系统包差异也不等于删除清单。
2. 本轮系统包输出不能证明某包从镜像物理删除，也没有按分区或 APK 大小统计；先前 ABI 等信息是同日另一轮的运行观察，不能假定为每一份雷电安装的固定结果。
3. 动态 VDI、文件系统空白区域、分区大小、压缩算法、是否下载额外资源、安装程序内容及 Android 版本都可能影响体积；这些机制各自对差距的贡献尚未量化。
4. 已声明 NFC、计步不等于对应服务或传感器可工作。前一轮实例中没有发现匹配的计步传感器或 NFC 服务，不能把声明复制到产品当作能力已实现。
5. 小安装包不自动意味着内存更少、启动更快、兼容性更好；也不代表可直接复用雷电的专有程序、镜像或翻译库。

## 后续只读对比方法

如果需要进一步回答“全新安装时实际列出什么”，应先由操作者准备各自的**全新、无个人数据**测试实例，确认 Android 版本与 ADB 端点的对应关系。注意同机运行可能出现 5555 端口冲突，实例序号或 `emulator-5554` 本身不足以确认产品身份；避免冲突，重新确认设备归属后再采集。以下示例适用于本机 Windows 和对应已运行实例，先替换两个经过确认的目标占位符，禁止复用其他用户实例：

```powershell
$adbExe = '<本项目实际安装目录中的 adb.exe 完整路径>'
$ldTarget = '<经确认的雷电测试实例 ADB 目标>'
$artemisTarget = '<经确认的 ArtemisOS 测试实例 ADB 目标>'
rtk proxy $adbExe -s $ldTarget shell getprop ro.build.version.release
rtk proxy $adbExe -s $ldTarget shell getprop ro.build.version.sdk
$ldPackageOutput = @(rtk proxy $adbExe -s $ldTarget shell pm list packages -s)
rtk proxy $adbExe -s $ldTarget shell df -h /system /vendor /product
rtk proxy $adbExe -s $artemisTarget shell getprop ro.build.version.release
rtk proxy $adbExe -s $artemisTarget shell getprop ro.build.version.sdk
$artemisPackageOutput = @(rtk proxy $adbExe -s $artemisTarget shell pm list packages -s)
rtk proxy $adbExe -s $artemisTarget shell df -h /system /vendor /product
```

将两个系统包列表规范化排序后比较“只存在于 A / B / 两边都有”，再对候选应用以 `pm path <包名>` 确认分区与是否被数据分区更新覆盖。此表只能回答**两次运行时包集合的差别**；要推断某产品具体删了什么，还要有该产品同一构建版本的源配置、发行清单与可信基线。不同动态分区实现可能使 `df` 的挂载点或结果不同；不应把 `df` 输出直接当作镜像压缩大小。避免采集手机号、账号、IMEI、SIM 信息、Android ID、MAC 或 USB 设备序列号。

本次统计对采集到的两组输出使用以下规范化方法；需要分时运行实例时，可在同一 PowerShell 会话中先保存第一组变量，再切换经核验的目标采集第二组：

```powershell
$ldNames = @($ldPackageOutput | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^package:[A-Za-z0-9._]+$' } | ForEach-Object { $_.Substring(8) } | Sort-Object -Unique)
$artemisNames = @($artemisPackageOutput | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^package:[A-Za-z0-9._]+$' } | ForEach-Object { $_.Substring(8) } | Sort-Object -Unique)
[pscustomobject]@{
    LD = $ldNames.Count
    Artemis = $artemisNames.Count
    Common = @($ldNames | Where-Object { $_ -in $artemisNames }).Count
    LDOnly = @($ldNames | Where-Object { $_ -notin $artemisNames }).Count
    ArtemisOnly = @($artemisNames | Where-Object { $_ -notin $ldNames }).Count
}
```

若测性能，应先统一 CPU 核数、虚拟 RAM、分辨率、dpi、刷新率、图形后端、网络和快照/冷启动策略，并使用同一可合法分发的测试 APK；记录宿主机型、系统、虚拟化、GPU、驱动、系统版本、冷/热启动、空闲和运行中 CPU、内存、磁盘及帧时间。分别在 8 GiB 笔记本、集显和软件渲染配置实测，重复测试并报告失败样本。不同 API 级别仍是控制不了的变量；不要把一个游戏结果外推为一般 APP 测试的兼容性。

可借鉴的是**产品方法**：依据 APK 依赖和测试场景制定镜像软件清单，分析并移除经验证的非必需组件；区分系统只读基线与实例可写数据，评估稀疏/动态分配和压缩交付；对仅用于 APP 测试的运行模式测量较低分辨率、帧率和后台负载的实际效果；保留各功能的可观测性和独立回滚。每项都必须在我们自己的镜像、运行时和目标机器上独立验证，并确认相关许可及第三方应用依赖。

## 手机测试画像建议

以 Android 15 作为现有产品的初始测试基线，预设 720p 和更高分辨率、不同显示密度，必要时再加入其他 Android 系统版本进行覆盖。调整屏幕或型号名称不能更改实际系统 API 版本；不同版本需要对应版本的镜像。设备显示名称和外观配置不代表已实现真实手机的传感器、拍照、蜂窝网络或 ARM 应用兼容性；按测试需要记录功能和结果，不采集稳定硬件身份。

## 来源条目

| 标题及链接 | 维护者 / 类型 / 版本 | 构建环境与运行环境 | 解决问题与关键结论 | 限制和验证状态 |
| --- | --- | --- | --- | --- |
| [雷电 14 常见问题](https://help.ldmnq.com/docs/FAQ-lei-dian-14-yun-xing-chang-jian-wen-ti) | 雷电官方；产品 FAQ；页面未锁定补丁版本，2026-10-31 查阅 | 非构建文档；Windows 上雷电 14 | 厂商介绍雷电 14 为 Android 14，FAQ 说 Win7 不受支持，且可与雷电 9 分别安装。 | 官方产品说明，不给完整镜像清单、最低硬件矩阵或独立性能测试。 |
| [雷电版本历史](https://www.ldmnq.com/other/version-history-and-release-notes.html) | 雷电官方；版本历史页；2026-10-31 查阅 | 不描述构建环境；Windows 客户端 | 用于查找厂商发布说明与版本信息。 | 页面动态加载、内容可能变化；本研究未保存接口响应或固定版本快照，不以其具体补丁条目证明性能。 |
| [ldconsole 开发者使用说明](https://help.ldmnq.com/docs/LDPlayer-ming-ling-hang-kai-fa-zhe-shi-yong-shuo-ming/n) | 雷电官方；命令行文档；页面称支持雷电 14、9 | 非构建文档；原生 Windows `ldconsole.exe` 控制已安装的雷电实例 | 产品提供按索引管理实例、启动停止、设备动作、应用和 ADB 接入的接口，可启发我们设计实例管理契约。 | 本轮实际执行了实例状态、启动、退出及 ADB 查询；其他命令未逐项验证，部分条目标为暂不可用。这不是 ArtemisOS 的实现或许可。 |
| [雷电 ADB 命令使用说明](https://help.ldmnq.com/docs/lei-dian-mo-ni-qi-ADB-ming-ling-shi-yong-shuo-ming/800187326) | 雷电官方；开发者指南；页面称 2026-09-03 更新，面向雷电实例 | 非构建文档；Windows 上雷电及本机 ADB | 给出系统包查询、明确目标的方法，提示雷电 9 与 14 的 0 号实例可能竞争 5555 端口。 | 这是厂商对自身产品的说明，端口复用与产品归属需逐次实测；本轮另外确认雷电与 ArtemisOS 存在类似冲突，不代表所有机器均如此。 |
| [QEMU VDI 镜像驱动](https://github.com/qemu/qemu/blob/master/block/vdi.c) | QEMU 维护者；上游源码，`master`，2026-10-31 查阅 | QEMU 可在多平台构建；此处只用文件格式解析，与将雷电作为运行时无关 | 提供 VDI 头字段、小端转换及 `VDI_TYPE_DYNAMIC=1` 的定义；据此解释本机读取到的 VDI 头。 | 这是标准格式的源码依据；不能推断雷电的具体构建流程、修改清单或许可。 |
| [VirtualBox 7.1 用户手册](https://download.virtualbox.org/virtualbox/7.1.6/UserManual.pdf) | Oracle；官方用户手册；7.1.6 | 多平台虚拟机产品文档；与本机选型无关 | 解释动态分配与固定大小镜像文件的常见区别。 | 通用文件格式背景，并非雷电厂商对其分区或压缩实现的披露。 |
| [本项目 0.3.4 发行验证](../history/release-0.3.4-validation.md) | ArtemisOS 项目；本地验证记录；0.3.4 | 现有镜像实验使用开发环境；交付包运行在 Windows 本机 | 记录包体、被移除应用、ARM64 基础用例、新装与旧版升级验证。 | 实验性定制镜像不等于源码构建或所有应用兼容；不是低端笔记本性能报告。 |
