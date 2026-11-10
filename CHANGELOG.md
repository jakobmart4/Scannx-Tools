# Changelog

## Unreleased

Fixes from a full review of v1.0.0.

- **Stutter log on a decimal-comma Windows** (Estonian, German, Finnish and similar regional formats): `log.csv` got extra columns and the summary gave a wrong verdict without any error. The logger now uses fixed number and time formats. Logs with times like `13.45.10` are still read. The minutes prompt accepts `0,5` and `0.5` everywhere.
- **Scan, services**: only the real Windows system folders are trusted now. A service in `C:\Windows\Temp` used to be left out of the list, and a file named `Windows Defender.exe` in ProgramData was never flagged.
- **Scan, scheduled tasks**: tasks under `\Microsoft\` are checked too (a common hiding place), and for script hosts (`cmd`, `powershell`, `mshta`, `rundll32`...) the arguments are checked, not only the program.
- **Scan, Defender exclusions**: extension exclusions such as `exe` or `dll` are flagged as suspicious, the counts in the flag are right, and the 90-day history also shows added extension and IP exclusions.
- **Scan, detections**: a recent Defender detection is flagged even when Defender gives no name for it.
- **Scan, file walk**: a vendor name somewhere in the path (`GoogleUpdater.exe`, a folder named `Cache`) no longer hides a file. ProgramData is walked first, so the time budget cuts the least important folders.
- **Scan, report**: the head now says what was not checked (`NOT CHECKED`, `COULD NOT READ`), so "none" is not read as a clean bill of health. If the report cannot be written, the `.partial` file is kept and the message says so instead of "Done".
- Tests: unit tests for the scan's rules (`tests/scan-rules.Tests.ps1`) and for the regional formats.

## v1.0.0 - 2026-10-25

First public release.

- **Scannx.cmd**: one double-click launcher with a menu (full scan, quick scan, stutter log, summarize an old log). Asks for administrator rights itself.
- **scan-check.ps1**: read-only malware and health check. Defender state, exclusions (including exclusions planted as policy) and their history, detections, autostart, scheduled tasks, services, persistence spots, hosts and proxy, miner hiding spots, Discord `index.js`, disk errors, remote-access and crack-type software, and a time-boxed file walk for miner/proxyware markers. FLAGS on top of the report.
- **disk-log.ps1**: stutter logger with a summary and a verdict: memory pressure, commit charge, game memory trimming, disk latency, CPU/GPU load, CPU clock drops, network loss and lag, GPU thermal throttling, and frame-time hitches from PresentMon. Press F9 to mark a stutter; each mark gets its own diagnosis.
- Frame times: the zip bundles Intel PresentMon 2.3.1 (MIT, SHA256-checked at build time). Loading screens at the start and the end are cut out by frame rate.
