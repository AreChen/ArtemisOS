# NexusLauncher uses Launcher3's pref_allowRotation; migrate it once, not per boot.
function ConvertTo-ArtemisLauncherRotationXml([string]$Xml) {
    if ([string]::IsNullOrWhiteSpace($Xml) -or $Xml.Length -gt 1MB) { throw 'Launcher preferences are empty or too large.' }
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $inputText = New-Object IO.StringReader($Xml)
    $reader = [Xml.XmlReader]::Create($inputText, $settings)
    $document = New-Object Xml.XmlDocument
    $document.PreserveWhitespace = $true
    $document.XmlResolver = $null
    try { $document.Load($reader) } finally { $reader.Dispose(); $inputText.Dispose() }
    if ($null -eq $document.DocumentElement -or $document.DocumentElement.LocalName -cne 'map' -or $document.DocumentElement.NamespaceURI) {
        throw 'Launcher preferences must contain an Android SharedPreferences map.'
    }
    $entries = @($document.DocumentElement.SelectNodes("./*[@name='pref_allowRotation']"))
    if ($entries.Count -gt 1) { throw 'Launcher rotation preference is duplicated.' }
    if ($entries.Count -eq 1) {
        $entry = $entries[0]
        if ($entry.LocalName -cne 'boolean' -or $entry.NamespaceURI -or $entry.GetAttribute('value') -cnotin @('true','false')) {
            throw 'Launcher rotation preference is not a valid boolean.'
        }
        if ($entry.GetAttribute('value') -ceq 'true') { return [pscustomobject]@{Changed=$false;Xml=$Xml} }
    } else {
        $entry = $document.CreateElement('boolean')
        $entry.SetAttribute('name', 'pref_allowRotation')
        [void]$document.DocumentElement.AppendChild($entry)
    }
    $entry.SetAttribute('value', 'true')
    return [pscustomobject]@{Changed=$true;Xml=$document.OuterXml}
}

function Initialize-ArtemisLauncherRotation {
    param(
        [ValidateRange(1,5)][int]$Attempts = 3,
        [ValidateRange(0,2000)][int]$RetryDelayMilliseconds = 1000
    )
    $local = ''; $remote = ''
    try {
        $state = Read-ArtemisKeyValues $script:ArtemisStatePath
        if ($state['launcher_rotation'] -eq '1') { return }
        if ((Invoke-Device @('shell','getprop','ro.boot.qemu')) -ne '1' -or
            (Invoke-Device @('shell','getprop','ro.debuggable')) -ne '1' -or
            (Invoke-Device @('shell','getprop','ro.build.type')) -ne 'userdebug') {
            Write-InitializeLog 'Launcher rotation migration skipped: requires the supported qemu userdebug image.'
            return
        }
        if ((Invoke-Device @('shell','am','get-current-user')) -ne '0') {
            Write-InitializeLog 'Launcher rotation migration skipped: the active Android user is not user 0.'
            return
        }
        $homeActivity = Invoke-Device @('shell','cmd','package','resolve-activity','--brief','--user','0','-a','android.intent.action.MAIN','-c','android.intent.category.HOME')
        if ($homeActivity -cnotmatch '(?m)^com\.google\.android\.apps\.nexuslauncher/[^\s]+\s*$') {
            Write-InitializeLog 'Launcher rotation migration skipped: NexusLauncher is not the current HOME.'
            return
        }
        if ((Invoke-Device @('shell','su','0','id','-u')) -ne '0') {
            Write-InitializeLog 'Launcher rotation migration skipped: root is unavailable.'
            return
        }
        $preferences = '/data/user/0/com.google.android.apps.nexuslauncher/shared_prefs/com.android.launcher3.prefs.xml'
        $original = ''
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            try {
                $original = Invoke-Device @('shell','su','0','cat',$preferences)
                if (-not [string]::IsNullOrWhiteSpace($original)) { break }
            } catch { }
            if ($attempt -lt $Attempts -and $RetryDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $RetryDelayMilliseconds }
        }
        if ([string]::IsNullOrWhiteSpace($original)) {
            Write-InitializeLog 'Launcher preferences are not ready; rotation migration will retry on a later startup.'
            return
        }
        $converted = ConvertTo-ArtemisLauncherRotationXml $original
        if (-not $converted.Changed) {
            Set-ArtemisState 'launcher_rotation' '1'
            Write-InitializeLog 'Launcher rotation is already enabled; no restart was needed.'
            return
        }
        $token = [Guid]::NewGuid().ToString('N')
        $local = Join-Path ([IO.Path]::GetTempPath()) ('artemisos-launcher-rotation-' + $token + '.xml')
        $bytes = [Text.Encoding]::UTF8.GetBytes($converted.Xml)
        $stream = [IO.File]::Open($local, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        $backup = $preferences + '.artemisos-rotation-' + $token + '.bak'
        [void](Invoke-Device @('shell','su','0','cp','-p',$preferences,$backup))
        $remote = '/data/local/tmp/artemisos-launcher-rotation-' + $token + '.xml'
        [void](Invoke-Device @('push',$local,$remote))
        # cp into the existing inode: do not unlink, chmod, chown or relabel it.
        [void](Invoke-Device @('shell','su','0','cp',$remote,$preferences))
        $verified = ConvertTo-ArtemisLauncherRotationXml (Invoke-Device @('shell','su','0','cat',$preferences))
        if ($verified.Changed) { throw 'Launcher rotation preference did not persist after its in-place copy.' }
        [void](Invoke-Device @('shell','am','force-stop','com.google.android.apps.nexuslauncher'))
        $started = Invoke-Device @('shell','am','start','-a','android.intent.action.MAIN','-c','android.intent.category.HOME')
        if ($started -match '(?m)^Error:') { throw 'The launcher HOME activity could not restart.' }
        $verified = ConvertTo-ArtemisLauncherRotationXml (Invoke-Device @('shell','su','0','cat',$preferences))
        if ($verified.Changed) { throw 'Launcher rotation preference did not survive the HOME restart.' }
        Set-ArtemisState 'launcher_rotation' '1'
        Write-InitializeLog ('Launcher rotation enabled once; original preferences preserved at ' + $backup + '.')
    } catch {
        Write-InitializeLog ('Launcher rotation migration deferred; startup can continue: ' + $_.Exception.Message)
    } finally {
        if ($remote) {
            try { [void](Invoke-Device @('shell','su','0','rm','-f',$remote)) }
            catch { Write-InitializeLog ('Could not remove the migration temporary XML: ' + $_.Exception.Message) }
        }
        if ($local -and [IO.File]::Exists($local)) { [IO.File]::Delete($local) }
    }
}
