<#
  Acceptance test for an exact, previously built installer. No account is created
  without -Execute. Run only from an elevated 64-bit Windows PowerShell 5.1.
  This is isolation from existing HKCU/profile state, not a security sandbox.
  Input files must be independent, previously approved release artifacts.
#>
param(
    [Parameter(Mandatory=$true)][string]$Installer,
    [Parameter(Mandatory=$true)][string]$ExpectedImage,
    [Parameter(Mandatory=$true)][string]$ExpectedServer,
    [Parameter(Mandatory=$true)][string]$ExpectedTrustedKey,
    [switch]$Execute,
    [int]$TimeoutMinutes = 120
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
foreach ($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management','Microsoft.PowerShell.Security','CimCmdlets')) {
    Import-Module (Join-Path $PSHOME ('Modules\' + $module + '\' + $module + '.psd1')) -ErrorAction Stop
}
. (Join-Path $PSScriptRoot 'isolated-install-common.ps1')
if ($PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell 5.1.' }
$current = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($current)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'An elevated administrator token is required.' }
if ($TimeoutMinutes -lt 5 -or $TimeoutMinutes -gt 180) { throw 'TimeoutMinutes must be between 5 and 180.' }
Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction Stop
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$build = [IO.Path]::GetFullPath((Join-Path $repo 'build'))
if (-not (Test-Path -LiteralPath $build -PathType Container)) { throw 'The existing build directory is required.' }
Assert-NoReparsePoints $build
$sources = @{}
foreach ($entry in @{ Installer=$Installer; Image=$ExpectedImage; Server=$ExpectedServer; TrustedKey=$ExpectedTrustedKey }.GetEnumerator()) {
    $path = (Resolve-Path -LiteralPath $entry.Value -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'A required release input is missing.' }
    $sources[$entry.Key] = $path
}
$rtkPath = (Get-Command rtk.exe -ErrorAction Stop).Source
$key = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\ArtemisOS15-Release_is1'
foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)) {
    $reg = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
    try { $existing = $reg.OpenSubKey($key); if ($existing) { $existing.Dispose(); throw 'Same AppId is registered machine-wide; do not proceed.' } }
    finally { $reg.Dispose() }
}
$hashes = @{}
foreach ($name in @('Installer','Image','Server','TrustedKey')) { $hashes[$name] = (Get-FileHash -LiteralPath $sources[$name] -Algorithm SHA256).Hash }
if (-not $Execute) { Write-Host 'Read-only preflight passed. No account or installer was started.'; return }

$runId = [Guid]::NewGuid().ToString('N')
$identity = Get-IsolatedAccountIdentity $runId
$name = $identity.Name
$marker = $identity.Marker
$run = Join-Path $build ('isolated-final-' + $runId)
$work = Join-Path $run 'work'
if (-not (Test-IsolatedChildPath $build $run) -or (Test-Path -LiteralPath $run)) { throw 'Fixture path is not new under build.' }
if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) { throw 'Random account name already exists.' }
$profilesBefore = @(Get-CimInstance -ClassName Win32_UserProfile)
$profileRootRaw = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList').ProfilesDirectory
$profileRoot = [Environment]::ExpandEnvironmentVariables($profileRootRaw).TrimEnd('\')
Assert-NoReparsePoints $profileRoot
$profileDirectoriesBefore = @(Get-ChildItem -LiteralPath $profileRoot -Force -Directory | ForEach-Object { $_.FullName })
[void][IO.Directory]::CreateDirectory($run)
Assert-NoReparsePoints $run

# Restrict the journal before account creation. The temporary user can later
# traverse/read the run root but can only write within work.
$adminSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
$systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
$inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
$none = [Security.AccessControl.PropagationFlags]::None
$rootAcl = New-Object Security.AccessControl.DirectorySecurity
$rootAcl.SetAccessRuleProtection($true, $false)
foreach ($sid in @($adminSid,$systemSid,$current.User)) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inherit, $none, 'Allow')
    $rootAcl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $run -AclObject $rootAcl
