param(
 [Parameter(Mandatory=$true)][string]$File,
 [Parameter(Mandatory=$true)][ValidatePattern('^(installers/ArtemisOS15-Offline-Installer-(?:1\.0\.(?:7(?:-r2)?|8|9)|1\.1\.0)\.exe(?:\.sha256)?|sources/ArtemisOS15-Display-Sources-1\.0\.6\.zip|sources/ArtemisOS15-Secure-Display-Sources-1\.0\.9(?:-r2)?\.zip)$')][string]$RelativePath,
 [Parameter(Mandatory=$true)][string]$ResultFile
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
foreach($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management','Microsoft.PowerShell.Security')){Import-Module (Join-Path $PSHOME ('Modules\'+$module+'\'+$module+'.psd1')) -ErrorAction Stop}
Add-Type -AssemblyName System.Net.Http
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'stage\update\core.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Publish-OpenList.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Publisher parse failed.'}
foreach($name in @('Invoke-OpenListJson','Get-RemoteMeta','Ensure-RemoteDirectory','Upload-OpenListFile','Open-PublicFile','Test-PublicObject')){
 $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false)
 if(-not $node){throw 'Missing reviewed publisher helper.'}
 . ([scriptblock]::Create($node.Extent.Text))
}
$PublicBase=[uri]'https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/'
$RemoteRoot='/ota';$script:ServerOrigin='https://cloudx.playones.com';$script:ApiToken=$null
function Get-PublicUrl([string]$Relative){if($Relative -cne $RelativePath){throw 'Unexpected artifact.'};return [uri]::new($PublicBase,$Relative)}
$local=(Resolve-Path -LiteralPath $File).Path
$size=(Get-Item -LiteralPath $local).Length
$hash=(Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()
$handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseCookies=$false;$handler.UseDefaultCredentials=$false;$handler.Credentials=$null
$http=[Net.Http.HttpClient]::new($handler);$http.Timeout=[TimeSpan]::FromMinutes(30)
$credential=Import-Clixml (Join-Path $project '.secrets\openlist-publish.clixml')
try{
 $body=@{username=$credential.UserName;password=$credential.GetNetworkCredential().Password}
 try{$login=Invoke-OpenListJson 'POST' '/api/auth/login' $body $false}finally{$body=$null;$credential=$null}
 if($login.code -ne 200 -or -not $login.data.token){throw 'Login failed.'}
 $script:ApiToken=$login.data.token;$login=$null
 $me=Invoke-OpenListJson 'GET' '/api/me' $null $true
 if($me.code -ne 200 -or $me.data.disabled -or [int]$me.data.role -ne 0 -or ([int]$me.data.permission -band 8) -eq 0 -or
     [uri]::UnescapeDataString($PublicBase.AbsolutePath) -cne ('/d'+$me.data.base_path.TrimEnd('/')+$RemoteRoot+'/')){throw 'Unexpected publishing scope.'}
 Ensure-RemoteDirectory ($RemoteRoot+'/'+$RelativePath.Split('/')[0])
 $remote=Get-RemoteMeta ($RemoteRoot+'/'+$RelativePath)
 if($null -eq $remote){Write-Output ('Uploading '+$RelativePath+' ('+$size+' bytes)');Upload-OpenListFile $local ($RemoteRoot+'/'+$RelativePath)}
 elseif($remote.is_dir -or [long]$remote.size -ne $size){throw 'Existing artifact differs; refusing overwrite.'}
 $response=Open-UpdateResponse (Get-PublicUrl $RelativePath) -RangeEnd 0
 try{$finalHost=$response.ResponseUri.Host;if($finalHost -notmatch '(?i)(?:^|\.)ctyunxs\.cn$'){throw 'Artifact is not downloaded directly from Tianyi.'}}finally{$response.Dispose()}
 Write-Output ('Anonymous full size/SHA256 readback: '+$RelativePath)
 Test-PublicObject $RelativePath $size $hash
 $record=[ordered]@{published=$true;relativePath=$RelativePath;url=(Get-PublicUrl $RelativePath).AbsoluteUri;bytes=$size;sha256=$hash;anonymousReadback=$true;fullHashVerified=$true;finalHost=$finalHost;completedUtc=[DateTime]::UtcNow.ToString('o')}
 [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultFile),($record|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 $record|ConvertTo-Json -Compress
}finally{$script:ApiToken=$null;$credential=$null;$http.Dispose();$handler.Dispose()}
