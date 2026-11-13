param(
    [string]$SdkRoot = (Join-Path $PSScriptRoot '..\..\build\slim-sdk-0.3.5-pilot'),
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
$outputNames = @('sdk-reuse-files.iss.inc', 'sdk-reuse-files-solidbreak.iss.inc', 'sdk-reuse-verification.json')
foreach ($name in $outputNames) {
    if (Test-Path -LiteralPath (Join-Path $output $name)) {
        throw 'Refusing to reuse output containing a previous generated snippet; choose a new output directory.'
    }
}
$sdk = (Resolve-Path -LiteralPath $SdkRoot).ProviderPath.TrimEnd('\')
if ($sdk -eq $output -or $sdk.StartsWith($output + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $output.StartsWith($sdk + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'SDK and output must be separate trees.' }
$qt = Join-Path $sdk 'emulator\lib64\qt'
$bin = Join-Path $qt 'bin'
$resources = Join-Path $qt 'resources'
$binLocales = Join-Path $bin 'qtwebengine_locales'
$translationLocales = Join-Path $qt 'translations\qtwebengine_locales'
foreach ($directory in @($bin, $resources, $binLocales, $translationLocales)) {
    $item = Get-Item -LiteralPath $directory -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected a normal directory: $directory"
    }
}
foreach ($directory in @($resources, $binLocales, $translationLocales)) {
    if (@(Get-ChildItem -LiteralPath $directory -Directory -Force).Count) { throw "Unexpected nested directory: $directory" }
}

$resourceFiles = @(Get-ChildItem -LiteralPath $resources -File -Force)
$resourceNames = @($resourceFiles | ForEach-Object { $_.Name } | Sort-Object)
$sourceNames = @(@(Get-ChildItem -LiteralPath $bin -File -Filter '*.pak' -Force | ForEach-Object { $_.Name }) + @('icudtl.dat') | Sort-Object)
if ($resourceNames.Count -eq 0 -or (Compare-Object $resourceNames $sourceNames)) {
    throw 'Resource names differ; wildcard reuse could omit or add a file.'
}
$translations = @(Get-ChildItem -LiteralPath $translationLocales -File -Force)
$translationNames = @($translations | ForEach-Object { $_.Name } | Sort-Object)
$binNames = @(Get-ChildItem -LiteralPath $binLocales -File -Force | ForEach-Object { $_.Name } | Sort-Object)
if ($translationNames.Count -eq 0 -or (Compare-Object $translationNames $binNames) -or
    @($translationNames | Where-Object { $_ -notlike '*.pak' }).Count) {
    throw 'Locale names differ; wildcard reuse could omit or add a file.'
}
$pairs = @(foreach ($name in $resourceNames) {
    [pscustomobject]@{ source=(Join-Path $bin $name); alias=(Join-Path $resources $name) }
}) + @(foreach ($name in $translationNames) {
    [pscustomobject]@{ source=(Join-Path $binLocales $name); alias=(Join-Path $translationLocales $name) }
})
$verified = @(foreach ($pair in $pairs) {
    $first = Get-Item -LiteralPath $pair.source -Force
    $second = Get-Item -LiteralPath $pair.alias -Force
    if (($first.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($second.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $first.Length -ne $second.Length) { throw "Invalid duplicate pair: $($pair.alias)" }
    $firstHash = (Get-FileHash -LiteralPath $first.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $secondHash = (Get-FileHash -LiteralPath $second.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($firstHash -ne $secondHash) { throw "Content differs: $($pair.alias)" }
    [pscustomobject]@{ source=$first.FullName.Substring($sdk.Length + 1); alias=$second.FullName.Substring($sdk.Length + 1);
        bytes=[Int64]$first.Length; sha256=$firstHash }
})
[void][IO.Directory]::CreateDirectory($output)
$encoding = New-Object Text.UTF8Encoding $false
$checks = New-Object 'Collections.Generic.List[string]'
$checks.Add('; Generated from SHA-256 checked pairs. Use only with the matching SDK source.')
$checks.Add('; Sources must remain immutable from generation through the end of compilation.')
$checks.Add('#if Copy(SdkSource, 2, 2) == ":\" || Copy(SdkSource, 1, 2) == "\\"')
$checks.Add('  #define RuntimeReuseSdkRoot AddBackslash(SdkSource)')
$checks.Add('#else')
$checks.Add('  #define RuntimeReuseSdkRoot AddBackslash(SourcePath) + AddBackslash(SdkSource)')
$checks.Add('#endif')
$exclusions = New-Object 'Collections.Generic.List[string]'
foreach ($item in $verified) {
    foreach ($relative in @($item.source, $item.alias)) {
        if ($relative -match '[,\r\n"*?]') { throw "Cannot safely use file in an Inno exact exclusion: $relative" }
        $exclusions.Add('\' + $relative)
        $checks.Add(('#if LowerCase(GetSHA256OfFile(RuntimeReuseSdkRoot + "{0}")) != "{1}"' -f $relative,$item.sha256))
        $checks.Add('  #error SDK reuse hash mismatch; regenerate the snippet for this SDK')
        $checks.Add('#endif')
    }
}
function New-ReuseSnippet([bool]$SolidBreak) {
    $lines = New-Object 'Collections.Generic.List[string]'
    foreach ($line in $checks) { $lines.Add($line) }
    foreach ($item in $verified) {
        foreach ($relative in @($item.source, $item.alias)) {
            $directory = Split-Path -Parent $relative
            $leaf = Split-Path -Leaf $relative
            $first = $relative -ieq $item.source
            $flags = if ($SolidBreak -and $first) { 'onlyifdoesntexist solidbreak' } else { 'onlyifdoesntexist' }
            $lines.Add(('Source: "{{#SdkSource}}\{0}"; DestDir: "{{app}}\sdk\{1}"; DestName: "{2}"; Flags: {3}' -f $item.source,$directory,$leaf,$flags))
        }
    }
    $lines.Add(('Source: "{{#SdkSource}}\*"; DestDir: "{{app}}\sdk"; Excludes: "{0}"; Flags: onlyifdoesntexist recursesubdirs createallsubdirs' -f ($exclusions -join ',')))
    return $lines.ToArray()
}
[IO.File]::WriteAllLines((Join-Path $output 'sdk-reuse-files.iss.inc'), (New-ReuseSnippet $false), $encoding)
[IO.File]::WriteAllLines((Join-Path $output 'sdk-reuse-files-solidbreak.iss.inc'), (New-ReuseSnippet $true), $encoding)
$report = [pscustomobject]@{ sdk=$sdk; verified_pairs=$verified.Count; source_and_aliases_sha256_equal=$true;
    duplicate_logical_bytes=($verified | Measure-Object -Property bytes -Sum).Sum;
    note='Exact exclusions preserve new unlisted files. ISPP checks both paths against the recorded SHA-256, but source files must remain immutable throughout compilation. Full installer and application behavior require independent tests.';
    pairs=$verified }
[IO.File]::WriteAllText((Join-Path $output 'sdk-reuse-verification.json'), (($report | ConvertTo-Json -Depth 5) + [Environment]::NewLine), $encoding)
Write-Host "Verified $($verified.Count) source/alias pairs. Wrote interleaved snippets, with and without per-pair solidbreak, to $output."
