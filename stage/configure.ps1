param(
    [ValidateSet('low', 'medium', 'high')][string]$SetProfile,
    [ValidateSet('0', '1')][string]$SetCleanup,
    [ValidateSet('0', '1')][string]$SetVideoCompat,
    [ValidateSet('mobile', 'telecom', 'unicom')][string]$SetCarrier,
    [ValidateSet('auto', 'host', 'vulkan', 'vulkan_intel', 'vulkan_amd', 'software', 'swiftshader', 'swangle', 'lavapipe')][string]$SetGraphics,
    [AllowEmptyString()][string]$SetGraphicsDevice,
    [ValidateSet('720p', '900p', '1080p', '720x1280', '1080x1920', '1280x720', '1920x1080')][string]$SetResolution,
    [ValidateSet('artemis', 'native')][string]$SetFrontend,
    [switch]$NoGui
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'settings.ps1')
$preferences = Get-ArtemisPreferences

if ($NoGui) {
    if ($SetProfile) { $preferences.Profile = $SetProfile }
    if ($SetCleanup) { $preferences.Cleanup = $SetCleanup }
    if ($SetVideoCompat) { $preferences.VideoCompat = $SetVideoCompat }
    if ($SetCarrier) { $preferences.Carrier = $SetCarrier }
    if ($SetGraphics) {
        if ($preferences.Graphics -ne $SetGraphics) { $preferences.GraphicsDevice = '' }
        $preferences.Graphics = $SetGraphics
    }
    if ($PSBoundParameters.ContainsKey('SetGraphicsDevice')) { $preferences.GraphicsDevice = $SetGraphicsDevice }
    if ($SetResolution) { $preferences.Resolution = $SetResolution }
    if ($SetFrontend) { $preferences.Frontend = $SetFrontend }
    Write-ArtemisPreferences $preferences.Profile $preferences.Cleanup $preferences.VideoCompat $preferences.Carrier $preferences.Graphics $preferences.Resolution $preferences.Frontend $preferences.GraphicsDevice
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = 'ArtemisOS 15 - 配置'
$form.ClientSize = New-Object Drawing.Size(620, 686)
$form.AutoScroll = $true
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9.5)
$iconPath = Join-Path $PSScriptRoot 'ArtemisOS15.ico'
if (Test-Path -LiteralPath $iconPath -PathType Leaf) { $form.Icon = New-Object Drawing.Icon($iconPath) }

$heading = New-Object Windows.Forms.Label
$heading.Location = New-Object Drawing.Point(20, 16)
$heading.Size = New-Object Drawing.Size(580, 28)
$heading.Text = '选择模拟器配置'
$heading.Font = New-Object Drawing.Font('Microsoft YaHei UI', 12, [Drawing.FontStyle]::Bold)
$form.Controls.Add($heading)

$group = New-Object Windows.Forms.GroupBox
$group.Location = New-Object Drawing.Point(20, 48)
$group.Size = New-Object Drawing.Size(580, 155)
$group.Text = '虚拟 CPU 和内存'
$form.Controls.Add($group)

$profiles = @(
    @{ Key = 'low'; Text = '低：2 核 / 2.5 GB；建议电脑内存至少 8 GB' },
    @{ Key = 'medium'; Text = '中：4 核 / 4 GB；建议电脑内存至少 16 GB' },
    @{ Key = 'high'; Text = '高：6 核 / 8 GB；建议电脑内存至少 16 GB' }
)
$buttons = @{}
for ($i = 0; $i -lt $profiles.Count; $i++) {
    $radio = New-Object Windows.Forms.RadioButton
    $radio.Location = New-Object Drawing.Point(20, (28 + 36 * $i))
    $radio.Size = New-Object Drawing.Size(535, 28)
    $radio.Text = $profiles[$i].Text
    $radio.Checked = ($preferences.Profile -eq $profiles[$i].Key)
    $group.Controls.Add($radio)
    $buttons[$profiles[$i].Key] = $radio
}

