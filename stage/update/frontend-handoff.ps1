# Shared by the launcher, initializer and updater. No process is ever killed here.
function Assert-ArtemisFrontendPathSafe([string]$Path) {
    $part = [IO.Path]::GetFullPath($Path)
    while ($part) {
        try { $attributes = [IO.File]::GetAttributes($part) }
        catch {
            $reason = $_.Exception
            while ($reason -is [Management.Automation.MethodInvocationException] -and $reason.InnerException) { $reason = $reason.InnerException }
            if ($reason -isnot [IO.FileNotFoundException] -and $reason -isnot [IO.DirectoryNotFoundException]) { throw 'Cannot verify the frontend session path.' }
            $attributes = 0
        }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Frontend session paths cannot traverse reparse points.' }
        $parent = [IO.Path]::GetDirectoryName($part.TrimEnd([char[]]'\/'))
        if (-not $parent -or [string]::Equals($part, $parent, [StringComparison]::OrdinalIgnoreCase)) { break }
        $part = $parent
    }
}

function Get-ArtemisFrontendSessionPath([string]$InstallRoot, [string]$SessionId) {
    if ($SessionId -cnotmatch '^[0-9a-f]{32}$') { throw 'A frontend session must be a lowercase GUID in N format.' }
    if (-not [IO.Path]::IsPathRooted($InstallRoot)) { throw 'The frontend installation path must be absolute.' }
    $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd([char[]]'\/')
    $path = Join-Path $root ('data\runtime\' + $SessionId + '.json')
    Assert-ArtemisFrontendPathSafe $path
    return $path
}

function Get-ArtemisFrontendPipeName([string]$InstallRoot, [string]$SessionId) {
    [void](Get-ArtemisFrontendSessionPath $InstallRoot $SessionId)
    $normalized = [IO.Path]::GetFullPath($InstallRoot).TrimEnd([char[]]'\/').ToUpperInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return 'ArtemisOS-Frontend-' + $digest + '-' + $SessionId
}

function Get-ArtemisFrontendProcessSnapshot([int]$ProcessId) {
    if ($ProcessId -le 0) { return $null }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $null }
    try {
        $path = $process.Path
        if (-not $path) { throw 'Cannot verify the process executable path.' }
        return [pscustomobject]@{
            ProcessId=$process.Id
            ExecutablePath=[IO.Path]::GetFullPath($path)
            StartTimeUtcTicks=$process.StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
        }
    } catch {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $null }
        throw 'Cannot verify the process path and exact creation time.'
    } finally { $process.Dispose() }
}

function Test-ArtemisFrontendIdentity($Process, [string]$InstallRoot, [int]$FrontendPid, [string]$FrontendStartTimeUtcTicks) {
    if ($null -eq $Process -or $FrontendPid -le 0 -or $FrontendStartTimeUtcTicks -cnotmatch '^[1-9][0-9]{0,18}$') { return $false }
    try {
        $ticks = [long]$FrontendStartTimeUtcTicks
        if ($ticks -gt [DateTime]::MaxValue.Ticks) { return $false }
        $expected = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'update\frontend\ArtemisFrontend.exe'))
        return ([int]$Process.ProcessId -eq $FrontendPid -and
            [string]::Equals([IO.Path]::GetFullPath([string]$Process.ExecutablePath), $expected, [StringComparison]::OrdinalIgnoreCase) -and
            [string]$Process.StartTimeUtcTicks -ceq $FrontendStartTimeUtcTicks)
    } catch { return $false }
}

function Test-ArtemisFrontendBackendIdentity($Process, [string]$InstallRoot, [int]$EmulatorPid, [string]$EmulatorStartTimeUtcTicks) {
    if ($null -eq $Process -or $EmulatorPid -le 0 -or $EmulatorStartTimeUtcTicks -cnotmatch '^[1-9][0-9]{0,18}$') { return $false }
    try {
        if ([long]$EmulatorStartTimeUtcTicks -gt [DateTime]::MaxValue.Ticks) { return $false }
        $expected = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'sdk\emulator\emulator.exe'))
        return ([int]$Process.ProcessId -eq $EmulatorPid -and
            [string]::Equals([IO.Path]::GetFullPath([string]$Process.ExecutablePath), $expected, [StringComparison]::OrdinalIgnoreCase) -and
            [string]$Process.StartTimeUtcTicks -ceq $EmulatorStartTimeUtcTicks)
    } catch { return $false }
}

