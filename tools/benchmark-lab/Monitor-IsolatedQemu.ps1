param(
    [Parameter(Mandatory=$true)][string]$TestRoot,
    [Parameter(Mandatory=$true)][string]$QemuExecutable,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$AvdName,
    [Parameter(Mandatory=$true)][ValidateRange(5554, 5680)][int]$Port,
    [Parameter(Mandatory=$true)][string]$Output,
    [ValidateRange(1, 10)][int]$ExpectedSessions = 2,
    [ValidateRange(1, 30)][int]$IntervalSeconds = 5,
    [ValidateRange(10, 1800)][int]$WaitSeconds = 300,
    [ValidateRange(10, 3600)][int]$DurationSeconds = 1200
)

$ErrorActionPreference = 'Stop'
if ($Port % 2 -ne 0) { throw 'The test port must be even.' }
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$allowedBuild = [IO.Path]::GetFullPath((Join-Path $project 'build')).TrimEnd('\')
$allowedTemp = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'ArtemisOS-image-lab')).TrimEnd('\')
$root = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
if (-not ($root.StartsWith($allowedBuild + '\', [StringComparison]::OrdinalIgnoreCase) -or
          $root.StartsWith($allowedTemp + '\', [StringComparison]::OrdinalIgnoreCase))) {
    throw 'TestRoot must be an isolated directory under build/ or the dedicated ArtemisOS-image-lab temporary root.'
}
$out = [IO.Path]::GetFullPath($Output)
if ($out.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Output must be outside TestRoot, so the monitor does not create the test directory.'
}
if (Test-Path -LiteralPath $out) { throw 'Refusing to overwrite an existing measurement.' }
$outParent = Split-Path -Parent $out
if (-not (Test-Path -LiteralPath $outParent -PathType Container)) { throw 'Output parent directory must already exist.' }
$expectedExe = (Resolve-Path -LiteralPath $QemuExecutable).ProviderPath
if ([IO.Path]::GetFileName($expectedExe) -notin @('qemu-system-x86_64.exe','qemu-system-x86_64-headless.exe')) {
    throw 'QemuExecutable must identify a Windows x86_64 emulator QEMU binary.'
}
$expectedSysdir = Join-Path $root 'sysdir'
$resultFile = Join-Path $root 'test-results.json'
if (Test-Path -LiteralPath $resultFile) { throw 'TestRoot contains a result from an earlier run.' }

function Test-Invocation([string]$CommandLine) {
    if (-not $CommandLine) { return $false }
    $avd = [regex]::Escape($AvdName)
    $sysdir = [regex]::Escape($expectedSysdir)
    return ($CommandLine -match "(?i)(?:^|\s)-avd\s+`"?$avd`"?(?:\s|$)" -and
            $CommandLine -match "(?i)(?:^|\s)-port\s+$Port(?:\s|$)" -and
            $CommandLine -match "(?i)(?:^|\s)-sysdir\s+`"?$sysdir`"?(?:\s|$)")
}

function Find-OwnedQemu {
    $name = [IO.Path]::GetFileName($expectedExe)
    $matches = @()
    foreach ($item in @(Get-CimInstance Win32_Process -Filter "Name='$name'")) {
        if (-not $item.ExecutablePath -or -not $item.ExecutablePath.Equals($expectedExe, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $owned = Test-Invocation $item.CommandLine
        $parentOwned = $false
        if ($item.ParentProcessId) {
            $parent = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $item.ParentProcessId)
            $emulatorRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $expectedExe) '..\..'))
            $expectedParent = Join-Path $emulatorRoot 'emulator.exe'
            if ($parent -and $parent.ExecutablePath -and $parent.ExecutablePath.Equals($expectedParent, [StringComparison]::OrdinalIgnoreCase)) {
                $parentOwned = Test-Invocation $parent.CommandLine
                if (-not $owned) { $owned = $parentOwned }
            }
        }
        if ($owned) {
            # On some Windows builds CIM reports an unknown state for a
            # listener. Match the local bound endpoint (remote port zero) and
            # its owner instead of filtering the potentially unavailable state.
            $listeners = @(Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue | Where-Object { $_.RemotePort -eq 0 })
            if (-not $listeners.Count) { continue }
            $ownerIds = @([uint32]$item.ProcessId)
            if ($parentOwned) { $ownerIds += [uint32]$item.ParentProcessId }
            $valid = @($listeners | Where-Object { $ownerIds -contains [uint32]$_.OwningProcess })
            if (-not $valid.Count) { throw 'The test console port is bound by a different process.' }
            $matches += [PSCustomObject]@{ Process = $item; PortOwnerPid = [uint32]$valid[0].OwningProcess }
        }
    }
    if ($matches.Count -gt 1) { throw 'More than one process matches the isolated target; refusing ambiguous sampling.' }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

$os = Get-CimInstance Win32_OperatingSystem
$computer = Get-CimInstance Win32_ComputerSystem
$logicalCpus = [Environment]::ProcessorCount
$samples = [Collections.Generic.List[object]]::new()
$sessions = [Collections.Generic.List[object]]::new()
$byProcess = @{}
$clock = [Diagnostics.Stopwatch]::StartNew()
$sampleDeadlineSeconds = $null
$result = [ordered]@{
    schema = 1
    test_root = $root
    qemu_executable = $expectedExe
    avd_name = $AvdName
    port = $Port
    interval_seconds = $IntervalSeconds
    expected_sessions = $ExpectedSessions
    host = [ordered]@{ os = $os.Caption; os_version = $os.Version; os_build = $os.BuildNumber;
        logical_cpus = $logicalCpus; physical_memory_bytes = [uint64]$computer.TotalPhysicalMemory }
    scope = 'QEMU process only: working set, private bytes and process CPU. Other emulator processes, GPU/driver and separately accounted hypervisor memory/CPU are excluded.'
    readiness_note = 'Samples start on observing QEMU; use the matching Test-Candidate test-results.json for boot and compatibility results. Sample windows may include startup and active probes.'
    sessions = $null
    samples = $null
    complete = $false
    error = $null
}
try {
    while ($true) {
        if ($null -ne $sampleDeadlineSeconds -and $clock.Elapsed.TotalSeconds -ge $sampleDeadlineSeconds) { break }
        if ($null -eq $sampleDeadlineSeconds -and $clock.Elapsed.TotalSeconds -ge $WaitSeconds) { throw 'Timed out waiting for the isolated QEMU process.' }
        $owned = Find-OwnedQemu
        if ($owned) {
            $item = $owned.Process
            try { $proc = Get-Process -Id $item.ProcessId -ErrorAction Stop; $proc.Refresh() }
            catch { Start-Sleep -Seconds $IntervalSeconds; continue }
            $now = [DateTime]::UtcNow
            $monotonicSeconds = $clock.Elapsed.TotalSeconds
            $processKey = '{0}:{1}' -f $item.ProcessId, $item.CreationDate.ToUniversalTime().ToString('o')
            if (-not $byProcess.ContainsKey($processKey)) {
                $session = [ordered]@{ index = $sessions.Count + 1; pid = $item.ProcessId;
                    process_created_utc = $item.CreationDate.ToUniversalTime().ToString('o'); first_observed_utc = $now.ToString('o');
                    last_observed_utc = $null; samples = 0; peak_working_set_bytes = [int64]0; peak_private_bytes = [int64]0 }
                $byProcess[$processKey] = @{ summary = $session; lastMonotonic = $null; lastCpu = $null }
                $sessions.Add($session)
                if ($null -eq $sampleDeadlineSeconds) { $sampleDeadlineSeconds = $monotonicSeconds + $DurationSeconds }
            }
            $tracking = $byProcess[$processKey]
            $cpuSeconds = $proc.TotalProcessorTime.TotalSeconds
            $cpuSingle = $null
            $cpuHost = $null
            $elapsed = $null
            if ($null -ne $tracking.lastMonotonic) {
                $elapsed = $monotonicSeconds - $tracking.lastMonotonic
                if ($elapsed -gt 0 -and $cpuSeconds -ge $tracking.lastCpu) {
                    $cpuSingle = [math]::Round(100 * ($cpuSeconds - $tracking.lastCpu) / $elapsed, 2)
                    $cpuHost = [math]::Round($cpuSingle / $logicalCpus, 2)
                }
            }
            $working = [int64]$proc.WorkingSet64
            $private = [int64]$proc.PrivateMemorySize64
            $samples.Add([ordered]@{ observed_utc = $now.ToString('o'); elapsed_since_monitor_seconds = [math]::Round($monotonicSeconds, 3);
                session = $tracking.summary.index; pid = $item.ProcessId; console_port_owner_pid = $owned.PortOwnerPid;
                sample_window_seconds = if ($null -ne $elapsed) { [math]::Round($elapsed, 3) } else { $null };
                cpu_time_seconds = [math]::Round($cpuSeconds, 3); cpu_percent_one_core = $cpuSingle;
                cpu_percent_host_capacity = $cpuHost; working_set_bytes = $working; private_bytes = $private })
            $tracking.lastMonotonic = $monotonicSeconds
            $tracking.lastCpu = $cpuSeconds
            $tracking.summary.last_observed_utc = $now.ToString('o')
            $tracking.summary.samples++
            $tracking.summary.peak_working_set_bytes = [math]::Max($tracking.summary.peak_working_set_bytes, $working)
            $tracking.summary.peak_private_bytes = [math]::Max($tracking.summary.peak_private_bytes, $private)
        } elseif ($sessions.Count -gt 0 -and (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
            if ($sessions.Count -ne $ExpectedSessions) { throw "Observed $($sessions.Count) sessions; expected $ExpectedSessions." }
            $result.complete = $true
            break
        } elseif ($sessions.Count -eq 0 -and (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
            throw 'The test ended before its QEMU process was observed.'
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
    if ($sessions.Count -eq 0) { throw 'No isolated QEMU process was sampled.' }
} catch {
    $result.error = $_.Exception.Message
} finally {
    $result.sessions = @($sessions.ToArray())
    $result.samples = @($samples.ToArray())
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $out -Encoding UTF8
}
if ($result.error) { Write-Error $result.error; exit 1 }
if (-not $result.complete) { Write-Output 'Sampling duration elapsed before the test result appeared; measurements are partial.' }
Write-Output "QEMU measurement saved to $out"
