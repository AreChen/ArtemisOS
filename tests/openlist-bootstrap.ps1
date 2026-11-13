param([Parameter(Mandatory=$true)][string]$Setup)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$setupPath = (Resolve-Path -LiteralPath $Setup).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('ArtemisOS-connect-test-' + [guid]::NewGuid().ToString('N'))
$ascii = [Text.Encoding]::ASCII

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}
function Make-Install([string]$Name, [string]$Version, [bool]$ValidKey) {
    $install = Join-Path $root $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $install 'update'))
    [void][IO.Directory]::CreateDirectory((Join-Path $install 'data\update'))
    [void][IO.Directory]::CreateDirectory((Join-Path $install 'data\avd'))
    [IO.File]::WriteAllText((Join-Path $install 'version.ini'), "[ArtemisOS]`r`nVersion=$Version`r`n", $ascii)
    [IO.File]::WriteAllText((Join-Path $install 'update\core.ps1'), 'old-core', $ascii)
    [IO.File]::WriteAllText((Join-Path $install 'update\bridge.ps1'), 'old-bridge', $ascii)
    [IO.File]::WriteAllText((Join-Path $install 'update\server.txt'), 'https://old.invalid/', $ascii)
    [IO.File]::WriteAllText((Join-Path $install 'data\update\server.txt'), 'http://127.0.0.1:8181/', $ascii)
    [IO.File]::WriteAllText((Join-Path $install 'data\avd\sentinel.txt'), 'user-data', $ascii)
    if ($ValidKey) { Copy-Item -LiteralPath (Join-Path $project 'stage\update\trusted-key.xml') -Destination (Join-Path $install 'update\trusted-key.xml') }
    else { [IO.File]::WriteAllText((Join-Path $install 'update\trusted-key.xml'), 'wrong-key', $ascii) }
    return $install
}
function Invoke-Setup([string]$Install) {
    $args = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',('/DIR="' + $Install + '"'))
    return (Start-Process -FilePath $setupPath -ArgumentList $args -PassThru -Wait).ExitCode
}
try {
    [void][IO.Directory]::CreateDirectory($root)
    $install = Make-Install 'valid' '0.3.4' $true
    Assert ((Invoke-Setup $install) -eq 0) 'compatible installation accepts connection component'
    $backup = @(Get-ChildItem -LiteralPath (Join-Path $install 'data\update') -Directory -Filter 'before-openlist-*')
    Assert ($backup.Count -eq 1) 'original component and update addresses are backed up'
    Assert ([IO.File]::ReadAllText((Join-Path $backup[0].FullName 'core.ps1')) -ceq 'old-core') 'backup contains original component'
    Assert ([IO.File]::ReadAllText((Join-Path $backup[0].FullName 'default-server.txt')) -ceq 'https://old.invalid/') 'backup contains original default address'
    Assert ([IO.File]::ReadAllText((Join-Path $backup[0].FullName 'user-server.txt')) -ceq 'http://127.0.0.1:8181/') 'backup contains original user address'
    Assert ((Get-FileHash (Join-Path $install 'update\core.ps1')).Hash -ceq (Get-FileHash (Join-Path $project 'stage\update\core.ps1')).Hash) 'updated component matches the tested source'
    Assert ([IO.File]::ReadAllText((Join-Path $install 'data\update\server.txt')) -ceq 'https://example.invalid/sd/probe/?d') 'effective server is switched'
    Assert ([IO.File]::ReadAllText((Join-Path $install 'data\avd\sentinel.txt')) -ceq 'user-data') 'virtual machine data stays intact'
    Assert ([IO.File]::ReadAllText((Join-Path $install 'version.ini')) -match 'Version=0\.3\.4') 'installed version stays intact'
    $wrongVersion = Make-Install 'wrong-version' '0.3.5' $true
    Assert ((Invoke-Setup $wrongVersion) -ne 0) 'unsupported version is rejected'
    Assert ([IO.File]::ReadAllText((Join-Path $wrongVersion 'update\core.ps1')) -ceq 'old-core') 'version rejection leaves component untouched'
    $wrongKey = Make-Install 'wrong-key' '0.3.4' $false
    Assert ((Invoke-Setup $wrongKey) -ne 0) 'different signing key is rejected'
    Assert ([IO.File]::ReadAllText((Join-Path $wrongKey 'data\update\server.txt')) -ceq 'http://127.0.0.1:8181/') 'key rejection leaves address untouched'
    $pending = Make-Install 'pending' '0.3.4' $true
    [void][IO.Directory]::CreateDirectory((Join-Path $pending 'data\update\pending'))
    [IO.File]::WriteAllText((Join-Path $pending 'data\update\pending\applying.flag'), '1', $ascii)
    Assert ((Invoke-Setup $pending) -ne 0) 'incomplete update is rejected until recovered'
    Assert ([IO.File]::ReadAllText((Join-Path $pending 'update\core.ps1')) -ceq 'old-core') 'pending transaction leaves component untouched'
} finally {
    $tempPath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith($tempPath, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolved -Leaf).StartsWith('ArtemisOS-connect-test-') -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
