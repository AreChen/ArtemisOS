param(
    [ValidateSet('low', 'medium', 'high')][string]$SetProfile,
    [ValidateSet('0', '1')][string]$SetCleanup,
    [switch]$NoGui
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'settings.ps1')
$preferences = Get-ArtemisPreferences

if ($NoGui) {
    if ($SetProfile) { $preferences.Profile = $SetProfile }
    if ($SetCleanup) { $preferences.Cleanup = $SetCleanup }
    Write-ArtemisPreferences $preferences.Profile $preferences.Cleanup
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = 'ArtemisOS 15 - 配置'
$form.ClientSize = New-Object Drawing.Size(620, 390)
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
$cleanup.Text = '精简 Google 预装应用（云端硬盘、Gmail、地图、YouTube、相册等）'
$cleanup.Checked = ($preferences.Cleanup -eq '1')
$form.Controls.Add($cleanup)

$hostMemory = ''
try {
    $memoryGB = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    $hostMemory = "当前电脑：$([Environment]::ProcessorCount) 个逻辑处理器，${memoryGB} GB 内存。"
} catch {
    $hostMemory = "当前电脑：$([Environment]::ProcessorCount) 个逻辑处理器。"
}
$note = New-Object Windows.Forms.Label
$note.Location = New-Object Drawing.Point(23, 255)
$note.Size = New-Object Drawing.Size(575, 63)
$note.Text = "$hostMemory`r`n更改后请关闭并重新启动模拟器。精简应用不会删除数据；取消勾选可恢复。"
$form.Controls.Add($note)

$save = New-Object Windows.Forms.Button
$save.Text = '保存配置'
$save.Location = New-Object Drawing.Point(385, 334)
$save.Size = New-Object Drawing.Size(100, 34)
$save.Add_Click({
    try {
        $chosen = 'low'
        foreach ($key in @('low', 'medium', 'high')) { if ($buttons[$key].Checked) { $chosen = $key } }
        $cleanValue = if ($cleanup.Checked) { '1' } else { '0' }
        Write-ArtemisPreferences $chosen $cleanValue
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
$cancel.Location = New-Object Drawing.Point(495, 334)
$cancel.Size = New-Object Drawing.Size(100, 34)
$cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($cancel)
$form.AcceptButton = $save
$form.CancelButton = $cancel
[void]$form.ShowDialog()
$form.Dispose()
