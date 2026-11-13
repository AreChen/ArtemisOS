$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root = Join-Path $project ('build\diagnostic-memory-selftest-' + [guid]::NewGuid().ToString('N'))
$exeDir = Join-Path $root 'sdk\emulator\qemu\windows-x86_64'
$decoyDir = Join-Path $root 'decoy'
$avdDir = Join-Path $root 'data\avd\InternalAndroid15.avd'
$outRoot = Join-Path $root 'output'
foreach ($dir in @($exeDir, $decoyDir, $avdDir, $outRoot)) { [void][IO.Directory]::CreateDirectory($dir) }
$exe = Join-Path $exeDir 'qemu-system-x86_64.exe'
$decoy = Join-Path $decoyDir 'qemu-system-x86_64.exe'
Add-Type -OutputAssembly $exe -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.Threading;
public static class SyntheticQemuForMemoryTest {
    public static void Main(string[] args) {
        var data = new byte[4 * 1024 * 1024];
        data[0] = 1;
        Thread.Sleep(18000);
        GC.KeepAlive(data);
    }
}
'@
Copy-Item -LiteralPath $exe -Destination $decoy
[IO.File]::WriteAllText((Join-Path $root 'version.ini'), "[ArtemisOS]`nVersion=1.0.0`n")
[IO.File]::WriteAllText((Join-Path $root 'sdk\emulator\source.properties'), "Pkg.Revision=37.3.6`nPkg.BuildId=16696583`n")
[IO.File]::WriteAllText((Join-Path $root 'data\avd\ArtemisOS_15.ini'), "path=$avdDir`n")
[IO.File]::WriteAllText((Join-Path $avdDir 'config.ini'), "hw.cpu.ncore=4`nhw.ramSize=4096`nhw.lcd.width=720`nhw.lcd.height=1600`nhw.lcd.density=320`n")
$rtk = (Get-Command rtk -CommandType Application).Source
$targetRunner = Start-Process -FilePath $rtk -ArgumentList @('proxy', ('"' + $exe + '"'), '-avd', 'ArtemisOS_15', '-gpu', 'swiftshader', '-port', '5554', '-feature', '-HardwareDecoder') -PassThru -WindowStyle Hidden
$decoyRunner = Start-Process -FilePath $rtk -ArgumentList @('proxy', ('"' + $decoy + '"'), '-avd', 'UnrelatedAVD') -PassThru -WindowStyle Hidden
$target = $null; $other = $null
try {
    for ($attempt = 0; $attempt -lt 30 -and (-not $target -or -not $other); $attempt++) {
        $all = @(Get-CimInstance Win32_Process -Filter "Name = 'qemu-system-x86_64.exe'")
        $target = @($all | Where-Object { $_.ExecutablePath -eq $exe } | Select-Object -First 1)
        $other = @($all | Where-Object { $_.ExecutablePath -eq $decoy } | Select-Object -First 1)
        if (-not $target.Count -or -not $other.Count) { Start-Sleep -Milliseconds 200 }
    }
    if (-not $target.Count -or -not $other.Count) { throw 'Synthetic QEMU processes did not start.' }
    $targetId = [int]$target[0].ProcessId
    $decoyId = [int]$other[0].ProcessId
    $monitor = Join-Path $project 'tools\diagnostics\Collect-ArtemisMemory.ps1'
    & rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File $monitor -IntervalSeconds 1 -DurationSeconds 20 -MaxSamples 2 -OutputRoot $outRoot
    if ($LASTEXITCODE -ne 0) { throw 'Auto-selection run failed.' }
    $firstDir = Get-ChildItem -LiteralPath $outRoot -Directory | Select-Object -First 1
    $firstRows = @(Import-Csv -LiteralPath (Join-Path $firstDir.FullName 'memory.csv'))
    if (-not @($firstRows | Where-Object { $_.pid -eq [string]$targetId -and $_.status -eq 'running' }).Count) { throw 'Auto-selection missed the matching AVD.' }
    if (@($firstRows | Where-Object { $_.pid -eq [string]$decoyId }).Count) { throw 'Auto-selection included an unrelated AVD.' }

    & rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File $monitor -IntervalSeconds 1 -DurationSeconds 35 -MaxSamples 15 -ProcessId $targetId -OutputRoot $outRoot
    if ($LASTEXITCODE -ne 0) { throw 'PID selection run failed.' }
    $secondDir = @(Get-ChildItem -LiteralPath $outRoot -Directory | Where-Object { $_.FullName -ne $firstDir.FullName })[0]
    $rows = @(Import-Csv -LiteralPath (Join-Path $secondDir.FullName 'memory.csv'))
    $sessions = @(Get-Content -LiteralPath (Join-Path $secondDir.FullName 'sessions.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    if (@($rows | Where-Object { $_.status -eq 'running' -and $_.pid -eq [string]$targetId }).Count -lt 2) { throw 'Not enough samples from the selected PID.' }
    if (-not @($rows | Where-Object { $_.status -eq 'no_matching_process' }).Count) { throw 'Process exit was not recorded.' }
    if (@($rows | Where-Object { $_.status -eq 'running' -and $_.pid -ne [string]$targetId }).Count) { throw 'PID selection included another process.' }
    if ($sessions.Count -ne 1 -or $sessions[0].emulator_version -ne '37.3.6' -or $sessions[0].artemisos_version -ne '1.0.0') { throw 'Version metadata is incorrect.' }
    if ($sessions[0].graphics_requested -ne 'swiftshader' -or $sessions[0].hardware_decoder -ne 'disabled_by_argument') { throw 'Launch metadata is incorrect.' }
    if ($sessions[0].avd_config_at_first_observation.ram_mb -ne 4096 -or $sessions[0].avd_config_at_first_observation.cpu_cores -ne 4) { throw 'AVD metadata is incorrect.' }
    $sample = @($rows | Where-Object { $_.status -eq 'running' })[0]
    if ([long]$sample.private_commit_bytes -le 0 -or [long]$sample.working_set_bytes -le 0 -or [long]$sample.host_commit_remaining_bytes -le 0) { throw 'A memory metric is missing.' }
    $expected = [long]$sample.host_commit_limit_bytes - [long]$sample.host_commit_bytes
    if ([long]$sample.host_commit_remaining_bytes -ne $expected) { throw 'System commit remaining was calculated incorrectly.' }
    Write-Output 'PASS: matching and unrelated AVDs, PID selection, process exit, metadata, and system commit accounting.'
} finally {
    foreach ($runner in @($targetRunner, $decoyRunner)) {
        if (-not $runner.HasExited) { Wait-Process -Id $runner.Id -Timeout 25 -ErrorAction SilentlyContinue }
    }
}
