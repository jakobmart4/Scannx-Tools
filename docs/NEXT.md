# Scannx-Tools: plan

Status 2026-11-13: **v1.0.0** is the public release; the fixes from a full review, the new verdict tests and the hardened release are on `main` and wait for **v1.0.1** (see `CHANGELOG.md`, "Unreleased").
Each step stays small and checkable: change, test, update this file and `CHANGELOG.md`, commit. Who works where: [AGENTS.md](../AGENTS.md); task list for the second AI agent: [docs/CODEX.md](CODEX.md).

## Done since v1.0.0

- Stutter log: fixed number and time formats (a decimal-comma Windows broke `log.csv`).
- Scan: services, scheduled tasks, Defender exclusions, detections and the file walk filters tightened; the report says what was not checked.
- Stutter log: NVIDIA FrameView per-frame logs as a second frame source (`tests/frameview.Tests.ps1`, synthetic). **Not yet tried on a real FrameView capture**: the first real log decides whether the file-name time is the capture start and whether any column is quoted.
- Scan rules have unit tests (`tests/scan-rules.Tests.ps1`), mutation-checked: 17 broken copies of the rules, every one fails a test.
- Every stutter verdict has isolated tests with near misses (task C1): 82 mutants of the summary, 80 killed; the two survivors are in C4a.
- Independent review of the above: `docs/reviews/2026-11-codex.md` (task C2), 8 findings, all reproduced; they are in C4a and C4b.
- Release trust chain (task C3): actions pinned by commit, Dependabot, least permissions, `SECURITY.md`, build provenance, forward-slash zip entries, LF `.sha256`, Intel signature check, CHANGELOG check before the build.

## Next (assigned in [docs/CODEX.md](CODEX.md), wave 2)

- **C4a, stutter log and launcher**: a log across midnight gives a wrong verdict; "game not found" must be said in the verdict; one lost ping is not a network problem; the launcher started from inside the zip; an empty `frames.csv` blocks a FrameView log; FrameView logs of other programs; quoted CSV fields; the test gaps left from C1.
- **C4b, scan**: `PS*` autostart names; bare `cmd`/`rundll32` reported as missing; crack and software names matching games; `$badEx` false positives; hardware flag counts warnings; `Userinit` on another drive; policy exclusions without admin; the real Desktop and Downloads; "Done" for a half-written report; unreadable folders in the file walk; the Defender folder exemption; miner task names under `\Microsoft\`; `ProgramData` matching a file name.
- **C5, RivaTuner probes** (draft PR): raise the accepted shared-memory version to 2.21, then a live run on a PC with RTSS.
- Smaller, not assigned: flags do not say what to do next; no feedback when F9 is pressed.

## Before the v1.0.1 tag

1. Run the `release` workflow by hand once (it has never run since the release changes): it must build the zip as an artifact; the Intel signature check on the hosted runner is the open question.
2. Owner: turn on private vulnerability reporting (the link in `SECURITY.md` needs it).
3. Rename "Unreleased" in `CHANGELOG.md` to `## v1.0.1 - <date>`: the release workflow now stops without a matching, non-empty section.

## Known limits

- The stutter log uses English performance-counter names; Windows with translated counter names may stop with "Cannot read performance counters". (Idea: `PdhAddEnglishCounter`.)
- The 90-day exclusion history reads the English text of Defender event 5007.
- Loading screens in the middle of a session count as play; a short session where loading takes about half the time is not trimmed.
- The ping reaches the router and 1.1.1.1, not the game server.
- Ctrl+C inside the launcher ends with cmd's "Terminate batch job (Y/N)?"; answer N to get back to the menu.
- The anti-cheat hint only recognises EA AntiCheat. PresentMon's fix for anti-cheat (2.5 and later) is in its service only, not in the console program that Scannx bundles, so "start before the game" stays.
- Scripts are not code-signed (SmartScreen warns on first run); the launcher is a `.cmd` and cannot carry a signature. Trust path: the release's build provenance and its SHA256.
- Pester and PSScriptAnalyzer come from the PowerShell Gallery by version, without a hash.
- One release job holds the write permissions for the whole run; splitting it into build and publish would be tighter.

## Ideas (not planned yet)

- Scan: command lines of autostarts and services, more Run keys, signs of protection being switched off (Defender settings and events, Windows Update services, Win+R history), processes with a system name in the wrong folder, kernel drivers, browser extensions, a saved baseline, `-Json` output.
- Stutter log: DPC/interrupt time, the busiest single core, VRAM overflow into shared memory, CPU-side vs GPU-side hitches from PresentMon's busy times, a snapshot of power plan / memory speed, RivaTuner Statistics Server as a frame source and for on-screen feedback.
- Release: immutable releases and branch rules (repository settings, owner).
- Measure the connection to the game server itself.

## How to release

1. Rename "Unreleased" in `CHANGELOG.md` to `## vX.Y.Z - <date>`.
2. Run the `release` workflow by hand with that version; it builds the zip as an artifact only.
3. `git tag vX.Y.Z` and `git push origin vX.Y.Z`: CI checks the CHANGELOG section, tests, builds `Scannx-vX.Y.Z.zip`, attests it and publishes the GitHub release.
