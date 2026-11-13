# Experiment only. Opens RTSSSharedMemoryV2 read-only; writes only console output.
# No settings, files or shared-memory bytes are changed. Layout sources: README.md.
[CmdletBinding()]
param(
    [ValidateRange(1, 86400)]
    [int]$Seconds = 1
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$mapping = $null
$view = $null
$failed = $false

function Get-RtssHeader {
    param([IO.MemoryMappedFiles.MemoryMappedViewAccessor]$Accessor)

    if ($Accessor.Capacity -lt 36) { throw 'RTSS mapping is shorter than its header.' }
    if ($Accessor.ReadUInt32(0) -ne 0x52545353) { throw 'RTSS shared memory is not initialized (invalid signature).' }
    $version = $Accessor.ReadUInt32(4)
    if ($version -lt 0x00020000 -or $version -gt 0x00020015) {
        throw ('Unknown RTSS shared-memory version 0x{0:X8}; supported: 2.0 through 2.21.' -f $version)
    }

    # Later header additions precede the arrays; do not accept an array over them.
    $headerSize = 36
    if ($version -ge 0x0002000e) { $headerSize = 40 }
    if ($version -ge 0x0002000f) { $headerSize = 64 }
    if ($version -ge 0x00020010) { $headerSize = 72 }
    if ($version -ge 0x00020012) { $headerSize = 80 }
    if ($version -ge 0x00020013) { $headerSize = 96 }
    $entrySize = [long]$Accessor.ReadUInt32(8)
    $offset = [long]$Accessor.ReadUInt32(12)
    $count = [long]$Accessor.ReadUInt32(16)
    if ($Accessor.Capacity -lt $headerSize -or $entrySize -lt 316 -or $offset -lt $headerSize -or
        $offset -gt $Accessor.Capacity -or $count -gt 65536 -or
        $count -gt [math]::Floor(($Accessor.Capacity - $offset) / $entrySize)) {
        throw 'RTSS application array is outside the mapping or has an unsupported size.'
    }
    [pscustomobject]@{ Version = $version; EntrySize = $entrySize; Offset = $offset; Count = $count }
}

try {
    try {
        $mapping = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting(
            'RTSSSharedMemoryV2', [IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
    } catch [IO.FileNotFoundException] {
        throw 'RTSS is not running (RTSSSharedMemoryV2 was not found).'
    }
    $view = $mapping.CreateViewAccessor(0, 0, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
    $header = Get-RtssHeader $view
    Write-Host ('RTSS shared-memory version {0}.{1}' -f ($header.Version -shr 16), ($header.Version -band 65535))

    for ($sample = 0; $sample -lt $Seconds; $sample++) {
        $header = Get-RtssHeader $view
        Write-Host ('Sample {0}/{1}' -f ($sample + 1), $Seconds)
        $found = $false
        for ($index = 0; $index -lt $header.Count; $index++) {
            $position = $header.Offset + $index * $header.EntrySize
            $bytes = New-Object byte[] 316
            [void]$view.ReadArray($position, $bytes, 0, $bytes.Length)
            $processId = [BitConverter]::ToUInt32($bytes, 0)
            if ($processId -eq 0) { continue }
            # RTSS updates asynchronously. Skip entries reused while being copied.
            if ($view.ReadUInt32($position) -ne $processId) { continue }
            $found = $true
            $nameEnd = 4
            while ($nameEnd -lt 264 -and $bytes[$nameEnd] -ne 0) { $nameEnd++ }
            $time0 = [BitConverter]::ToUInt32($bytes, 268)
            $time1 = [BitConverter]::ToUInt32($bytes, 272)
            $frames = [BitConverter]::ToUInt32($bytes, 276)
            $frameTime = [BitConverter]::ToUInt32($bytes, 280)
            $fps = $null
            # DWORD millisecond counters wrap at about 49.7 days.
            $elapsed = ([long]$time1 - [long]$time0 + 4294967296L) % 4294967296L
            if ($time0 -ne 0 -and $elapsed -gt 0) { $fps = 1000.0 * $frames / $elapsed }
            [pscustomobject]@{
                ProcessId = $processId
                Name = [Text.Encoding]::Default.GetString($bytes, 4, $nameEnd - 4)
                FrameTimeUs = $frameTime
                Time0Ms = $time0
                Time1Ms = $time1
                Frames = $frames
                PeriodFps = $fps
                StatFlags = [BitConverter]::ToUInt32($bytes, 284)
                StatTime0Ms = [BitConverter]::ToUInt32($bytes, 288)
                StatTime1Ms = [BitConverter]::ToUInt32($bytes, 292)
                StatFrames = [BitConverter]::ToUInt32($bytes, 296)
                StatCount = [BitConverter]::ToUInt32($bytes, 300)
                StatFramerateMin = [BitConverter]::ToUInt32($bytes, 304)
                StatFramerateAvg = [BitConverter]::ToUInt32($bytes, 308)
                StatFramerateMax = [BitConverter]::ToUInt32($bytes, 312)
            } | Format-List | Out-Host
        }
        if (-not $found) { Write-Host 'No active RTSS application entries.' }
        if ($sample + 1 -lt $Seconds) { Start-Sleep -Seconds 1 }
    }
} catch {
    Write-Host ('RTSS read probe: {0}' -f $_.Exception.Message)
    $failed = $true
} finally {
    if ($null -ne $view) { $view.Dispose() }
    if ($null -ne $mapping) { $mapping.Dispose() }
}
if ($failed) { exit 1 }
