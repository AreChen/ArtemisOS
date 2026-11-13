[CmdletBinding()]
param([string]$InstallRoot='E:\ArtemisOS15',[string]$Serial='emulator-5554')
$ErrorActionPreference='Stop'
foreach($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management')){Import-Module (Join-Path $PSHOME ('Modules\'+$module+'\'+$module+'.psd1'))}
$project=Split-Path -Parent $PSScriptRoot
$output=Join-Path $project ('build\secure-display-lifecycle\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($output)
$adb=Join-Path $InstallRoot 'sdk\platform-tools\adb.exe'
$viewer=Join-Path $InstallRoot 'update\frontend\runtime\scrcpy.exe'
$server=Join-Path $project 'build\secure-display-server\scrcpy-server'
function RootServers {
    $lines=& rtk proxy $adb -s $Serial shell 'ps -A -o USER,PID,PPID,ARGS'
    if($LASTEXITCODE -ne 0){throw 'Cannot inspect Android processes.'}
    @($lines|Where-Object{$_ -match '^root\s+\d+\s+\d+\s+app_process\s+.*com\.genymobile\.scrcpy\.(Server|CleanUp)(?:\s|$)'})
}
$baseline=@(RootServers).Count
$originalServer=$env:SCRCPY_SERVER_PATH
try {
    $env:SCRCPY_SERVER_PATH=$server
    foreach($mode in @('reverse','forward')) {
        $marker='ARTEMIS_SECURE_LIFECYCLE_'+[guid]::NewGuid().ToString('N')
        $arguments=@('proxy',('"'+$viewer+'"'),'-s',$Serial,('--window-title='+$marker),'--no-playback','--no-audio','--max-size=720','--max-fps=10','--video-codec=h264','--video-encoder=c2.android.avc.encoder',('--record="'+(Join-Path $output ($mode+'.mkv'))+'"'),'--time-limit=15')
        if($mode -eq 'forward'){$arguments+='--force-adb-forward'}
        $launcher=Start-Process -FilePath ((Get-Command rtk.exe -CommandType Application|Select-Object -First 1).Source) -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $output ($mode+'.log')) -RedirectStandardError (Join-Path $output ($mode+'-stderr.log'))
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        do {
            $client=@(Get-CimInstance Win32_Process -Filter "Name='scrcpy.exe'"|Where-Object{$_.ExecutablePath -eq $viewer -and $_.CommandLine.Contains($marker)})
            $count=@(RootServers).Count
            $ready=(Test-Path -LiteralPath (Join-Path $output ($mode+'.log'))) -and ((Get-Content -LiteralPath (Join-Path $output ($mode+'.log')) -Raw) -match 'Recording started')
            if($client.Count -eq 1 -and $count -gt $baseline -and $ready){break}
            Start-Sleep -Milliseconds 200
        }while([DateTime]::UtcNow -lt $deadline)
        if($client.Count -ne 1 -or $count -le $baseline -or -not $ready){throw "Dedicated server did not finish connecting in $mode mode."}
        # Kill only our uniquely identified test client, never the active frontend viewer.
        Stop-Process -Id $client[0].ProcessId -Force
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        do {$remaining=@(RootServers).Count;if($remaining -le $baseline){break};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $deadline)
        if($remaining -gt $baseline){throw "Privileged server/cleanup process remained after $mode client termination."}
        Write-Host "PASS: $mode client termination leaves no additional privileged server/cleanup process."
    }
    # A forced-forward server with no connecting client used to block accept()
    # forever while its adb shell wrapper remained alive. Exercise that state
    # directly, independently from the timing of the official client startup.
    $remote='/data/local/tmp/artemis-secure-timeout-fixture.jar'
    & rtk proxy $adb -s $Serial push $server $remote
    if($LASTEXITCODE -ne 0){throw 'Cannot deploy handshake timeout fixture.'}
    $command='CLASSPATH='+$remote+' app_process / com.genymobile.scrcpy.Server 4.1 scid=0a11ce01 audio=false tunnel_forward=true cleanup=false'
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $timeoutProcess=Start-Process -FilePath ((Get-Command rtk.exe -CommandType Application|Select-Object -First 1).Source) -ArgumentList @('proxy',('"'+$adb+'"'),'-s',$Serial,'shell',('"'+$command+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $output 'timeout.log') -RedirectStandardError (Join-Path $output 'timeout-stderr.log')
    if(-not $timeoutProcess.WaitForExit(14000)){throw 'Unconnected secure server exceeded its handshake deadline.'}
    $timer.Stop()
    $logs=(Get-Content -LiteralPath (Join-Path $output 'timeout.log') -Raw)+(Get-Content -LiteralPath (Join-Path $output 'timeout-stderr.log') -Raw)
    if($timer.Elapsed.TotalSeconds -lt 9 -or $logs -notmatch 'handshake.*timed out|handshake.*timeout'){throw 'Server exited without exercising the expected handshake timeout.'}
    if(@(RootServers).Count -gt $baseline){throw 'Unconnected server remained after its handshake timeout.'}
    & rtk proxy $adb -s $Serial shell rm $remote
    Write-Host 'PASS: unconnected forward server times out and exits without a privileged process leak.'
}finally{$env:SCRCPY_SERVER_PATH=$originalServer}
Write-Output "Evidence: $output"
