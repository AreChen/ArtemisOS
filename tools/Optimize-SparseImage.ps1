<#
.SYNOPSIS
Experimentally creates a new, byte-identical NTFS sparse copy of an image.

.DESCRIPTION
Only the source file is read. The destination must not exist. If the filesystem
does not support sparse files, or the output fails SHA-256 verification, the
newly created output is removed and the source remains untouched. This does not
reduce the file's logical length or an installer download by itself.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop

$Source = [IO.Path]::GetFullPath($Source)
$Destination = [IO.Path]::GetFullPath($Destination)
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw 'Source file does not exist.' }
if (Test-Path -LiteralPath $Destination) { throw 'Destination already exists; refusing to overwrite it.' }
$parent = Split-Path -Parent $Destination
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Destination directory does not exist.' }
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Destination))
if ($drive.DriveFormat -cne 'NTFS') { throw 'This experiment requires an NTFS destination.' }

if (-not ('Artemis.SparseImageCopy' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace Artemis {
    public static class SparseImageCopy {
        private const uint FSCTL_SET_SPARSE = 0x000900C4;
        private const int ReadBufferSize = 4 * 1024 * 1024;
        private const int SegmentSize = 64 * 1024;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(SafeFileHandle file, uint code,
            IntPtr input, uint inputSize, IntPtr output, uint outputSize,
            out uint returned, IntPtr overlapped);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetCompressedFileSizeW(string path, out uint high);

        [DllImport("kernel32.dll")]
        private static extern void SetLastError(uint code);

        public static long AllocatedSize(string path) {
            uint high;
            SetLastError(0);
            uint low = GetCompressedFileSizeW(path, out high);
            int error = Marshal.GetLastWin32Error();
            if (low == 0xffffffff && error != 0) throw new Win32Exception(error);
            return ((long)high << 32) | low;
        }

        private static bool IsZero(byte[] buffer, int start, int count) {
            int end = start + count;
            int i = start;
            for (; i <= end - 8; i += 8)
                if (BitConverter.ToUInt64(buffer, i) != 0) return false;
            for (; i < end; i++)
                if (buffer[i] != 0) return false;
            return true;
        }

        private static string Hex(byte[] bytes) {
            return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
        }

        public static string CopyAndVerify(string source, string destination) {
            bool created = false;
            try {
                long expectedLength;
                string expectedHash;
                using (var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read,
                           ReadBufferSize, FileOptions.SequentialScan))
                using (var hash = SHA256.Create()) {
                    expectedLength = input.Length;
                    using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.ReadWrite,
                               FileShare.None, ReadBufferSize, FileOptions.SequentialScan)) {
                        created = true;
                        uint returned;
                        if (!DeviceIoControl(output.SafeFileHandle, FSCTL_SET_SPARSE, IntPtr.Zero, 0,
                                IntPtr.Zero, 0, out returned, IntPtr.Zero))
                            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not mark destination sparse");
                        output.SetLength(expectedLength);
                        byte[] buffer = new byte[ReadBufferSize];
                        long position = 0;
                        int count;
                        while ((count = input.Read(buffer, 0, buffer.Length)) != 0) {
                            hash.TransformBlock(buffer, 0, count, buffer, 0);
                            int run = -1;
                            for (int offset = 0; offset < count; offset += SegmentSize) {
                                int length = Math.Min(SegmentSize, count - offset);
                                if (!IsZero(buffer, offset, length)) {
                                    if (run < 0) run = offset;
                                } else if (run >= 0) {
                                    output.Position = position + run;
                                    output.Write(buffer, run, offset - run);
                                    run = -1;
                                }
                            }
                            if (run >= 0) {
                                output.Position = position + run;
                                output.Write(buffer, run, count - run);
                            }
                            position += count;
                        }
                        if (position != expectedLength) throw new IOException("Source length changed while copying");
                        hash.TransformFinalBlock(new byte[0], 0, 0);
                        expectedHash = Hex(hash.Hash);
                        output.Flush(true);
                    }
                }
                if ((File.GetAttributes(destination) & FileAttributes.SparseFile) == 0)
                    throw new IOException("Destination was not marked sparse");
                using (var result = new FileStream(destination, FileMode.Open, FileAccess.Read, FileShare.Read,
                           ReadBufferSize, FileOptions.SequentialScan))
                using (var hash = SHA256.Create()) {
                    if (result.Length != expectedLength || Hex(hash.ComputeHash(result)) != expectedHash)
                        throw new IOException("Destination length or SHA-256 differs from source");
                }
                return expectedHash;
            } catch (Exception operationError) {
                if (created) {
                    try { File.Delete(destination); }
                    catch (Exception cleanupError) {
                        throw new IOException("Sparse copy failed and its new output could not be removed.",
                            new AggregateException(operationError, cleanupError));
                    }
                }
                throw;
            }
        }
    }
}
'@
}

$watch = [Diagnostics.Stopwatch]::StartNew()
$sourceAllocated = [Artemis.SparseImageCopy]::AllocatedSize($Source)
$digest = [Artemis.SparseImageCopy]::CopyAndVerify($Source, $Destination)
$watch.Stop()
[pscustomobject]@{
    Source = $Source
    Destination = $Destination
    LogicalBytes = (Get-Item -LiteralPath $Destination).Length
    SourceAllocatedBytes = $sourceAllocated
    DestinationAllocatedBytes = [Artemis.SparseImageCopy]::AllocatedSize($Destination)
    Sha256 = $digest
    ElapsedSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
}
