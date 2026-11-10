# Scannx-Tools: plan

Status 2026-11-10: **v1.0.0** is the public release; the fixes from a full review are on `main` and wait for **v1.0.1** (see `CHANGELOG.md`, "Unreleased").
Each step stays small and checkable: change, test, update this file and `CHANGELOG.md`, commit. Who works where: [AGENTS.md](../AGENTS.md).

## Done since v1.0.0

- Stutter log: fixed number and time formats (a decimal-comma Windows broke `log.csv`).
- Scan: services, scheduled tasks, Defender exclusions, detections and the file walk filters tightened; the report says what was not checked.
- Scan rules have unit tests (`tests/scan-rules.Tests.ps1`), mutation-checked: 17 broken copies of the rules, every one fails a test.

## Open from the review (next)

1. **Tests for the stutter verdicts that have none** (in progress on a `codex/*` branch, see [docs/CODEX.md](CODEX.md)): DISK latency, GPU above 95 %, CPU above 90 %, the paging/DISK/CPU/GPU causes of an F9 mark, the two halves of the memory rule, the trimming rule, `summary.txt` itself, a log without a detected game.
2. A log that runs across midnight gives a **wrong verdict** (the launch is not cut and memory gets the blame), not just missing rows. Fix: add 86400 s to the rows after the wrap.
3. When the game process is not found, the verdict covers the idle desktop too and can say "no trouble visible". Say "game not found" in the verdict.
4. Launcher: say "unzip first" when the scripts are not next to `Scannx.cmd`; call `powershell` and `fltmc` by full path.
5. Smaller: autostart values whose name starts with `PS` are skipped; bare `cmd`/`rundll32` autostarts are reported as "missing file"; `Crack`/`Xeno`/`KMS` match game names; the hardware flag counts warnings; flags do not say what to do next; no feedback when F9 is pressed.

## Known limits

- The stutter log uses English performance-counter names; Windows with translated counter names may stop with "Cannot read performance counters". (Idea: `PdhAddEnglishCounter`.)
- The 90-day exclusion history reads the English text of Defender event 5007.
- Loading screens in the middle of a session count as play; a short session where loading takes about half the time is not trimmed.
- The ping reaches the router and 1.1.1.1, not the game server.
- Ctrl+C inside the launcher ends with cmd's "Terminate batch job (Y/N)?"; answer N to get back to the menu.
- The anti-cheat hint only recognises EA AntiCheat. PresentMon's fix for anti-cheat (2.5 and later) is in its service only, not in the console program that Scannx bundles, so "start before the game" stays.
- The stutter verdict tests cover the CPU clock, GPU throttle bits, ping, frame hitches and loading cuts; the rules in "Open" item 1 are not covered yet.
- Scripts are not code-signed (SmartScreen warns on first run). GitHub Actions are pinned by tag, Pester comes from the PowerShell Gallery without a hash.

## Ideas (not planned yet)

- Scan: command lines of autostarts and services, more Run keys, signs of protection being switched off (Defender settings and events, Windows Update services, Win+R history), processes with a system name in the wrong folder, kernel drivers, browser extensions, a saved baseline, `-Json` output.
- Stutter log: DPC/interrupt time, the busiest single core, VRAM overflow into shared memory, CPU-side vs GPU-side hitches from PresentMon's busy times, a snapshot of power plan / memory speed, a frame log from NVIDIA FrameView as a second source.
- Release: build provenance (artifact attestation), immutable releases, actions pinned by commit, `SECURITY.md`.
- Measure the connection to the game server itself.

## How to release

1. Rename "Unreleased" in `CHANGELOG.md` to `## vX.Y.Z - <date>`.
2. Optional: run the `release` workflow by hand; it builds the zip as an artifact only.
3. `git tag vX.Y.Z` and `git push origin vX.Y.Z`: CI tests, builds `Scannx-vX.Y.Z.zip` and publishes the GitHub release.
