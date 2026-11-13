param([string]$FixtureParent = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build'))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\ArtemisInstallDiscovery.psm1') -Force
$parent = (Resolve-Path -LiteralPath $FixtureParent).Path.TrimEnd('\')
$fixture = Join-Path $parent ('installer-discovery-' + [Guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $fixture) { throw 'Fixture path unexpectedly exists.' }
[void][IO.Directory]::CreateDirectory($fixture)
function Assert([bool]$Ok, [string]$Message) {
    if (-not $Ok) { throw $Message }
    Write-Host "PASS: $Message"
}
function New-FixtureInstall([string]$Name, [string]$Version) {
    $root = Join-Path $fixture $Name
    foreach ($path in @('sdk\emulator', 'sdk\system-images\android-35\google_apis\x86_64', 'data\avd')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $root $path))
    }
    $files = @{
        'version.ini' = "[ArtemisOS]`nVersion=$Version`n"; 'launch.ps1' = '# fixture'; 'settings.ps1' = '# fixture'
        'sdk\emulator\emulator.exe' = 'fake emulator'; 'sdk\system-images\android-35\google_apis\x86_64\system.img' = 'fake image'
        'unins000.exe' = 'fake uninstaller'; 'unins000.dat' = 'fake uninstall log'; 'data\preferences.ini' = 'user preferences'
        'data\avd\userdata-qemu.img.qcow2' = 'user disk'
    }
    foreach ($file in $files.Keys) { [IO.File]::WriteAllText((Join-Path $root $file), $files[$file], [Text.Encoding]::ASCII) }
    return $root
}
function New-Registration([string]$Path, [string]$AppId, [string]$Hive = 'CurrentUser', [string]$View = 'Registry64') {
    return [pscustomobject]@{
        Hive=$Hive; View=$View; AppId=$AppId; InstallLocation=$Path + '\'; AppPath=$Path
        UninstallString='"' + (Join-Path $Path 'unins000.exe') + '"'
    }
}
try {
    $legacy = New-FixtureInstall 'legacy' '0.3.5'
    $modern = New-FixtureInstall 'modern' '0.3.6'
    $manual = New-FixtureInstall 'manual' '0.3.3'
    $unicode = New-FixtureInstall ([string][char]0x4e2d + [string][char]0x6587) '1.0.0.0'
    $userDisk = Join-Path $legacy 'data\avd\userdata-qemu.img.qcow2'
    $userPrefs = Join-Path $legacy 'data\preferences.ini'
    $beforeDisk = [IO.File]::ReadAllBytes($userDisk)
    $beforePrefs = [IO.File]::ReadAllBytes($userPrefs)
    $oldId = '{E49344F1-069E-4DA4-A5B7-232C0BE325A8}'
    $newId = 'ArtemisOS15-Release'
    $old32 = New-Registration $legacy $oldId 'CurrentUser' 'Registry32'
    $old64 = New-Registration $legacy $oldId 'CurrentUser' 'Registry64'
    $new64 = New-Registration $modern $newId
    $unrelated = New-Registration $manual 'SomeOtherProduct'
    $discovery = Get-ArtemisInstallCandidates -Registrations @($old32,$old64,$new64,$unrelated)
    Assert ($discovery.Issues.Count -eq 0 -and $discovery.Candidates.Count -eq 2) 'known AppIds are discovered; duplicate registry views and unrelated products are handled'
    $oldCandidate = @($discovery.Candidates | Where-Object Path -eq $legacy)[0]
    Assert ($oldCandidate.Registrations.Count -eq 2 -and -not $oldCandidate.RegistrationAmbiguous) 'two views of the same identity and location are not treated as separate installs'
    Assert ((Resolve-ArtemisInstallTarget $discovery -TargetVersion '1.0.0').Status -eq 'selection_required') 'multiple installations require an explicit choice'
    $selected = Resolve-ArtemisInstallTarget $discovery -ExplicitPath ($legacy.ToUpperInvariant() + '\') -TargetVersion '1.0.0'
    Assert ($selected.Status -eq 'selected' -and $selected.Candidate.Path -ieq $legacy) 'an explicit path selects the intended old installation'
    $single = Get-ArtemisInstallCandidates -Registrations @($old32,$old64)
    Assert ((Resolve-ArtemisInstallTarget $single -TargetVersion '1.0.0').Status -eq 'selected') 'a single validated old installation is selected'
    Assert ((Resolve-ArtemisInstallTarget $single -TargetVersion '0.3.5').Status -eq 'current') 'equal versions are reported without implying an upgrade'
    Assert ((Resolve-ArtemisInstallTarget $single -TargetVersion '0.3.4').Status -eq 'newer') 'a downgrade is not selected'
    $chosenManual = Resolve-ArtemisInstallTarget $single -ExplicitPath $manual -TargetVersion '1.0.0'
    Assert ($chosenManual.Status -eq 'unregistered' -and -not $chosenManual.Candidate.Registered) 'a manually chosen valid unregistered install is distinguished'
    $unicodeInfo = Get-ArtemisProductInfo $unicode
    Assert ($unicodeInfo.Path -eq $unicode) 'valid Unicode installation paths are supported'
    Assert ((Resolve-ArtemisInstallTarget $single -ExplicitPath $unicode -TargetVersion '1.0.0').Status -eq 'current') 'three- and four-part equivalent versions compare equally'
    $sameRootOtherId = New-Registration $legacy $newId
    $clash = Get-ArtemisInstallCandidates -Registrations @($old64,$sameRootOtherId)
    Assert ((Resolve-ArtemisInstallTarget $clash -TargetVersion '1.0.0').Status -eq 'registration_ambiguous') 'different AppIds targeting one directory are blocked'
    $sameIdentityOtherRoot = New-Registration $modern $oldId 'CurrentUser' 'Registry32'
    $clash = Get-ArtemisInstallCandidates -Registrations @($old64,$sameIdentityOtherRoot)
    Assert ((Resolve-ArtemisInstallTarget $clash -ExplicitPath $legacy -TargetVersion '1.0.0').Status -eq 'registration_ambiguous') 'one registry identity targeting different paths is blocked'
    $invalidUninstaller = New-Registration $legacy $oldId
    $invalidUninstaller.UninstallString = '"C:\Windows\System32\cmd.exe"'
    $bad = Get-ArtemisInstallCandidates -Registrations @($invalidUninstaller)
    Assert ($bad.Issues.Count -eq 1 -and (Resolve-ArtemisInstallTarget $bad).Status -eq 'registration_uncertain') 'a foreign uninstall command is never trusted or executed'
    Assert ((Resolve-ArtemisInstallTarget $bad -ExplicitPath $legacy).Status -eq 'registration_uncertain') 'an invalid registration cannot be bypassed by treating the directory as unregistered'
    $badAndValid = Get-ArtemisInstallCandidates -Registrations @($old64,$invalidUninstaller)
    Assert ((Resolve-ArtemisInstallTarget $badAndValid -ExplicitPath $legacy).Status -eq 'registration_uncertain') 'a valid registration cannot hide another unverified registration'
    $badFields = New-Registration $legacy $oldId
    $badFields.AppPath = $modern
    $bad = Get-ArtemisInstallCandidates -Registrations @($badFields)
    Assert ($bad.Issues.Count -eq 1) 'conflicting installation path fields are rejected'
    Assert ((Resolve-ArtemisInstallTarget (Get-ArtemisInstallCandidates) -ExplicitPath $fixture).Status -eq 'invalid_target') 'an ordinary non-product directory is rejected'
    $empty = Get-ArtemisInstallCandidates
    Assert ((Resolve-ArtemisInstallTarget $empty).Status -eq 'not_found') 'absence of registrations is reported explicitly'
    $link = Join-Path $fixture 'link'
    [void](New-Item -ItemType Junction -Path $link -Target $legacy -ErrorAction Stop)
    Assert ((Resolve-ArtemisInstallTarget $empty -ExplicitPath $link).Status -eq 'invalid_target') 'a reparse-point target is rejected'
    Assert ([Convert]::ToBase64String($beforeDisk) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($userDisk)) -and
        [Convert]::ToBase64String($beforePrefs) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($userPrefs))) 'discovery did not modify fixture data or preferences'
} finally {
    # Only delete this test's exact freshly created fixture under its resolved parent.
    if (Test-Path -LiteralPath $fixture) {
        $item = Get-Item -LiteralPath $fixture -Force
        if ($item.FullName -ine $fixture -or $item.Parent.FullName.TrimEnd('\') -ine $parent -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe fixture cleanup path.' }
        $junction = Join-Path $fixture 'link'
        if (Test-Path -LiteralPath $junction) {
            $linkItem = Get-Item -LiteralPath $junction -Force
            if (-not ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unexpected junction fixture.' }
            [IO.Directory]::Delete($junction)
        }
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
