$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root = Join-Path $project ('build\benchmark-monitor-selftest-' + [guid]::NewGuid().ToString('N'))
$testRoot = Join-Path $root 'isolated-test'
$exeDir = Join-Path $root 'sdk\emulator\qemu\windows-x86_64'
$decoyDir = Join-Path $root 'decoy'
foreach ($dir in @($exeDir,$decoyDir,(Join-Path $testRoot 'sysdir'))) { [void][IO.Directory]::CreateDirectory($dir) }
$exe = Join-Path $exeDir 'qemu-system-x86_64-headless.exe'
$decoy = Join-Path $decoyDir 'qemu-system-x86_64-headless.exe'
$source = @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
public static class BenchSyntheticQemu {
    public static void Main(string[] args) {
        var bytes = new byte[4 * 1024 * 1024];
        bytes[0] = 1;
        TcpListener listener = null;
        if (Array.IndexOf(args, "-decoy") < 0) {
            int i = Array.IndexOf(args, "-port");
            listener = new TcpListener(IPAddress.Loopback, int.Parse(args[i+1]));
            listener.Start();
        }
        Thread.Sleep(20000);
        if (listener != null) listener.Stop();
        GC.KeepAlive(bytes);
    }
}
'@
Add-Type -TypeDefinition $source -OutputAssembly $exe -OutputType ConsoleApplication
Copy-Item -LiteralPath $exe -Destination $decoy
$runner = (Get-Command rtk -CommandType Application).Source
$sysdir = Join-Path $testRoot 'sysdir'
$port = 0
for ($candidate=5678; $candidate -ge 5660; $candidate-=2) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $candidate)
    try { $listener.Start(); $port = $candidate; break } catch { } finally { $listener.Stop() }
}
if (-not $port) { throw 'No free synthetic test port.' }
$job = Start-Job -ArgumentList $runner,$exe,$decoy,$sysdir,$testRoot,$port -ScriptBlock {
    param($runner,$exe,$decoy,$sysdir,$testRoot,$port)
    $decoyArgs = @('proxy',('"'+$decoy+'"'),'-avd','ArtemisBenchSynthetic','-sysdir',('"'+$sysdir+'"'),'-port',[string]$port,'-decoy')
    $decoyProcess = Start-Process -FilePath $runner -ArgumentList $decoyArgs -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    & $runner proxy $exe -avd ArtemisBenchSynthetic -sysdir $sysdir -port $port
    if ($LASTEXITCODE -ne 0) { throw 'First synthetic process failed.' }
    Start-Sleep -Seconds 2
    & $runner proxy $exe -avd ArtemisBenchSynthetic -sysdir $sysdir -port $port
    if ($LASTEXITCODE -ne 0) { throw 'Second synthetic process failed.' }
    [IO.File]::WriteAllText((Join-Path $testRoot 'test-results.json'), '{"accepted":true}')
    if (-not $decoyProcess.HasExited) { Wait-Process -Id $decoyProcess.Id -Timeout 15 -ErrorAction SilentlyContinue }
}
$measurement = Join-Path $root 'metrics.json'
$monitor = Join-Path $project 'tools\benchmark-lab\Monitor-IsolatedQemu.ps1'
try {
    & rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File $monitor -TestRoot $testRoot -QemuExecutable $exe `
        -AvdName ArtemisBenchSynthetic -Port $port -Output $measurement -IntervalSeconds 1 -WaitSeconds 25 -DurationSeconds 90
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic monitor run failed.' }
    $metrics = Get-Content -LiteralPath $measurement -Raw | ConvertFrom-Json
    if ($metrics.error -or @($metrics.sessions).Count -ne 2 -or @($metrics.samples).Count -lt 2) { throw 'Unexpected synthetic monitoring result.' }
    if ($metrics.qemu_executable -ne $exe -or -not $metrics.complete) { throw 'Synthetic run included the decoy or did not complete.' }
    if (@($metrics.sessions | Select-Object -ExpandProperty pid -Unique).Count -ne 2) { throw 'The two synthetic processes were not recorded separately.' }
    if (@($metrics.samples | Where-Object { $_.private_bytes -le 0 -or $_.working_set_bytes -le 0 }).Count) { throw 'Synthetic process memory readings are missing.' }
    if (@($metrics.samples | Where-Object { $_.pid -ne $_.console_port_owner_pid }).Count) { throw 'Synthetic console ownership does not match the selected process.' }
    Write-Output "PASS: sampled two isolated synthetic sessions, verified port ownership, and ignored the decoy; output: $measurement"
} finally {
    if ($job.State -eq 'Running') { Wait-Job -Job $job -Timeout 50 | Out-Null }
    Receive-Job -Job $job -ErrorAction Continue
}