function Write-ArtemisFrontendSessionFile([string]$Path, $Session, [switch]$CreateOnly) {
    Assert-ArtemisFrontendPathSafe $Path
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $previous = $temporary + '.previous'
    try {
        Assert-ArtemisFrontendPathSafe $temporary
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Session | ConvertTo-Json -Depth 4))
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Assert-ArtemisFrontendPathSafe $Path
        if ($CreateOnly) { [IO.File]::Move($temporary, $Path) }
        else {
            Assert-ArtemisFrontendPathSafe $previous
            [IO.File]::Replace($temporary, $Path, $previous)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ([IO.File]::Exists($previous)) { [IO.File]::Delete($previous) }
    }
}

function New-ArtemisFrontendSession {
    param(
        [string]$InstallRoot, [string]$SessionId, [string]$Serial,
        [int]$EmulatorPid, [string]$EmulatorStartTimeUtcTicks,
        [int]$FrontendPid, [string]$FrontendStartTimeUtcTicks,
        [ValidateSet('auto','swiftshader')][string]$GraphicsOverride = 'auto',
        [string]$GraphicsRenderer, [string]$GraphicsDevice = '', [string]$StdoutLog, [string]$StderrLog
    )
    $path = Get-ArtemisFrontendSessionPath $InstallRoot $SessionId
    if ($Serial -notmatch '^emulator-(555[468]|55[67][02468]|558[024])$' -or
        $EmulatorPid -le 0 -or $EmulatorStartTimeUtcTicks -cnotmatch '^[1-9][0-9]{0,18}$' -or
        [long]$EmulatorStartTimeUtcTicks -gt [DateTime]::MaxValue.Ticks) { throw 'The frontend backend identity is invalid.' }
    if (-not (Test-ArtemisFrontendIdentity (Get-ArtemisFrontendProcessSnapshot $FrontendPid) $InstallRoot $FrontendPid $FrontendStartTimeUtcTicks)) {
        throw 'The frontend executable path or creation time does not match this installation.'
    }
    if (-not (Test-ArtemisFrontendBackendIdentity (Get-ArtemisFrontendProcessSnapshot $EmulatorPid) $InstallRoot $EmulatorPid $EmulatorStartTimeUtcTicks)) {
        throw 'The backend executable path or creation time does not match this installation.'
    }
    $session = [ordered]@{
        schemaVersion=1; sessionId=$SessionId
        installRoot=[IO.Path]::GetFullPath($InstallRoot).TrimEnd([char[]]'\/')
        serial=$Serial; emulatorPid=$EmulatorPid; emulatorStartTimeUtcTicks=[string]$EmulatorStartTimeUtcTicks
        graphicsOverride=$GraphicsOverride; graphicsRenderer=$GraphicsRenderer; graphicsDevice=$GraphicsDevice
        frontendPid=$FrontendPid; frontendStartTimeUtcTicks=[string]$FrontendStartTimeUtcTicks
        state='starting'; error=''; stdoutLog=$StdoutLog; stderrLog=$StderrLog; actualRenderer=''
    }
    Write-ArtemisFrontendSessionFile $path $session -CreateOnly
}

function Read-ArtemisFrontendSession([string]$InstallRoot, [string]$SessionId) {
    $path = Get-ArtemisFrontendSessionPath $InstallRoot $SessionId
    if ((Get-Item -LiteralPath $path -Force).Length -gt 65536) { throw 'The frontend session receipt is too large.' }
    $session = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($session.schemaVersion -ne 1 -or $session.sessionId -cne $SessionId -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$session.installRoot).TrimEnd([char[]]'\/'),
            [IO.Path]::GetFullPath($InstallRoot).TrimEnd([char[]]'\/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The frontend session belongs to another installation or session.'
    }
    return $session
}

function Set-ArtemisFrontendSessionState {
    param(
        [string]$InstallRoot, [string]$SessionId, [string]$Serial, [int]$EmulatorPid,
        [ValidateSet('ready','failed')][string]$State, [string]$Error = '', [string]$ActualRenderer = ''
    )
    $session = Read-ArtemisFrontendSession $InstallRoot $SessionId
    if ($session.serial -cne $Serial -or [int]$session.emulatorPid -ne $EmulatorPid) { throw 'The initializer does not own this frontend session.' }
    if ($State -ceq 'ready') {
        $backend = Get-ArtemisFrontendProcessSnapshot $EmulatorPid
        if (-not (Test-ArtemisFrontendBackendIdentity $backend $InstallRoot $EmulatorPid ([string]$session.emulatorStartTimeUtcTicks))) { throw 'The initialized backend has exited or its identity has changed.' }
        if ([string]::IsNullOrWhiteSpace($ActualRenderer)) { throw 'The actual renderer is missing from a ready frontend session.' }
        $Error = ''
    } elseif ([string]::IsNullOrWhiteSpace($Error)) { throw 'A failed frontend session needs an error message.' }
    $session.state = $State
    $session.error = $Error
    $session.actualRenderer = $ActualRenderer
    Write-ArtemisFrontendSessionFile (Get-ArtemisFrontendSessionPath $InstallRoot $SessionId) $session
}

