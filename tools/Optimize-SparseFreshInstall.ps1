<#
.SYNOPSIS
Experimental NTFS zero-range reclamation for a freshly extracted system image.

.DESCRIPTION
The installer must first establish that InstallRoot is a new, empty install
directory, create it, write .artemis-fresh-install containing a unique 32-digit
hexadecimal token, and then extract the image. This script cannot itself prove that the
installer established those conditions. No existing install may be given a
fresh marker. The caller supplies the expected image SHA-256 and the same GUID.

The image is opened exclusively, rejected if it has multiple hard links, and
verified before being marked sparse. Only ranges read as entirely zero from the
locked file are deallocated. On a recoverable failure, the hash is checked again
before reporting a skip. If post-operation integrity cannot be confirmed, this
script throws and the caller must not start the image. The installer embeds the
script when a SHA-256 build parameter is supplied.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedSha256,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{32}$')][string]$FreshInstallToken
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ($InstallRoot -eq [IO.Path]::GetPathRoot($InstallRoot).TrimEnd('\')) { throw 'InstallRoot cannot be a volume root.' }
$marker = Join-Path $InstallRoot '.artemis-fresh-install'
$image = Join-Path $InstallRoot 'sdk\system-images\android-35\google_apis\x86_64\system.img'
function Skip([string]$Reason) { [pscustomobject]@{ Status='Skipped'; Reason=$Reason } }
function HasReparsePoint([string]$Path) {
    $absolute = [IO.Path]::GetFullPath($Path)
    $volume = [IO.Path]::GetPathRoot($absolute)
    $current = $volume
    foreach ($part in $absolute.Substring($volume.Length).Split('\')) {
        if (-not $part) { continue }
        $current = Join-Path $current $part
        if (-not (Test-Path -LiteralPath $current)) { return $true }
        if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $true }
    }
    return $false
}
try {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or (HasReparsePoint $marker) -or
        [IO.File]::ReadAllText($marker).Trim() -ine $FreshInstallToken) { return Skip 'Fresh-install marker is missing or invalid.' }
    if (-not (Test-Path -LiteralPath $image -PathType Leaf) -or (HasReparsePoint $image)) { return Skip 'Image is missing or its path contains a reparse point.' }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($image))
    if ($drive.DriveFormat -cne 'NTFS') { return Skip 'The destination filesystem is not NTFS.' }
} catch { return Skip 'The installation directory is not accessible.' }

