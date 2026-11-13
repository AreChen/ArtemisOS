[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$encoding = [Text.UTF8Encoding]::new($false)
function Hash([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create(); $stream = [IO.File]::OpenRead($Path)
    try { ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}
function JsonFile([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), $encoding) }
$original = Get-Content -LiteralPath (Join-Path $root 'sources.json') -Raw | ConvertFrom-Json
$archives = @(
    @{ file='scrcpy-build-fa57d7c6.tar.gz'; url='https://codeload.github.com/Genymobile/scrcpy/tar.gz/fa57d7c6b47139797a8e103f87719740718887d4' },
    @{ file='scrcpy-4.1.tar.gz'; url='https://codeload.github.com/Genymobile/scrcpy/tar.gz/refs/tags/v4.1' },
    @{ file='ffmpeg-8.1.2.tar.xz'; url='https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz' },
    @{ file='libusb-1.0.30.tar.gz'; url='https://github.com/libusb/libusb/archive/refs/tags/v1.0.30.tar.gz' },
    @{ file='SDL-release-3.4.12.tar.gz'; url='https://github.com/libsdl-org/SDL/archive/refs/tags/release-3.4.12.tar.gz' },
    @{ file='dav1d-1.5.3.tar.gz'; url='https://code.videolan.org/videolan/dav1d/-/archive/1.5.3/dav1d-1.5.3.tar.gz' },
    @{ file='zlib-1.3.1.tar.gz'; url='https://zlib.net/fossils/zlib-1.3.1.tar.gz' }
)
$sourceRecords = @($archives | ForEach-Object {
    $path = Join-Path $root ('source-archives\'+$_.file)
    [ordered]@{file=('source-archives/'+$_.file); url=$_.url; size=(Get-Item -LiteralPath $path).Length; sha256=(Hash $path)}
})
# The original recipes pin the four directly built libraries independently.
foreach ($pair in @(@('ffmpeg','ffmpeg-8.1.2.tar.xz'),@('libusb','libusb-1.0.30.tar.gz'),@('sdl','SDL-release-3.4.12.tar.gz'),@('dav1d','dav1d-1.5.3.tar.gz'))) {
    $script = Get-Content -LiteralPath (Join-Path $root ('upstream-'+$pair[0]+'.sh')) -Raw
    $expected = [regex]::Match($script,'(?m)^SHA256SUM=([0-9a-f]{64})').Groups[1].Value
    if ((Hash (Join-Path $root ('source-archives\'+$pair[1]))) -cne $expected) { throw ('Upstream source checksum mismatch: '+$pair[1]) }
}
$officialZip = Join-Path $root 'source-archives\scrcpy-win64-v4.1.zip'
if ((Hash $officialZip) -cne '5b12172b3264b2889f4583ee64752ce832e29bc8b1089dca81093459697165db') { throw 'The official release ZIP hash differs.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($officialZip)
try {
    foreach ($record in $original.binaryFiles) {
        $entry = $archive.GetEntry('scrcpy-win64-v4.1/'+$record.file)
        if ($null -eq $entry) { throw ('Missing official ZIP entry: '+$record.file) }
        $stream = $entry.Open(); $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $stream.Dispose(); $sha.Dispose() }
        if ($hash -cne $record.sha256) { throw ('Official runtime identity differs: '+$record.file) }
    }
} finally { $archive.Dispose() }
$lightweight = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $relative = $_.FullName.Substring($root.Length+1).Replace('\','/')
    $relative -notmatch '^(source-archives|dist)/' -and $relative -notin @('sources.json','source-package-manifest.json')
} | Sort-Object FullName)
$records = @($lightweight | ForEach-Object {
    [ordered]@{file=$_.FullName.Substring($root.Length+1).Replace('\','/'); size=$_.Length; sha256=(Hash $_.FullName)}
})
$noticeOrigins = [ordered]@{
    scrcpy='https://github.com/Genymobile/scrcpy/tree/v4.1'
    buildReference='https://github.com/Genymobile/scrcpy/tree/fa57d7c6b47139797a8e103f87719740718887d4'
    ffmpeg='https://github.com/FFmpeg/FFmpeg/tree/n8.1.2'
    sdl='https://github.com/libsdl-org/SDL/tree/release-3.4.12'
    libusb='https://github.com/libusb/libusb/tree/v1.0.30'
    dav1d='https://code.videolan.org/videolan/dav1d/-/tree/1.5.3'
    zlib='https://github.com/madler/zlib/tree/v1.3.1'
    mingwRuntime='https://github.com/mingw-w64/mingw-w64/blob/v12.0.0/COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt'
    mingwNotices='https://github.com/mingw-w64/mingw-w64/blob/v12.0.0/COPYING.MinGW-w64/COPYING.MinGW-w64.txt'
    gccException='https://github.com/gcc-mirror/gcc/blob/releases/gcc-13.3.0/COPYING.RUNTIME'
    gccGPL='https://github.com/gcc-mirror/gcc/blob/releases/gcc-13.3.0/COPYING3'
    permissiveNotices='Original comment blocks collected from the supplied complete FFmpeg/SDL source archives, including uncompiled platform code.'
}
$packageManifest = [ordered]@{
    schemaVersion=1; release='ArtemisOS 1.0.6'; scrcpyVersion='4.1'; platform='windows-x86_64'
    buildCommit='fa57d7c6b47139797a8e103f87719740718887d4'
    tagCommit='2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0'
    modifications='No changes to third-party runtime binaries, LGPL sources or original build recipes.'
    sourceArchives=$sourceRecords; noticeFiles=$records; noticeOrigins=$noticeOrigins; binaryFiles=@($original.binaryFiles)
}
$packageManifestPath = Join-Path $root 'source-package-manifest.json'
JsonFile $packageManifestPath $packageManifest
$dist = Join-Path $root 'dist'
[void][IO.Directory]::CreateDirectory($dist)
$zipPath = Join-Path $dist 'ArtemisOS15-Display-Sources-1.0.6.zip'
$temporary = $zipPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
$zip = [IO.Compression.ZipFile]::Open($temporary,[IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($record in @($records)+@($sourceRecords)+@(@{file='source-package-manifest.json'})) {
        $path = Join-Path $root $record.file
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$path,
            ('ArtemisOS15-Display-Sources-1.0.6/'+$record.file),[IO.Compression.CompressionLevel]::Fastest)
    }
} finally { $zip.Dispose() }
if ([IO.File]::Exists($zipPath)) {
    $previous = $temporary+'.previous'
    [IO.File]::Replace($temporary,$zipPath,$previous)
    [IO.File]::Delete($previous)
}
else { [IO.File]::Move($temporary,$zipPath) }
$records += [ordered]@{file='source-package-manifest.json'; size=(Get-Item -LiteralPath $packageManifestPath).Length; sha256=(Hash $packageManifestPath)}
$manifest = [ordered]@{
    schemaVersion=2; scrcpyVersion='4.1'; platform='windows-x86_64'
    redistributionReviewStatus='source-bundle-prepared-publication-required'
    sourceArchiveIncluded=$false
    runtimeProvenance='Official scrcpy 4.1 Windows x64 ZIP verified against GitHub release digest; every copied binary/artwork entry matched the pinned WinGet bytes.'
    releaseUrl='https://github.com/Genymobile/scrcpy/releases/tag/v4.1'
    officialArchiveSha256='5b12172b3264b2889f4583ee64752ce832e29bc8b1089dca81093459697165db'
    sourceDelivery='LGPL-2.1 sections 4 and 6(d): equivalent public access from the same distribution place; upload/readback must precede binary publication.'
    sourceBundle=[ordered]@{
        file='dist/ArtemisOS15-Display-Sources-1.0.6.zip'
        relativePublicPath='sources/ArtemisOS15-Display-Sources-1.0.6.zip'
        url='https://cloudx.playones.com/sd/YCsIY2UB/sources/ArtemisOS15-Display-Sources-1.0.6.zip?d'
        size=(Get-Item -LiteralPath $zipPath).Length; sha256=(Hash $zipPath)
        publicAvailabilityVerified=$false
    }
    dependencies=@($original.dependencies | Where-Object {$_.name -ne 'zlib'})+@([ordered]@{name='zlib';version='1.3.1';license='Zlib';source='https://zlib.net/fossils/zlib-1.3.1.tar.gz'})
    files=$records; sourceArchives=$sourceRecords; noticeOrigins=$noticeOrigins; binaryFiles=@($original.binaryFiles)
}
JsonFile (Join-Path $root 'sources.json') $manifest
$manifest.sourceBundle | ConvertTo-Json
