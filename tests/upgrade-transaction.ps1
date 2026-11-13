$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Upgrade-Transaction.ps1'
$script:work = Join-Path ([IO.Path]::GetTempPath()) ('artemis-upgrade-test-' + [guid]::NewGuid().ToString('N'))
$env:ARTEMIS_UPGRADE_TEST = '1'
$script:failed = 0

function Assert([bool]$Value, [string]$Label) { if (-not $Value) { throw "Assertion failed: $Label" } }
function Write-File([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text)
}
function New-Tree([string]$Root, [string]$Version, [bool]$Old) {
    Write-File (Join-Path $Root 'version.ini') "[ArtemisOS]`r`nVersion=$Version`r`n"
    Write-File (Join-Path $Root 'start-auto.vbs') ("launcher $Version")
    Write-File (Join-Path $Root 'launch.ps1') ("runtime $Version")
    foreach ($file in @('emulator\emulator.exe', 'emulator\qemu\windows-x86_64\qemu-system-x86_64.exe',
        'emulator\qemu\windows-x86_64\qemu-system-x86_64-headless.exe',
        'platform-tools\adb.exe', 'system-images\android-35\google_apis\x86_64\system.img',
        'system-images\android-35\google_apis\x86_64\vendor.img',
        'system-images\android-35\google_apis\x86_64\ramdisk.img',
        'system-images\android-35\google_apis\x86_64\kernel-ranchu')) {
        Write-File (Join-Path $Root ('sdk\' + $file)) ("$Version $file")
    }
    if ($Old) {
        Write-File (Join-Path $Root 'data\avd\InternalAndroid15.avd\userdata-qemu.img.qcow2') 'private android data'
        Write-File (Join-Path $Root 'data\avd\InternalAndroid15.avd\userdata-qemu.img') 'backing image'
        Write-File (Join-Path $Root 'data\avd\InternalAndroid15.avd\encryptionkey.img.qcow2') 'encrypted key data'
        Write-File (Join-Path $Root 'data\avd\InternalAndroid15.avd\snapshots\boot\ram.bin') 'snapshot data'
        Write-File (Join-Path $Root 'data\preferences.ini') 'user prefs and unknown keys'
        Write-File (Join-Path $Root 'update\server.txt') 'private configured endpoint'
        Write-File (Join-Path $Root 'update\custom.json') 'user update config'
        Write-File (Join-Path $Root 'custom\preferences.yaml') 'other user configuration'
        Write-File (Join-Path $Root 'unins000.exe') 'old uninstaller'
        Write-File (Join-Path $Root 'sdk\emulator\obsolete.dll') 'old SDK component'
        [void][IO.Directory]::CreateDirectory((Join-Path $Root 'custom\empty'))
        Set-Content -LiteralPath (Join-Path $Root 'data\preferences.ini') -Stream 'custom' -Value 'an NTFS alternate stream'
    } else {
        Write-File (Join-Path $Root 'update\server.txt') 'default endpoint'
        Write-File (Join-Path $Root 'update\core.ps1') 'new update core'
    }
}
function Run-Upgrade([string]$Action, [string]$Target, [string]$Payload = '', [string]$Crash = '') {
    $argsForTest = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:tool, '-Action', $Action, '-Target', $Target)
    if ($Payload) { $argsForTest += @('-Payload', $Payload) }
    if ($Crash) { $argsForTest += @('-TestCrashAt', $Crash) }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $script:lastOutput = @(& rtk proxy powershell.exe @argsForTest 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    return $code
}
function New-Fixture([string]$Name, [string]$Version = '0.3.5') {
    $base = Join-Path $script:work $Name
    $old = Join-Path $base 'installed'
    $payload = Join-Path $base 'payload'
    New-Tree $old $Version $true
    New-Tree $payload '1.0.0' $false
    return [pscustomobject]@{ Base = $base; Target = $old; Payload = $payload }
}
function Get-Record($Fixture) {
    $root = @(Get-ChildItem -LiteralPath $Fixture.Base -Directory -Force | Where-Object { $_.Name -like '.ArtemisOS-upgrade-*' })
    Assert ($root.Count -eq 1) 'one transaction root exists'
    $record = Get-Content -LiteralPath (Join-Path $root[0].FullName 'transaction.json') -Raw | ConvertFrom-Json
    return [pscustomobject]@{ Root = $root[0].FullName; Value = $record; Tx = (Join-Path $root[0].FullName $record.id) }
}
function Content([string]$Path) { return [IO.File]::ReadAllText($Path).Trim() }
function Test-Case([string]$Name, [scriptblock]$Block) {
    try { & $Block; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)"; Write-Host $script:lastOutput }
}

try {
    [void][IO.Directory]::CreateDirectory($script:work)
    Test-Case 'upgrade preserves user data, custom configuration, uninstaller and full old tree' {
        $f = New-Fixture 'success'
        Assert ((Run-Upgrade 'Apply' $f.Target $f.Payload) -eq 0) 'apply succeeds'
        $r = Get-Record $f
        $old = Join-Path $r.Tx 'old'
        Assert ((Content (Join-Path $f.Target 'launch.ps1')) -eq 'runtime 1.0.0') 'new runtime installed'
        Assert ((Content (Join-Path $old 'launch.ps1')) -eq 'runtime 0.3.5') 'old runtime retained'
        Assert ((Content (Join-Path $f.Target 'data\preferences.ini')) -eq 'user prefs and unknown keys') 'preferences preserved'
        Assert ((Get-Content -LiteralPath (Join-Path $f.Target 'data\preferences.ini') -Stream 'custom').Trim() -eq 'an NTFS alternate stream') 'alternate stream preserved'
        Assert ((Content (Join-Path $f.Target 'update\server.txt')) -eq 'private configured endpoint') 'server preserved'
        Assert ((Content (Join-Path $f.Target 'update\custom.json')) -eq 'user update config') 'custom updater config preserved'
        Assert ((Content (Join-Path $f.Target 'custom\preferences.yaml')) -eq 'other user configuration') 'custom config preserved'
        Assert ((Content (Join-Path $f.Target 'unins000.exe')) -eq 'old uninstaller') 'old uninstaller retained'
        Assert ([IO.Directory]::Exists((Join-Path $f.Target 'custom\empty'))) 'empty custom directory retained'
        Assert ((Content (Join-Path $f.Target 'data\avd\InternalAndroid15.avd\snapshots\boot\ram.bin')) -eq 'snapshot data') 'snapshot copied'
        Assert ((Content (Join-Path $f.Target 'data\avd\InternalAndroid15.avd\encryptionkey.img.qcow2')) -eq 'encrypted key data') 'encryption copied'
        Assert (-not [IO.File]::Exists((Join-Path $f.Target 'sdk\emulator\obsolete.dll'))) 'old runtime files not mixed'
        Assert ([IO.File]::Exists((Join-Path $old 'sdk\emulator\obsolete.dll'))) 'old SDK kept for rollback'
        Assert ((Run-Upgrade 'Recover' $f.Target) -eq 0) 'recover applied transaction is idempotent'
        Write-File (Join-Path $f.Target 'data\created-after-upgrade.txt') 'new valuable data'
        Assert ((Run-Upgrade 'Rollback' $f.Target) -eq 0) 'explicit rollback succeeds'
        Assert ((Content (Join-Path $f.Target 'launch.ps1')) -eq 'runtime 0.3.5') 'old version restored'
        Assert ((Content (Join-Path $r.Tx 'upgraded-preserved\data\created-after-upgrade.txt')) -eq 'new valuable data') 'post-upgrade data retained'
        Assert ((Run-Upgrade 'Recover' $f.Target) -eq 0) 'recover rolled back transaction is idempotent'
    }
    foreach ($point in @('Prepared', 'SdkMoved', 'OldMoved', 'SdkRestored', 'NewMoved')) {
        Test-Case "interruption at $point and recovery" {
            $f = New-Fixture ('crash-' + $point)
            Assert ((Run-Upgrade 'Apply' $f.Target $f.Payload $point) -eq 91) 'fault was injected'
            $recoveryPath = if ($point -eq 'Prepared') { $f.Target.ToUpperInvariant() } else { $f.Target }
            Assert ((Run-Upgrade 'Recover' $recoveryPath) -eq 0) 'recovery succeeds with equivalent path spelling'
            if ($point -eq 'NewMoved') {
                Assert ((Content (Join-Path $f.Target 'launch.ps1')) -eq 'runtime 1.0.0') 'completed swap retained'
                $r = Get-Record $f
                Assert ((Content (Join-Path $r.Tx 'old\data\preferences.ini')) -eq 'user prefs and unknown keys') 'old data retained'
            } else {
                Assert ((Content (Join-Path $f.Target 'launch.ps1')) -eq 'runtime 0.3.5') 'original restored'
                Assert ([IO.File]::Exists((Join-Path $f.Target 'sdk\emulator\emulator.exe'))) 'original SDK restored'
                Assert ((Content (Join-Path $f.Target 'data\preferences.ini')) -eq 'user prefs and unknown keys') 'original data retained'
                Assert ((Run-Upgrade 'Apply' $f.Target $f.Payload) -eq 0) 'retry after recovery succeeds'
            }
        }
    }
    Test-Case 'interrupted explicit rollback keeps upgraded data' {
        $f = New-Fixture 'rollback-crash'
        Assert ((Run-Upgrade 'Apply' $f.Target $f.Payload) -eq 0) 'apply succeeds'
        Write-File (Join-Path $f.Target 'data\after.txt') 'preserve me'
        Assert ((Run-Upgrade 'Rollback' $f.Target '' 'RollbackMoved') -eq 91) 'rollback interrupted'
        Assert ((Run-Upgrade 'Recover' $f.Target) -eq 0) 'rollback recovered'
        $r = Get-Record $f
        Assert ((Content (Join-Path $r.Tx 'upgraded-preserved\data\after.txt')) -eq 'preserve me') 'new data kept'
        Assert ((Content (Join-Path $f.Target 'launch.ps1')) -eq 'runtime 0.3.5') 'old version restored'
    }
    Test-Case 'changes during the unlocked move window prevent commit' {
        $f = New-Fixture 'window-change'
        Assert ((Run-Upgrade 'Apply' $f.Target $f.Payload 'MutationAfterUnlock') -ne 0) 'mutation stops apply'
        Assert ((Run-Upgrade 'Recover' $f.Target) -eq 0) 'mutated original can be restored'
        Assert ((Content (Join-Path $f.Target 'launch.ps1')) -eq 'runtime 0.3.5') 'old runtime restored'
        Assert ((Content (Join-Path $f.Target 'data\preferences.ini')) -eq 'user prefs and unknown keys changed during swap') 'concurrent change retained'
    }
    Test-Case 'corrupt old data backup prevents rollback' {
        $f = New-Fixture 'corrupt-backup'
        Assert ((Run-Upgrade 'Apply' $f.Target $f.Payload) -eq 0) 'apply succeeds'
        $r = Get-Record $f
        Write-File (Join-Path $r.Tx 'old\data\preferences.ini') 'unexpectedly modified backup'
        Assert ((Run-Upgrade 'Rollback' $f.Target) -ne 0) 'corrupt backup rejected'
        Assert ((Content (Join-Path $f.Target 'launch.ps1')) -eq 'runtime 1.0.0') 'new install remains present'
        Assert ((Content (Join-Path $f.Target 'data\preferences.ini')) -eq 'user prefs and unknown keys') 'new data remains intact'
    }
    Test-Case 'ambiguous recovery never replaces an unexpected target' {
        $f = New-Fixture 'ambiguous'
        Assert ((Run-Upgrade 'Apply' $f.Target $f.Payload 'OldMoved') -eq 91) 'fault was injected'
        $r = Get-Record $f
        Write-File (Join-Path $f.Target 'version.ini') "[ArtemisOS]`r`nVersion=9.9.9`r`n"
        Write-File (Join-Path $f.Target 'data\unexpected.txt') 'do not overwrite'
        Assert ((Run-Upgrade 'Recover' $f.Target) -ne 0) 'ambiguous target rejected'
        Assert ((Content (Join-Path $f.Target 'data\unexpected.txt')) -eq 'do not overwrite') 'unexpected target preserved'
        Assert ((Content (Join-Path $r.Tx 'old\data\preferences.ini')) -eq 'user prefs and unknown keys') 'original backup preserved'
    }
    Test-Case 'same-version foreign target is not mistaken for the upgraded tree' {
        $f = New-Fixture 'same-version-impostor'
        Assert ((Run-Upgrade 'Apply' $f.Target $f.Payload 'NewMoved') -eq 91) 'fault was injected'
        $r = Get-Record $f
        $saved = Join-Path $r.Tx 'separately-retained-new'
        Assert ($saved.StartsWith($f.Base + '\', [StringComparison]::OrdinalIgnoreCase)) 'save path is inside fixture'
        [IO.Directory]::Move($f.Target, $saved)
        Write-File (Join-Path $f.Target 'version.ini') "[ArtemisOS]`r`nVersion=1.0.0`r`n"
        Write-File (Join-Path $f.Target 'data\foreign.txt') 'foreign same-version data'
        Assert ((Run-Upgrade 'Recover' $f.Target) -ne 0) 'same-version impostor denied'
        Assert ((Content (Join-Path $f.Target 'data\foreign.txt')) -eq 'foreign same-version data') 'foreign data retained'
        Assert ((Content (Join-Path $saved 'data\preferences.ini')) -eq 'user prefs and unknown keys') 'real upgraded data retained'
    }
    Test-Case 'reject downgrade and unknown install' {
        $f = New-Fixture 'downgrade' '1.1.0'
        Assert ((Run-Upgrade 'Apply' $f.Target $f.Payload) -ne 0) 'downgrade denied'
        Assert ((Content (Join-Path $f.Target 'launch.ps1')) -eq 'runtime 1.1.0') 'newer install untouched'
        $g = New-Fixture 'unknown' '0.3.2'
        Assert ((Run-Upgrade 'Apply' $g.Target $g.Payload) -ne 0) 'unqualified version denied'
    }
    Test-Case 'reject unfinished or concurrently running legacy OTA' {
        $f = New-Fixture 'pending-ota'
        Write-File (Join-Path $f.Target 'data\update\pending\applying.flag') '1'
        Assert ((Run-Upgrade 'Apply' $f.Target $f.Payload) -ne 0) 'unfinished legacy OTA rejected'
        Assert ((Content (Join-Path $f.Target 'launch.ps1')) -eq 'runtime 0.3.5') 'legacy install preserved'
        $g = New-Fixture 'locked-ota'
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($g.Target.ToLowerInvariant())))).Replace('-', '') }
        finally { $sha.Dispose() }
        $mutex = New-Object Threading.Mutex ($false, ('Local\ArtemisOS-Update-' + $digest.Substring(0, 24)))
        try {
            Assert ($mutex.WaitOne(0)) 'legacy mutex acquired by test fixture'
            Assert ((Run-Upgrade 'Apply' $g.Target $g.Payload) -ne 0) 'running legacy OTA rejected'
        } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
        Assert ((Content (Join-Path $g.Target 'data\preferences.ini')) -eq 'user prefs and unknown keys') 'legacy OTA data preserved'
    }
    Test-Case 'reject conflicts and preserve original' {
        $f = New-Fixture 'conflict'
        Write-File (Join-Path $f.Payload 'custom\preferences.yaml') 'conflicting payload file'
        Assert ((Run-Upgrade 'Apply' $f.Target $f.Payload) -ne 0) 'custom file conflict denied'
        Assert ((Content (Join-Path $f.Target 'custom\preferences.yaml')) -eq 'other user configuration') 'custom content intact'
        Assert ((Run-Upgrade 'Recover' $f.Target) -eq 0) 'failed preparation recovered'
    }
    Test-Case 'reject locked data and reparse points' {
        $f = New-Fixture 'locked'
        $path = Join-Path $f.Target 'data\preferences.ini'
        $lock = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { Assert ((Run-Upgrade 'Apply' $f.Target $f.Payload) -ne 0) 'active writer denied' } finally { $lock.Dispose() }
        Assert ((Content $path) -eq 'user prefs and unknown keys') 'locked file untouched'
        $g = New-Fixture 'junction'
        [void](New-Item -ItemType Junction -Path (Join-Path $g.Target 'data\foreign-link') -Target $g.Payload)
        Assert ((Run-Upgrade 'Apply' $g.Target $g.Payload) -ne 0) 'junction denied'
        Assert ((Content (Join-Path $g.Target 'launch.ps1')) -eq 'runtime 0.3.5') 'junction test original intact'
        $h = New-Fixture 'hardlink'
        [void](New-Item -ItemType HardLink -Path (Join-Path $h.Target 'data\same-preferences.ini') -Target (Join-Path $h.Target 'data\preferences.ini'))
        Assert ((Run-Upgrade 'Apply' $h.Target $h.Payload) -ne 0) 'user-data hard link denied'
        Assert ((Content (Join-Path $h.Target 'data\preferences.ini')) -eq 'user prefs and unknown keys') 'hard-linked data untouched'
    }
    Test-Case 'reject an owned running emulator process' {
        $f = New-Fixture 'running'
        $fake = Join-Path $f.Target 'sdk\emulator\qemu\windows-x86_64\qemu-system-x86_64.exe'
        [IO.File]::Copy((Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'), $fake, $true)
        $child = Start-Process -FilePath $fake -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 60' -WindowStyle Hidden -PassThru
        try {
            Start-Sleep -Seconds 1
            Assert (-not $child.HasExited) 'fixture process is running'
            Assert ((Run-Upgrade 'Apply' $f.Target $f.Payload) -ne 0) 'running emulator rejected'
            Assert ((Content (Join-Path $f.Target 'data\preferences.ini')) -eq 'user prefs and unknown keys') 'running data untouched'
        } finally {
            if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force; $child.WaitForExit() }
        }
    }
} finally {
    Remove-Item Env:ARTEMIS_UPGRADE_TEST -ErrorAction SilentlyContinue
    # This test created this exact isolated temporary directory and no other path.
    if ([IO.Directory]::Exists($script:work) -and $script:work.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $script:work -Recurse -Force
    }
}
if ($script:failed) { throw "$script:failed upgrade transaction test(s) failed." }