if (-not ('Artemis.SparseFreshInstall' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace Artemis {
    public sealed class ImageHashMismatchException : Exception {
        public ImageHashMismatchException(string message) : base(message) { }
    }
    public sealed class ImageIntegrityUnconfirmedException : IOException {
        public ImageIntegrityUnconfirmedException(string message, Exception inner) : base(message, inner) { }
    }
    public sealed class SparseOutcome {
        public string Status, Reason, Sha256;
        public long Length, ZeroBytes;
        public int Ranges;
    }
    public static class SparseFreshInstall {
        private const uint FSCTL_SET_SPARSE=0x000900C4, FSCTL_SET_ZERO_DATA=0x000980C8;
        private const int Block=64*1024, BufferSize=4*1024*1024;
        [StructLayout(LayoutKind.Sequential)] private struct FileInfo {
            public uint Attributes, CreatedLow, CreatedHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ZeroRange { public long Offset, End; }
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInfo info);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool DeviceIoControl(SafeFileHandle file,
            uint control, IntPtr input, uint inputLength, IntPtr output, uint outputLength, out uint returned, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool DeviceIoControl(SafeFileHandle file,
            uint control, ref ZeroRange input, uint inputLength, IntPtr output, uint outputLength, out uint returned, IntPtr overlapped);

        private static string Hash(FileStream file) {
            file.Position=0;
            using (var hash=SHA256.Create()) {
                byte[] bytes=new byte[BufferSize]; int n;
                while ((n=file.Read(bytes,0,bytes.Length)) != 0) hash.TransformBlock(bytes,0,n,bytes,0);
                hash.TransformFinalBlock(new byte[0],0,0);
                return BitConverter.ToString(hash.Hash).Replace("-","").ToLowerInvariant();
            }
        }
        private static bool Zero(byte[] bytes, int start, int length) {
            int end=start+length, i=start;
            for (; i<=end-8; i+=8) if (BitConverter.ToUInt64(bytes,i)!=0) return false;
            for (; i<end; i++) if (bytes[i]!=0) return false;
            return true;
        }
        private static void Release(SafeFileHandle handle, long begin, long end) {
            var range=new ZeroRange { Offset=begin, End=end }; uint returned;
            if (!DeviceIoControl(handle,FSCTL_SET_ZERO_DATA,ref range,(uint)Marshal.SizeOf(typeof(ZeroRange)),
                    IntPtr.Zero,0,out returned,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        // The optional callback exists for isolated interruption regression;
        // the production PowerShell entry point always passes null.
        public static SparseOutcome Reclaim(string path, string expected, Action<int> afterRange) {
            using (var file=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,FileShare.None,BufferSize,FileOptions.SequentialScan)) {
                FileInfo info;
                if (!GetFileInformationByHandle(file.SafeFileHandle,out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (info.Links!=1) return new SparseOutcome { Status="Skipped", Reason="Image has multiple hard links." };
                long length=file.Length;
                string before=Hash(file);
                if (!String.Equals(before,expected,StringComparison.OrdinalIgnoreCase))
                    throw new ImageHashMismatchException("Image SHA-256 does not match the expected version.");
                if (!GetFileInformationByHandle(file.SafeFileHandle,out info) || info.Links!=1)
                    return new SparseOutcome { Status="Skipped", Reason="Could not confirm a single hard link." };
                bool changed=false;
                var result=new SparseOutcome { Status="Optimized", Length=length, Sha256=before };
                try {
                    uint returned;
                    if (!DeviceIoControl(file.SafeFileHandle,FSCTL_SET_SPARSE,IntPtr.Zero,0,IntPtr.Zero,0,out returned,IntPtr.Zero))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    changed=true;
                    file.Position=0;
                    byte[] bytes=new byte[BufferSize]; long position=0; int count;
                    while ((count=file.Read(bytes,0,bytes.Length))!=0) {
                        int run=-1;
                        for (int offset=0; offset<count; offset+=Block) {
                            int n=Math.Min(Block,count-offset);
                            if (Zero(bytes,offset,n)) { if (run<0) run=offset; }
                            else if (run>=0) {
                                Release(file.SafeFileHandle,position+run,position+offset);
                                result.ZeroBytes+=offset-run; result.Ranges++; run=-1;
                                if (afterRange!=null) afterRange(result.Ranges);
                            }
                        }
                        if (run>=0) {
                            Release(file.SafeFileHandle,position+run,position+count);
                            result.ZeroBytes+=count-run; result.Ranges++;
                            if (afterRange!=null) afterRange(result.Ranges);
                        }
                        position+=count;
                    }
                    file.Flush(true);
                    if (file.Length!=length || !String.Equals(Hash(file),before,StringComparison.Ordinal))
                        throw new IOException("Image integrity check failed after sparse reclamation.");
                    return result;
                } catch (Exception e) {
                    if (changed) {
                        try {
                            if (file.Length!=length || !String.Equals(Hash(file),before,StringComparison.Ordinal))
                                throw new IOException("Image hash differs.");
                        } catch (Exception verification) {
                            throw new ImageIntegrityUnconfirmedException("Sparse reclamation failed and image integrity could not be confirmed.",
                                new AggregateException(e,verification));
                        }
                    }
                    return new SparseOutcome { Status="Skipped", Reason="Sparse reclamation was unavailable; image hash verified.", Sha256=before, Length=length };
                }
            }
        }
    }
}
'@
}
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    $outcome = [Artemis.SparseFreshInstall]::Reclaim($image, $ExpectedSha256, $null)
} catch {
    # PowerShell wraps exceptions from static .NET method calls.
    $cause = $_.Exception
    while ($cause -is [System.Management.Automation.MethodInvocationException] -and $cause.InnerException) {
        $cause = $cause.InnerException
    }
    if ($cause -is [Artemis.ImageIntegrityUnconfirmedException] -or $cause -is [Artemis.ImageHashMismatchException]) { throw }
    if ($cause -is [IO.IOException] -or $cause -is [UnauthorizedAccessException] -or $cause -is [ComponentModel.Win32Exception]) {
        return Skip 'Image is busy or inaccessible.'
    }
    throw
}
$timer.Stop()
[pscustomobject]@{ Status=$outcome.Status; Reason=$outcome.Reason; Sha256=$outcome.Sha256;
    LogicalBytes=$outcome.Length; ExaminedZeroBytes=$outcome.ZeroBytes; ZeroRanges=$outcome.Ranges;
    ElapsedSeconds=[math]::Round($timer.Elapsed.TotalSeconds,2) }
