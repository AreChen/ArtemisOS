$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $workspace 'stage\settings.ps1')

$probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port
$probe.Stop()
$ready = Join-Path ([IO.Path]::GetTempPath()) ('artemis-adb-test-' + [Guid]::NewGuid().ToString('N'))
$job = $null
try {
    $job = Start-Job -ArgumentList $port, $ready -ScriptBlock {
        param($Port, $Ready)
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
        try {
            $listener.Start()
            [IO.File]::WriteAllText($Ready, 'ready')
            $connection = $listener.AcceptTcpClient()
            try {
                $stream = $connection.GetStream()
                $request = New-Object byte[] 16
                $offset = 0
                while ($offset -lt $request.Length) {
                    $read = $stream.Read($request, $offset, $request.Length - $offset)
                    if ($read -le 0) { throw 'Incomplete request' }
                    $offset += $read
                }
                if ([Text.Encoding]::ASCII.GetString($request) -ne '000Chost:devices') { throw 'Unexpected request' }
                $payload = "emulator-5554`tdevice`n127.0.0.1:5561`tdevice`nemulator-5584`toffline`nUSB-DEVICE`tdevice`n"
                $data = [Text.Encoding]::UTF8.GetBytes($payload)
                $prefix = [Text.Encoding]::ASCII.GetBytes(('OKAY{0:X4}' -f $data.Length))
                # ADB responses may arrive in multiple TCP packets.
                foreach ($part in @($prefix, $data)) {
                    for ($i = 0; $i -lt $part.Length; $i += 3) {
                        $count = [Math]::Min(3, $part.Length - $i)
                        $stream.Write($part, $i, $count)
                    }
                }
            } finally { $connection.Close() }
        } finally { $listener.Stop() }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path -LiteralPath $ready)) { throw 'Fake ADB server did not start' }
    $ports = @(Get-ArtemisAdbReservedPorts -ServerPort $port | Sort-Object -Unique)
    if (($ports -join ',') -ne '5554,5560,5584') { throw "Unexpected reserved ports: $($ports -join ',')" }
    $null = Wait-Job -Job $job -Timeout 10
    if ($job.State -ne 'Completed') { throw 'Fake ADB server did not complete' }
    Receive-Job -Job $job

    $empty = @(Get-ArtemisAdbReservedPorts -ServerPort $port)
    if ($empty.Count -ne 0) { throw 'An absent ADB server returned reserved ports' }
    Write-Host 'ADB coexistence tests passed.'
} finally {
    if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $ready -Force -ErrorAction SilentlyContinue
}
