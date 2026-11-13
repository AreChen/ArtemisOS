# Intel 显卡名称识别修复

状态：源码修复、回归和 1.0.8 完整包/OTA 发布完成。1.0.7-r2 历史安装包保持不变，线上 1.0.7 清单已切换为签名升级至 1.0.8。

## 原因

`stage/settings.ps1` 的 `Get-ArtemisIntelVulkanDevice` 要求设备已启用、PCI 厂商为 `8086`，还额外要求名称包含 `HD/UHD/Iris`。`Get-ArtemisGraphicsEnvironment` 再次执行相同名称限制。因此 `Intel Graphics` 在启动模拟器前即被拒绝。新增回归测试先在旧实现上观察到这一错误，再进行修复。

通用硬件 Vulkan 和硬件 OpenGL 路径没有 NVIDIA/AMD 产品名称白名单。前端中的厂商名称匹配只影响状态栏显示，不决定是否允许启动。

## 修改

- Intel 定向选择依据已启用的 PCI `VEN_8086` 设备，不依赖 HD、UHD、Iris、Arc 等名称词。保留名称长度、空白、控制字符及引号校验，以及多个不同 Intel 设备时的明确拒绝。
- 将完整设备名称原样传给 ANGLE；此层不再猜测名称所属厂商，厂商判断由前一步 PCI 检测负责。
- 不依据名称断言核显或独显，配置项改称“Intel 显卡 Vulkan”。Arc 核显/独显都不会仅因名称而被排除；这不等于已验证所有 Arc 驱动的 Vulkan 兼容性。
- 保留运行时组件校验和启动后实际 Vulkan 渲染设备核验，拒绝软件回落或错误设备。保留用户指定的渲染模式，不自动改为软件渲染。

## 验证与限制

Windows PowerShell 5.1 下通过：

- `tests/intel-vulkan-environment.ps1`：新旧名称、任意显示名但真实 Intel PCI 标识、Arc、禁用设备、伪造/错误 PCI 厂商、危险名称、多设备冲突、设备名传递及启动后核验。
- `tests/hardware-vulkan-environment.ps1`：Intel Graphics、Arc、NVIDIA GeForce/RTX/Quadro 和 AMD Radeon 名称样本，以及实际渲染报告中的软件回落拒绝。
- `tests/modern-vulkan-environment.ps1`：软件渲染隔离和已有组件失败保护。
- `tests/frontend-launch-lifecycle.ps1`：启动/初始化成功与失败、前端交接及签名更新回归。

本机 CIM 实际选中 `Intel(R) UHD Graphics 770`，生成 ANGLE Vulkan 环境成功，未改动运行中实例。上述新型号由可控输入覆盖，并非在对应实物显卡上实测。

Windows 设备名称与 Vulkan 驱动名称若不同，现有启动后精确匹配仍可能拒绝；本次没有放宽该检查或声称已解决这一独立问题。驱动无 Vulkan 支持、多块 Intel 设备无法唯一选择，也仍需用户选择其他渲染模式。

后续发布须分配新产品版本并生成签名 OTA；不得覆盖不可变的 1.0.7-r2 已发布产物或沿用旧 SHA256。
