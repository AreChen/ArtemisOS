$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
foreach ($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management')) {
    Import-Module (Join-Path $PSHOME ('Modules\'+$module+'\'+$module+'.psd1')) -ErrorAction Stop
}
$project = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $project ('build\secure-runtime-tests\' + [guid]::NewGuid().ToString('N'))
try {
    & (Join-Path $project 'tools\Prepare-FrontendRuntime.ps1') -TargetRoot $fixture
    $notices = Join-Path $fixture 'update\frontend\third-party'
    $metadata = Join-Path $notices 'artemis-display\manifest.json'
    if (-not (Test-Path -LiteralPath $metadata)) { throw 'Missing the provenance for the dedicated secure display server.' }
    $record = Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json
    $server = Join-Path $fixture 'update\frontend\runtime\scrcpy-server'
    if ((Get-FileHash -LiteralPath $server).Hash.ToLowerInvariant() -cne $record.serverSha256) { throw 'The packaged server does not match its dedicated build record.' }
    $upstream = Get-Content -LiteralPath (Join-Path $notices 'sources.json') -Raw | ConvertFrom-Json
    $officialServer = @($upstream.binaryFiles | Where-Object file -ceq 'scrcpy-server')[0]
    if ($record.serverSha256 -ceq $officialServer.sha256) { throw 'The runtime preparation silently retained the nonsecure upstream server.' }
    foreach ($file in $upstream.binaryFiles) {
        if ($file.file -ceq 'scrcpy-server' -or -not (Test-Path -LiteralPath (Join-Path $fixture ('update\frontend\runtime\' + $file.file)))) { continue }
        if ((Get-FileHash -LiteralPath (Join-Path $fixture ('update\frontend\runtime\' + $file.file))).Hash.ToLowerInvariant() -cne $file.sha256) { throw ('Unexpected change to the upstream runtime: ' + $file.file) }
    }
    foreach ($name in @('README.md','LICENSE','Build-SecureDisplayServer.ps1','secure-display-server.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $notices ('artemis-display\' + $name)))) { throw ('Missing derived-server source/build notice: ' + $name) }
    }
    Write-Host 'PASS: dedicated secure server, provenance, rebuild instructions and unchanged upstream host runtime.'
} finally {
    $absolute = [IO.Path]::GetFullPath($fixture)
    $allowed = [IO.Path]::GetFullPath((Join-Path $project 'build\secure-runtime-tests')) + '\'
    if (-not $absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $absolute) { Remove-Item -LiteralPath $absolute -Recurse -Force }
}
