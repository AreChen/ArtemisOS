param(
    [string]$Compiler = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\build\runtime-slim-exp')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$allowed = [IO.Path]::GetFullPath((Join-Path $project 'build\runtime-slim-exp')).TrimEnd('\')
$output = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
if ($output -ne $allowed -and -not $output.StartsWith($allowed + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Output must be inside the runtime lab.' }
$compiler = (Resolve-Path -LiteralPath $Compiler).ProviderPath
$lab = Join-Path $output ('inno-reuse-guards-' + [guid]::NewGuid().ToString('N'))
$sdk = Join-Path $lab 'sdk'
$generated = Join-Path $lab 'generated'
$pairs = @(
    @('emulator\lib64\qt\bin\icudtl.dat', 'emulator\lib64\qt\resources\icudtl.dat'),
    @('emulator\lib64\qt\bin\test.pak', 'emulator\lib64\qt\resources\test.pak'),
    @('emulator\lib64\qt\bin\qtwebengine_locales\en-US.pak', 'emulator\lib64\qt\translations\qtwebengine_locales\en-US.pak')
)
foreach ($pair in $pairs) {
    foreach ($relative in $pair) {
        $path = Join-Path $sdk $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, 'synthetic-' + (Split-Path -Leaf $relative))
    }
}
$generator = Join-Path $PSScriptRoot 'Write-InnoReuseSnippet.ps1'
& $generator -SdkRoot $sdk -OutputDirectory $generated
$iss = Join-Path $lab 'guard.iss'
$content = @(
    ('#define SdkSource "' + $sdk + '"'), '[Setup]', 'AppName=Artemis Runtime Guard Fixture',
    'AppVersion=0.0.0', 'DefaultDirName={tmp}\Artemis-Runtime-Guard-Fixture', 'Uninstallable=no',
    'CreateUninstallRegKey=no', '[Files]', ('#include "' + (Join-Path $generated 'sdk-reuse-files.iss.inc') + '"')
)
[IO.File]::WriteAllLines($iss, $content, (New-Object Text.UTF8Encoding $false))
function Invoke-Check([bool]$ExpectSuccess) {
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $logs = @(& rtk proxy $compiler /Qp /O- $iss 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($ExpectSuccess -and $code -ne 0) { throw "Unexpected preprocessor failure: $($logs -join "`n")" }
    if (-not $ExpectSuccess -and ($code -eq 0 -or ($logs -join "`n") -notmatch 'SDK reuse hash mismatch')) {
        throw "Modified pair was not rejected by ISPP: $($logs -join "`n")"
    }
}
Invoke-Check $true
foreach ($relative in $pairs[2]) {
    $path = Join-Path $sdk $relative
    $old = [IO.File]::ReadAllText($path)
    try { [IO.File]::WriteAllText($path, $old + '-changed'); Invoke-Check $false }
    finally { [IO.File]::WriteAllText($path, $old) }
}
$resourceAlias = Join-Path $sdk $pairs[1][1]
$old = [IO.File]::ReadAllText($resourceAlias)
try {
    # Same size to exercise SHA-256 rather than the length check.
    [IO.File]::WriteAllText($resourceAlias, ('X' * $old.Length))
    $contentMismatch = $false
    try { & $generator -SdkRoot $sdk -OutputDirectory (Join-Path $lab 'content-mismatch') | Out-Null }
    catch { $contentMismatch = $_.Exception.Message -like '*Content differs*' }
    if (-not $contentMismatch) { throw 'Generation failed to reject same-length content mismatch.' }
} finally { [IO.File]::WriteAllText($resourceAlias, $old) }
$extra = Join-Path $sdk 'emulator\lib64\qt\resources\extra.pak'
[IO.File]::WriteAllText($extra, 'extra')
$namesMismatch = $false
try { & $generator -SdkRoot $sdk -OutputDirectory (Join-Path $lab 'name-mismatch') | Out-Null }
catch { $namesMismatch = $_.Exception.Message -like '*names differ*' }
if (-not $namesMismatch) { throw 'Generation failed to reject mismatched names.' }
Invoke-Check $true
$result = [pscustomobject]@{ positive_compilation=$true; source_and_alias_mutations_rejected_at_compile=$true;
    same_length_content_mismatch_rejected_at_generation=$contentMismatch; name_set_mismatch_rejected_at_generation=$namesMismatch;
    newly_added_unlisted_file_does_not_break_compilation=$true; fixture_bytes='small synthetic files only'; inno_output_disabled=$true }
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $lab 'result.json') -Encoding UTF8
Write-Host "Guard checks passed: $(Join-Path $lab 'result.json')"