$cleanup = New-Object Windows.Forms.CheckBox
$cleanup.Location = New-Object Drawing.Point(23, 218)
$cleanup.Size = New-Object Drawing.Size(575, 28)
$cleanup.Text = '停用可选的 Google 预装应用（如镜像内存在）'
$cleanup.Checked = ($preferences.Cleanup -eq '1')
$form.Controls.Add($cleanup)

$videoCompat = New-Object Windows.Forms.CheckBox
$videoCompat.Location = New-Object Drawing.Point(23, 250)
$videoCompat.Size = New-Object Drawing.Size(575, 28)
$videoCompat.Text = '视频兼容模式（软件解码，改善部分摄像头播放；可能增加 CPU 占用）'
$videoCompat.Checked = ($preferences.VideoCompat -eq '1')
$form.Controls.Add($videoCompat)

$carrierLabel = New-Object Windows.Forms.Label
$carrierLabel.Location = New-Object Drawing.Point(23, 290)
$carrierLabel.Size = New-Object Drawing.Size(115, 28)
$carrierLabel.Text = '模拟运营商：'
$form.Controls.Add($carrierLabel)

$carriers = @(
    @{ Key = 'mobile'; Text = '中国移动（LTE）' },
    @{ Key = 'telecom'; Text = '中国电信（LTE）' },
    @{ Key = 'unicom'; Text = '中国联通（LTE）' }
)
$carrier = New-Object Windows.Forms.ComboBox
$carrier.Location = New-Object Drawing.Point(140, 286)
$carrier.Size = New-Object Drawing.Size(210, 28)
$carrier.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($item in $carriers) { [void]$carrier.Items.Add($item.Text) }
for ($i = 0; $i -lt $carriers.Count; $i++) {
    if ($carriers[$i].Key -eq $preferences.Carrier) { $carrier.SelectedIndex = $i; break }
}
$form.Controls.Add($carrier)

$graphicsLabel = New-Object Windows.Forms.Label
$graphicsLabel.Location = New-Object Drawing.Point(23, 329)
$graphicsLabel.Size = New-Object Drawing.Size(115, 28)
$graphicsLabel.Text = '图形渲染：'
$form.Controls.Add($graphicsLabel)

$graphicsModes = @(
    @{ Key = 'auto'; Text = '自动选择（根据电脑和驱动选择）' },
    @{ Key = 'host'; Text = '硬件 OpenGL（默认，依赖显卡驱动）' },
    @{ Key = 'vulkan'; Text = '硬件 Vulkan（ANGLE，实验，仅 OpenGL ES）' },
    @{ Key = 'vulkan_intel'; Text = 'Intel 显卡 Vulkan（按 PCI 厂商识别，实验）' },
    @{ Key = 'vulkan_amd'; Text = 'AMD 显卡 Vulkan（集显 / 独显，实验）' },
    @{ Key = 'software'; Text = '软件自动（兼容优先，CPU 占用较高）' },
    @{ Key = 'swiftshader'; Text = '软件 SwiftShader（Vulkan，CPU 渲染）' },
    @{ Key = 'swangle'; Text = '软件 Vulkan（ANGLE + SwiftShader，CPU 渲染）' },
    @{ Key = 'lavapipe'; Text = '软件 Lavapipe（Vulkan 兼容测试）' }
)
$graphics = New-Object Windows.Forms.ComboBox
$graphics.Location = New-Object Drawing.Point(140, 325)
$graphics.Size = New-Object Drawing.Size(450, 28)
$graphics.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($item in $graphicsModes) { [void]$graphics.Items.Add($item.Text) }
for ($i = 0; $i -lt $graphicsModes.Count; $i++) {
    if ($graphicsModes[$i].Key -eq $preferences.Graphics) { $graphics.SelectedIndex = $i; break }
}
$form.Controls.Add($graphics)

