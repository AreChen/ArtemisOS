param(
 [string]$AndroidSdk=(Join-Path $env:LOCALAPPDATA 'Android/Sdk'),
 [string]$OutputDirectory,
 [string]$JavaHome=$env:JAVA_HOME
)
$ErrorActionPreference='Stop'
foreach($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management')){
 Import-Module (Join-Path $PSHOME ('Modules/'+$module+'/'+$module+'.psd1')) -ErrorAction Stop
}
$project=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $project 'build/secure-display-server'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$upstream=Join-Path $project 'third-party/scrcpy-4.1/source-archives/scrcpy-4.1.tar.gz'
$custom=Join-Path $project 'third-party/artemis-scrcpy-display'
$expected='537b2ade623cb94b6edddfa5c61bf0b0af21484aa8365ea2531b686ea573249a'
if((Get-FileHash -LiteralPath $upstream -Algorithm SHA256).Hash -ne $expected){throw 'Pinned official scrcpy 4.1 source archive hash mismatch.'}
$androidJar=Join-Path $AndroidSdk 'platforms/android-36/android.jar'
$frameworkAidl=Join-Path $AndroidSdk 'platforms/android-36/framework.aidl'
$buildTools=Join-Path $AndroidSdk 'build-tools/36.0.0'
$aidl=Join-Path $buildTools 'aidl.exe'
$d8=Join-Path $buildTools 'd8.bat'
$lambda=Join-Path $buildTools 'core-lambda-stubs.jar'
foreach($file in @($androidJar,$frameworkAidl,$aidl,$d8,$lambda)){if(-not (Test-Path -LiteralPath $file -PathType Leaf)){throw "Required Android SDK 36 file missing: $file"}}
if($JavaHome){$javac=Join-Path $JavaHome 'bin/javac.exe';$java=Join-Path $JavaHome 'bin/java.exe'}else{$javac=(Get-Command javac.exe -ErrorAction Stop).Source;$java=(Get-Command java.exe -ErrorAction Stop).Source}
if(-not (Test-Path -LiteralPath $javac)){throw 'JDK javac is required.'}
# Every run starts in a unique workspace. No recursive deletion or mutation of SDK/upstream sources.
$work=Join-Path $OutputDirectory ('work-'+[Guid]::NewGuid().ToString('N'))
$source=Join-Path $work 'scrcpy-4.1'
$classes=Join-Path $work 'classes'
$gen=Join-Path $work 'gen'
foreach($dir in @($work,$classes,(Join-Path $gen 'com/genymobile/scrcpy'))){[void][IO.Directory]::CreateDirectory($dir)}
function Invoke-Native([string]$Program,[string[]]$Arguments){
 & rtk proxy $Program @Arguments
 if($LASTEXITCODE -ne 0){throw "Native command failed ($LASTEXITCODE): $Program"}
}
Invoke-Native 'tar' @('-xf',$upstream,'-C',$work)
$patch=Join-Path $custom 'secure-display.patch'
# A fresh independent repository prevents git apply from inheriting a parent
# repository prefix and silently skipping files when this source bundle is
# extracted inside another checkout. No index/add/commit is used.
Invoke-Native 'git' @('-C',$source,'init','--quiet')
Invoke-Native 'git' @('-C',$source,'apply','--check',$patch)
Invoke-Native 'git' @('-C',$source,'apply',$patch)
$javaSource=Join-Path $source 'server/src/main/java'
Copy-Item -LiteralPath (Join-Path $custom 'src/ArtemisDisplayPolicy.java') -Destination (Join-Path $javaSource 'com/genymobile/scrcpy/ArtemisDisplayPolicy.java')
# Fail before AIDL/javac/D8 if a source patch was skipped or malformed. The full
# Java policy check is also run after compilation below.
& (Join-Path $project 'tests/secure-display-server.ps1') -SourceRoot $source -SkipJava
if(-not $?){throw 'Secure display pre-compilation source checks failed.'}
[IO.File]::WriteAllText((Join-Path $gen 'com/genymobile/scrcpy/BuildConfig.java'),@'
package com.genymobile.scrcpy;
public final class BuildConfig {
 public static final boolean DEBUG = false;
 public static final String VERSION_NAME = "4.1";
}
'@,[Text.UTF8Encoding]::new($false))
$aidlSource=Join-Path $source 'server/src/main/aidl'
Push-Location -LiteralPath $aidlSource
try {
 Invoke-Native $aidl @(('-o'+$gen),('-I'+$aidlSource),(Join-Path $aidlSource 'android/content/IOnPrimaryClipChangedListener.aidl'))
 Invoke-Native $aidl @(('-o'+$gen),('-I'+$aidlSource),'-p',$frameworkAidl,(Join-Path $aidlSource 'android/view/IDisplayWindowListener.aidl'))
}finally{Pop-Location}
# This follows upstream server/build_without_gradle.sh: hidden-type fake sources + generated AIDL.
$sources=@(Get-ChildItem -LiteralPath $javaSource -Recurse -Filter '*.java' | ForEach-Object FullName)
$sources+=@(Get-ChildItem -LiteralPath $gen -Recurse -Filter '*.java' | ForEach-Object FullName)
$javacArgs=Join-Path $work 'javac.args'
[IO.File]::WriteAllLines($javacArgs,@($sources|ForEach-Object {'"'+$_.Replace('\','/')+'"'}),[Text.UTF8Encoding]::new($false))
Invoke-Native $javac @('-encoding','UTF-8','-bootclasspath',$androidJar,'-classpath',($lambda+';'+$gen),'-d',$classes,'-source','1.8','-target','1.8',('@'+$javacArgs))
# D8's response-file parser does not unquote paths like javac does. One input jar also supports spaces.
$classJar=Join-Path $work 'classes.jar'
$jar=Join-Path (Split-Path -Parent $javac) 'jar.exe'
Invoke-Native $jar @('--create','--file',$classJar,'-C',$classes,'.')
$dexOutput=Join-Path $work 'classes.zip'
Invoke-Native $d8 @('--classpath',$androidJar,'--min-api','21','--output',$dexOutput,$classJar)
& (Join-Path $project 'tests/secure-display-server.ps1') -SourceRoot $source
if(-not $?){throw 'Secure display regression tests failed.'}
$artifact=Join-Path $OutputDirectory 'scrcpy-server'
Copy-Item -LiteralPath $dexOutput -Destination $artifact -Force
$javaVersion=(& rtk proxy $java --version | Out-String).Trim()
if($LASTEXITCODE -ne 0){throw 'Cannot determine the JDK version.'}
$record=[ordered]@{
 variant='ArtemisOS-local-secure-display';protocolVersion='4.1';upstreamTag='v4.1';
 upstreamSha256=$expected;patchSha256=(Get-FileHash $patch).Hash.ToLowerInvariant();
 policySha256=(Get-FileHash (Join-Path $custom 'src/ArtemisDisplayPolicy.java')).Hash.ToLowerInvariant();
 artifactSha256=(Get-FileHash $artifact).Hash.ToLowerInvariant();artifactBytes=(Get-Item $artifact).Length;
 androidPlatform=36;buildTools='36.0.0';java=$javaVersion;sourceRoot=$source;
 builtAtUtc=[DateTime]::UtcNow.ToString('o');deviceValidation='Not performed by this build';
}
$record|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $OutputDirectory 'build-record.json') -Encoding UTF8
$manifest=[ordered]@{variant=$record.variant;revision='artemis-secure-display-r2';serverSha256=$record.artifactSha256;upstreamArchiveSha256=$expected;protocolVersion='4.1';patchSha256=$record.patchSha256;policySha256=$record.policySha256;buildScriptSha256=(Get-FileHash $PSCommandPath).Hash.ToLowerInvariant()}
$manifest|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutputDirectory 'manifest.json') -Encoding UTF8
Write-Output "Built dedicated server: $artifact"
Write-Output "SHA256: $($record.artifactSha256)"
