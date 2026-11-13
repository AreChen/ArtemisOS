param(
    [string]$InstallRoot = '',
    [switch]$NoUi,
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Management\Microsoft.PowerShell.Management.psd1') -ErrorAction Stop
$expected = @{
    'core.ps1' = '3a0d3ed7fe46c9870b849f8c8a37e5a81aa61513884f972a815ca877424d40e2'
    'apply.ps1' = 'ae67e85292399ea86c4713958ab545c4784c6dea0f25605d9c1bf0a5c09c681a'
    'recovery.ps1' = 'f4288c9c5fe8b3bf368a2a7fadfd55fe719269c800157cf14afc63a0ff95d78a'
    'trusted-key.xml' = 'de2c7be759256c476025456fa64d0acecee62c4d92c5d68fd4685b3c8964c3ae'
}
function Show-RepairMessage([string]$Message, [bool]$ErrorMessage) {
    if ($NoUi) { if ($ErrorMessage) { [Console]::Error.WriteLine($Message) } else { Write-Output $Message }; return }
    Add-Type -AssemblyName System.Windows.Forms
    $icon = if ($ErrorMessage) { 'Warning' } else { 'Information' }
    [void][Windows.Forms.MessageBox]::Show($Message, 'ArtemisOS 15 更新修复', 'OK', $icon)
}
function Assert-KnownUpdater([string]$Root) {
    foreach ($name in $expected.Keys) {
        $file = Join-Path $Root ('update\' + $name)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected[$name]) {
            throw '更新组件与支持的 1.0.0/1.0.1 版本不符，未进行修改。'
        }
    }
}
function Wait-ClosedRuntime([string]$Root) {
    $sdk = [IO.Path]::GetFullPath((Join-Path $Root 'sdk\emulator')).TrimEnd('\') + '\'
    $filter = "Name='qemu-system-x86_64.exe' OR Name='qemu-system-x86_64-headless.exe' OR Name='emulator.exe'"
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    while ($true) {
        $watchdogs = $false
        foreach ($process in @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction Stop)) {
            if (-not $process.ExecutablePath) { throw '无法确认模拟器进程的安装路径。' }
            $path = [IO.Path]::GetFullPath([string]$process.ExecutablePath)
            if (-not $path.StartsWith($sdk, [StringComparison]::OrdinalIgnoreCase)) { continue }
            # Wait for shutdown helpers, but do not stop a real instance.
            if ($process.Name -ieq 'emulator.exe' -and $process.CommandLine -match '(?i)(?:^|\s)-kill\s+\d+\s+-sleep\s+\d+\s*$') {
                $watchdogs = $true
            } else { throw '请先关闭 ArtemisOS 模拟器，然后重新运行更新修复工具。' }
        }
        if (-not $watchdogs) { return }
        if ([DateTime]::UtcNow -ge $deadline) { throw '模拟器关闭尚未完成，请稍后重试。' }
        Start-Sleep -Milliseconds 500
    }
}
function Enter-LaunchLock([string]$Root) {
    $path = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\/').ToUpperInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path)) } finally { $sha.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Global\ArtemisOS-Launch-' + ([BitConverter]::ToString($digest) -replace '-', '')))
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw '模拟器正在启动，请稍后重试。' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}
try {
    if (-not $InstallRoot) {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ArtemisOS15-Release_is1'
        $InstallRoot = [string](Get-ItemProperty -LiteralPath $key -Name InstallLocation -ErrorAction Stop).InstallLocation
    }
    if (-not [IO.Path]::IsPathRooted($InstallRoot)) { throw '无法确定 ArtemisOS 安装目录。' }
    $InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) { throw '未找到 ArtemisOS 安装目录。' }
    Assert-KnownUpdater $InstallRoot
    . (Join-Path $InstallRoot 'update\core.ps1')
    Assert-UpdatePathSafe $InstallRoot
    Assert-UpdatePathSafe (Join-Path $InstallRoot 'data\update')
    $version = Get-UpdateVersion $InstallRoot
    if ($version -cnotin @('1.0.0','1.0.1')) { throw '此工具仅适用于 ArtemisOS 15 的 1.0.0 和 1.0.1。' }
    $launchLock = Enter-LaunchLock $InstallRoot
    try {
        Wait-ClosedRuntime $InstallRoot
        while ($version -cne '1.0.2') {
            Assert-KnownUpdater $InstallRoot
            $expectedTarget = if ($version -ceq '1.0.0') { '1.0.1' } else { '1.0.2' }
            $offer = Get-UpdateOffer $InstallRoot
            if ($null -eq $offer -or $offer.Manifest.from -cne $version -or $offer.Manifest.to -cne $expectedTarget) {
                throw '更新服务器未提供所需的签名修复，请稍后重试。'
            }
            $staged = Stage-UpdateOffer $InstallRoot $offer
            Wait-ClosedRuntime $InstallRoot
            $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $apply = Join-Path $InstallRoot 'update\apply.ps1'
            $args = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
                '-File', ('"' + $apply + '"'), '-Staging', ('"' + $staged + '"'), '-Serial', 'emulator-5554', '-NoRestart')
            $process = Start-Process -FilePath $ps -ArgumentList $args -WindowStyle Hidden -Wait -PassThru
            if ($process.ExitCode -ne 0 -or (Get-UpdateVersion $InstallRoot) -cne $expectedTarget) {
                throw '未能完成更新。请查看安装目录 data\update\update.log。'
            }
            $version = $expectedTarget
        }
    } finally { $launchLock.ReleaseMutex(); $launchLock.Dispose() }
    if (-not $NoRestart) {
        $launch = Join-Path $InstallRoot 'start-auto.vbs'
        Assert-UpdatePathSafe $launch
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $launch + '"') -WindowStyle Hidden | Out-Null
    }
    Show-RepairMessage '更新修复完成，已升级至 ArtemisOS 15 1.0.2。' $false
} catch {
    Show-RepairMessage ('更新修复未完成，原有数据已保留。' + "`r`n`r`n" + $_.Exception.Message) $true
    exit 1
}
