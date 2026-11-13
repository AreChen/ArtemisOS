# Isolated fixtures only: no live emulator or user AVD is opened or stopped.
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'stage\update\core.ps1')
$fixture = Join-Path $project ('build\updater-path-process-' + [Guid]::NewGuid().ToString('N'))
$outside = Join-Path $fixture 'outside'
$root = Join-Path $fixture 'install'
foreach ($dir in @($outside, (Join-Path $root 'update'), (Join-Path $root 'data\avd'))) { [void][IO.Directory]::CreateDirectory($dir) }
Copy-Item -Path (Join-Path $project 'stage\update\*.ps1') -Destination (Join-Path $root 'update')
$sentinel = Join-Path $root 'data\avd\user-data.img'
$outsideSentinel = Join-Path $outside 'sentinel.txt'
[IO.File]::WriteAllText($sentinel, 'user data must not be touched', [Text.Encoding]::ASCII)
[IO.File]::WriteAllText($outsideSentinel, 'outside must not be touched', [Text.Encoding]::ASCII)
$userHash = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash
$outsideHash = (Get-FileHash -LiteralPath $outsideSentinel -Algorithm SHA256).Hash
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw ('FAILED: ' + $Message) }; Write-Host ('PASS: ' + $Message) }
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-True $rejected $Message
}
function Invoke-TestScript([string]$Script, [string[]]$Arguments) {
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & rtk proxy (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | Out-Null
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
}

$sdk = Join-Path $root 'sdk\emulator'
$launcher = [pscustomobject]@{Name='emulator.exe';ExecutablePath=(Join-Path $sdk 'emulator.exe');CommandLine='emulator.exe -port 5554';ProcessId=101;ParentProcessId=10}
$headless = [pscustomobject]@{Name='qemu-system-x86_64-headless.exe';ExecutablePath=(Join-Path $sdk 'qemu\windows-x86_64\qemu-system-x86_64-headless.exe');CommandLine='qemu-system-x86_64-headless.exe -port 5554';ProcessId=102;ParentProcessId=101}
Assert-True ((Get-VerifiedUpdateEmulator @($launcher,$headless) $sdk 'emulator-5554' 101).ProcessId -eq 102) 'headless qemu is recognized and tied to launcher and port'
Assert-Rejected { Get-VerifiedUpdateEmulator @($launcher,$headless) $sdk 'emulator-5556' 101 } 'wrong port cannot be stopped'
Assert-Rejected { Get-VerifiedUpdateEmulator @($headless,$headless) $sdk 'emulator-5554' } 'multiple instances cannot be guessed'
$unknown = [pscustomobject]@{Name='qemu-system-x86_64-headless.exe';ExecutablePath=$null;CommandLine='';ProcessId=103;ParentProcessId=0}
Assert-Rejected { Get-VerifiedUpdateEmulator @($unknown) $sdk 'emulator-5554' } 'inaccessible executable path causes a conservative stop'
Assert-Rejected { Get-VerifiedUpdateEmulator @($launcher) $sdk 'emulator-5554' 101 } 'launcher without confirmed qemu causes a conservative stop'

$lostTarget = Join-Path $fixture 'removed-junction-target'
$dangling = Join-Path $root 'data\dangling'
[void][IO.Directory]::CreateDirectory($lostTarget)
[void](New-Item -ItemType Junction -Path $dangling -Target $lostTarget)
[IO.Directory]::Delete($lostTarget)
Assert-Rejected { Assert-UpdatePathSafe (Join-Path $dangling 'child') } 'dangling junction is rejected'

$dataUpdate = Join-Path $root 'data\update'
[void](New-Item -ItemType Junction -Path $dataUpdate -Target $outside)
Assert-Rejected { Get-UpdateBaseUri $root } 'configuration refuses a junction at data/update'
Assert-Rejected { Stage-UpdateOffer $root ([pscustomobject]@{}) } 'staging refuses a junction before writing'
$badStage = Join-Path $dataUpdate ('staged-' + [Guid]::NewGuid().ToString('N'))
$applyCode = Invoke-TestScript (Join-Path $root 'update\apply.ps1') @('-Staging',$badStage,'-Serial','emulator-5554','-NoRestart')
Assert-True ($applyCode -ne 0) 'apply refuses a linked update root before process detection'
$bridgeCode = Invoke-TestScript (Join-Path $root 'update\bridge.ps1') @('-Serial','emulator-5554','-EmulatorPid','1')
Assert-True ($bridgeCode -ne 0) 'bridge refuses a linked update root before creating logs'
$recoveryCode = Invoke-TestScript (Join-Path $root 'update\recovery.ps1') @()
Assert-True ($recoveryCode -ne 0) 'recovery independently refuses a linked update root'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $outside 'update.log')) -and -not (Test-Path -LiteralPath (Join-Path $outside 'bridge.log'))) 'linked target receives no updater logs'

# Remove only this exact fixture junction, never the linked directory tree.
[IO.Directory]::Delete($dataUpdate)
[void][IO.Directory]::CreateDirectory($dataUpdate)
$pending = Join-Path $dataUpdate 'pending'
[void](New-Item -ItemType Junction -Path $pending -Target $outside)
$recoveryCode = Invoke-TestScript (Join-Path $root 'update\recovery.ps1') @()
Assert-True ($recoveryCode -ne 0) 'recovery refuses a linked pending directory'
[IO.Directory]::Delete($pending)
[void][IO.Directory]::CreateDirectory($pending)

# A backup file symlink must be refused even when its bytes match the journal.
$linkedBackup = Join-Path $pending '0000.bak'
[void](New-Item -ItemType SymbolicLink -Path $linkedBackup -Target $outsideSentinel)
$backupHash = $outsideHash.ToLowerInvariant()
$journal = @{schema=1;files=@(@{path='version.ini';existed=$true;backup='0000.bak';sha256=$backupHash})} | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $pending 'transaction.json'), $journal)
[IO.File]::WriteAllText((Join-Path $pending 'applying.flag'), '1')
[IO.File]::WriteAllText((Join-Path $root 'version.ini'), 'must stay unchanged')
$recoveryCode = Invoke-TestScript (Join-Path $root 'update\recovery.ps1') @()
Assert-True ($recoveryCode -ne 0) 'recovery refuses a linked backup file'
Assert-True ([IO.File]::ReadAllText((Join-Path $root 'version.ini')) -ceq 'must stay unchanged') 'recovery does not replace target on unsafe backup'
Assert-True ((Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash -ceq $userHash) 'AVD user data remains unchanged'
Assert-True ((Get-FileHash -LiteralPath $outsideSentinel -Algorithm SHA256).Hash -ceq $outsideHash) 'linked external data remains unchanged'
Write-Host 'Isolated updater security tests passed.'