$deviceLabel = New-Object Windows.Forms.Label
$deviceLabel.Location = New-Object Drawing.Point(23, 368)
$deviceLabel.Size = New-Object Drawing.Size(115, 28)
$deviceLabel.Text = '渲染设备：'
$form.Controls.Add($deviceLabel)
$renderDevice = New-Object Windows.Forms.ComboBox
$renderDevice.Location = New-Object Drawing.Point(140, 364)
$renderDevice.Size = New-Object Drawing.Size(450, 28)
$renderDevice.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
$renderDevice.DisplayMember = 'Text'
$form.Controls.Add($renderDevice)
$script:ArtemisConfigDeviceMode = ''
function Update-ArtemisConfigDevices {
    $mode = $graphicsModes[$graphics.SelectedIndex].Key
    $selectedId = if ($mode -eq $script:ArtemisConfigDeviceMode -and $renderDevice.SelectedItem) { $renderDevice.SelectedItem.Id }
        elseif ($mode -eq $preferences.Graphics) { $preferences.GraphicsDevice } else { '' }
    $script:ArtemisConfigDeviceMode = $mode
    $renderDevice.Items.Clear()
    [void]$renderDevice.Items.Add([pscustomobject]@{Text = '自动选择（仅有一张对应厂商显卡时）'; Id = ''})
    $renderDevice.Enabled = ($mode -in @('vulkan_amd', 'vulkan_intel'))
    if ($renderDevice.Enabled) {
        try {
            foreach ($candidate in @(Get-ArtemisVulkanDevices -Renderer $mode)) {
                [void]$renderDevice.Items.Add([pscustomobject]@{Text = $candidate.Name; Id = $candidate.Id})
            }
        } catch {
            [void]$renderDevice.Items.Add([pscustomobject]@{Text = '无法读取显卡，请检查驱动或选择其他模式'; Id = ''})
        }
        if ($selectedId -and @($renderDevice.Items | Where-Object { $_.Id -ieq $selectedId }).Count -eq 0) {
            [void]$renderDevice.Items.Add([pscustomobject]@{Text = '已保存的显卡当前不可用，请重新选择'; Id = $selectedId})
        }
    } else { $renderDevice.Items[0].Text = '由当前渲染模式选择设备' }
    $renderDevice.SelectedIndex = 0
    if ($renderDevice.Enabled -and $selectedId) {
        for ($i = 1; $i -lt $renderDevice.Items.Count; $i++) {
            if ($renderDevice.Items[$i].Id -ieq $selectedId) { $renderDevice.SelectedIndex = $i; break }
        }
    }
}
$graphics.Add_SelectedIndexChanged({ Update-ArtemisConfigDevices })
Update-ArtemisConfigDevices

$resolutionLabel = New-Object Windows.Forms.Label
$resolutionLabel.Location = New-Object Drawing.Point(23, 407)
$resolutionLabel.Size = New-Object Drawing.Size(115, 28)
$resolutionLabel.Text = '屏幕分辨率：'
$form.Controls.Add($resolutionLabel)

$resolutions = @(
    @{ Key = '720x1280'; Text = '720 × 1280（竖屏 9:16，省资源）' },
    @{ Key = '1080x1920'; Text = '1080 × 1920（竖屏 9:16，较清晰）' },
    @{ Key = '1280x720'; Text = '1280 × 720（横屏 16:9，省资源）' },
    @{ Key = '1920x1080'; Text = '1920 × 1080（横屏 16:9，较清晰）' },
    @{ Key = '720p'; Text = '720 × 1600（原默认，竖屏约 9:20）' },
    @{ Key = '900p'; Text = '900 × 2000（原有选项，竖屏约 9:20）' },
    @{ Key = '1080p'; Text = '1080 × 2400（原有选项，竖屏约 9:20）' }
)
$resolution = New-Object Windows.Forms.ComboBox
$resolution.Location = New-Object Drawing.Point(140, 403)
$resolution.Size = New-Object Drawing.Size(450, 28)
$resolution.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($item in $resolutions) { [void]$resolution.Items.Add($item.Text) }
for ($i = 0; $i -lt $resolutions.Count; $i++) {
    if ($resolutions[$i].Key -eq $preferences.Resolution) { $resolution.SelectedIndex = $i; break }
}
$form.Controls.Add($resolution)

