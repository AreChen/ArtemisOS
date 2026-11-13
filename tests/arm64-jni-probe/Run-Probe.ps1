param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^emulator-[0-9]+$')]
    [string]$Serial,
    [string]$SdkPath = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$AdbPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$output = Join-Path $projectRoot 'build\arm64-jni-probe'
$classes = Join-Path $output 'classes'
$staging = Join-Path $output 'staging'
$libs = Join-Path $staging 'lib\arm64-v8a'
$android = Join-Path $SdkPath 'platforms\android-35\android.jar'
if (-not $AdbPath) { $AdbPath = Join-Path $SdkPath 'platform-tools\adb.exe' }

$buildTools = Get-ChildItem -LiteralPath (Join-Path $SdkPath 'build-tools') -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
$ndk = Get-ChildItem -LiteralPath (Join-Path $SdkPath 'ndk') -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $buildTools -or -not $ndk -or -not (Test-Path -LiteralPath $android) -or
    -not (Test-Path -LiteralPath $AdbPath)) { throw 'Android SDK, API 35 platform, NDK, build tools, and adb are required.' }
$clang = Join-Path $ndk.FullName 'toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe'
$javac = (Get-Command javac.exe -ErrorAction Stop).Source
$keytool = (Get-Command keytool.exe -ErrorAction Stop).Source
New-Item -ItemType Directory -Force -Path $classes,$libs | Out-Null

function Invoke-Checked([string]$program, [string[]]$programArgs) {
    & rtk proxy $program @programArgs
    if ($LASTEXITCODE -ne 0) { throw "$program failed with exit code $LASTEXITCODE" }
}

$boot = & rtk proxy $AdbPath -s $Serial shell getprop sys.boot_completed
if ($LASTEXITCODE -ne 0 -or ($boot | Out-String).Trim() -ne '1') { throw "Emulator $Serial is not fully booted." }

Invoke-Checked $clang @('--target=aarch64-linux-android23','-O2','-fPIC','-shared',
    (Join-Path $PSScriptRoot 'native.c'),'-o',(Join-Path $libs 'libarmprobe.so'))
Invoke-Checked $javac @('-source','8','-target','8','-classpath',$android,'-d',$classes,
    (Join-Path $PSScriptRoot 'src\internal\artemis\abilab\MainActivity.java'))
Invoke-Checked (Join-Path $buildTools.FullName 'd8.bat') @('--lib',$android,'--min-api','23',
    '--output',$staging,(Join-Path $classes 'internal\artemis\abilab\MainActivity.class'))

$unsigned = Join-Path $output 'unsigned.apk'
$aligned = Join-Path $output 'aligned.apk'
$signed = Join-Path $output 'arm64-probe.apk'
Invoke-Checked (Join-Path $buildTools.FullName 'aapt.exe') @('package','-f','-M',
    (Join-Path $PSScriptRoot 'AndroidManifest.xml'),'-I',$android,'-F',$unsigned)
Push-Location $staging
try { Invoke-Checked (Join-Path $buildTools.FullName 'aapt.exe') @('add',$unsigned,'classes.dex','lib/arm64-v8a/libarmprobe.so') }
finally { Pop-Location }
Invoke-Checked (Join-Path $buildTools.FullName 'zipalign.exe') @('-f','4',$unsigned,$aligned)

$store = Join-Path $output 'test.keystore'
if (-not (Test-Path -LiteralPath $store)) {
    Invoke-Checked $keytool @('-genkeypair','-keystore',$store,'-alias','lab','-storepass','android',
        '-keypass','android','-keyalg','RSA','-validity','3650','-dname','CN=Artemis local test')
}
Invoke-Checked (Join-Path $buildTools.FullName 'apksigner.bat') @('sign','--ks',$store,
    '--ks-key-alias','lab','--ks-pass','pass:android','--key-pass','pass:android','--out',$signed,$aligned)

$token = [guid]::NewGuid().ToString('N')
Invoke-Checked $AdbPath @('-s',$Serial,'install','-r',$signed)
Invoke-Checked $AdbPath @('-s',$Serial,'shell','am','force-stop','internal.artemis.abilab')
Invoke-Checked $AdbPath @('-s',$Serial,'shell','am','start','-W','-n',
    'internal.artemis.abilab/.MainActivity','--es','run_token',$token)
$logs = & rtk proxy $AdbPath -s $Serial logcat -d -s 'ArtemisAbiProbe:I' '*:S'
if ($LASTEXITCODE -ne 0 -or -not ($logs -match "ARM64_JNI_OK:37042:$token")) {
    throw "ARM64 JNI probe failed on $Serial. Inspect the ArtemisAbiProbe log."
}
Write-Output "ARM64 JNI probe passed on $Serial."
