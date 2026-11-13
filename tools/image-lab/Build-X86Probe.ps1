param(
    [Parameter(Mandatory=$true)][string]$Output,
    [Parameter(Mandatory=$true)][string]$SdkPath,
    [ValidateSet('x86_64','arm64-v8a')][string]$Abi = 'x86_64'
)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $project 'build')).TrimEnd('\')
$destination = [IO.Path]::GetFullPath($Output).TrimEnd('\')
if (-not $destination.StartsWith($buildRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $destination)) {
    throw 'Output must be a new directory under this project build directory.'
}
$probeSource = Join-Path $project 'tests\arm64-jni-probe'
$buildTools = Get-ChildItem -LiteralPath (Join-Path $SdkPath 'build-tools') -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
$ndk = Get-ChildItem -LiteralPath (Join-Path $SdkPath 'ndk') -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
$android = Join-Path $SdkPath 'platforms\android-35\android.jar'
if (-not $buildTools -or -not $ndk -or -not (Test-Path -LiteralPath $android)) { throw 'API 35, NDK and Android build tools are required.' }
$clang = Join-Path $ndk.FullName 'toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe'
$javac = (Get-Command javac.exe -ErrorAction Stop).Source
$keytool = (Get-Command keytool.exe -ErrorAction Stop).Source
$classes = Join-Path $destination 'classes'
$staging = Join-Path $destination 'staging'
$libs = Join-Path $staging ('lib\' + $Abi)
New-Item -ItemType Directory -Path $classes,$libs | Out-Null
function Checked([string]$program, [string[]]$argsList) {
    & rtk proxy $program @argsList
    if ($LASTEXITCODE -ne 0) { throw "$program exited with $LASTEXITCODE" }
}
$clangTarget = if ($Abi -eq 'arm64-v8a') { 'aarch64-linux-android23' } else { 'x86_64-linux-android23' }
Checked $clang @("--target=$clangTarget",'-O2','-fPIC','-shared',(Join-Path $probeSource 'native.c'),'-o',(Join-Path $libs 'libarmprobe.so'))
Checked $javac @('-source','8','-target','8','-classpath',$android,'-d',$classes,(Join-Path $probeSource 'src\internal\artemis\abilab\MainActivity.java'))
Checked (Join-Path $buildTools.FullName 'd8.bat') @('--lib',$android,'--min-api','23','--output',$staging,(Join-Path $classes 'internal\artemis\abilab\MainActivity.class'))
$unsigned = Join-Path $destination 'unsigned.apk'
$aligned = Join-Path $destination 'aligned.apk'
$signed = Join-Path $destination ($Abi + '-probe.apk')
Checked (Join-Path $buildTools.FullName 'aapt.exe') @('package','-M',(Join-Path $probeSource 'AndroidManifest.xml'),'-I',$android,'-F',$unsigned)
Push-Location $staging
try { Checked (Join-Path $buildTools.FullName 'aapt.exe') @('add',$unsigned,'classes.dex',("lib/$Abi/libarmprobe.so")) }
finally { Pop-Location }
Checked (Join-Path $buildTools.FullName 'zipalign.exe') @('4',$unsigned,$aligned)
$store = Join-Path $destination 'test.keystore'
Checked $keytool @('-genkeypair','-keystore',$store,'-alias','lab','-storepass','android','-keypass','android','-keyalg','RSA','-validity','30','-dname',"CN=Artemis local $Abi test")
Checked (Join-Path $buildTools.FullName 'apksigner.bat') @('sign','--ks',$store,'--ks-key-alias','lab','--ks-pass','pass:android','--key-pass','pass:android','--out',$signed,$aligned)
Write-Output $signed
