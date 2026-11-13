param([string]$Compiler = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'))
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixture = Join-Path $parent ('artemisos-fixture-ota-default-' + [Guid]::NewGuid().ToString('N'))
if (-not (Test-Path -LiteralPath $Compiler -PathType Leaf)) { throw 'Inno Setup compiler not found.' }
if (Test-Path -LiteralPath $fixture) { throw 'Fixture path unexpectedly exists.' }
[void][IO.Directory]::CreateDirectory($fixture)
$want = 'https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/'
function Assert([bool]$Ok, [string]$Message) {
    if (-not $Ok) { throw $Message }
    Write-Host "PASS: $Message"
}
function Write-Fixture([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.Encoding]::ASCII)
}
function Make-Sdk([string]$Root, [bool]$Complete = $true) {
    foreach ($name in @('emulator\emulator.exe', 'emulator\qemu\windows-x86_64\qemu-system-x86_64.exe',
        'emulator\qemu\windows-x86_64\qemu-system-x86_64-headless.exe',
        'platform-tools\adb.exe', 'system-images\android-35\google_apis\x86_64\system.img',
        'system-images\android-35\google_apis\x86_64\vendor.img',
        'system-images\android-35\google_apis\x86_64\ramdisk.img',
        'system-images\android-35\google_apis\x86_64\kernel-ranchu')) {
        if (-not $Complete -and $name -eq 'platform-tools\adb.exe') { continue }
        Write-Fixture (Join-Path $Root $name) ('fixture:' + $name)
    }
}
function Make-Old([string]$Root, [string]$Default, [string]$Override, [bool]$Complete = $true) {
    Make-Sdk (Join-Path $Root 'sdk') $Complete
    Write-Fixture (Join-Path $Root 'version.ini') "[ArtemisOS]`r`nVersion=0.3.5`r`n"
    foreach ($name in @('launch.ps1', 'settings.ps1', 'start-auto.vbs')) { Write-Fixture (Join-Path $Root $name) 'old fixture' }
    Write-Fixture (Join-Path $Root '.artemis-test-fixture') 'isolated fixture'
    Write-Fixture (Join-Path $Root 'update\server.txt') $Default
    if ($null -ne $Override -and $Override -ne '') { Write-Fixture (Join-Path $Root 'data\update\server.txt') $Override }
    Write-Fixture (Join-Path $Root 'data\preferences.ini') "profile=high`r`nunknown-setting=keep`r`n"
    Write-Fixture (Join-Path $Root 'data\avd\userdata-qemu.img.qcow2') 'user disk'
    Write-Fixture (Join-Path $Root 'data\apps\app.apk') 'user application'
}
function Read-Server([string]$Root, [string]$Relative) {
    $path = Join-Path $Root $Relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    return [IO.File]::ReadAllText($path).Trim()
}
function Run-Setup([string]$Exe, [string]$Root, [bool]$Success = $true) {
    $log = $Root + '.log'
    $exitCode = Invoke-HiddenSetup $Exe @('/SP-', ("/DIR=$Root"), ("/LOG=$log"))
    if ($Success -and $exitCode -ne 0) { throw "Fixture setup failed: $([IO.File]::ReadAllText($log))" }
    if (-not $Success -and $exitCode -eq 0) { throw 'Invalid fixture unexpectedly installed.' }
}
function Invoke-HiddenSetup([string]$Exe, [string[]]$Arguments) {
    $rtkPath = (Get-Command rtk.exe -ErrorAction Stop).Source
    $quoted = @('proxy', ('"' + $Exe + '"'), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') + @($Arguments | ForEach-Object { '"' + $_ + '"' })
    $process = Start-Process -FilePath $rtkPath -ArgumentList $quoted -PassThru -Wait -WindowStyle Hidden
    return $process.ExitCode
}
function Compile([string]$Template, [string]$Name, [string[]]$Extra = @(), [bool]$Success = $true) {
    $rtkPath=(Get-Command rtk.exe -ErrorAction Stop).Source
    $stdout=Join-Path $fixture ($Name+'.compile.out');$stderr=Join-Path $fixture ($Name+'.compile.err')
    $compilerArgs=@('proxy',('"'+$Compiler+'"'),'/Qp',('"/O'+$fixture+'"'),('"/F'+$Name+'"'),'/DPackageCompression=none')+@($Extra|ForEach-Object{'"'+$_+'"'})+('"'+(Join-Path $fixture $Template)+'"')
    $compilerProcess=Start-Process -FilePath $rtkPath -ArgumentList $compilerArgs -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $diagnostic=[IO.File]::ReadAllText($stderr)
    if ($Success -and $compilerProcess.ExitCode -ne 0) { throw "Compilation failed: $Template $diagnostic" }
    if (-not $Success -and ($compilerProcess.ExitCode -eq 0 -or $diagnostic -notmatch 'OpenListServerFile is retired')) { throw "Legacy server macro did not fail for the intended reason: $Template $diagnostic" }
    return (Join-Path $fixture ($Name + '.exe'))
}
try {
    # Compile the actual templates with a tiny SDK and inert scripts. This catches
    # broken [Files]/[Code] wiring without building or launching the Android SDK.
    foreach ($name in @('installer.iss', 'installer-upgrade.iss', 'ChineseSimplified.isl')) {
        Copy-Item -LiteralPath (Join-Path $repo $name) -Destination (Join-Path $fixture $name)
    }
    # Expected failures must suppress even code-generated message boxes. Only
    # the copied fixture templates change; production installer prompts remain.
    foreach ($name in @('installer.iss', 'installer-upgrade.iss')) {
        $path = Join-Path $fixture $name
        $text = [regex]::Replace([IO.File]::ReadAllText($path), '(?<!Suppressible)MsgBox\(([^\r\n]*?), (mbError|mbCriticalError), MB_OK\)', 'SuppressibleMsgBox($1, $2, MB_OK, IDOK)')
        [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($true))
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'tools'))
    foreach ($name in @('ArtemisInstallDiscovery.psm1', 'Find-ArtemisInstallations.ps1', 'Upgrade-Transaction.ps1', 'InnoUpgradePrototype.iss', 'InstallerOtaConfig.iss')) {
        $source = Join-Path $repo ('tools\' + $name)
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $fixture ('tools\' + $name)) }
    }
    # Keep the real path/version discovery and transaction, but isolate registry
    # enumeration from unrelated installed products and stale machine entries.
    $discoveryScript = Join-Path $fixture 'tools\Find-ArtemisInstallations.ps1'
    $discoveryText = [IO.File]::ReadAllText($discoveryScript).Replace('$registry = Get-ArtemisRegistryRegistrations', '$registry = [pscustomobject]@{ Records = @(); Issues = @() }')
    [IO.File]::WriteAllText($discoveryScript, $discoveryText, [Text.UTF8Encoding]::new($true))
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'stage'))
    foreach ($name in @('ArtemisOS15.ico', 'ArtemisOS15-wizard.png', 'ArtemisOS15-banner.bmp')) {
        Copy-Item -LiteralPath (Join-Path $repo ('stage\' + $name)) -Destination (Join-Path $fixture ('stage\' + $name))
    }
    foreach ($name in @('launch.ps1','settings.ps1','initialize.ps1','configure.ps1','configure.vbs',
        'start-auto.vbs','start-software.vbs','carrier-operators.xml','使用说明.txt','licenses\fixture.txt','update\fixture.txt')) {
        Write-Fixture (Join-Path $fixture ('stage\' + $name)) 'inert fixture'
    }
    $server = Join-Path $repo 'stage\update\server.txt'
    if (Test-Path -LiteralPath $server) { Copy-Item -LiteralPath $server -Destination (Join-Path $fixture 'stage\update\server.txt') }
    Write-Fixture (Join-Path $fixture 'stage\version.ini') "[ArtemisOS]`r`nVersion=1.0.0`r`n"
    Make-Sdk (Join-Path $fixture 'stage\sdk')
    $id = 'ArtemisOtaDefaultFixture' + [Guid]::NewGuid().ToString('N')
    $setup = Compile 'installer-upgrade.iss' 'ota-default' @('/DArtemisUpgradeFixture=1', "/DReleaseAppId=$id")
    $fresh = Join-Path $fixture 'fresh'
    Run-Setup $setup $fresh
    Assert ((Read-Server $fresh 'update\server.txt') -ceq $want) 'fresh installation uses the direct HTTPS OTA repository'
    $oldShare = 'https://cloudx.playones.com/sd/YCsIY2UB/?d'
    foreach ($case in @(
        @{ Name = 'official'; Default = $oldShare; Override = $oldShare; DefaultWant = $want; OverrideWant = $want },
        @{ Name = 'mixed'; Default = $oldShare; Override = 'http://127.0.0.1:8181/'; DefaultWant = $want; OverrideWant = 'http://127.0.0.1:8181/' },
        @{ Name = 'custom'; Default = 'https://updates.example.invalid/ota/'; Override = 'https://other.example.invalid/custom/'; DefaultWant = 'https://updates.example.invalid/ota/'; OverrideWant = 'https://other.example.invalid/custom/' },
        @{ Name = 'absent'; Default = 'https://cloudx.playones.com/sd/YCsIY2UB'; Override = ''; DefaultWant = $want; OverrideWant = '' }
    )) {
        $target = Join-Path $fixture $case.Name
        Make-Old $target $case.Default $case.Override
        Run-Setup $setup $target
        Assert ((Read-Server $target 'update\server.txt') -ceq $case.DefaultWant -and
            (Read-Server $target 'data\update\server.txt') -ceq $case.OverrideWant) ("successful transaction updates only retired official addresses: " + $case.Name)
        Assert ([IO.File]::ReadAllText((Join-Path $target 'data\preferences.ini')) -ceq "profile=high`r`nunknown-setting=keep`r`n" -and
            [IO.File]::ReadAllText((Join-Path $target 'data\avd\userdata-qemu.img.qcow2')) -ceq 'user disk' -and
            [IO.File]::ReadAllText((Join-Path $target 'data\apps\app.apk')) -ceq 'user application') ("preferences, AVD, and applications stay unchanged: " + $case.Name)
    }
    $bad = Join-Path $fixture 'failed'
    Make-Old $bad $oldShare $oldShare $false
    Run-Setup $setup $bad $false
    Assert ((Read-Server $bad 'update\server.txt') -ceq $oldShare -and
        (Read-Server $bad 'data\update\server.txt') -ceq $oldShare) 'failed transaction leaves both existing server files untouched'
    # Exercise the production template with its real installation code. A unique
    # registration and shortcut group are removed by its own uninstaller.
    $production = Compile 'installer.iss' 'fresh-default' @("/DReleaseAppId=$id", "/DReleaseShortcutName=$id")
    $productionTarget = Join-Path $fixture 'production-fresh'
    try {
        Run-Setup $production $productionTarget
        Assert ((Read-Server $productionTarget 'update\server.txt') -ceq $want) 'production fresh-install code path installs the direct HTTPS default'
    } finally {
        $uninstaller = Join-Path $productionTarget 'unins000.exe'
        if (Test-Path -LiteralPath $uninstaller -PathType Leaf) {
            if ((Invoke-HiddenSetup $uninstaller @()) -ne 0) { throw 'Production fixture uninstaller failed.' }
        }
    }
    Write-Fixture (Join-Path $fixture 'old-share.txt') $oldShare
    foreach ($template in @('installer.iss','installer-upgrade.iss')) {
        $null = Compile $template ('reject-' + [IO.Path]::GetFileNameWithoutExtension($template)) @("/DOpenListServerFile=$(Join-Path $fixture 'old-share.txt')") $false
        Write-Host "PASS: $template rejects the retired build-time server override"
    }
} finally {
    if (Test-Path -LiteralPath $fixture) {
        $item = Get-Item -LiteralPath $fixture -Force
        if ($item.FullName -ine $fixture -or $item.Parent.FullName.TrimEnd('\') -ine $parent -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
