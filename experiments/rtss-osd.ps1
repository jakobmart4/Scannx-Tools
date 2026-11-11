# Experiment only. Writes one owned OSD slot, dwBusy bit 0 and dwOSDFrame in
# RTSSSharedMemoryV2. Finally attempts to clear/release that slot. No settings change.
# Add-Type may use temporary compiler files; the named mutex lasts for this run.
# Layout, atomic-helper rationale and cleanup limits: README.md.
[CmdletBinding()]
param(
    [ValidateLength(1, 255)]
    [ValidatePattern('\A[\x20-\x7E]+\z')]
    [string]$Text = 'Scannx RTSS probe: temporary OSD (10 seconds)'
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$mapping = $null
$view = $null
$probe = $null
$mutex = $null
$ownsMutex = $false
$failed = $false

try {
    # A stable owner ID needs local serialization: never reuse an existing Scannx slot.
    $mutex = New-Object Threading.Mutex($false, 'Local\Scannx.RtssOsdProbe')
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Another Scannx OSD probe is running.' }

    if (-not ('Scannx.RtssOsdSlot' -as [type])) {
        # Original interop code, not an SDK header or sample copy. Atomics must
        # operate on the mapped DWORD, not a managed copy passed by reference.
        $compiler = New-Object CodeDom.Compiler.CompilerParameters -Property @{
            CompilerOptions = '/unsafe'; GenerateInMemory = $true
        }
        [void]$compiler.ReferencedAssemblies.Add('System.Core.dll')
        Add-Type -CompilerParameters $compiler -TypeDefinition @'
using System;
using System.IO.MemoryMappedFiles;
using System.Threading;

namespace Scannx {
    public sealed unsafe class RtssOsdSlot {
        private readonly MemoryMappedViewAccessor view;
        private readonly uint version, appSize, appOffset, appCount, size, offset, count;
        private readonly byte[] owner = System.Text.Encoding.ASCII.GetBytes("Scannx\0");
        private long slot = -1;

        public RtssOsdSlot(MemoryMappedViewAccessor accessor) {
            view = accessor;
            if (view.Capacity < 40 || view.ReadUInt32(0) != 0x52545353)
                throw new InvalidOperationException("RTSS shared memory is not initialized (invalid header/signature).");
            version = view.ReadUInt32(4);
            if (version < 0x0002000e || version > 0x00020014)
                throw new InvalidOperationException("Unknown/unsupported RTSS OSD version; supported: 2.14 through 2.20.");
            long header = version >= 0x00020013 ? 96 : version >= 0x00020012 ? 80 :
                version >= 0x00020010 ? 72 : version >= 0x0002000f ? 64 : 40;
            appSize = view.ReadUInt32(8); appOffset = view.ReadUInt32(12); appCount = view.ReadUInt32(16);
            size = view.ReadUInt32(20); offset = view.ReadUInt32(24); count = view.ReadUInt32(28);
            CheckArray(appOffset, appSize, appCount, header, 316);
            CheckArray(offset, size, count, header, version >= 0x00020014 ? 299520U : 266752U);
            long appEnd = appOffset + (long)appSize * appCount;
            long osdEnd = offset + (long)size * count;
            if ((offset % 8) != 0 || (size % 8) != 0 || (appCount != 0 && count != 0 &&
                offset < appEnd && appOffset < osdEnd))
                throw new InvalidOperationException("RTSS arrays overlap or OSD entries are not 8-byte-aligned.");
        }

        private void CheckArray(uint start, uint stride, uint length, long header, uint minimum) {
            if (view.Capacity < header || start < header || start > view.Capacity || stride < minimum ||
                length > 65536 || length > (view.Capacity - start) / stride)
                throw new InvalidOperationException("RTSS array is outside the mapping or has an unsupported size.");
        }

        private bool SameHeader() {
            return view.ReadUInt32(0) == 0x52545353 && view.ReadUInt32(4) == version &&
                view.ReadUInt32(8) == appSize && view.ReadUInt32(12) == appOffset && view.ReadUInt32(16) == appCount &&
                view.ReadUInt32(20) == size && view.ReadUInt32(24) == offset && view.ReadUInt32(28) == count;
        }

        // The SafeHandle remains pinned for the entire atomic operation.
        private bool Lock(byte* address) {
            int* busy = (int*)(address + 36);
            int start = Environment.TickCount;
            do {
                int previous = Interlocked.CompareExchange(ref *busy, 0, 0);
                if ((previous & 1) == 0 && Interlocked.CompareExchange(ref *busy, previous | 1, previous) == previous)
                    return true;
                Thread.Sleep(1);
            } while (unchecked((uint)(Environment.TickCount - start)) < 3000);
            return false;
        }

        private void Unlock(byte* address) {
            int* busy = (int*)(address + 36);
            int previous;
            do { previous = Interlocked.CompareExchange(ref *busy, 0, 0); }
            while (Interlocked.CompareExchange(ref *busy, previous & ~1, previous) != previous);
        }

        private bool IsOwner(long position) {
            for (int i = 0; i < 256; i++)
                if (view.ReadByte(position + 256 + i) != (i < owner.Length ? owner[i] : (byte)0)) return false;
            return true;
        }

        private void Clear(long position, long length) {
            byte[] zeros = new byte[4096];
            for (long done = 0; done < length; done += zeros.Length) {
                RequireOwner();
                view.WriteArray(position + done, zeros, 0, (int)Math.Min(zeros.Length, length - done));
            }
        }

        private void RequireOwner() {
            if (!SameHeader() || !IsOwner(slot))
                throw new InvalidOperationException("RTSS slot ownership/layout changed; no further payload writes are allowed.");
        }

        private void ClearText() {
            Clear(slot, 256);
            Clear(slot + 512, 4096);
            if (version >= 0x00020014) Clear(slot + 266752, 32768);
        }

        public bool Claim(string text) {
            if (String.IsNullOrEmpty(text) || text.Length > 255)
                throw new ArgumentException("OSD text must contain 1-255 printable ASCII characters.");
            foreach (char character in text)
                if (character < 32 || character > 126)
                    throw new ArgumentException("OSD text must be a single printable ASCII line.");
            byte* pointer = null;
            bool locked = false;
            view.SafeMemoryMappedViewHandle.AcquirePointer(ref pointer);
            try {
                pointer += view.PointerOffset;
                if (!SameHeader()) throw new InvalidOperationException("RTSS header changed before claiming a slot.");
                if (!Lock(pointer)) throw new InvalidOperationException("RTSS OSD is busy; no slot was claimed.");
                locked = true;
                if (!SameHeader()) throw new InvalidOperationException("RTSS header changed before claiming a slot.");
                // Slot zero is reserved for the primary OSD client by the SDK sample.
                for (uint i = 1; i < count; i++) {
                    long candidate = offset + (long)i * size;
                    // Require an entirely clean owner, then install the complete ID atomically.
                    bool empty = true;
                    for (int j = 0; j < 256; j++)
                        if (view.ReadByte(candidate + 256 + j) != 0) { empty = false; break; }
                    if (!empty || Interlocked.CompareExchange(ref *(long*)(pointer + candidate + 256),
                        0x0000786e6e616353L, 0) != 0) continue;
                    slot = candidate;
                    ClearText();
                    byte[] bytes = System.Text.Encoding.ASCII.GetBytes(text);
                    RequireOwner();
                    view.WriteArray(slot + 512, bytes, 0, bytes.Length);
                    RequireOwner();
                    Interlocked.Increment(ref *(int*)(pointer + 32));
                    return true;
                }
                return false;
            } finally {
                if (locked) Unlock(pointer);
                view.SafeMemoryMappedViewHandle.ReleasePointer();
            }
        }

        public void Release() {
            if (slot < 0) return;
            byte* pointer = null;
            bool locked = false;
            view.SafeMemoryMappedViewHandle.AcquirePointer(ref pointer);
            try {
                pointer += view.PointerOffset;
                if (!SameHeader()) throw new InvalidOperationException("RTSS header changed; cleanup will not touch a different layout.");
                if (!Lock(pointer)) throw new InvalidOperationException("RTSS stayed busy; owned slot could not be cleaned up safely.");
                locked = true;
                RequireOwner();
                ClearText();
                // Owner is released last, after the visible payload is empty.
                RequireOwner();
                if (Interlocked.CompareExchange(ref *(long*)(pointer + slot + 256), 0,
                    0x0000786e6e616353L) != 0x0000786e6e616353L)
                    throw new InvalidOperationException("RTSS owner changed during release; the replacement owner was left intact.");
                slot = -1;
                Interlocked.Increment(ref *(int*)(pointer + 32));
            } finally {
                if (locked) Unlock(pointer);
                view.SafeMemoryMappedViewHandle.ReleasePointer();
            }
        }
    }
}
'@
    }
    try {
        $mapping = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting(
            'RTSSSharedMemoryV2', [IO.MemoryMappedFiles.MemoryMappedFileRights]::ReadWrite)
    } catch [IO.FileNotFoundException] {
        throw 'RTSS is not running (RTSSSharedMemoryV2 was not found).'
    }
    $view = $mapping.CreateViewAccessor(0, 0, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
    $probe = New-Object Scannx.RtssOsdSlot($view)
    if ($probe.Claim($Text)) {
        Write-Host 'Scannx OSD slot claimed for 10 seconds. Ctrl+C requests early cleanup.'
        Start-Sleep -Seconds 10
    } else {
        Write-Host 'No free secondary RTSS OSD slot; no slot was changed.'
        $failed = $true
    }
} catch {
    Write-Host ('RTSS OSD probe: {0}' -f $_.Exception.GetBaseException().Message)
    $failed = $true
} finally {
    try {
        if ($null -ne $probe) { $probe.Release() }
    } catch {
        Write-Host ('RTSS OSD cleanup: {0}' -f $_.Exception.GetBaseException().Message)
        $failed = $true
    } finally {
        if ($null -ne $view) { $view.Dispose() }
        if ($null -ne $mapping) { $mapping.Dispose() }
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}
if ($failed) { exit 1 }