function Request-ArtemisFrontendExitForUpdate {
    param(
        [string]$InstallRoot, [string]$Serial, [int]$EmulatorPid = 0,
        [ValidateRange(100,60000)][int]$TimeoutMilliseconds = 15000
    )
    $expectedExe = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'update\frontend\ArtemisFrontend.exe'))
    Assert-ArtemisFrontendPathSafe $expectedExe
    $live = @()
    foreach ($candidate in @(Get-CimInstance Win32_Process -Filter "Name='ArtemisFrontend.exe'" -ErrorAction Stop)) {
        if (-not $candidate.ExecutablePath) { throw 'Cannot verify a frontend process path; update has been stopped.' }
        if (-not [string]::Equals([IO.Path]::GetFullPath([string]$candidate.ExecutablePath), $expectedExe, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $snapshot = Get-ArtemisFrontendProcessSnapshot ([int]$candidate.ProcessId)
        if ($null -ne $snapshot) { $live += $snapshot }
    }
    if ($live.Count -eq 0) { return $false }
    if ($live.Count -ne 1 -or $EmulatorPid -le 0) { throw 'Cannot uniquely associate the active frontend with this update.' }
    $runtimeDirectory = Join-Path $InstallRoot 'data\runtime'
    Assert-ArtemisFrontendPathSafe $runtimeDirectory
    $matchedSessions = @()
    if (Test-Path -LiteralPath $runtimeDirectory -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $runtimeDirectory -File -Filter '*.json' -Force) {
            if ($file.BaseName -cnotmatch '^[0-9a-f]{32}$') { continue }
            try { $session = Read-ArtemisFrontendSession $InstallRoot $file.BaseName } catch { continue }
            if ($session.serial -cne $Serial -or [int]$session.emulatorPid -ne $EmulatorPid) { continue }
            if (Test-ArtemisFrontendIdentity $live[0] $InstallRoot ([int]$session.frontendPid) ([string]$session.frontendStartTimeUtcTicks)) { $matchedSessions += $session }
        }
    }
    if ($matchedSessions.Count -ne 1) { throw 'The active frontend has no unique matching backend/session receipt; update has been stopped.' }
    $session = $matchedSessions[0]
    $backend = Get-ArtemisFrontendProcessSnapshot $EmulatorPid
    if (-not (Test-ArtemisFrontendBackendIdentity $backend $InstallRoot $EmulatorPid ([string]$session.emulatorStartTimeUtcTicks))) { throw 'The backend creation time does not match the frontend session.' }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', (Get-ArtemisFrontendPipeName $InstallRoot $session.sessionId), [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    $reader = $null; $writer = $null
    try {
        $pipe.Connect($TimeoutMilliseconds)
        $writer = New-Object IO.StreamWriter($pipe, (New-Object Text.UTF8Encoding($false)), 1024, $true)
        $reader = New-Object IO.StreamReader($pipe, [Text.Encoding]::UTF8, $false, 1024, $true)
        $writer.WriteLine('prepare-update:' + $session.sessionId)
        $writer.Flush()
        $read = $reader.ReadLineAsync()
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $read.Wait($remaining)) { throw 'The frontend update handshake timed out.' }
        if ($read.Result -cne ('ready:' + $session.sessionId)) { throw 'The frontend did not acknowledge this update session.' }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $writer) { $writer.Dispose() }
        $pipe.Dispose()
    }
    while ($true) {
        $current = Get-ArtemisFrontendProcessSnapshot ([int]$session.frontendPid)
        if ($null -eq $current -or $current.StartTimeUtcTicks -cne $session.frontendStartTimeUtcTicks) { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'The frontend acknowledged the update but has not exited; no files were replaced.' }
        Start-Sleep -Milliseconds 50
    }
    # An automatic restart or a second frontend must not race file replacement.
    foreach ($candidate in @(Get-CimInstance Win32_Process -Filter "Name='ArtemisFrontend.exe'" -ErrorAction Stop)) {
        if (-not $candidate.ExecutablePath) { throw 'Cannot verify frontend exit.' }
        if ([string]::Equals([IO.Path]::GetFullPath([string]$candidate.ExecutablePath), $expectedExe, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A frontend is still running from this installation; update has been stopped.'
        }
    }
    return $true
}
