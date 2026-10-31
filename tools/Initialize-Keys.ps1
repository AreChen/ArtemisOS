param(
    [string]$KeyDirectory = (Join-Path $env:LOCALAPPDATA 'ArtemisOS-Dev\signing')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$projectRoot = Split-Path -Parent $PSScriptRoot
$publicPath = Join-Path $projectRoot 'stage\update\trusted-key.xml'
$privatePath = Join-Path $KeyDirectory 'ota-private.dpapi'
$passwordPath = Join-Path $KeyDirectory 'apk-password.dpapi'
$keystorePath = Join-Path $KeyDirectory 'android-updater.p12'
[void][IO.Directory]::CreateDirectory($KeyDirectory)
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $publicPath))

if (Test-Path -LiteralPath $privatePath) {
    $protected = [IO.File]::ReadAllBytes($privatePath)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.PersistKeyInCsp = $false
    $rsa.FromXmlString([Text.Encoding]::UTF8.GetString($bytes))
} else {
    if (Test-Path -LiteralPath $publicPath) { throw '已有 OTA 公钥但找不到私钥；请恢复原签名密钥，不能生成新密钥覆盖。' }
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(3072)
    $rsa.PersistKeyInCsp = $false
    $bytes = [Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))
    $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes($privatePath, $protected)
}
try {
    $public = $rsa.ToXmlString($false)
    if ((Test-Path -LiteralPath $publicPath) -and ([IO.File]::ReadAllText($publicPath).Trim() -ne $public)) {
        throw '当前私钥与仓库中的 OTA 公钥不匹配。'
    }
    [IO.File]::WriteAllText($publicPath, $public, (New-Object Text.UTF8Encoding($false)))
} finally { $rsa.Dispose() }

if ((Test-Path -LiteralPath $passwordPath) -xor (Test-Path -LiteralPath $keystorePath)) {
    throw 'Android 应用签名密钥或密码缺失，请恢复原密钥。'
}
if (-not (Test-Path -LiteralPath $keystorePath)) {
    $random = New-Object byte[] 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($random) } finally { $generator.Dispose() }
    $password = [Convert]::ToBase64String($random).Replace('+', 'a').Replace('/', 'b').TrimEnd('=')
    $protectedPassword = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($password), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes($passwordPath, $protectedPassword)
    $env:ARTEMISOS_APK_SIGNING_PASSWORD = $password
    try {
        & keytool.exe -genkeypair -alias artemisos-updater -keyalg RSA -keysize 3072 -validity 9125 -storetype PKCS12 -keystore $keystorePath -storepass:env ARTEMISOS_APK_SIGNING_PASSWORD -keypass:env ARTEMISOS_APK_SIGNING_PASSWORD -dname 'CN=ArtemisOS Updater, O=ArtemisOS' -noprompt
        if ($LASTEXITCODE -ne 0) { throw 'Android 应用签名密钥创建失败。' }
    } finally { Remove-Item Env:ARTEMISOS_APK_SIGNING_PASSWORD -ErrorAction SilentlyContinue }
}
Write-Host "OTA 公钥已准备，私钥与 Android 应用签名材料保存在当前用户的本机目录：$KeyDirectory"
