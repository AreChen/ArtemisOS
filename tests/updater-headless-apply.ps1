# Drive apply.ps1 with synthetic process metadata and a fake ADB executable.
# No real emulator or AVD participates in this test.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $project ('build\updater-headless-' + [Guid]::NewGuid().ToString('N'))
$root = Join-Path $fixture 'install'
$staged = Join-Path $root ('data\update\staged-' + [Guid]::NewGuid().ToString('N'))
foreach ($directory in @((Join-Path $root 'update'),(Join-Path $root 'sdk\platform-tools'),$staged,(Join-Path $root 'data\avd'))) { [void][IO.Directory]::CreateDirectory($directory) }
Copy-Item -Path (Join-Path $project 'stage\update\*.ps1') -Destination (Join-Path $root 'update')
[IO.File]::WriteAllText((Join-Path $root 'version.ini'), "[ArtemisOS]`nVersion=1.0.0`n", [Text.Encoding]::ASCII)
$data = Join-Path $root 'data\avd\sentinel.img'
[IO.File]::WriteAllText($data, 'preserve user data', [Text.Encoding]::ASCII)
$before = (Get-FileHash -LiteralPath $data -Algorithm SHA256).Hash
$targetVersion = [Text.Encoding]::ASCII.GetBytes("[ArtemisOS]`nVersion=1.0.1`n")
$sha = [Security.Cryptography.SHA256]::Create()
try { $targetHash = ([BitConverter]::ToString($sha.ComputeHash($targetVersion))).Replace('-','').ToLowerInvariant() }
finally { $sha.Dispose() }
$baseHash = (Get-FileHash -LiteralPath (Join-Path $root 'version.ini') -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest = [ordered]@{schema=1;product='ArtemisOS-15';from='1.0.0';to='1.0.1';notes='fixture';files=@(
    [ordered]@{path='version.ini';base_sha256=$baseHash;sha256=$targetHash;size=$targetVersion.Length}
)}
$manifestBytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 5))
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
$rsa.PersistKeyInCsp = $false
try {
    [IO.File]::WriteAllText((Join-Path $root 'update\trusted-key.xml'), $rsa.ToXmlString($false))
    [IO.File]::WriteAllBytes((Join-Path $staged 'manifest.json'), $manifestBytes)
    [IO.File]::WriteAllText((Join-Path $staged 'manifest.sig'), [Convert]::ToBase64String($rsa.SignData($manifestBytes, 'SHA256')))
} finally { $rsa.Dispose() }
[IO.File]::WriteAllBytes((Join-Path $staged $targetHash), $targetVersion)
$pending = Join-Path $root 'data\update\pending'
[void][IO.Directory]::CreateDirectory($pending)
[IO.File]::WriteAllText((Join-Path $pending '0000.bak'), 'previous launcher', [Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $root 'launch.ps1'), 'partially updated', [Text.Encoding]::ASCII)
$backupHash = (Get-FileHash -LiteralPath (Join-Path $pending '0000.bak') -Algorithm SHA256).Hash.ToLowerInvariant()
$journal = @{schema=1;files=@(@{path='launch.ps1';existed=$true;backup='0000.bak';sha256=$backupHash})} | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $pending 'transaction.json'), $journal)
[IO.File]::WriteAllText((Join-Path $pending 'applying.flag'), '1')
$fakeAdb = Join-Path $root 'sdk\platform-tools\adb.exe'
Add-Type -OutputAssembly $fakeAdb -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
public class FixtureAdb {
    public static int Main() {
        File.WriteAllText(Environment.GetEnvironmentVariable("ARTEMIS_TEST_FAKE_ADB_MARK"), "fake adb invoked");
        return 1;
    }
}
'@
$runner = Join-Path $fixture 'runner.ps1'
[IO.File]::WriteAllText($runner, @'
param([string]$Root,[string]$Staged,[string]$TestPort)
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName,[string]$Filter)
    if ($Filter -notmatch "Name='qemu-system-x86_64-headless.exe'") { return }
    $sdk = Join-Path $Root 'sdk\emulator'
    [pscustomobject]@{Name='emulator.exe';ExecutablePath=(Join-Path $sdk 'emulator.exe');CommandLine=('emulator.exe -port ' + $TestPort);ProcessId=101;ParentProcessId=10}
    [pscustomobject]@{Name='qemu-system-x86_64-headless.exe';ExecutablePath=(Join-Path $sdk 'qemu\windows-x86_64\qemu-system-x86_64-headless.exe');CommandLine=('qemu.exe -port ' + $TestPort);ProcessId=102;ParentProcessId=101}
}
& (Join-Path $Root 'update\apply.ps1') -Staging $Staged -Serial 'emulator-5554' -EmulatorPid 101 -NoRestart
if (-not $?) { exit 1 }
'@, [Text.Encoding]::ASCII)
$marker = Join-Path $fixture 'fake-adb-called'
$previous = [Environment]::GetEnvironmentVariable('ARTEMIS_TEST_FAKE_ADB_MARK', 'Process')
[Environment]::SetEnvironmentVariable('ARTEMIS_TEST_FAKE_ADB_MARK', $marker, 'Process')
try {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & rtk proxy $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -Root $root -Staged $staged -TestPort '5554' 2>&1 | Out-Null
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($code -eq 0 -or -not (Test-Path -LiteralPath $marker)) { throw 'Headless process was not detected or fake ADB failure was ignored.' }
    [IO.File]::Delete($marker)
    try {
        $ErrorActionPreference = 'Continue'
        & rtk proxy $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -Root $root -Staged $staged -TestPort '5556' 2>&1 | Out-Null
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($code -eq 0 -or (Test-Path -LiteralPath $marker)) { throw 'Mismatched headless port reached fake ADB.' }
    if ((Get-FileHash -LiteralPath $data -Algorithm SHA256).Hash -cne $before -or
        (Get-FileHash -LiteralPath (Join-Path $root 'version.ini') -Algorithm SHA256).Hash.ToLowerInvariant() -cne $baseHash -or
        [IO.File]::ReadAllText((Join-Path $root 'launch.ps1')) -cne 'partially updated' -or
        -not (Test-Path -LiteralPath (Join-Path $pending 'applying.flag'))) {
        throw 'Refused update changed user data or version.'
    }
    Write-Host 'PASS: apply detects headless qemu; only the confirmed test port reaches fake ADB; data remains unchanged.'
} finally { [Environment]::SetEnvironmentVariable('ARTEMIS_TEST_FAKE_ADB_MARK', $previous, 'Process') }
