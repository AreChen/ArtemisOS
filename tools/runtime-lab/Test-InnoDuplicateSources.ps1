param(
    [string]$Manifest = (Join-Path $PSScriptRoot '..\..\build\runtime-slim-exp\runtime-duplicates.json'),
    [string]$Compiler = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\build\runtime-slim-exp'),
    [string]$SourceOverride,
    [switch]$RealisticWildcard
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$allowed = [IO.Path]::GetFullPath((Join-Path $project 'build\runtime-slim-exp')).TrimEnd('\')
$output = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
if ($output -ne $allowed -and -not $output.StartsWith($allowed + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Output must be inside build\runtime-slim-exp.'
}
$compilerPath = (Resolve-Path -LiteralPath $Compiler).ProviderPath
$data = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$sourcePath = if ($SourceOverride) { $SourceOverride } else { $data.source }
$source = (Resolve-Path -LiteralPath $sourcePath).ProviderPath.TrimEnd('\')
if ($source -eq $output -or $output.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The source cannot contain the output directory.'
}
$runDirectory = Join-Path $output ('inno-duplicate-fixture-' + [guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $runDirectory) { throw 'Refusing to reuse a fixture directory.' }
[void][IO.Directory]::CreateDirectory($runDirectory)

function Resolve-SourceFile([string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Unsafe relative path in manifest: $Relative"
    }
    $absolute = [IO.Path]::GetFullPath((Join-Path $source $Relative))
    if (-not $absolute.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A manifest path escapes the runtime directory.'
    }
    if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) { throw "Missing source: $Relative" }
    return $absolute
}

$seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$rows = @(foreach ($group in $data.groups) {
    $canonical = Resolve-SourceFile $group.canonical_path
    foreach ($relative in $group.paths) {
        if (-not $seen.Add([string]$relative)) { throw "Duplicate target in manifest: $relative" }
        $original = Resolve-SourceFile $relative
        if ((Get-Item -LiteralPath $original).Length -ne [Int64]$group.bytes_per_file -or
            (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -ine $group.sha256) {
            throw "Source no longer matches inventory: $relative"
        }
        [pscustomobject]@{ target = [string]$relative; original = $original; canonical = $canonical;
            sha256 = [string]$group.sha256; bytes = [Int64]$group.bytes_per_file }
    }
})
$rows = @($rows | Sort-Object target)
if ($rows.Count -lt 2) { throw 'At least two duplicate files are needed.' }
if ($RealisticWildcard) {
    # Wildcard mode is deliberately limited to a fixture containing the exact
    # inventoried files; it must never accidentally package the complete SDK.
    $fixtureFiles = @(Get-ChildItem -LiteralPath $source -File -Recurse -Force)
    if ($fixtureFiles.Count -ne $rows.Count -or -not $source.StartsWith($allowed + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Wildcard mode requires a prior duplicate-only installation fixture inside the runtime lab.'
    }
    foreach ($file in $fixtureFiles) {
        if (-not $seen.Contains($file.FullName.Substring($source.Length + 1))) { throw 'Unexpected file in wildcard fixture.' }
    }
    foreach ($row in $rows) {
        if ($row.target -like 'lib64\qt\resources\*') {
            $expected = Join-Path $source ('lib64\qt\bin\' + (Split-Path -Leaf $row.target))
            if ($row.canonical -ine $expected) { throw 'Unexpected Qt resource mapping.' }
        }
        if ($row.target -like 'lib64\qt\translations\qtwebengine_locales\*') {
            $expected = Join-Path $source ('lib64\qt\bin\qtwebengine_locales\' + (Split-Path -Leaf $row.target))
            if ($row.canonical -ine $expected) { throw 'Unexpected Qt locale mapping.' }
        }
    }
}

function Write-Fixture([string]$Name, [bool]$Merge) {
    $id = [guid]::NewGuid().ToString()
    $lines = New-Object 'Collections.Generic.List[string]'
    foreach ($line in @(
        '[Setup]', ('AppId={{' + $id + '}'), ('AppName=Artemis Runtime Laboratory ' + $Name),
        'AppVersion=0.0.0', 'PrivilegesRequired=lowest',
        ('DefaultDirName={tmp}\Artemis-Runtime-Fixture-' + $id),
        ('OutputDir=' + $runDirectory), ('OutputBaseFilename=' + $Name),
        'Compression=lzma2/fast', 'SolidCompression=yes', 'MergeDuplicateFiles=yes',
        'Uninstallable=no', 'CreateUninstallRegKey=no', 'DisableDirPage=yes',
        'DisableProgramGroupPage=yes', 'DisableWelcomePage=yes', 'DisableReadyPage=yes',
        'DisableFinishedPage=yes', '[Files]'
    )) { $lines.Add($line) }
    if ($RealisticWildcard) {
        $exclude = if ($Merge) { '; Excludes: "\lib64\qt\resources\*,\lib64\qt\translations\qtwebengine_locales\*"' } else { '' }
        $lines.Add(('Source: "{0}\*"; DestDir: "{{app}}"{1}; Flags: onlyifdoesntexist recursesubdirs createallsubdirs' -f $source,$exclude))
        if ($Merge) {
            $lines.Add(('Source: "{0}\lib64\qt\bin\*.pak"; DestDir: "{{app}}\lib64\qt\resources"; Flags: onlyifdoesntexist' -f $source))
            $lines.Add(('Source: "{0}\lib64\qt\bin\icudtl.dat"; DestDir: "{{app}}\lib64\qt\resources"; Flags: onlyifdoesntexist' -f $source))
            $lines.Add(('Source: "{0}\lib64\qt\bin\qtwebengine_locales\*.pak"; DestDir: "{{app}}\lib64\qt\translations\qtwebengine_locales"; Flags: onlyifdoesntexist' -f $source))
        }
    } else {
        foreach ($row in $rows) {
            $inputPath = if ($Merge) { $row.canonical } else { $row.original }
            $parent = Split-Path -Parent $row.target
            $leaf = Split-Path -Leaf $row.target
            $destDir = if ($parent) { '{app}\' + $parent } else { '{app}' }
            if ($inputPath.Contains('"') -or $destDir.Contains('"') -or $leaf.Contains('"')) { throw 'Unsafe quote in file path.' }
            $lines.Add(('Source: "{0}"; DestDir: "{1}"; DestName: "{2}"; Flags: onlyifdoesntexist' -f $inputPath,$destDir,$leaf))
        }
    }
    $iss = Join-Path $runDirectory ($Name + '.iss')
    [IO.File]::WriteAllLines($iss, $lines.ToArray(), (New-Object Text.UTF8Encoding $false))
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    & rtk proxy $compilerPath /Qp $iss | Out-Host
    $compileSeconds = $elapsed.Elapsed.TotalSeconds
    if ($LASTEXITCODE -ne 0) { throw "Compilation failed for $Name." }
    $exe = Join-Path $runDirectory ($Name + '.exe')
    $destination = Join-Path $runDirectory ($Name + '-install')
    $freshLog = Join-Path $runDirectory ($Name + '-fresh.log')
    if (Test-Path -LiteralPath $destination) { throw 'Refusing to use an existing test installation.' }
    $elapsed.Restart()
    & rtk proxy $exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /NOICONS ('/DIR=' + $destination) ('/LOG=' + $freshLog) | Out-Host
    $freshSeconds = $elapsed.Elapsed.TotalSeconds
    if ($LASTEXITCODE -ne 0) { throw "Installation failed for $Name." }
    $installed = @(Get-ChildItem -LiteralPath $destination -File -Recurse -Force)
    if ($installed.Count -ne $rows.Count) { throw "Unexpected installed file count for $Name." }
    foreach ($row in $rows) {
        $path = Join-Path $destination $row.target
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne $row.bytes -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $row.sha256) {
            throw "Installed fixture content mismatch: $Name / $($row.target)"
        }
    }
    # Simulate a partial existing SDK: present targets must remain untouched,
    # and absent targets must still be filled by both wildcard and alias lines.
    $existingDirectory = Join-Path $runDirectory ($Name + '-existing')
    $existingLog = Join-Path $runDirectory ($Name + '-existing.log')
    $preexisting = @('lib64\qt\bin\icudtl.dat', 'lib64\qt\resources\icudtl.dat',
        'lib64\qt\translations\qtwebengine_locales\zh-CN.pak')
    foreach ($relative in $preexisting) {
        if (-not $seen.Contains($relative)) { throw "Expected overwrite fixture file is missing: $relative" }
        $path = Join-Path $existingDirectory $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, 'previous local file: ' + $relative)
    }
    $elapsed.Restart()
    & rtk proxy $exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /NOICONS ('/DIR=' + $existingDirectory) ('/LOG=' + $existingLog) | Out-Host
    $existingSeconds = $elapsed.Elapsed.TotalSeconds
    if ($LASTEXITCODE -ne 0) { throw "Existing-directory installation failed for $Name." }
    foreach ($row in $rows) {
        $path = Join-Path $existingDirectory $row.target
        if ($row.target -in $preexisting) {
            if ([IO.File]::ReadAllText($path) -ne ('previous local file: ' + $row.target)) { throw "Existing file overwritten: $($row.target)" }
        } elseif (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $row.sha256) {
            throw "Missing or mismatched file in existing-directory fixture: $($row.target)"
        }
    }
    $destinations = @(Get-Content -LiteralPath $freshLog | Where-Object { $_ -match 'Dest filename: ' } |
        ForEach-Object { ($_ -split 'Dest filename: ', 2)[1].Substring($destination.Length + 1) })
    if ($destinations.Count -ne $rows.Count) { throw "Unexpected logged extraction entry count for $Name." }
    $destinations | Set-Content -LiteralPath (Join-Path $runDirectory ($Name + '-extraction-order.txt')) -Encoding UTF8
    return [pscustomobject]@{ name=$Name; merge=$Merge; bytes=(Get-Item -LiteralPath $exe).Length;
        installed_files=$installed.Count; installed_hashes_verified=$true; existing_targets_preserved=$preexisting.Count;
        compile_seconds=[math]::Round($compileSeconds,2); fresh_install_seconds=[math]::Round($freshSeconds,2);
        existing_install_seconds=[math]::Round($existingSeconds,2); extraction_order_entries=$destinations.Count;
        exe=$exe; install_directory=$destination; extraction_log=$freshLog }
}

$baseline = Write-Fixture 'baseline' $false
$merged = Write-Fixture 'merged' $true
$result = [pscustomobject]@{
    note = 'Inno Setup isolated fixture; lzma2/fast with solid compression. Results do not establish savings for the full lzma2/max installer.'
    realistic_wildcard = [bool]$RealisticWildcard
    duplicate_groups = @($data.groups).Count
    files = $rows.Count
    baseline = $baseline
    merged = $merged
    saved_bytes = [Int64]$baseline.bytes - [Int64]$merged.bytes
}
[IO.File]::WriteAllText((Join-Path $runDirectory 'result.json'), (($result | ConvertTo-Json -Depth 6) + [Environment]::NewLine), (New-Object Text.UTF8Encoding $false))
Write-Host "Baseline: $($baseline.bytes) bytes; merged: $($merged.bytes) bytes; saved: $($result.saved_bytes) bytes."
Write-Host "Verified $($rows.Count) installed files and $($baseline.existing_targets_preserved) existing targets in each fixture. Result: $(Join-Path $runDirectory 'result.json')"
