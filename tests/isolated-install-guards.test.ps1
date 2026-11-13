# Offline tests only: no installer, account, profile deletion, or remote calls.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'isolated-install-common.ps1')
function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-False([bool]$Value, [string]$Message) { if ($Value) { throw $Message } }
$root = 'C:\Users'
$sid = 'S-1-5-21-101-202-303-1001'
$name = 'ArtTest012345abcdef'
$profile = [pscustomobject]@{ SID=$sid; LocalPath=(Join-Path $root $name); Loaded=$false; Special=$false }
$identity = Get-IsolatedAccountIdentity '012345abcdef012345abcdef012345ab'
Assert-True ($identity.Name.Length -le 20 -and $identity.Marker.Length -le 48) 'account name or description exceeds Windows limits'
Assert-True (Test-IsolatedChildPath 'C:\Build' 'C:\Build\run\install') 'direct child rejected'
Assert-False (Test-IsolatedChildPath 'C:\Build' 'C:\Build') 'root must not be accepted'
Assert-False (Test-IsolatedChildPath 'C:\Build' 'C:\Build-other\run') 'sibling must not be accepted'
Assert-False (Test-IsolatedChildPath 'C:\Build' 'C:\Build\..\other') 'traversal must not be accepted'
Assert-True (Test-IsolatedProfileCandidate $sid $name $root $profile @('C:\Users\Other')) 'valid profile rejected'
Assert-False (Test-IsolatedProfileCandidate 'S-1-5-18' $name $root $profile @()) 'system SID accepted'
Assert-False (Test-IsolatedProfileCandidate $sid 'Administrator' $root $profile @()) 'unexpected account accepted'
$profile.Loaded = $true
Assert-False (Test-IsolatedProfileCandidate $sid $name $root $profile @()) 'loaded profile accepted'
$profile.Loaded = $false
$profile.Special = $true
Assert-False (Test-IsolatedProfileCandidate $sid $name $root $profile @()) 'special profile accepted'
$profile.Special = $false
Assert-False (Test-IsolatedProfileCandidate $sid $name $root $profile @($profile.LocalPath)) 'existing profile path accepted'
$profile.LocalPath = 'C:\Users\Other\ArtTest012345abcdef'
Assert-False (Test-IsolatedProfileCandidate $sid $name $root $profile @()) 'non-immediate profile accepted'
$files = @('isolated-final-install.ps1','isolated-install-worker.ps1','isolated-install-common.ps1')
foreach ($file in $files) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file), [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw ('PowerShell parse failed: ' + $file) }
}
Add-Type -Path (Join-Path $PSScriptRoot 'isolated-install-job.cs')
$job = [ArtemisAcceptanceJob]::Create()
if ($job -eq [IntPtr]::Zero) { throw 'Could not create an empty test job object.' }
[ArtemisAcceptanceJob]::Close($job)
Write-Host 'Offline isolation guard and parser tests passed; no account or installer was started.'
