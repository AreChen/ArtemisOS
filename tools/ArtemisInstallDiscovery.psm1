Set-StrictMode -Version 2.0

# This module only reads Windows registration and installation metadata.
# A caller performing an upgrade must independently revalidate the selected
# location immediately before taking any lock or modifying files.
$script:ArtemisKnownAppIds = @('{E49344F1-069E-4DA4-A5B7-232C0BE325A8}', 'ArtemisOS15-Release')
$script:ArtemisRequiredFiles = @(
    'version.ini', 'launch.ps1', 'settings.ps1',
    'sdk\emulator\emulator.exe',
    'sdk\system-images\android-35\google_apis\x86_64\system.img'
)

function Get-ArtemisCanonicalDirectory {
    param([Parameter(Mandatory=$true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '安装目录为空。' }
    $text = $Path.Trim()
    if ($text.StartsWith('"') -or $text.EndsWith('"') -or $text -notmatch '^[A-Za-z]:\\') {
        throw '安装目录必须是本地磁盘的绝对路径。'
    }
    if ($text -match '[\x00-\x1f<>"|?*]') { throw '安装目录包含不受支持的字符。' }
    $full = [IO.Path]::GetFullPath($text).TrimEnd('\')
    if ($full -ieq [IO.Path]::GetPathRoot($full).TrimEnd('\')) { throw '安装目录不能是磁盘根目录。' }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or $item.FullName.TrimEnd('\') -ine $full) { throw '安装目录不是普通目录。' }
    while ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '安装目录或其父目录包含重解析点。' }
        $next = $item.Parent
        if ($null -eq $next) { break }
        $item = $next
    }
    return $full
}

function Test-ArtemisRegularFile {
    param([string]$Root, [string]$Relative)
    $path = Join-Path $Root $Relative
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -le 0) {
        throw '产品文件缺失或不是普通文件。'
    }
    $parent = $item.Directory
    while ($parent -and $parent.FullName.TrimEnd('\') -ine $Root) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '产品文件路径包含重解析点。' }
        $parent = $parent.Parent
    }
    if (-not $parent) { throw '产品文件不在安装目录内。' }
    return $item
}

function Get-ArtemisProductInfo {
    param([Parameter(Mandatory=$true)][string]$Path)
    $root = Get-ArtemisCanonicalDirectory $Path
    foreach ($relative in $script:ArtemisRequiredFiles) { [void](Test-ArtemisRegularFile $root $relative) }
    $versionFile = Test-ArtemisRegularFile $root 'version.ini'
    if ($versionFile.Length -gt 65536) { throw '产品版本文件过大。' }
    $inSection = $false
    $versions = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in [IO.File]::ReadAllLines($versionFile.FullName)) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') { $inSection = ($matches[1] -ieq 'ArtemisOS'); continue }
        if ($inSection -and $trimmed -match '^Version\s*=\s*(\d+\.\d+\.\d+(?:\.\d+)?)$') { $versions.Add($matches[1]) }
        elseif ($inSection -and $trimmed -match '^Version\s*=') { throw '产品版本格式无效。' }
    }
    if ($versions.Count -ne 1) { throw '无法唯一确定产品版本。' }
    try { $version = [Version]$versions[0] } catch { throw '产品版本格式无效。' }
    return [pscustomobject]@{ Path = $root; Version = $version.ToString() }
}

function Get-ArtemisRegistryRegistrations {
    # Query the exact IDs only; never execute an uninstall command or search
    # arbitrary registry entries. A failing view is returned as an issue.
    $records = New-Object 'System.Collections.Generic.List[object]'
    $issues = New-Object 'System.Collections.Generic.List[object]'
    foreach ($hiveName in @('CurrentUser','LocalMachine')) {
        foreach ($viewName in @('Registry32','Registry64')) {
            $base = $null
            try {
                $hive = [Microsoft.Win32.RegistryHive]::$hiveName
                $view = [Microsoft.Win32.RegistryView]::$viewName
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
                foreach ($id in $script:ArtemisKnownAppIds) {
                    $key = $null
                    try {
                        $key = $base.OpenSubKey(('Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $id + '_is1'), $false)
                        if ($null -ne $key) {
                            $option = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                            $records.Add([pscustomobject]@{
                                Hive = $hiveName; View = $viewName; AppId = $id
                                InstallLocation = [string]$key.GetValue('InstallLocation', '', $option)
                                AppPath = [string]$key.GetValue('Inno Setup: App Path', '', $option)
                                UninstallString = [string]$key.GetValue('UninstallString', '', $option)
                            })
                        }
                    } catch {
                        $issues.Add([pscustomobject]@{ Code = 'registration_read_failed'; Hive = $hiveName; View = $viewName; AppId = $id })
                    } finally { if ($key) { $key.Dispose() } }
                }
            } catch {
                $issues.Add([pscustomobject]@{ Code = 'registry_view_read_failed'; Hive = $hiveName; View = $viewName; AppId = '' })
            } finally { if ($base) { $base.Dispose() } }
        }
    }
    return [pscustomobject]@{ Records = @($records.ToArray()); Issues = @($issues.ToArray()) }
}

function Test-ArtemisUninstallReference {
    param([string]$Root, [string]$Command)
    if ($Command -notmatch '^\s*"([^"]+)"\s*$') { return $false }
    try {
        $exe = [IO.Path]::GetFullPath($matches[1])
        if ([IO.Path]::GetDirectoryName($exe).TrimEnd('\') -ine $Root -or
            [IO.Path]::GetFileName($exe) -notmatch '^unins\d{3}\.exe$') { return $false }
        $relative = [IO.Path]::GetFileName($exe)
        [void](Test-ArtemisRegularFile $Root $relative)
        [void](Test-ArtemisRegularFile $Root ([IO.Path]::ChangeExtension($relative, '.dat')))
        return $true
    } catch { return $false }
}

function Get-ArtemisInstallCandidates {
    param([object[]]$Registrations = @(), [object[]]$InitialIssues = @())
    $byPath = @{}
    $issues = New-Object 'System.Collections.Generic.List[object]'
    foreach ($issue in $InitialIssues) { $issues.Add($issue) }
    foreach ($record in $Registrations) {
        if ($record.AppId -notin $script:ArtemisKnownAppIds -or
            $record.Hive -notin @('CurrentUser','LocalMachine') -or
            $record.View -notin @('Registry32','Registry64')) { continue }
        try {
            $a = [string]$record.InstallLocation
            $b = [string]$record.AppPath
            if (-not $a -and -not $b) { throw '注册信息中没有安装目录。' }
            $aRoot = if ($a) { Get-ArtemisCanonicalDirectory $a } else { '' }
            $bRoot = if ($b) { Get-ArtemisCanonicalDirectory $b } else { '' }
            if ($aRoot -and $bRoot -and $aRoot -ine $bRoot) { throw '两个安装目录字段不一致。' }
            $product = Get-ArtemisProductInfo $(if ($aRoot) { $aRoot } else { $bRoot })
            if (-not (Test-ArtemisUninstallReference $product.Path ([string]$record.UninstallString))) { throw '卸载记录与安装目录不一致。' }
            $index = $product.Path.ToLowerInvariant()
            if (-not $byPath.ContainsKey($index)) {
                $byPath[$index] = [pscustomobject]@{
                    Path = $product.Path; Version = $product.Version; Registered = $true
                    Registrations = (New-Object 'System.Collections.Generic.List[object]')
                }
            }
            $byPath[$index].Registrations.Add([pscustomobject]@{ Hive = $record.Hive; View = $record.View; AppId = $record.AppId })
        } catch {
            $issues.Add([pscustomobject]@{ Code = 'invalid_registration'; Hive = $record.Hive; View = $record.View; AppId = $record.AppId; Reason = $_.Exception.Message })
        }
    }
    $candidates = @(foreach ($key in @($byPath.Keys | Sort-Object)) {
        $candidate = $byPath[$key]
        $identities = @($candidate.Registrations | ForEach-Object { $_.Hive + '|' + $_.AppId } | Sort-Object -Unique)
        [pscustomobject]@{
            Path = $candidate.Path; Version = $candidate.Version; Registered = $true
            RegistrationAmbiguous = ($identities.Count -ne 1)
            Registrations = @($candidate.Registrations.ToArray())
        }
    })
    # The same logical registry identity pointing at different paths is also
    # ambiguous even when each individual candidate has just one identity.
    $locationsByIdentity = @{}
    foreach ($candidate in $candidates) {
        foreach ($r in $candidate.Registrations) {
            $idKey = ($r.Hive + '|' + $r.AppId).ToLowerInvariant()
            if (-not $locationsByIdentity.ContainsKey($idKey)) { $locationsByIdentity[$idKey] = @{} }
            $locationsByIdentity[$idKey][$candidate.Path.ToLowerInvariant()] = $true
        }
    }
    foreach ($candidate in $candidates) {
        foreach ($r in $candidate.Registrations) {
            $idKey = ($r.Hive + '|' + $r.AppId).ToLowerInvariant()
            if ($locationsByIdentity[$idKey].Count -gt 1) { $candidate.RegistrationAmbiguous = $true }
        }
    }
    return [pscustomobject]@{ Candidates = @($candidates); Issues = @($issues.ToArray()) }
}

function Resolve-ArtemisInstallTarget {
    param(
        [Parameter(Mandatory=$true)]$Discovery,
        [string]$ExplicitPath = '',
        [string]$TargetVersion = ''
    )
    $target = $null
    if ($TargetVersion) {
        if ($TargetVersion -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') { throw '目标版本格式无效。' }
        try { $target = [Version]$TargetVersion } catch { throw '目标版本格式无效。' }
        $target = [Version]::new($target.Major, $target.Minor, $target.Build, [Math]::Max(0, $target.Revision))
    }
    $candidate = $null
    $candidates = @($Discovery.Candidates)
    $issues = @($Discovery.Issues)
    if ($issues.Count -gt 0) { return [pscustomobject]@{ Status = 'registration_uncertain'; Candidate = $null; Reason = '存在无法核验的安装登记。' } }
    if ($ExplicitPath) {
        try { $product = Get-ArtemisProductInfo $ExplicitPath } catch {
            return [pscustomobject]@{ Status = 'invalid_target'; Candidate = $null; Reason = $_.Exception.Message }
        }
        $found = @($candidates | Where-Object { $_.Path -ieq $product.Path })
        if ($found.Count -eq 1) { $candidate = $found[0] }
        elseif ($found.Count -gt 1) { return [pscustomobject]@{ Status = 'registration_ambiguous'; Candidate = $null; Reason = '安装登记冲突。' } }
        else {
            $candidate = [pscustomobject]@{ Path = $product.Path; Version = $product.Version; Registered = $false; RegistrationAmbiguous = $false; Registrations = @() }
        }
    } else {
        if ($candidates.Count -eq 0) { return [pscustomobject]@{ Status = 'not_found'; Candidate = $null; Reason = '' } }
        if ($candidates.Count -gt 1) { return [pscustomobject]@{ Status = 'selection_required'; Candidate = $null; Reason = '发现多个安装，请指定目录。' } }
        $candidate = $candidates[0]
    }
    if ($candidate.RegistrationAmbiguous) { return [pscustomobject]@{ Status = 'registration_ambiguous'; Candidate = $candidate; Reason = '安装目录与卸载登记存在冲突。' } }
    if ($target) {
        $current = [Version]$candidate.Version
        $current = [Version]::new($current.Major, $current.Minor, $current.Build, [Math]::Max(0, $current.Revision))
        if ($current -eq $target) { return [pscustomobject]@{ Status = 'current'; Candidate = $candidate; Reason = '' } }
        if ($current -gt $target) { return [pscustomobject]@{ Status = 'newer'; Candidate = $candidate; Reason = '已安装版本比目标版本新。' } }
    }
    if (-not $candidate.Registered) { return [pscustomobject]@{ Status = 'unregistered'; Candidate = $candidate; Reason = '目录有效，但未发现可信的卸载登记。' } }
    return [pscustomobject]@{ Status = 'selected'; Candidate = $candidate; Reason = '' }
}

Export-ModuleMember -Function Get-ArtemisProductInfo, Get-ArtemisRegistryRegistrations, Get-ArtemisInstallCandidates, Resolve-ArtemisInstallTarget
