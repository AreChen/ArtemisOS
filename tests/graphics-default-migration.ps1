$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = Split-Path -Parent $PSScriptRoot
$parent = Join-Path $project 'build\graphics-default-migration-tests'
[void][IO.Directory]::CreateDirectory($parent)
$parent = (Resolve-Path -LiteralPath $parent).ProviderPath.TrimEnd('\')
$fixture = Join-Path $parent ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Bytes([byte[]]$Actual, [byte[]]$Expected, [string]$Message) {
    Assert ([Convert]::ToBase64String($Actual) -ceq [Convert]::ToBase64String($Expected)) $Message
}
function New-Fixture([string]$Name) {
    $root = Join-Path $fixture $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'data\avd'))
    Copy-Item -LiteralPath (Join-Path $project 'stage\settings.ps1') -Destination (Join-Path $root 'settings.ps1')
    [IO.File]::WriteAllText((Join-Path $root 'version.ini'), "[ArtemisOS]`nVersion=1.0.3`n", [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $root 'data\avd\userdata.img'), 'user-data-must-survive', [Text.Encoding]::ASCII)
    return $root
}

try {
    $cases = @(
        @{ Name='host-bom'; Text="graphics=host`r`ncarrier=unicom`r`ncustom=保留`r`n"; Expected='host'; Bom=$true },
        @{ Name='auto'; Text="profile=high`ngraphics=auto`n"; Expected='auto'; Bom=$false },
        @{ Name='software-choice'; Text="graphics=swiftshader`n"; Expected='swiftshader'; Bom=$false },
        @{ Name='swangle-choice'; Text="graphics=swangle`n"; Expected='swangle'; Bom=$false },
        @{ Name='duplicates'; Text="graphics=lavapipe`ngraphics=host`n"; Expected='host'; Bom=$false },
        @{ Name='missing'; Text="profile=medium`ncustom=保留"; Expected='host'; Bom=$false },
        @{ Name='invalid'; Text="graphics=invalid`n"; Expected='host'; Bom=$false },
        @{ Name='empty'; Text=''; Expected='host'; Bom=$false }
    )
    foreach ($case in $cases) {
        $root = New-Fixture $case.Name
        $pref = Join-Path $root 'data\preferences.ini'
        $marker = Join-Path $root 'data\graphics-swiftshader-1.0.1.flag'
        $prefix = if ($case.Bom) { [byte[]](0xEF,0xBB,0xBF) } else { [byte[]]@() }
        $original = [byte[]]($prefix + [Text.Encoding]::UTF8.GetBytes($case.Text))
        [IO.File]::WriteAllBytes($pref, $original)
        . (Join-Path $root 'settings.ps1')
        Assert ((Get-ArtemisPreferences).Graphics -ceq $case.Expected) "$($case.Name): renderer preference overridden or wrong hardware default"
        Assert-Bytes ([IO.File]::ReadAllBytes($pref)) $original "$($case.Name): reading preferences rewrote the file"
        Assert (-not (Test-Path -LiteralPath $marker)) "$($case.Name): obsolete migration still ran"
        Assert ([IO.File]::ReadAllText((Join-Path $root 'data\avd\userdata.img')) -ceq 'user-data-must-survive') "$($case.Name): Android data changed"
        [IO.File]::WriteAllText($marker, 'legacy-marker-must-survive', [Text.Encoding]::ASCII)
        Assert ((Get-ArtemisPreferences).Graphics -ceq $case.Expected) "$($case.Name): legacy marker changed preference behavior"
        Assert ([IO.File]::ReadAllText($marker) -ceq 'legacy-marker-must-survive') "$($case.Name): old marker was modified"
    }

    $root = New-Fixture 'fresh'
    . (Join-Path $root 'settings.ps1')
    Assert ((Get-ArtemisPreferences).Graphics -ceq 'host') 'Fresh installation did not default to hardware rendering'
    Write-ArtemisPreferences 'low' '1' '1'
    Assert ((Get-ArtemisPreferences).Graphics -ceq 'host') 'Preference writer did not default to hardware rendering'
    foreach ($renderer in @('auto', 'host', 'software', 'swiftshader', 'swangle', 'lavapipe')) {
        Write-ArtemisPreferences 'high' '1' '1' 'mobile' $renderer '720p'
        Assert ((Get-ArtemisPreferences).Graphics -ceq $renderer) "Explicit renderer did not persist: $renderer"
    }
    Write-Host 'Hardware defaults and existing renderer preferences passed.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath.TrimEnd('\')
    if (-not $resolved.StartsWith(($parent + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temporary directory.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}