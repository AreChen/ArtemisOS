param(
    [Parameter(Mandatory=$true)][string]$RunRoot,
    [Parameter(Mandatory=$true)][string]$ExpectedSid,
    [Parameter(Mandatory=$true)][string]$ExpectedImageHash,
    [Parameter(Mandatory=$true)][string]$ExpectedServerHash,
    [Parameter(Mandatory=$true)][string]$ExpectedTrustedKeyHash,
    [Parameter(Mandatory=$true)][string]$ExpectedInstallerHash
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
foreach ($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management','Microsoft.PowerShell.Security')) {
    Import-Module (Join-Path $PSHOME ('Modules\' + $module + '\' + $module + '.psd1')) -ErrorAction Stop
}
. (Join-Path $PSScriptRoot 'isolated-install-common.ps1')
$work = Join-Path $RunRoot 'work'
$install = Join-Path $work 'install'
$resultFile = Join-Path $work 'result.json'
$step = 'identity'
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($identity.User.Value -cne $ExpectedSid -or
        $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Unexpected security token.' }
    if (-not (Test-Path -LiteralPath ("Registry::HKEY_USERS\" + $ExpectedSid))) { throw 'User profile hive is not loaded.' }
    $profileKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $ExpectedSid
    $profilePath = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty -LiteralPath $profileKey).ProfileImagePath)
    if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) { throw 'User profile directory missing.' }
    foreach ($folder in @('UserProfile','DesktopDirectory','Programs','ApplicationData','LocalApplicationData')) {
        $known = [Environment]::GetFolderPath($folder)
        if ($known -and -not (Test-IsolatedChildPath $work $known) -and
            -not (Test-IsolatedChildPath $profilePath $known) -and
            -not [string]::Equals($known.TrimEnd('\'), $profilePath.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A user shell folder escapes the temporary profile and fixture.'
        }
    }
    if (-not (Test-IsolatedChildPath $work $install) -or (Test-Path -LiteralPath $install)) { throw 'Install path is not a new fixture.' }
    $key = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\ArtemisOS15-Release_is1'
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryHive]::LocalMachine)) {
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)) {
            $reg = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
            try { $existing = $reg.OpenSubKey($key); if ($existing) { $existing.Dispose(); throw 'Same AppId is already registered.' } }
            finally { $reg.Dispose() }
        }
    }
    $step = 'waiting-for-isolation-approval'
    [IO.File]::WriteAllText((Join-Path $work 'worker-ready'), 'ready', [Text.Encoding]::ASCII)
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    while (-not (Test-Path -LiteralPath (Join-Path $RunRoot 'go'))) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Parent did not approve isolation.' }
        Start-Sleep -Milliseconds 250
    }
    $step = 'installer-integrity'
    $installer = Join-Path $work 'installer.exe'
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -cne $ExpectedInstallerHash) { throw 'Installer hash changed.' }
    $rtk = Join-Path $work 'rtk.exe'
    $step = 'install'
    $args = @('proxy', ('"' + $installer + '"'), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/NOICONS', '/TASKS=""', ('/DIR="' + $install + '"'))
    $process = Start-Process -FilePath $rtk -ArgumentList $args -WindowStyle Hidden -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw 'Installer returned a failure status.' }
    $step = 'registration'
    $registration = Get-ItemProperty -LiteralPath ('HKCU:\' + $key) -ErrorAction Stop
    if ($registration.DisplayVersion -cne '1.0.0' -or
        -not [string]::Equals($registration.InstallLocation.TrimEnd('\'), $install.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Registration does not match fixture.' }
    $step = 'version'
    $versionIni = [IO.File]::ReadAllText((Join-Path $install 'version.ini'))
    if ($versionIni -notmatch '(?m)^Version=1\.0\.0\r?$') { throw 'Product version mismatch.' }
    $source = [IO.File]::ReadAllText((Join-Path $install 'sdk\emulator\source.properties'))
    if ($source -notmatch '(?m)^Pkg\.Revision\s*=\s*37\.3\.6\s*$') { throw 'Runtime package version mismatch.' }
    $step = 'emulator-executable-version'
    $emulator = Join-Path $install 'sdk\emulator\emulator.exe'
    $savedPreference = $ErrorActionPreference
    try {
        # Emulator emits informational messages to stderr even on success.
        $ErrorActionPreference = 'Continue'
        $emulatorVersion = (& $rtk proxy $emulator -version 2>&1 | Out-String)
        $emulatorExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($emulatorExit -ne 0 -or $emulatorVersion -notmatch '(?m)^Android emulator version 37\.3\.6(?:\.0)?(?:\s|$)') { throw 'Runtime executable version mismatch.' }
    $step = 'image'
    $image = Join-Path $install 'sdk\system-images\android-35\google_apis\x86_64\system.img'
    if ((Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash -cne $ExpectedImageHash) { throw 'Image hash mismatch.' }
    if (-not (Test-Path -LiteralPath (Join-Path $install 'sdk\system-images\android-35\google_apis\x86_64\data\empty_data_disk')) -or
        (Test-Path -LiteralPath (Join-Path $install '.artemis-fresh-install'))) { throw 'Fresh-install markers are inconsistent.' }
    $step = 'preferences'
    $prefs = [IO.File]::ReadAllText((Join-Path $install 'data\preferences.ini'))
    if ($prefs -notmatch '(?m)^graphics=auto\r?$') { throw 'Automatic graphics preference missing.' }
    . (Join-Path $install 'settings.ps1')
    if ((Get-ArtemisPreferences).Graphics -cne 'auto' -or (Get-ArtemisGraphics 'auto' 'auto') -cne 'auto') { throw 'Automatic graphics behavior mismatch.' }
    $step = 'update-config'
    if ((Get-FileHash -LiteralPath (Join-Path $install 'update\server.txt') -Algorithm SHA256).Hash -cne $ExpectedServerHash -or
        (Get-FileHash -LiteralPath (Join-Path $install 'update\trusted-key.xml') -Algorithm SHA256).Hash -cne $ExpectedTrustedKeyHash) { throw 'Update configuration hash mismatch.' }
    $step = 'signed-update-check'
    . (Join-Path $install 'update\core.ps1')
    try { $offer = Get-UpdateOffer $install } catch { throw 'Signed online update check failed; details suppressed.' }
    if ($null -ne $offer) { throw 'Server reports an available update.' }
    [IO.File]::WriteAllText($resultFile, '{"ok":true}', [Text.Encoding]::ASCII)
    exit 0
} catch {
    # Do not serialize exception details: HTTP exceptions can contain share URLs.
    $safeStep = $step -replace '[^A-Za-z0-9-]', ''
    [IO.File]::WriteAllText($resultFile, ('{"ok":false,"step":"' + $safeStep + '"}'), [Text.Encoding]::ASCII)
    exit 1
}
