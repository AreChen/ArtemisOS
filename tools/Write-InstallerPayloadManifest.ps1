<# Build-time only. Inventory exactly the production [Files] destinations.
   The carrier overlay wins over its SDK source; no Android user data is input. #>
param(
 [Parameter(Mandatory=$true)][string]$PackageRoot,
 [Parameter(Mandatory=$true)][string]$SdkRoot,
 [Parameter(Mandatory=$true)][string]$OutputFile
)
$ErrorActionPreference='Stop'
$package=(Resolve-Path -LiteralPath $PackageRoot).Path.TrimEnd('\')
$sdk=(Resolve-Path -LiteralPath $SdkRoot).Path.TrimEnd('\')
$stage=Join-Path $package stage
$destinations=[Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
function Add-Payload([string]$Source,[string]$Relative){
 if($Relative -match '(^data[\/]|\.\.|[:=\r\n])'){throw 'Unsafe payload destination.'}
 $item=Get-Item -LiteralPath $Source -Force
 if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Payload input must be an ordinary file.'}
 $destinations[$Relative.ToLowerInvariant()]=$item.FullName
}
foreach($root in @($sdk,$stage)){
 foreach($entry in @(Get-Item -LiteralPath $root -Force)+@(Get-ChildItem -LiteralPath $root -Recurse -Force)){
  if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Reparse-point input: '+$entry.FullName)}
 }
}
foreach($file in Get-ChildItem -LiteralPath $sdk -Recurse -File -Force){Add-Payload $file.FullName ('sdk\'+$file.FullName.Substring($sdk.Length+1))}
foreach($relative in @('launch.ps1','settings.ps1','initialize.ps1','configure.ps1','configure.vbs','ArtemisOS15.ico','start-auto.vbs','start-software.vbs','version.ini','使用说明.txt')){
 Add-Payload (Join-Path $stage $relative) $relative
}
foreach($file in Get-ChildItem -LiteralPath (Join-Path $stage update) -Recurse -File -Force){
 if($file.Name -eq 'test-marker.txt'){continue}
 Add-Payload $file.FullName ('update\'+$file.FullName.Substring((Join-Path $stage update).Length+1))
}
foreach($file in Get-ChildItem -LiteralPath (Join-Path $stage licenses) -Filter '*.txt' -File){Add-Payload $file.FullName ('licenses\'+$file.Name)}
Add-Payload (Join-Path $stage 'carrier-operators.xml') 'sdk\system-images\android-35\google_apis\x86_64\data\misc\modem_simulator\etc\modem_simulator\files\numeric_operator.xml'
$lines=[Collections.Generic.List[string]]::new();$lines.Add('[Files]')
foreach($item in $destinations.GetEnumerator()){$lines.Add($item.Key+'='+(Get-FileHash -LiteralPath $item.Value -Algorithm SHA256).Hash.ToLowerInvariant())}
$output=[IO.Path]::GetFullPath($OutputFile)
if(Test-Path -LiteralPath $output){throw 'Refusing to overwrite an installer input manifest.'}
[IO.File]::WriteAllLines($output,$lines,[Text.UTF8Encoding]::new($true))
Write-Output ('Installer inventory: '+$destinations.Count+' files; '+$output)
