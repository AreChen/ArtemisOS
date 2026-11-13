param([switch]$UseExecutable, [string]$LiveServerFrom = '')
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$newRelease = Join-Path $project 'build\ota-1.0.2-shutdown'
$parent = Join-Path $project 'build\repair-ota-tests'
[void][IO.Directory]::CreateDirectory($parent)
$fixture = Join-Path $parent ([guid]::NewGuid().ToString('N'))
$repository = Join-Path $fixture 'repository'
[void][IO.Directory]::CreateDirectory($repository)
Copy-Item -Path (Join-Path $project 'build\ota-1.0.1-swiftshader\repository\*') -Destination $repository -Recurse
Copy-Item -LiteralPath (Join-Path $newRelease 'repository\manifests\1.0.1.json') -Destination (Join-Path $repository 'manifests\1.0.1.json') -Force
Copy-Item -LiteralPath (Join-Path $newRelease 'repository\manifests\1.0.1.sig') -Destination (Join-Path $repository 'manifests\1.0.1.sig') -Force
Copy-Item -Path (Join-Path $newRelease 'repository\objects\*') -Destination (Join-Path $repository 'objects') -Force
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start(); $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port; $listener.Stop()
$job = Start-Job -ArgumentList $repository,$port -ScriptBlock {
    param($Repository,$Port)
    $server = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    $server.Start()
    while ($true) {
        $client = $server.AcceptTcpClient()
        try {
            $stream=$client.GetStream()
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,1024,$true)
            $line=$reader.ReadLine()
            while ($reader.ReadLine()) { }
            if ($line -match '^GET /__stop HTTP/1\.[01]$') { break }
            if ($line -match '^GET /(objects/[0-9a-f]{64}|manifests/\d+\.\d+\.\d+\.(json|sig)) HTTP/1\.[01]$') {
                $file=Join-Path $Repository ($Matches[1].Replace('/','\'))
                if (Test-Path -LiteralPath $file -PathType Leaf) {
                    $bytes=[IO.File]::ReadAllBytes($file)
                    $header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
                    $stream.Write($header,0,$header.Length); $stream.Write($bytes,0,$bytes.Length)
                } else { $bytes=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"); $stream.Write($bytes,0,$bytes.Length) }
            }
        } finally { $client.Close() }
    }
    $server.Stop()
}
try {
    $ready = $false
    for ($i=0; $i -lt 30; $i++) {
        try { $client=[Net.Sockets.TcpClient]::new(); $client.Connect('127.0.0.1',$port); $client.Close(); $ready=$true; break }
        catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ready) { throw 'Local fixture server did not start.' }
    foreach ($name in @('1.0.0','1.0.0-sd-fixed','1.0.1','modified')) {
        $baseline = if ($name -eq '1.0.0-sd-fixed') { '1.0.0-sd-fixed' } else { '1.0.0' }
        $root = Join-Path $fixture $name
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'sdk\emulator'))
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'data\avd'))
        Copy-Item -LiteralPath (Join-Path $project ('releases\' + $baseline + '\update')) -Destination (Join-Path $root 'update') -Recurse
        foreach ($file in @('settings.ps1','configure.ps1','version.ini')) {
            $source = if ($name -eq '1.0.1') { Join-Path $newRelease ('base\' + $file) } else { Join-Path $project ('releases\' + $baseline + '\' + $file) }
            if ($name -eq '1.0.1' -and $file -ne 'version.ini') { $source=Join-Path $project ('stage\' + $file) }
            Copy-Item -LiteralPath $source -Destination (Join-Path $root $file)
        }
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'data\update'))
        if ($LiveServerFrom) {
            $configured = Join-Path $LiveServerFrom 'data\update\server.txt'
            if (-not (Test-Path -LiteralPath $configured -PathType Leaf)) { $configured=Join-Path $LiveServerFrom 'update\server.txt' }
            Copy-Item -LiteralPath $configured -Destination (Join-Path $root 'data\update\server.txt')
        } else {
            [IO.File]::WriteAllText((Join-Path $root 'data\update\server.txt'), "http://127.0.0.1:$port/", [Text.Encoding]::ASCII)
        }
        [IO.File]::WriteAllText((Join-Path $root 'data\avd\userdata.img'), 'user data preserved', [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText((Join-Path $root 'data\preferences.ini'), "graphics=host`nprofile=high`n", [Text.Encoding]::ASCII)
        if ($name -eq 'modified') { Add-Content -LiteralPath (Join-Path $root 'update\apply.ps1') -Value '# altered' }
        if ($UseExecutable) {
            $exe = Join-Path $project 'build\ArtemisOS15-OTA-Repair-1.0.2.exe'
            $process = Start-Process -FilePath $exe -ArgumentList @('-InstallRoot',('"' + $root + '"'),'-NoUi','-NoRestart') -WindowStyle Hidden -Wait -PassThru
            $result = $process.ExitCode
        } else {
            & rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project 'tools\Repair-Ota.ps1') -InstallRoot $root -NoUi -NoRestart
            $result = $LASTEXITCODE
        }
        if ($name -eq 'modified') {
            if ($result -eq 0 -or (Get-Content -LiteralPath (Join-Path $root 'version.ini') -Raw) -notmatch 'Version=1\.0\.0') { throw 'Modified updater was accepted.' }
        } elseif ($result -ne 0 -or (Get-Content -LiteralPath (Join-Path $root 'version.ini') -Raw) -notmatch 'Version=1\.0\.2') { throw "$name did not update." }
        if ([IO.File]::ReadAllText((Join-Path $root 'data\avd\userdata.img')) -cne 'user data preserved' -or
            [IO.File]::ReadAllText((Join-Path $root 'data\preferences.ini')) -cne "graphics=host`nprofile=high`n") { throw "$name changed user data." }
        Write-Host "PASS: $name recovery and data protection."
    }
} finally {
    try {
        $stopClient=[Net.Sockets.TcpClient]::new();$stopClient.Connect('127.0.0.1',$port)
        $stopStream=$stopClient.GetStream();$stopBytes=[Text.Encoding]::ASCII.GetBytes("GET /__stop HTTP/1.1`r`nHost: 127.0.0.1`r`n`r`n")
        $stopStream.Write($stopBytes,0,$stopBytes.Length);$stopClient.Close()
    } catch { }
    [void](Wait-Job -Job $job -Timeout 5)
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixture) {
        $resolved=(Resolve-Path -LiteralPath $fixture).ProviderPath
        $parentFull=(Resolve-Path -LiteralPath $parent).ProviderPath.TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($parentFull,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
