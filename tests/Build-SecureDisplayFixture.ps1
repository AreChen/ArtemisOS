[CmdletBinding()]
param([string]$Sdk = "$env:LOCALAPPDATA\Android\Sdk")
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$output = Join-Path $project 'build\secure-display-fixture'
$source = Join-Path $PSScriptRoot 'fixtures\secure-display'
$platform = Join-Path $Sdk 'platforms\android-36\android.jar'
$tools = Join-Path $Sdk 'build-tools\36.0.0'
$classes = Join-Path $output 'classes'
$dex = Join-Path $output 'dex'
foreach ($directory in @($output,$classes,$dex)) { [void][IO.Directory]::CreateDirectory($directory) }
function Invoke-FixtureTool([string]$Exe,[string[]]$Arguments) {
    & rtk proxy $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Fixture tool failed: $Exe ($LASTEXITCODE)" }
}
Invoke-FixtureTool 'javac.exe' @('-encoding','UTF-8','-source','8','-target','8','-classpath',$platform,'-d',$classes,(Join-Path $source 'MainActivity.java'))
$jar = Join-Path $output 'fixture.jar'
Invoke-FixtureTool 'jar.exe' @('cf',$jar,'-C',$classes,'.')
Invoke-FixtureTool (Join-Path $tools 'd8.bat') @('--lib',$platform,'--min-api','23','--output',$dex,$jar)
$unsigned = Join-Path $output 'unsigned.apk'
Invoke-FixtureTool (Join-Path $tools 'aapt2.exe') @('link','-I',$platform,'--manifest',(Join-Path $source 'AndroidManifest.xml'),'-o',$unsigned)
Invoke-FixtureTool 'jar.exe' @('uf',$unsigned,'-C',$dex,'classes.dex')
$aligned = Join-Path $output 'aligned.apk'
Invoke-FixtureTool (Join-Path $tools 'zipalign.exe') @('-f','4',$unsigned,$aligned)
$key = Join-Path $output 'fixture-debug.jks'
if (-not (Test-Path -LiteralPath $key)) {
    Invoke-FixtureTool 'keytool.exe' @('-genkeypair','-keystore',$key,'-storepass','android','-keypass','android','-alias','fixture','-dname','CN=Artemis Test Only','-keyalg','RSA','-validity','3650','-noprompt')
}
$apk = Join-Path $output 'secure-display-fixture.apk'
Invoke-FixtureTool (Join-Path $tools 'apksigner.bat') @('sign','--ks',$key,'--ks-key-alias','fixture','--ks-pass','pass:android','--key-pass','pass:android','--out',$apk,$aligned)
Invoke-FixtureTool (Join-Path $tools 'apksigner.bat') @('verify',$apk)
Get-Item -LiteralPath $apk | Select-Object FullName,Length
