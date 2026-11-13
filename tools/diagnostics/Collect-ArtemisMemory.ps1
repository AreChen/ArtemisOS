param(
    [ValidateRange(1, 300)][int]$IntervalSeconds = 30,
    [ValidateRange(1, 172800)][int]$DurationSeconds = 28800,
    [ValidateRange(0, 100000)][int]$MaxSamples = 0,
    [ValidateRange(0, 2147483647)][int]$ProcessId = 0,
    [string]$OutputRoot = ([Environment]::GetFolderPath('Desktop'))
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
    throw 'The output root directory must already exist.'
}

# GetPerformanceInfo uses pages, not bytes. It reports the system-wide commit
# charge and limit; this is independent of the process working set.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace ArtemisMemoryDiag {
    [StructLayout(LayoutKind.Sequential)]
    public struct PerformanceInformation {
        public uint cb;
        public UIntPtr CommitTotal;
        public UIntPtr CommitLimit;
        public UIntPtr CommitPeak;
        public UIntPtr PhysicalTotal;
        public UIntPtr PhysicalAvailable;
        public UIntPtr SystemCache;
        public UIntPtr KernelTotal;
        public UIntPtr KernelPaged;
        public UIntPtr KernelNonpaged;
        public UIntPtr PageSize;
        public uint HandleCount;
        public uint ProcessCount;
        public uint ThreadCount;
    }
    public static class Native {
        [DllImport("psapi.dll", SetLastError = true)]
        private static extern bool GetPerformanceInfo(out PerformanceInformation info, uint size);
        public static PerformanceInformation Read() {
            var size = (uint)Marshal.SizeOf(typeof(PerformanceInformation));
            PerformanceInformation info;
            if (!GetPerformanceInfo(out info, size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return info;
        }
    }
}
'@

function Get-HostMemory {
    $info = [ArtemisMemoryDiag.Native]::Read()
    $page = $info.PageSize.ToUInt64()
    $totalCommit = $info.CommitTotal.ToUInt64() * $page
    $limitCommit = $info.CommitLimit.ToUInt64() * $page
    [pscustomobject]@{
        CommitBytes = $totalCommit
        CommitLimitBytes = $limitCommit
        CommitRemainingBytes = if ($limitCommit -gt $totalCommit) { $limitCommit - $totalCommit } else { [uint64]0 }
        PhysicalTotalBytes = $info.PhysicalTotal.ToUInt64() * $page
        PhysicalAvailableBytes = $info.PhysicalAvailable.ToUInt64() * $page
    }
}

$script:pinnedStartTicks = $null
function Get-MatchingProcesses {
    $items = @(Get-CimInstance Win32_Process -Filter "Name = 'qemu-system-x86_64.exe' OR Name = 'qemu-system-x86_64-headless.exe'" -ErrorAction Stop)
    foreach ($item in $items) {
        if ($ProcessId -gt 0) {
            if ($item.ProcessId -ne $ProcessId) { continue }
            $startTicks = $item.CreationDate.ToUniversalTime().Ticks
            if ($null -ne $script:pinnedStartTicks -and $script:pinnedStartTicks -ne $startTicks) { continue }
            if ($null -eq $script:pinnedStartTicks) { $script:pinnedStartTicks = $startTicks }
        } elseif (-not $item.CommandLine -or $item.CommandLine -notmatch '(?i)(?:^|\s)-avd\s+"?(?:ArtemisOS_15|InternalAndroid15)"?(?:\s|$)') {
            continue
        }
        $item
    }
}

function Read-SelectedConfig([string]$InstallRoot, [string]$AvdName) {
    $result = [ordered]@{ cpu_cores = $null; ram_mb = $null; width = $null; height = $null; density = $null }
    try {
        $avdRoot = Join-Path $InstallRoot 'data\avd'
        $ini = Join-Path $avdRoot ($AvdName + '.ini')
        $configPath = $null
        if (Test-Path -LiteralPath $ini -PathType Leaf) {
            $pathLine = @(Get-Content -LiteralPath $ini | Where-Object { $_ -match '^path=' } | Select-Object -First 1)
            if ($pathLine.Count) { $configPath = Join-Path ($pathLine[0] -replace '^path=', '') 'config.ini' }
        }
        if (-not $configPath -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            $configPath = Join-Path $avdRoot ($AvdName + '.avd\config.ini')
        }
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            $keys = @{ 'hw.cpu.ncore' = 'cpu_cores'; 'hw.ramSize' = 'ram_mb';
                       'hw.lcd.width' = 'width'; 'hw.lcd.height' = 'height'; 'hw.lcd.density' = 'density' }
            foreach ($line in Get-Content -LiteralPath $configPath) {
                if ($line -match '^([^=]+)=(\d+)$' -and $keys.ContainsKey($Matches[1])) {
                    $result[$keys[$Matches[1]]] = [int]$Matches[2]
                }
            }
        }
    } catch { }
    return $result
}

