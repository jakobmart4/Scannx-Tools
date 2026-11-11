# RTSS experiments (C5)

These Windows PowerShell 5.1 probes are development experiments, excluded from the release zip. They install nothing, use no modules, make no network requests and save no reports. RTSS must already be running in the same Windows session. Run these only when you intend to inspect RTSS or temporarily write an OSD line.

## Questions and commands

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\experiments\rtss-read.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\experiments\rtss-read.ps1 -Seconds 30
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\experiments\rtss-osd.ps1 -Text 'Scannx: temporary OSD probe'
```

The command's execution policy applies only to that process; it does not change the machine policy. Use the same privilege level as RTSS if access is denied. No elevation is requested by the scripts.

- `rtss-read.ps1`: does RTSS expose an entry for the game, its frame time in microseconds and raw frame-rate counters? Opens the mapping and view with read rights only, prints the version and every nonzero process ID. The default is one snapshot; `-Seconds N` takes N snapshots separated by a one-second sleep. Scheduling and printing can add delay. `PeriodFps` is blank when its time interval is invalid. Names use the Windows ANSI encoding. RTSS updates independently, so a snapshot is approximate rather than an atomic recording.
- `rtss-osd.ps1`: can a secondary client show a line and release its slot? Uses owner `Scannx`, displays printable ASCII text for ten seconds and then clears/releases its own slot in `finally`. Ctrl+C is intended to take the same cleanup path. It skips primary slot zero, existing Scannx slots and every other occupied slot. It does not reclaim stale slots.

Exit 0 means the requested probe completed. Missing RTSS, unsupported versions, malformed metadata, busy OSD, a second running probe or no free slot produce a clear diagnostic and exit 1. A rejected slot allocation leaves no slot or refresh-counter change. Acquiring and restoring the busy bit is the only temporary write on the no-free-slot path.

## Layout provenance

Source checked on 2026-11-11: the [RTSS SDK header as distributed in RTSSTweaks][sdk] and the [Unwinder-authored SDK interface sample distributed in obs-rtss][sample]. These are public copies, not an SDK installation inspected on the target PC. Compare the installed SDK before expanding support. No header or third-party implementation is copied into this repository.

The following byte offsets are derived from declaration order using [Windows data type sizes][types] and [MAX_PATH = 260][path]. Sources below apply to every field listed in a row. Values are little-endian. Offsets are relative to the header, application entry or OSD entry, respectively.

| Header field | Offset | Bytes | Version | Source |
|---|---:|---:|---|---|
| dwSignature | 0 | 4 | 2.0+ | [header][sdk] |
| dwVersion | 4 | 4 | 2.0+ | [header][sdk] |
| dwAppEntrySize, dwAppArrOffset, dwAppArrSize | 8, 12, 16 | 4 each | 2.0+ | [header][sdk] |
| dwOSDEntrySize, dwOSDArrOffset, dwOSDArrSize | 20, 24, 28 | 4 each | 2.0+ | [header][sdk] |
| dwOSDFrame | 32 | 4 | 2.0+ | [header][sdk] |
| dwBusy | 36 | 4 | 2.14+ | [header][sdk] |

| Application field | Offset | Bytes | Version | Source |
|---|---:|---:|---|---|
| dwProcessID, szName | 0, 4 | 4, 260 | 2.0+ | [header][sdk] |
| dwFlags (skipped) | 264 | 4 | 2.0+ | [header][sdk] |
| dwTime0, dwTime1, dwFrames, dwFrameTime | 268, 272, 276, 280 | 4 each | 2.0+ | [header][sdk] |
| dwStatFlags, dwStatTime0, dwStatTime1, dwStatFrames | 284, 288, 292, 296 | 4 each | 2.0+ | [header][sdk] |
| dwStatCount, dwStatFramerateMin, dwStatFramerateAvg, dwStatFramerateMax | 300, 304, 308, 312 | 4 each | 2.0+ | [header][sdk] |

| OSD field | Offset | Bytes | Version | Source |
|---|---:|---:|---|---|
| szOSD, szOSDOwner | 0, 256 | 256 each | 2.0+ | [header][sdk] |
| szOSDEx | 512 | 4096 | 2.7+ | [header][sdk] |
| buffer | 4608 | 262144 | 2.12+ | [header][sdk] |
| szOSDEx2 | 266752 | 32768 | 2.20+ | [header][sdk] |

Header minimums derived from the [versioned additions][sdk]: 2.0-2.13: 36; 2.14: 40; 2.15: 64; 2.16-2.17: 72; 2.18: 80; 2.19-2.20: 96 bytes. The application prefix above is 316 bytes. OSD minimums are 266752 bytes for 2.14-2.19 and 299520 for 2.20.

Array addresses always use the runtime `dw*ArrOffset + index * dw*EntrySize`, and iteration uses `dw*ArrSize`. Counts over 65536, undersized entries or ranges outside the view are rejected. The OSD probe additionally rejects overlapping arrays and OSD offsets/strides without 8-byte alignment. It clears only known text fields, leaving the embedded-data buffer and unused stride tail intact. No array base, stride or count is assumed from SDK sample array declarations. Some nearby header comments swap app/OSD names; the field names and [sample's address arithmetic][sample] determine their use.

Reader support is deliberately limited to layout versions 2.0 through 2.20. Writer support is 2.14 through 2.20, where the busy bit exists. Other major versions and later minor versions fail closed. RTSS product version and shared-memory layout version are different numbers.

## Ownership and cleanup

The original `Add-Type` helper is needed for atomic operations on mapped fields: passing a copied integer by reference from PowerShell cannot reserve a shared slot. It references only the built-in .NET Framework `System.Core.dll`. Compilation may use ordinary temporary compiler files. [Interlocked.CompareExchange][atomic] operates directly on pinned mapped memory; no downloaded code is compiled.

A session-local named mutex serializes this probe's stable owner ID. Under RTSS's busy bit, it requires an entirely empty owner buffer and atomically installs the complete `Scannx` ID before touching payload. The writer rechecks the header and full owner before each payload write, preserves unrelated busy bits, updates the global refresh counter and releases the busy bit in a C# `finally`. It holds no busy lock during the ten-second display. Cleanup clears known text fields first and conditionally releases the owner last. It never deliberately takes over another Scannx instance's slot.

**Concurrency limit:** the [SDK sample][sample] allocates an owner outside the busy-bit lock, with an empty check followed by a separate string write. Such a client could have observed an empty slot before this probe's atomic claim and overwrite the owner afterwards. Rechecking ownership stops further writes once that change is detected, but cannot eliminate the interval between a check and a write. Absolute exclusive ownership against that protocol cannot be guaranteed. This remains a material live-verification limit, including ordinary clients derived from the sample. Avoid starting other OSD clients during the probe.

If RTSS changes the layout/owner or keeps the busy bit set for three seconds, cleanup refuses an unsafe write and prints a diagnostic. Ctrl+C cleanup needs a live check; process termination, closing the host window or a system crash cannot guarantee `finally`. A stale Scannx slot after a forced termination is left untouched; restarting RTSS clears its shared state.

## Verification status and Claude handoff

Checked with Windows PowerShell 5.1: repository script parsing, compilation of the original helper and synthetic-only mapping checks. Synthetic checks covered layouts 2.14-2.20, nonstandard runtime offsets/strides, read-only output, claim/release, protected foreign/primary slots, existing Scannx slots, no-free-slot byte identity, malformed bounds/overlap/alignment, unknown versions, busy timeout, changed-owner refusal and script `finally` cleanup after an injected error. Synthetic adapters replaced the mapping name with a fresh GUID name before execution. They never opened RTSS's mapping.

**Not verified:** nothing was run against real RTSS or a game. Live frame-counter accuracy, OSD rendering (including Ex/Ex2 selection on layout 2.20), exclusive ownership with ordinary sample-derived concurrent clients, ten-second real display and Ctrl+C cleanup remain for Claude on the authorized RTSS PC. The OSD probe writes Ex and leaves Ex2 empty. PSScriptAnalyzer was not installed for this task. No live reports or memory dumps belong in the repository, PR or issues.

Claude's live check: run the reader while a game is present; compare its counters with RTSS; run the OSD probe once to timeout and once with Ctrl+C; confirm its line disappears and other clients' OSD survives. Assess allocation behavior with ordinary sample-derived clients, including simultaneous allocation, before accepting ownership safety. Repeat with no secondary slot available and verify no foreign slot changes. Record only sanitized outcomes, layout version and exit codes. A successful live run does not prove the absence of every allocation race.

[sdk]: https://github.com/jaxFF/RTSSTweaks/blob/master/thirdparty/rtss-sdk/Include/RTSSSharedMemory.h#L302-L455
[sample]: https://github.com/jfoster/obs-rtss/blob/main/RTSSSharedMemoryInterface.cpp
[atomic]: https://learn.microsoft.com/en-us/dotnet/api/system.threading.interlocked.compareexchange?view=netframework-4.8.1
[types]: https://learn.microsoft.com/en-us/windows/win32/winprog/windows-data-types
[path]: https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation
