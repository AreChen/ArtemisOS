param([string]$SourceRoot, [switch]$SkipJava)
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
if(-not $SourceRoot){
 $record=Join-Path $project 'build/secure-display-server/build-record.json'
 if(Test-Path -LiteralPath $record){$SourceRoot=(Get-Content -LiteralPath $record -Raw|ConvertFrom-Json).sourceRoot}
 else{$SourceRoot=Join-Path $project 'build/secure-display-server/source/scrcpy-4.1'}
}
$server=Join-Path $SourceRoot 'server/src/main/java/com/genymobile/scrcpy'
if(-not (Test-Path -LiteralPath $server)){throw 'Extract/build the source first, or specify -SourceRoot.'}
$entry=Get-Content -LiteralPath (Join-Path $server 'Server.java') -Raw
$capture=Get-Content -LiteralPath (Join-Path $server 'video/ScreenCapture.java') -Raw
$manager=Get-Content -LiteralPath (Join-Path $server 'wrappers/DisplayManager.java') -Raw
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw $Message};Write-Output ('PASS '+$Message)}
Assert ($entry -notmatch '(?m)^\s*dropRootPrivileges\(\);') 'Dedicated server must retain root instead of silently dropping to shell.'
Assert ($entry.Contains('ArtemisDisplayPolicy.mustRelaunch')) 'Only the server process relaunches through su, with recursion detection.'
Assert ($entry.Contains('process.waitFor()')) 'The shell wrapper must remain alive until its privileged server exits.'
Assert ($entry.Contains('Os.getppid()')) 'A privileged child must stop after its wrapper disappears.'
Assert ($entry.Contains('private static volatile boolean connectionEstablished;')) 'Handshake completion must be visible to the watchdog thread.'
Assert ($entry -match 'DesktopConnection connection = DesktopConnection\.open\([^;]+;\s*connectionEstablished = true;') 'The handshake is complete only after all DesktopConnection sockets connect.'
Assert ($entry -match '!connectionEstablished\s*&&\s*System\.nanoTime\(\)\s*-\s*watchStarted\s*>=\s*10_000_000_000L') 'A root server without a connected client must stop within a finite 10-second handshake window.'
Assert ($entry.Contains('Ln.e("Artemis secure display client handshake timed out (10s); stopping privileged server")')) 'A handshake timeout must have an explicit error even after standard streams are disabled.'
Assert (-not $entry.Contains('return; // An explicitly root-started server has no wrapper to watch.')) 'An already-root server must also enforce the handshake deadline.'
Assert ($entry.Contains('final int parent = hasWrapper ? Integer.parseInt(System.getenv("ARTEMIS_SECURE_DISPLAY_PARENT")) : -1;')) 'An already-root server needs no synthetic wrapper PID.'
Assert ($entry.Contains('if (parent > 1 && Os.getppid() != parent)')) 'Parent exit monitoring only applies when a real wrapper exists.'
Assert ($capture.Contains('ArtemisDisplayPolicy.requireRoot')) 'Secure mirror fails explicitly without root.'
Assert ($manager.Contains('ArtemisDisplayPolicy.mirrorFlags()')) 'The normal DisplayManager path must request a secure mirror.'
Assert ($capture.Contains('SurfaceControl.createDisplay("scrcpy", true)')) 'Fallback cannot silently become an insecure display.'
if(-not $SkipJava){
 $classes=Join-Path $project 'build/secure-display-server/policy-tests'
 [void][IO.Directory]::CreateDirectory($classes)
 & rtk proxy javac -encoding UTF-8 -d $classes (Join-Path $server 'ArtemisDisplayPolicy.java') (Join-Path $project 'third-party/artemis-scrcpy-display/tests/ArtemisDisplayPolicyTest.java')
 if($LASTEXITCODE){throw 'Policy test compilation failed.'}
 & rtk proxy java -cp $classes com.genymobile.scrcpy.ArtemisDisplayPolicyTest
 if($LASTEXITCODE){throw 'Policy tests failed.'}
}
