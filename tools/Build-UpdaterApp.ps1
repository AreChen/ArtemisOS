param(
    [string]$AndroidSdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$KeyDirectory = (Join-Path $env:LOCALAPPDATA 'ArtemisOS-Dev\signing')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$project = Split-Path -Parent $PSScriptRoot
$app = Join-Path $project 'android\updater'
$build = Join-Path $app 'build'
$tools = Join-Path $AndroidSdk 'build-tools\35.0.0'
$androidJar = Join-Path $AndroidSdk 'platforms\android-35\android.jar'
$aapt = Join-Path $tools 'aapt.exe'
$d8 = Join-Path $tools 'd8.bat'
$zipalign = Join-Path $tools 'zipalign.exe'
$apksigner = Join-Path $tools 'apksigner.bat'
$keystore = Join-Path $KeyDirectory 'android-updater.p12'
$passwordFile = Join-Path $KeyDirectory 'apk-password.dpapi'
foreach ($file in @($aapt, $d8, $zipalign, $apksigner, $androidJar, $keystore, $passwordFile)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "缺少构建依赖：$file" }
}
foreach ($dir in @($build, (Join-Path $build 'classes'), (Join-Path $build 'dex'))) {
    [void][IO.Directory]::CreateDirectory($dir)
}
$unsigned = Join-Path $build 'unsigned.apk'
$aligned = Join-Path $build 'aligned.apk'
$output = Join-Path $project 'stage\update\ArtemisUpdate.apk'
$classes = Join-Path $build 'classes'
$dex = Join-Path $build 'dex'
$javaFiles = @(Get-ChildItem -LiteralPath (Join-Path $app 'src') -Filter '*.java' -File -Recurse | ForEach-Object { $_.FullName })
if ($javaFiles.Count -eq 0) { throw '未找到更新应用源码。' }
& $aapt package -f -M (Join-Path $app 'AndroidManifest.xml') -S (Join-Path $app 'res') -I $androidJar -F $unsigned
if ($LASTEXITCODE -ne 0) { throw 'Android 资源打包失败。' }
& javac.exe --release 8 -encoding UTF-8 -classpath $androidJar -d $classes @javaFiles
if ($LASTEXITCODE -ne 0) { throw 'Android 更新应用编译失败。' }
$classFiles = @(Get-ChildItem -LiteralPath $classes -Filter '*.class' -File -Recurse | ForEach-Object { $_.FullName })
& $d8 --min-api 26 --lib $androidJar --output $dex @classFiles
if ($LASTEXITCODE -ne 0) { throw 'DEX 编译失败。' }
Push-Location $dex
try {
    & $aapt add $unsigned classes.dex
    if ($LASTEXITCODE -ne 0) { throw '无法写入 classes.dex。' }
} finally { Pop-Location }
& $zipalign -f 4 $unsigned $aligned
if ($LASTEXITCODE -ne 0) { throw 'APK 对齐失败。' }
$protectedPassword = [IO.File]::ReadAllBytes($passwordFile)
$plainPassword = [Security.Cryptography.ProtectedData]::Unprotect($protectedPassword, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
$env:ARTEMISOS_APK_SIGNING_PASSWORD = [Text.Encoding]::UTF8.GetString($plainPassword)
try {
    & $apksigner sign --v4-signing-enabled false --ks $keystore --ks-key-alias artemisos-updater --ks-pass env:ARTEMISOS_APK_SIGNING_PASSWORD --key-pass env:ARTEMISOS_APK_SIGNING_PASSWORD --out $output $aligned
    if ($LASTEXITCODE -ne 0) { throw 'APK 签名失败。' }
    & $apksigner verify $output
    if ($LASTEXITCODE -ne 0) { throw 'APK 签名验证失败。' }
} finally { Remove-Item Env:ARTEMISOS_APK_SIGNING_PASSWORD -ErrorAction SilentlyContinue }
Write-Host "已构建更新应用：$output"
