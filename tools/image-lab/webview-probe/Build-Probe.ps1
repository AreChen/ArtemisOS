param(
    [Parameter(Mandatory=$true)][string]$Output,
    [Parameter(Mandatory=$true)][string]$SdkPath
)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $project 'build')).TrimEnd('\')
$destination = [IO.Path]::GetFullPath($Output).TrimEnd('\')
if (-not $destination.StartsWith($buildRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $destination)) {
    throw 'Output must be a new directory under this project build directory.'
}
$buildTools = Get-ChildItem -LiteralPath (Join-Path $SdkPath 'build-tools') -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
$android = Join-Path $SdkPath 'platforms\android-35\android.jar'
if (-not $buildTools -or -not (Test-Path -LiteralPath $android)) { throw 'API 35 and Android build tools are required.' }
$javac = (Get-Command javac.exe -ErrorAction Stop).Source
$keytool = (Get-Command keytool.exe -ErrorAction Stop).Source
$classes = Join-Path $destination 'classes'
$staging = Join-Path $destination 'staging'
New-Item -ItemType Directory -Path $classes,$staging | Out-Null
function Checked([string]$program, [string[]]$argsList) {
    & rtk proxy $program @argsList
    if ($LASTEXITCODE -ne 0) { throw "$program exited with $LASTEXITCODE" }
}
Checked $javac @('-source','8','-target','8','-classpath',$android,'-d',$classes,(Join-Path $PSScriptRoot 'MainActivity.java'))
$classFiles = @(Get-ChildItem -LiteralPath $classes -Filter '*.class' -Recurse | ForEach-Object FullName)
if ($classFiles.Count -lt 1) { throw 'No compiled class files.' }
Checked (Join-Path $buildTools.FullName 'd8.bat') (@('--lib',$android,'--min-api','23','--output',$staging) + $classFiles)
$unsigned = Join-Path $destination 'unsigned.apk'
$aligned = Join-Path $destination 'aligned.apk'
$signed = Join-Path $destination 'webview-probe.apk'
Checked (Join-Path $buildTools.FullName 'aapt.exe') @('package','-M',(Join-Path $PSScriptRoot 'AndroidManifest.xml'),'-I',$android,'-F',$unsigned)
Push-Location $staging
try { Checked (Join-Path $buildTools.FullName 'aapt.exe') @('add',$unsigned,'classes.dex') }
finally { Pop-Location }
Checked (Join-Path $buildTools.FullName 'zipalign.exe') @('4',$unsigned,$aligned)
$store = Join-Path $destination 'test.keystore'
Checked $keytool @('-genkeypair','-keystore',$store,'-alias','lab','-storepass','android','-keypass','android','-keyalg','RSA','-validity','30','-dname','CN=Artemis local WebView test')
Checked (Join-Path $buildTools.FullName 'apksigner.bat') @('sign','--ks',$store,'--ks-key-alias','lab','--ks-pass','pass:android','--key-pass','pass:android','--out',$signed,$aligned)
Write-Output $signed
