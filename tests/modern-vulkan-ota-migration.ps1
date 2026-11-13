$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$bootstrap = Join-Path $project 'tools\ota\Launch-ModernVulkan.ps1'
$release = Join-Path $project 'releases\1.0.4'
$targetHash = '6af5e91c467d0b4dbc9d6b1f34a5bf25aef2f422437864aad47b52e98d6b4840'
$legacy = @(
    @{ Path = (Join-Path $project 'releases\1.0.0\launch.ps1'); Hash = 'f6ba9ca9102798014bed975dc2ad9d9f8409fac3f4f554d10e928f408ee0c07e' },
    @{ Path = (Join-Path $project 'releases\1.0.0-sd-fixed\launch.ps1'); Hash = '49d234a4cee1e83af12385de3206e2a11939b2cabc35693dd885d1459fe7fac5' }
)
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Write-Text([string]$Path, [string]$Value) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Value, (New-Object Text.UTF8Encoding($false)))
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}
Assert (Test-Path -LiteralPath $bootstrap -PathType Leaf) 'Modern Vulkan OTA migration bootstrap has not been implemented.'
Assert ((Hash (Join-Path $release 'launch.ps1')) -ceq $targetHash) 'The frozen 1.0.4 launcher changed.'
foreach ($item in $legacy) { Assert ((Hash $item.Path) -ceq $item.Hash) 'The frozen legacy launcher changed.' }
$testRoot = Join-Path $project 'build\modern-vulkan-ota-migration-tests'
[void][IO.Directory]::CreateDirectory($testRoot)
$fixtureBase = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureBase)
$global:ArtemisMigrationTestProcesses = @()
$global:ArtemisMigrationTestCimFailure = $false
function global:Get-CimInstance {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$ClassName, [string]$Filter)
    if ($global:ArtemisMigrationTestCimFailure) { throw 'simulated CIM metadata failure' }
    return $global:ArtemisMigrationTestProcesses
}
function New-Fixture([string]$Name, [string]$Launcher) {
    $install = Join-Path $fixtureBase $Name
    $update = Join-Path $install 'update'
    $pending = Join-Path $install 'data\update\pending'
    [void][IO.Directory]::CreateDirectory($update)
    [void][IO.Directory]::CreateDirectory($pending)
    Copy-Item -LiteralPath (Join-Path $release 'update\core.ps1') -Destination (Join-Path $update 'core.ps1')
    Copy-Item -LiteralPath (Join-Path $release 'update\recovery.ps1') -Destination (Join-Path $update 'recovery.ps1')
    Copy-Item -LiteralPath $bootstrap -Destination (Join-Path $update 'launch-current.ps1')
    Copy-Item -LiteralPath (Join-Path $release 'launch.ps1') -Destination (Join-Path $update 'launcher-1.0.4.ps1')
    Copy-Item -LiteralPath $Launcher -Destination (Join-Path $install 'launch.ps1')
    Write-Text (Join-Path $install 'version.ini') "Version=1.0.4`r`n"
    Write-Text (Join-Path $install 'settings.ps1') 'new-settings'
    Write-Text (Join-Path $pending '0000.bak') 'old-settings'
    Write-Text (Join-Path $pending '0001.bak') "Version=1.0.3`r`n"
    Write-Text (Join-Path $install 'data\preferences.ini') "graphics=host`r`nprofile=medium`r`n"
    Write-Text (Join-Path $install 'data\avd\user-data.qcow2') 'do-not-touch-user-data'
    $journal = [ordered]@{ schema = 1; from = '1.0.3'; to = '1.0.4'; files = @(
        [ordered]@{ path = 'settings.ps1'; existed = $true; backup = '0000.bak'; sha256 = (Hash (Join-Path $pending '0000.bak')) },
        [ordered]@{ path = 'version.ini'; existed = $true; backup = '0001.bak'; sha256 = (Hash (Join-Path $pending '0001.bak')) }
    ) }
    Write-Text (Join-Path $pending 'transaction.json') ($journal | ConvertTo-Json -Depth 8)
    Write-Text (Join-Path $pending 'completed.flag') '1'
    return $install
}
function Invoke-Bootstrap([string]$Install) { & (Join-Path $Install 'update\launch-current.ps1') -NoLaunch -Headless }
function Assert-DataPreserved([string]$Install) {
    Assert ([IO.File]::ReadAllText((Join-Path $Install 'data\preferences.ini')) -ceq "graphics=host`r`nprofile=medium`r`n") 'User rendering preferences changed.'
    Assert ([IO.File]::ReadAllText((Join-Path $Install 'data\avd\user-data.qcow2')) -ceq 'do-not-touch-user-data') 'AVD user data changed.'
}
function Assert-RolledBack([string]$Install) {
    Assert ([IO.File]::ReadAllText((Join-Path $Install 'version.ini')) -match 'Version=1.0.3') 'The common transaction version was not restored.'
    Assert ([IO.File]::ReadAllText((Join-Path $Install 'settings.ps1')) -ceq 'old-settings') 'The common transaction files were not restored.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $Install 'data\update\pending\applying.flag'))) 'Recovery left an active transaction.'
    Assert-DataPreserved $Install
}
try {
    foreach ($item in $legacy) {
        $install = New-Fixture ('legacy-' + $item.Hash.Substring(0, 8)) $item.Path
        Invoke-Bootstrap $install
        Assert ((Hash (Join-Path $install 'launch.ps1')) -ceq $targetHash) 'A supported legacy launcher was not migrated.'
        $pending = Join-Path $install 'data\update\pending'
        $journal = [IO.File]::ReadAllText((Join-Path $pending 'transaction.json')) | ConvertFrom-Json
        $entry = @($journal.files | Where-Object path -EQ 'launch.ps1')
        Assert ($entry.Count -eq 1 -and $entry[0].sha256 -ceq $item.Hash) 'The actual legacy launcher backup was not journaled.'
        Assert ((Hash (Join-Path $pending $entry[0].backup)) -ceq $item.Hash) 'The legacy launcher backup was corrupted.'
        Assert (Test-Path -LiteralPath (Join-Path $pending 'completed.flag')) 'Migration did not complete its transaction.'
        $journalHash = Hash (Join-Path $pending 'transaction.json')
        Invoke-Bootstrap $install
        Assert ((Hash (Join-Path $pending 'transaction.json')) -ceq $journalHash) 'Repeated startup changed a completed migration.'
        Assert-DataPreserved $install
    }
    $install = New-Fixture 'already-current' (Join-Path $release 'launch.ps1')
    Remove-Item -LiteralPath (Join-Path $install 'update\launcher-1.0.4.ps1')
    $global:ArtemisMigrationTestCimFailure = $true
    try { Invoke-Bootstrap $install } finally { $global:ArtemisMigrationTestCimFailure = $false }
    Assert ((Hash (Join-Path $install 'launch.ps1')) -ceq $targetHash) 'Current launcher should not require migration or process discovery.'
    Assert-DataPreserved $install

    $install = New-Fixture 'unknown-launcher' $legacy[0].Path
    Write-Text (Join-Path $install 'launch.ps1') 'custom-unknown-launcher'
    $unknownHash = Hash (Join-Path $install 'launch.ps1')
    Assert-Rejected { Invoke-Bootstrap $install } 'An unknown launcher was accepted.'
    Assert ((Hash (Join-Path $install 'launch.ps1')) -ceq $unknownHash) 'An unknown launcher was overwritten during rollback.'
    Assert-RolledBack $install

    $install = New-Fixture 'unknown-after-journal-preparation' $legacy[0].Path
    $pending = Join-Path $install 'data\update\pending'
    Copy-Item -LiteralPath (Join-Path $install 'launch.ps1') -Destination (Join-Path $pending '0002.bak')
    $journal = [IO.File]::ReadAllText((Join-Path $pending 'transaction.json')) | ConvertFrom-Json
    $journal.files = @($journal.files) + @([pscustomobject]@{ path = 'launch.ps1'; existed = $true; backup = '0002.bak'; sha256 = $legacy[0].Hash })
    Write-Text (Join-Path $pending 'transaction.json') ($journal | ConvertTo-Json -Depth 8)
    Write-Text (Join-Path $install 'launch.ps1') 'custom-after-journal-preparation'
    $unknownHash = Hash (Join-Path $install 'launch.ps1')
    Assert-Rejected { Invoke-Bootstrap $install } 'A prepared journal accepted an unknown launcher.'
    Assert ((Hash (Join-Path $install 'launch.ps1')) -ceq $unknownHash) 'Rollback overwrote an unknown launcher from a previously prepared journal.'
    Assert-RolledBack $install

    $install = New-Fixture 'bad-payload' $legacy[0].Path
    Write-Text (Join-Path $install 'update\launcher-1.0.4.ps1') 'corrupt payload'
    Assert-Rejected { Invoke-Bootstrap $install } 'An invalid launcher payload was accepted.'
    Assert ((Hash (Join-Path $install 'launch.ps1')) -ceq $legacy[0].Hash) 'Rejected payload changed the legacy launcher.'
    Assert-RolledBack $install

    $install = New-Fixture 'idempotent-journal' $legacy[1].Path
    $pending = Join-Path $install 'data\update\pending'
    Copy-Item -LiteralPath (Join-Path $install 'launch.ps1') -Destination (Join-Path $pending '0002.bak')
    $journal = [IO.File]::ReadAllText((Join-Path $pending 'transaction.json')) | ConvertFrom-Json
    $journal.files = @($journal.files) + @([pscustomobject]@{ path = 'launch.ps1'; existed = $true; backup = '0002.bak'; sha256 = $legacy[1].Hash })
    Write-Text (Join-Path $pending 'transaction.json') ($journal | ConvertTo-Json -Depth 8)
    Invoke-Bootstrap $install
    $journal = [IO.File]::ReadAllText((Join-Path $pending 'transaction.json')) | ConvertFrom-Json
    Assert (@($journal.files | Where-Object path -EQ 'launch.ps1').Count -eq 1) 'Resuming journal preparation duplicated the launcher backup.'
    Assert ((Hash (Join-Path $install 'launch.ps1')) -ceq $targetHash) 'Prepared journal could not resume migration.'

    foreach ($afterReplace in @($false, $true)) {
        $install = New-Fixture ('interrupted-' + $afterReplace) $legacy[0].Path
        $pending = Join-Path $install 'data\update\pending'
        Copy-Item -LiteralPath (Join-Path $install 'launch.ps1') -Destination (Join-Path $pending '0002.bak')
        $journal = [IO.File]::ReadAllText((Join-Path $pending 'transaction.json')) | ConvertFrom-Json
        $journal.files = @($journal.files) + @([pscustomobject]@{ path = 'launch.ps1'; existed = $true; backup = '0002.bak'; sha256 = $legacy[0].Hash })
        Write-Text (Join-Path $pending 'transaction.json') ($journal | ConvertTo-Json -Depth 8)
        Move-Item -LiteralPath (Join-Path $pending 'completed.flag') -Destination (Join-Path $pending 'applying.flag')
        if ($afterReplace) { Copy-Item -LiteralPath (Join-Path $release 'launch.ps1') -Destination (Join-Path $install 'launch.ps1') -Force }
        Invoke-Bootstrap $install
        Assert-RolledBack $install
        Assert ((Hash (Join-Path $install 'launch.ps1')) -ceq $legacy[0].Hash) 'Interrupted migration did not restore the actual old launcher.'
    }
    foreach ($fault in @('live-runtime', 'missing-process-path', 'cim-failure')) {
        $install = New-Fixture $fault $legacy[0].Path
        Write-Text (Join-Path $install 'launch.ps1') 'custom-unknown-launcher'
        $global:ArtemisMigrationTestProcesses = switch ($fault) {
            'live-runtime' { @([pscustomobject]@{ Name = 'qemu-system-x86_64.exe'; ExecutablePath = (Join-Path $install 'sdk\emulator\qemu\windows-x86_64\qemu-system-x86_64.exe') }) }
            'missing-process-path' { @([pscustomobject]@{ Name = 'emulator.exe'; ExecutablePath = $null }) }
            default { @() }
        }
        $global:ArtemisMigrationTestCimFailure = $fault -eq 'cim-failure'
        try { Assert-Rejected { Invoke-Bootstrap $install } 'Rollback proceeded without proving runtime files were unused.' }
        finally { $global:ArtemisMigrationTestProcesses = @(); $global:ArtemisMigrationTestCimFailure = $false }
        Assert ([IO.File]::ReadAllText((Join-Path $install 'settings.ps1')) -ceq 'new-settings') 'Blocked rollback restored files under a potentially running runtime.'
        Assert-DataPreserved $install
    }
    $install = New-Fixture 'startup-recovery-live-runtime' $legacy[0].Path
    $pending = Join-Path $install 'data\update\pending'
    Move-Item -LiteralPath (Join-Path $pending 'completed.flag') -Destination (Join-Path $pending 'applying.flag')
    $global:ArtemisMigrationTestProcesses = @([pscustomobject]@{ Name = 'qemu-system-x86_64-headless.exe'; ExecutablePath = (Join-Path $install 'sdk\emulator\qemu\windows-x86_64\qemu-system-x86_64-headless.exe') })
    try { Assert-Rejected { Invoke-Bootstrap $install } 'Startup recovery ignored a live runtime.' }
    finally { $global:ArtemisMigrationTestProcesses = @() }
    Assert ([IO.File]::ReadAllText((Join-Path $install 'settings.ps1')) -ceq 'new-settings') 'Startup recovery restored files while a runtime was active.'
    Assert (Test-Path -LiteralPath (Join-Path $pending 'applying.flag')) 'Blocked startup recovery discarded its recoverable transaction.'
    Assert-DataPreserved $install

    $install = New-Fixture 'recovery-before-core' $legacy[0].Path
    $pending = Join-Path $install 'data\update\pending'
    Copy-Item -LiteralPath (Join-Path $release 'update\core.ps1') -Destination (Join-Path $pending '0002.bak')
    $journal = [IO.File]::ReadAllText((Join-Path $pending 'transaction.json')) | ConvertFrom-Json
    $journal.files = @($journal.files) + @([pscustomobject]@{ path = 'update/core.ps1'; existed = $true; backup = '0002.bak'; sha256 = (Hash (Join-Path $pending '0002.bak')) })
    Write-Text (Join-Path $pending 'transaction.json') ($journal | ConvertTo-Json -Depth 8)
    Write-Text (Join-Path $install 'update\core.ps1') "throw 'An interrupted core must not run before recovery.'"
    Move-Item -LiteralPath (Join-Path $pending 'completed.flag') -Destination (Join-Path $pending 'applying.flag')
    Invoke-Bootstrap $install
    Assert-RolledBack $install
    Assert ((Hash (Join-Path $install 'update\core.ps1')) -ceq (Hash (Join-Path $release 'update\core.ps1'))) 'Recovery did not restore core before loading it.'
    $install = New-Fixture 'invalid-journal' $legacy[0].Path
    Write-Text (Join-Path $install 'data\update\pending\0000.bak') 'bad backup'
    Assert-Rejected { Invoke-Bootstrap $install } 'A corrupt completed transaction backup was accepted.'
    Assert ((Hash (Join-Path $install 'launch.ps1')) -ceq $legacy[0].Hash) 'Corrupt transaction changed the legacy launcher.'
    Assert-DataPreserved $install

    $install = New-Fixture 'future-version' $legacy[0].Path
    Write-Text (Join-Path $install 'version.ini') "Version=1.0.5`r`n"
    Remove-Item -LiteralPath (Join-Path $install 'update\launcher-1.0.4.ps1')
    Invoke-Bootstrap $install
    Assert ((Hash (Join-Path $install 'launch.ps1')) -ceq $legacy[0].Hash) 'The compatibility bootstrap modified a future version.'
    Assert-DataPreserved $install

    $install = New-Fixture 'forward-launch-parameters' $legacy[0].Path
    Write-Text (Join-Path $install 'version.ini') "Version=1.0.5`r`n"
    Write-Text (Join-Path $install 'launch.ps1') @'
param([string]$Graphics, [switch]$Headless, [int]$Port)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'data\forwarded.json'), (@{graphics=$Graphics;headless=[bool]$Headless;port=$Port} | ConvertTo-Json))
'@
    & (Join-Path $install 'update\launch-current.ps1') -Graphics swiftshader -Headless -Port 5578
    $forwarded = [IO.File]::ReadAllText((Join-Path $install 'data\forwarded.json')) | ConvertFrom-Json
    Assert ($forwarded.graphics -ceq 'swiftshader' -and $forwarded.headless -eq $true -and $forwarded.port -eq 5578) 'The bootstrap did not forward launch parameters to the root launcher.'
    Assert-DataPreserved $install
    Write-Host 'Modern Vulkan OTA migration passed: two real legacy baselines, repeat startup, unknown/corrupt inputs, idempotency, interruption recovery, live-runtime guards and future versions.'
} finally {
    Remove-Item -LiteralPath 'Function:\Get-CimInstance' -ErrorAction SilentlyContinue
    Remove-Variable -Name ArtemisMigrationTestProcesses,ArtemisMigrationTestCimFailure -Scope Global -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($fixtureBase).TrimEnd('\')
    if (-not $resolved.StartsWith(([IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