function Get-SessionMetadata($Item) {
    $cmd = [string]$Item.CommandLine
    $avd = $null; $gpu = $null; $port = $null
    if ($cmd -match '(?i)(?:^|\s)-avd\s+"?([A-Za-z0-9_-]+)') { $avd = $Matches[1] }
    if ($cmd -match '(?i)(?:^|\s)-gpu\s+"?([A-Za-z0-9_-]+)') { $gpu = $Matches[1] }
    if ($cmd -match '(?i)(?:^|\s)-port\s+(\d+)') { $port = [int]$Matches[1] }
    $decoderFlag = if ($cmd -match '(?i)(?:^|\s)-HardwareDecoder(?:\s|$)') { 'disabled_by_argument' } else { 'not_disabled_by_argument' }
    $version = $null; $build = $null; $productVersion = $null; $config = $null
    if ($Item.ExecutablePath) {
        try {
            $runtime = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Item.ExecutablePath))
            $installRoot = Split-Path -Parent (Split-Path -Parent $runtime)
            $sourceProperties = Join-Path $runtime 'source.properties'
            if (Test-Path -LiteralPath $sourceProperties -PathType Leaf) {
                foreach ($line in Get-Content -LiteralPath $sourceProperties) {
                    if ($line -match '^Pkg\.Revision=(.+)$') { $version = $Matches[1] }
                    elseif ($line -match '^Pkg\.BuildId=(.+)$') { $build = $Matches[1] }
                }
            }
            $versionFile = Join-Path $installRoot 'version.ini'
            if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
                foreach ($line in Get-Content -LiteralPath $versionFile) {
                    if ($line -match '^Version=([0-9A-Za-z._-]+)$') { $productVersion = $Matches[1] }
                }
            }
            if ($avd) { $config = Read-SelectedConfig $installRoot $avd }
        } catch { }
    }
    return [ordered]@{
        pid = [int]$Item.ProcessId
        process_started = $Item.CreationDate.ToString('o')
        avd_name = $avd
        console_port = $port
        graphics_requested = $gpu
        actual_renderer_note = 'For auto or software, the selected renderer may differ; check emulator startup logs.'
        hardware_decoder = $decoderFlag
        artemisos_version = $productVersion
        emulator_version = $version
        emulator_build = $build
        avd_config_at_first_observation = $config
    }
}

$folderName = 'ArtemisOS-Diagnostics-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
$outputDir = Join-Path $OutputRoot $folderName
[void][IO.Directory]::CreateDirectory($outputDir)
$csvPath = Join-Path $outputDir 'memory.csv'
$sessionsPath = Join-Path $outputDir 'sessions.jsonl'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$hostInfo = [ordered]@{
    schema = 1
    collected_at = [DateTimeOffset]::Now.ToString('o')
    interval_seconds = $IntervalSeconds
    duration_seconds = $DurationSeconds
    os = $null
    video_controllers = @()
    notes = @('Only ArtemisOS QEMU processes with recognized AVD names are auto-selected.',
              'Commit is a system-wide resource, distinct from physical available memory.',
              'No screen, Android logs, account data, complete command lines, or memory dumps are collected.')
}
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $hostInfo.os = [ordered]@{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber; architecture = $os.OSArchitecture }
} catch { }
try {
    $hostInfo.video_controllers = @(Get-CimInstance Win32_VideoController | ForEach-Object {
        [ordered]@{ name = $_.Name; driver_version = $_.DriverVersion }
    })
} catch { }
[IO.File]::WriteAllText((Join-Path $outputDir 'host.json'), ($hostInfo | ConvertTo-Json -Depth 8), $utf8)
[IO.File]::WriteAllText($sessionsPath, '', $utf8)