$journal = [ordered]@{ schema=1; runId=$runId; accountName=$name; marker=$marker; createdUtc=[DateTime]::UtcNow.ToString('o'); accountExpiresUtc=[DateTime]::UtcNow.AddHours(4).ToString('o') }
[IO.File]::WriteAllText((Join-Path $run 'account-journal.json'), ($journal | ConvertTo-Json -Compress), [Text.Encoding]::UTF8)
$accountSid = $null
$secure = $null
$worker = $null
$job = [IntPtr]::Zero
$cleanupErrors = New-Object 'Collections.Generic.List[string]'
$testSucceeded = $false
try {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $secure = New-Object Security.SecureString
    foreach ($char in 'Aa1!'.ToCharArray()) { $secure.AppendChar($char) }
    $alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    foreach ($byte in $bytes) { $secure.AppendChar($alphabet[[int]$byte % $alphabet.Length]) }
    [Array]::Clear($bytes, 0, $bytes.Length)
    $secure.MakeReadOnly()
    $user = New-LocalUser -Name $name -Password $secure -Description $marker -AccountExpires (Get-Date).AddHours(4) -ErrorAction Stop
    $accountSid = $user.SID.Value
    [IO.File]::WriteAllText((Join-Path $run 'account-sid.txt'), $accountSid, [Text.Encoding]::ASCII)
    if ($accountSid -notmatch '^S-1-5-21-(?:\d+-){3}\d+$' -or $accountSid -ceq $current.User.Value) { throw 'Unexpected account SID.' }
    $testSid = New-Object Security.Principal.SecurityIdentifier($accountSid)
    $readRule = New-Object Security.AccessControl.FileSystemAccessRule($testSid, 'ReadAndExecute', $inherit, $none, 'Allow')
    $rootAcl.AddAccessRule($readRule)
    Set-Acl -LiteralPath $run -AclObject $rootAcl
    [void][IO.Directory]::CreateDirectory($work)
    $workAcl = Get-Acl -LiteralPath $work
    $modifyRule = New-Object Security.AccessControl.FileSystemAccessRule($testSid, 'Modify', $inherit, $none, 'Allow')
    $workAcl.AddAccessRule($modifyRule)
    Set-Acl -LiteralPath $work -AclObject $workAcl
    foreach ($dir in @('home','home\Desktop','home\AppData\Roaming','home\AppData\Local','temp')) { [void][IO.Directory]::CreateDirectory((Join-Path $work $dir)) }
    [IO.File]::Copy($sources.Installer, (Join-Path $work 'installer.exe'))
    [IO.File]::Copy($rtkPath, (Join-Path $work 'rtk.exe'))
    foreach ($file in @('isolated-install-worker.ps1','isolated-install-common.ps1')) { [IO.File]::Copy((Join-Path $PSScriptRoot $file), (Join-Path $work $file)) }
    Add-Type -Path (Join-Path $PSScriptRoot 'isolated-install-job.cs')
    $job = [ArtemisAcceptanceJob]::Create()
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.UseShellExecute = $false
    $start.LoadUserProfile = $true
    $start.UserName = $name
    $start.Domain = $env:COMPUTERNAME
    $start.Password = $secure
    $start.WorkingDirectory = $work
    $start.CreateNoWindow = $true
    $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $work 'isolated-install-worker.ps1') + '"' +
        ' -RunRoot "' + $run + '" -ExpectedSid "' + $accountSid + '" -ExpectedImageHash ' + $hashes.Image +
        ' -ExpectedServerHash ' + $hashes.Server + ' -ExpectedTrustedKeyHash ' + $hashes.TrustedKey + ' -ExpectedInstallerHash ' + $hashes.Installer
    $start.EnvironmentVariables.Clear()
    foreach ($var in @('SystemRoot','SystemDrive','ComSpec','PATHEXT','ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','PROCESSOR_ARCHITECTURE','NUMBER_OF_PROCESSORS')) {
        $value = [Environment]::GetEnvironmentVariable($var, 'Process')
        if ($value) { $start.EnvironmentVariables[$var] = $value }
    }
    $start.EnvironmentVariables['windir'] = $env:SystemRoot
    $start.EnvironmentVariables['PATH'] = (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot + ';' + (Join-Path $env:SystemRoot 'System32\Wbem')
    $start.EnvironmentVariables['USERPROFILE'] = Join-Path $work 'home'
    $start.EnvironmentVariables['APPDATA'] = Join-Path $work 'home\AppData\Roaming'
    $start.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $work 'home\AppData\Local'
    $start.EnvironmentVariables['TEMP'] = Join-Path $work 'temp'
    $start.EnvironmentVariables['TMP'] = Join-Path $work 'temp'
    $start.EnvironmentVariables['USERNAME'] = $name
    $start.EnvironmentVariables['USERDOMAIN'] = $env:COMPUTERNAME
    $worker = [Diagnostics.Process]::Start($start)
    [ArtemisAcceptanceJob]::Attach($job, $worker.Handle)
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    while (-not (Test-Path -LiteralPath (Join-Path $work 'worker-ready'))) {
        if ($worker.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'Worker did not pass its isolation checks.' }
        Start-Sleep -Milliseconds 250
    }
    $p = @(Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.SID -ceq $accountSid })
    if ($p.Count -ne 1 -or -not $p[0].Loaded -or $p[0].Special -or -not (Test-IsolatedChildPath $profileRoot $p[0].LocalPath)) { throw 'Temporary profile did not match its new SID.' }
    Assert-NoReparsePoints $p[0].LocalPath
    $previousPaths = @($profilesBefore.LocalPath) + $profileDirectoriesBefore
    if (@($previousPaths | Where-Object { [string]::Equals($_, $p[0].LocalPath, [StringComparison]::OrdinalIgnoreCase) -or (Test-IsolatedChildPath $_ $p[0].LocalPath) -or (Test-IsolatedChildPath $p[0].LocalPath $_) }).Count -ne 0) { throw 'Temporary profile path existed beforehand.' }
    [IO.File]::WriteAllText((Join-Path $run 'go'), 'go', [Text.Encoding]::ASCII)
    if (-not $worker.WaitForExit($TimeoutMinutes * 60000)) { throw 'Acceptance test timed out.' }
    $resultPath = Join-Path $work 'result.json'
    if (-not (Test-Path -LiteralPath $resultPath)) { throw 'Worker did not write a result.' }
    $result = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
    if ($worker.ExitCode -ne 0 -or -not $result.ok) {
        $step = if ($result.PSObject.Properties['step']) { [string]$result.step } else { 'unknown' }
        throw ('Acceptance failed at safe step: ' + ($step -replace '[^A-Za-z0-9-]', ''))
    }
    $testSucceeded = $true
} finally {
    if ($job -ne [IntPtr]::Zero) { [ArtemisAcceptanceJob]::Close($job); $job = [IntPtr]::Zero }
    if ($worker -and -not $worker.HasExited) { try { $worker.Kill(); $worker.WaitForExit(10000) | Out-Null } catch { $cleanupErrors.Add('Could not stop worker.') } }
    if ($secure) { $secure.Dispose() }
    $owned = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if ($owned) {
        if ($owned.Description -cne $marker -or ($accountSid -and $owned.SID.Value -cne $accountSid) -or $owned.SID.Value -ceq $current.User.Value) {
            $cleanupErrors.Add('Account ownership check failed; no account or profile was changed.')
        } else {
            $accountSid = $owned.SID.Value
            try { Disable-LocalUser -SID $owned.SID -ErrorAction Stop } catch { $cleanupErrors.Add('Could not disable temporary account.') }
            try {
                $profileDeadline = [DateTime]::UtcNow.AddSeconds(30)
                do {
                    $profiles = @(Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.SID -ceq $accountSid })
                    if ($profiles.Count -eq 0 -or -not $profiles[0].Loaded) { break }
                    Start-Sleep -Seconds 1
                } while ([DateTime]::UtcNow -lt $profileDeadline)
                if ($profiles.Count -gt 1) { throw 'Multiple profile records.' }
                if ($profiles.Count -eq 1) {
                    $otherPaths = @((Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.SID -cne $accountSid }).LocalPath) + @($profilesBefore.LocalPath) + $profileDirectoriesBefore
                    if (-not (Test-IsolatedProfileCandidate $accountSid $name $profileRoot $profiles[0] $otherPaths)) { throw 'Profile safety check failed.' }
                    Assert-NoReparsePoints $profiles[0].LocalPath
                    $aclMatches = @((Get-Acl -LiteralPath $profiles[0].LocalPath).Access | Where-Object {
                        try { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ceq $accountSid } catch { $false }
                    })
                    if ($aclMatches.Count -eq 0) { throw 'Profile ACL does not identify the temporary SID.' }
                    $profiles[0] | Remove-CimInstance -ErrorAction Stop
                }
            } catch { $cleanupErrors.Add('Temporary profile retained because cleanup could not be verified.') }
            try { Remove-LocalUser -SID $owned.SID -ErrorAction Stop } catch { $cleanupErrors.Add('Temporary account could not be removed.') }
        }
    }
    [IO.File]::WriteAllText((Join-Path $run 'cleanup-status.json'), (@{ success=($cleanupErrors.Count -eq 0); issues=@($cleanupErrors.ToArray()) } | ConvertTo-Json -Compress), [Text.Encoding]::UTF8)
    if ($cleanupErrors.Count -gt 0) { throw ('Cleanup incomplete. Inspect the protected journal at ' + $run + '. ' + ($cleanupErrors -join ' ')) }
}
if ($testSucceeded) { Write-Host ('Installer checks passed; temporary account and eligible profile removed. Fixture retained: ' + $run) }
