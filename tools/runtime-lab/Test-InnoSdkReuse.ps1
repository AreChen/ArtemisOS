param(
    [string]$DuplicateFixture = (Join-Path $PSScriptRoot '..\..\build\runtime-slim-exp\inno-duplicate-fixture-51e9099c7a334926ad2fac5681142a82\baseline-install'),
    [string]$Compiler = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\build\runtime-slim-exp')
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
$fixture = (Resolve-Path -LiteralPath $DuplicateFixture).ProviderPath.TrimEnd('\')
if (-not $fixture.StartsWith($allowed + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Source fixture must be in the runtime lab.' }
$compiler = (Resolve-Path -LiteralPath $Compiler).ProviderPath
$runDirectory = Join-Path $output ('inno-sdk-reuse-' + [guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $runDirectory) { throw 'Refusing to reuse a fixture directory.' }
$sdk = Join-Path $runDirectory 'source-sdk'
$emulator = Join-Path $sdk 'emulator'
$generated = Join-Path $runDirectory 'generated'
[void][IO.Directory]::CreateDirectory($sdk)
Copy-Item -LiteralPath $fixture -Destination $emulator -Recurse
$generator = Join-Path $PSScriptRoot 'Write-InnoReuseSnippet.ps1'
& $generator -SdkRoot $sdk -OutputDirectory $generated
$report = Get-Content -LiteralPath (Join-Path $generated 'sdk-reuse-verification.json') -Raw | ConvertFrom-Json
if ($report.verified_pairs -ne 58) { throw 'Fixture does not contain the expected 58 Qt pairs.' }

# Simulate a future SDK file that appeared after the list was generated. The
# exact exclusions must leave it to the original wildcard, even in a paired dir.
$extra = Join-Path $emulator 'lib64\qt\resources\future-file-test.pak'
[IO.File]::WriteAllText($extra, 'future-sdk-file')
$sources = @(Get-ChildItem -LiteralPath $sdk -File -Recurse -Force | ForEach-Object {
    [pscustomobject]@{ relative=$_.FullName.Substring($sdk.Length + 1); sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
if ($sources.Count -ne 119) { throw 'Unexpected fixture source count.' }

function New-Iss([string]$Name, [string]$SdkSource, [string]$Include) {
    $id = [guid]::NewGuid().ToString()
    $lines = New-Object 'Collections.Generic.List[string]'
    foreach ($line in @(
        ('#define SdkSource "' + $SdkSource + '"'), '[Setup]', ('AppId={{' + $id + '}'),
        ('AppName=Artemis Runtime Test ' + $Name), 'AppVersion=0.0.0', 'PrivilegesRequired=lowest',
        ('DefaultDirName={tmp}\Artemis-Runtime-Fixture-' + $id), ('OutputDir=' + $runDirectory),
        ('OutputBaseFilename=' + $Name), 'Compression=lzma2/fast', 'SolidCompression=yes',
        'MergeDuplicateFiles=yes', 'Uninstallable=no', 'CreateUninstallRegKey=no',
        'DisableDirPage=yes', 'DisableProgramGroupPage=yes', 'DisableWelcomePage=yes',
        'DisableReadyPage=yes', 'DisableFinishedPage=yes', '[Files]'
    )) { $lines.Add($line) }
    if ($Include) {
        $lines.Add(('#include "{0}"' -f $Include))
    } else {
        $lines.Add('Source: "{#SdkSource}\*"; DestDir: "{app}\sdk"; Flags: onlyifdoesntexist recursesubdirs createallsubdirs')
    }
    $iss = Join-Path $runDirectory ($Name + '.iss')
    [IO.File]::WriteAllLines($iss, $lines.ToArray(), (New-Object Text.UTF8Encoding $false))
    return $iss
}
function Test-Installation([string]$Name, [string]$Iss) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    & rtk proxy $compiler /Qp $Iss | Out-Host
    $compileSeconds = $timer.Elapsed.TotalSeconds
    if ($LASTEXITCODE -ne 0) { throw "Compilation failed for $Name." }
    $exe = Join-Path $runDirectory ($Name + '.exe')
    $destination = Join-Path $runDirectory ($Name + '-install')
    $freshLog = Join-Path $runDirectory ($Name + '-fresh.log')
    $timer.Restart()
    & rtk proxy $exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /NOICONS ('/DIR=' + $destination) ('/LOG=' + $freshLog) | Out-Host
    $freshSeconds = $timer.Elapsed.TotalSeconds
    if ($LASTEXITCODE -ne 0) { throw "Installation failed for $Name." }
    $installed = @(Get-ChildItem -LiteralPath (Join-Path $destination 'sdk') -File -Recurse -Force)
    if ($installed.Count -ne $sources.Count) { throw "Unexpected installed file count for $Name." }
    foreach ($source in $sources) {
        $path = Join-Path $destination ('sdk\' + $source.relative)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $source.sha256) {
            throw "Installed content mismatch: $Name / $($source.relative)"
        }
    }
    $existing = Join-Path $runDirectory ($Name + '-existing')
    $existingLog = Join-Path $runDirectory ($Name + '-existing.log')
    $preexisting = @('emulator\lib64\qt\bin\icudtl.dat', 'emulator\lib64\qt\resources\icudtl.dat',
        'emulator\lib64\qt\translations\qtwebengine_locales\zh-CN.pak')
    foreach ($relative in $preexisting) {
        $path = Join-Path $existing ('sdk\' + $relative)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, 'previous local file: ' + $relative)
    }
    $timer.Restart()
    & rtk proxy $exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /NOICONS ('/DIR=' + $existing) ('/LOG=' + $existingLog) | Out-Host
    $existingSeconds = $timer.Elapsed.TotalSeconds
    if ($LASTEXITCODE -ne 0) { throw "Existing-directory installation failed for $Name." }
    foreach ($source in $sources) {
        $path = Join-Path $existing ('sdk\' + $source.relative)
        if ($source.relative -in $preexisting) {
            if ([IO.File]::ReadAllText($path) -ne ('previous local file: ' + $source.relative)) { throw "Existing file overwritten: $($source.relative)" }
        } elseif (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $source.sha256) {
            throw "Mismatched existing-directory file: $($source.relative)"
        }
    }
    $destinations = @(Get-Content -LiteralPath $freshLog | Where-Object { $_ -match 'Dest filename: ' } |
        ForEach-Object { ($_ -split 'Dest filename: ', 2)[1].Substring($destination.Length + 1) })
    if ($destinations.Count -ne $sources.Count) { throw "Unexpected logged extraction entry count for $Name." }
    $destinations | Set-Content -LiteralPath (Join-Path $runDirectory ($Name + '-extraction-order.txt')) -Encoding UTF8
    return [pscustomobject]@{ name=$Name; bytes=(Get-Item -LiteralPath $exe).Length;
        installed_files=$installed.Count; installed_hashes_verified=$true; existing_targets_preserved=$preexisting.Count;
        compile_seconds=[math]::Round($compileSeconds,2); fresh_install_seconds=[math]::Round($freshSeconds,2);
        existing_install_seconds=[math]::Round($existingSeconds,2); extraction_order_entries=$destinations.Count }
}
$baselineIss = New-Iss 'baseline' 'source-sdk' ''
$reuseIss = New-Iss 'interleaved' 'source-sdk' (Join-Path $generated 'sdk-reuse-files.iss.inc')
$breakIss = New-Iss 'per-pair-break' $sdk (Join-Path $generated 'sdk-reuse-files-solidbreak.iss.inc')
$baseline = Test-Installation 'baseline' $baselineIss
$reuse = Test-Installation 'interleaved' $reuseIss
$broken = Test-Installation 'per-pair-break' $breakIss

# Input sets that differ must be rejected by generation. This extra file is not
# in the generated list and remains correctly included by the wildcard above.
$mismatchRejected = $false
try { & $generator -SdkRoot $sdk -OutputDirectory (Join-Path $runDirectory 'mismatched-set') | Out-Null }
catch { $mismatchRejected = $_.Exception.Message -like '*names differ*' }
if (-not $mismatchRejected) { throw 'Generator did not reject a mismatched directory set.' }

# Check both paths at ISPP time; fixture SDK is a physical copy, not hardlinked.
$pair = @($report.pairs | Where-Object { $_.source -like '*qtwebengine_locales\zh-CN.pak' })[0]
$gate = @()
foreach ($relative in @($pair.source, $pair.alias)) {
    $path = Join-Path $sdk $relative
    $original = [IO.File]::ReadAllBytes($path)
    try {
        [IO.File]::AppendAllText($path, 'modified-for-guard-test')
        $savedPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $log = @(& rtk proxy $compiler /Qp /O- $reuseIss 2>&1 | ForEach-Object { [string]$_ })
        } finally { $ErrorActionPreference = $savedPreference }
        $rejected = $LASTEXITCODE -ne 0 -and (($log -join "`n") -match 'SDK reuse hash mismatch')
        if (-not $rejected) { throw "ISPP did not reject modified input: $relative`n$($log -join "`n")" }
        $gate += [pscustomobject]@{ path=$relative; modified_source_rejected=$true }
    } finally { [IO.File]::WriteAllBytes($path, $original) }
}
$result = [pscustomobject]@{
    note='Isolated duplicate-only Qt fixture, lzma2/fast solid. Timing is a single noisy run; no full lzma2/max package or device behavior has been tested. Log order is target extraction order, not direct observation of compressed block reads.'
    future_unlisted_file_installed=$true; mismatched_pair_sets_rejected=$mismatchRejected; changed_paths_rejected_at_compile=$gate
    baseline=$baseline; interleaved=$reuse; per_pair_solidbreak=$broken
    interleaved_saved_bytes=[Int64]$baseline.bytes-[Int64]$reuse.bytes
    per_pair_solidbreak_saved_bytes=[Int64]$baseline.bytes-[Int64]$broken.bytes
}
[IO.File]::WriteAllText((Join-Path $runDirectory 'result.json'), (($result | ConvertTo-Json -Depth 8) + [Environment]::NewLine), (New-Object Text.UTF8Encoding $false))
Write-Host "Completed exact-exclusion fixture. Results: $(Join-Path $runDirectory 'result.json')"