Write-Host "Output folder: $outputDir"
Write-Host 'Start or continue ArtemisOS and keep this window open. Press Ctrl+C to stop.'
Write-Host 'Samples are saved as they are taken. The tool never restarts or modifies the emulator.'
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$sessions = @{}
$sampleCount = 0
do {
    $now = [DateTimeOffset]::Now
    $tick = $stopwatch.Elapsed.TotalSeconds
    $memory = Get-HostMemory
    $queryError = $false
    try { $items = @(Get-MatchingProcesses) } catch { $items = @(); $queryError = $true }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        try {
            $proc = Get-Process -Id $item.ProcessId -ErrorAction Stop
            $proc.Refresh()
            $key = '{0}:{1}' -f $item.ProcessId, $item.CreationDate.ToUniversalTime().Ticks
            if (-not $sessions.ContainsKey($key)) {
                $session = Get-SessionMetadata $item
                [IO.File]::AppendAllText($sessionsPath, (($session | ConvertTo-Json -Depth 8 -Compress) + "`n"), $utf8)
                $sessions[$key] = @{ session = $session; previous_time = $null; previous_cpu = $null }
            }
            $tracking = $sessions[$key]
            $cpuSeconds = $proc.TotalProcessorTime.TotalSeconds
            $cpuOneCore = $null
            if ($null -ne $tracking.previous_time -and $tick -gt $tracking.previous_time -and $cpuSeconds -ge $tracking.previous_cpu) {
                $cpuOneCore = [math]::Round(100 * ($cpuSeconds - $tracking.previous_cpu) / ($tick - $tracking.previous_time), 2)
            }
            $tracking.previous_time = $tick
            $tracking.previous_cpu = $cpuSeconds
            $rows.Add([pscustomobject][ordered]@{
                time = $now.ToString('o'); status = 'running'; pid = [int]$item.ProcessId
                process_started = $item.CreationDate.ToString('o'); graphics_requested = $tracking.session.graphics_requested
                private_commit_bytes = [int64]$proc.PrivateMemorySize64; working_set_bytes = [int64]$proc.WorkingSet64
                cpu_percent_one_core = $cpuOneCore; handle_count = $proc.HandleCount; thread_count = $proc.Threads.Count
                host_commit_bytes = $memory.CommitBytes; host_commit_limit_bytes = $memory.CommitLimitBytes
                host_commit_remaining_bytes = $memory.CommitRemainingBytes; host_physical_total_bytes = $memory.PhysicalTotalBytes
                host_physical_available_bytes = $memory.PhysicalAvailableBytes
            })
        } catch { }
    }
    if ($rows.Count -eq 0) {
        $status = if ($queryError) { 'process_query_failed' } else { 'no_matching_process' }
        $rows.Add([pscustomobject][ordered]@{
            time = $now.ToString('o'); status = $status; pid = $null; process_started = $null; graphics_requested = $null
            private_commit_bytes = $null; working_set_bytes = $null; cpu_percent_one_core = $null; handle_count = $null; thread_count = $null
            host_commit_bytes = $memory.CommitBytes; host_commit_limit_bytes = $memory.CommitLimitBytes
            host_commit_remaining_bytes = $memory.CommitRemainingBytes; host_physical_total_bytes = $memory.PhysicalTotalBytes
            host_physical_available_bytes = $memory.PhysicalAvailableBytes
        })
    }
    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Append -Encoding UTF8
    $sampleCount++
    $remainingGiB = [math]::Round($memory.CommitRemainingBytes / 1GB, 2)
    $memoryText = @($rows | Where-Object { $_.status -eq 'running' } | ForEach-Object {
        'PID {0}: private {1:N2} GiB' -f $_.pid, ($_.private_commit_bytes / 1GB)
    }) -join '; '
    if (-not $memoryText) { $memoryText = $rows[0].status }
    Write-Host ('{0} | {1} | system commit remaining {2:N2} GiB' -f $now.ToString('HH:mm:ss'), $memoryText, $remainingGiB)
    if ($memory.CommitRemainingBytes -lt 2GB) {
        Write-Warning 'System commit remaining is below 2 GiB. Stop the test if memory pressure continues; this tool does not stop the emulator.'
    }
    if ($MaxSamples -gt 0 -and $sampleCount -ge $MaxSamples) { break }
    $remaining = $DurationSeconds - $stopwatch.Elapsed.TotalSeconds
    if ($remaining -le 0) { break }
    Start-Sleep -Seconds ([math]::Min($IntervalSeconds, [math]::Ceiling($remaining)))
} while ($stopwatch.Elapsed.TotalSeconds -lt $DurationSeconds)
Write-Host "Finished. Send the output folder for analysis: $outputDir"
