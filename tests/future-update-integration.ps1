$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
Add-Type -AssemblyName System.Security
$project = Split-Path -Parent $PSScriptRoot
$parent = Join-Path $project 'build\future-update-tests'
[void][IO.Directory]::CreateDirectory($parent)
$parent = (Resolve-Path -LiteralPath $parent).ProviderPath.TrimEnd('\')
$fixture = Join-Path $parent ([Guid]::NewGuid().ToString('N'))
$base = Join-Path $fixture 'installed'
$target = Join-Path $fixture 'target'
$keys = Join-Path $fixture 'keys'
$repo = Join-Path $fixture 'repository'
$ascii = [Text.Encoding]::ASCII
try {
    foreach ($dir in @($base,$target,$keys)) { [void][IO.Directory]::CreateDirectory($dir) }
    foreach ($dir in @($base,$target)) {
        Copy-Item -LiteralPath (Join-Path $project 'stage\update') -Destination (Join-Path $dir 'update') -Recurse
        [void][IO.Directory]::CreateDirectory((Join-Path $dir 'sdk\emulator'))
    }
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
    $rsa.PersistKeyInCsp = $false
    try {
        $public = $rsa.ToXmlString($false)
        $private = [Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))
        $protected = [Security.Cryptography.ProtectedData]::Protect($private, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes((Join-Path $keys 'ota-private.dpapi'), $protected)
        foreach ($dir in @($base,$target)) { [IO.File]::WriteAllText((Join-Path $dir 'update\trusted-key.xml'), $public, $ascii) }
    } finally { $rsa.Dispose(); if ($private) { [Array]::Clear($private, 0, $private.Length) } }
    [IO.File]::WriteAllText((Join-Path $base 'version.ini'), "[ArtemisOS]`nVersion=1.0.0`n", $ascii)
    [IO.File]::WriteAllText((Join-Path $target 'version.ini'), "[ArtemisOS]`nVersion=1.0.1`n", $ascii)
    [IO.File]::WriteAllText((Join-Path $base 'launch.ps1'), 'fixture old launcher', $ascii)
    [IO.File]::WriteAllText((Join-Path $target 'launch.ps1'), 'fixture new launcher', $ascii)
    [IO.File]::WriteAllText((Join-Path $base 'sdk\emulator\fixture.dll'), 'fixture old runtime', $ascii)
    [IO.File]::WriteAllText((Join-Path $target 'sdk\emulator\fixture.dll'), 'fixture new runtime', $ascii)
    [void][IO.Directory]::CreateDirectory((Join-Path $base 'data\avd'))
    $prefs = Join-Path $base 'data\preferences.ini'
    $disk = Join-Path $base 'data\avd\userdata.img'
    [IO.File]::WriteAllText($prefs, "graphics=auto`nprofile=high`ncustom=preserve`n", $ascii)
    [IO.File]::WriteAllText($disk, 'fixture user data', $ascii)
    $hashes = @((Get-FileHash -LiteralPath $prefs -Algorithm SHA256).Hash, (Get-FileHash -LiteralPath $disk -Algorithm SHA256).Hash)
    & (Join-Path $project 'tools\Publish-Update.ps1') -BaseRoot $base -TargetRoot $target -Repository $repo -KeyDirectory $keys -IncludeSdk
    . (Join-Path $base 'update\core.ps1')
    $json = Join-Path $repo 'manifests\1.0.0.json'
    $sig = Join-Path $repo 'manifests\1.0.0.sig'
    $manifest = Verify-UpdateManifest $base ([IO.File]::ReadAllBytes($json)) ([IO.File]::ReadAllBytes($sig))
    $expected = @('launch.ps1','sdk/emulator/fixture.dll','version.ini')
    if (@($manifest.files).Count -ne $expected.Count -or @($manifest.files | Where-Object { $_.path -notin $expected }).Count) {
        throw 'The fixture patch does not contain the expected changed files.'
    }
    $staged = Join-Path $base ('data\update\staged-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staged)
    Copy-Item -LiteralPath $json -Destination (Join-Path $staged 'manifest.json')
    Copy-Item -LiteralPath $sig -Destination (Join-Path $staged 'manifest.sig')
    foreach ($entry in @($manifest.files)) {
        Copy-Item -LiteralPath (Join-Path $repo ('objects\' + $entry.sha256)) -Destination (Join-Path $staged $entry.sha256)
    }
    & (Join-Path $base 'update\apply.ps1') -Staging $staged -Serial 'emulator-5554' -NoRestart
    if ((Get-UpdateVersion $base) -ne '1.0.1' -or
        [IO.File]::ReadAllText((Join-Path $base 'launch.ps1')) -cne 'fixture new launcher' -or
        [IO.File]::ReadAllText((Join-Path $base 'sdk\emulator\fixture.dll')) -cne 'fixture new runtime') {
        throw 'The installed version or changed program files were not replaced.'
    }
    if ((Get-FileHash -LiteralPath $prefs -Algorithm SHA256).Hash -ne $hashes[0] -or
        (Get-FileHash -LiteralPath $disk -Algorithm SHA256).Hash -ne $hashes[1]) { throw 'User data or preferences changed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $base 'data\update\pending\completed.flag'))) { throw 'Update transaction did not complete.' }
    Write-Host 'PASS: a signed 1.0.0 to 1.0.1 fixture replaces program files and preserves user data.'
} finally {
    if (Test-Path -LiteralPath $fixture) {
        $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath.TrimEnd('\')
        if ($resolved -ine $fixture -or -not $resolved.StartsWith(($parent + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