$frontendLabel = New-Object Windows.Forms.Label
$frontendLabel.Location = New-Object Drawing.Point(23, 446)
$frontendLabel.Size = New-Object Drawing.Size(115, 28)
$frontendLabel.Text = '显示前端：'
$form.Controls.Add($frontendLabel)
$frontends = @(
    @{ Key = 'artemis'; Text = 'ArtemisOS 自定义窗口（默认）' },
    @{ Key = 'native'; Text = 'Android Emulator 原生窗口' }
)
$frontend = New-Object Windows.Forms.ComboBox
$frontend.Location = New-Object Drawing.Point(140, 442)
$frontend.Size = New-Object Drawing.Size(450, 28)
$frontend.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($item in $frontends) { [void]$frontend.Items.Add($item.Text) }
for ($i = 0; $i -lt $frontends.Count; $i++) {
    if ($frontends[$i].Key -eq $preferences.Frontend) { $frontend.SelectedIndex = $i; break }
}
$form.Controls.Add($frontend)

$hostMemory = ''
try {
    $memoryGB = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    $hostMemory = "当前电脑：$([Environment]::ProcessorCount) 个逻辑处理器，${memoryGB} GB 内存。"
} catch {
    $hostMemory = "当前电脑：$([Environment]::ProcessorCount) 个逻辑处理器。"
}
$note = New-Object Windows.Forms.Label
$note.Location = New-Object Drawing.Point(23, 488)
$note.Size = New-Object Drawing.Size(575, 118)
$note.Text = "$hostMemory`r`n更改后请关闭并重新启动模拟器。取消勾选可恢复已停用的预装应用。`r`nAMD Vulkan 尚未经 AMD 实机验证；不支持时请手动切换其他模式。`r`n自定义窗口支持安全页面显示；遇到兼容问题可切换原生窗口。`r`n精简镜像未内置的应用需另行安装；模拟运营商不提供真实电话或短信服务。"
$form.Controls.Add($note)

$save = New-Object Windows.Forms.Button
$save.Text = '保存配置'
$save.Location = New-Object Drawing.Point(385, 634)
$save.Size = New-Object Drawing.Size(100, 34)
$save.Add_Click({
    try {
        $chosen = 'low'
        foreach ($key in @('low', 'medium', 'high')) { if ($buttons[$key].Checked) { $chosen = $key } }
        $cleanValue = if ($cleanup.Checked) { '1' } else { '0' }
        $videoValue = if ($videoCompat.Checked) { '1' } else { '0' }
        if ($carrier.SelectedIndex -lt 0) { throw '请选择模拟运营商。' }
        if ($graphics.SelectedIndex -lt 0) { throw '请选择图形渲染模式。' }
        if ($resolution.SelectedIndex -lt 0) { throw '请选择屏幕分辨率。' }
        if ($frontend.SelectedIndex -lt 0) { throw '请选择显示前端。' }
        $chosenGraphics = $graphicsModes[$graphics.SelectedIndex].Key
        $chosenDevice = if ($renderDevice.Enabled -and $renderDevice.SelectedItem) { $renderDevice.SelectedItem.Id } else { '' }
        if ($chosenGraphics -in @('vulkan_intel', 'vulkan_amd')) { [void](Get-ArtemisSelectedVulkanDevice -Renderer $chosenGraphics -DeviceId $chosenDevice) }
        Write-ArtemisPreferences $chosen $cleanValue $videoValue $carriers[$carrier.SelectedIndex].Key $chosenGraphics $resolutions[$resolution.SelectedIndex].Key $frontends[$frontend.SelectedIndex].Key $chosenDevice
        [void][Windows.Forms.MessageBox]::Show('配置已保存，关闭并重新启动模拟器后生效。', 'ArtemisOS 15', 'OK', 'Information')
        $form.DialogResult = [Windows.Forms.DialogResult]::OK
        $form.Close()
    } catch {
        [void][Windows.Forms.MessageBox]::Show("保存配置失败：$($_.Exception.Message)", 'ArtemisOS 15', 'OK', 'Error')
    }
})
$form.Controls.Add($save)

$cancel = New-Object Windows.Forms.Button
$cancel.Text = '取消'
$cancel.Location = New-Object Drawing.Point(495, 634)
$cancel.Size = New-Object Drawing.Size(100, 34)
$cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($cancel)
$form.AcceptButton = $save
$form.CancelButton = $cancel
[void]$form.ShowDialog()
$form.Dispose()
