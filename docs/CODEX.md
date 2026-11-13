# Codex: onboarding and tasks

Read in this order: `AGENTS.md` (rules), this file, `README.md` (what the tool does and what each flag and verdict means), `docs/NEXT.md`.

## Cloud: what you cannot run

The scripts and tests target **Windows PowerShell 5.1** and Pester 3.4, and the tests start `powershell.exe`. A Linux cloud container has neither, and it cannot see a Windows PC, a game, RivaTuner or FrameView.

- Do not rewrite a test or a script so that it runs on your side (`pwsh`, another Pester). CI on the pull request (`windows-latest`, Windows PowerShell 5.1, Pester 3.4) is the test run.
- Say it in the PR under "Not verified": what you could not run. Never write "tested" or "verified" for something only CI or nobody has run.
- "A test must be able to fail" still holds. For each new test, name the change to the script that should make it fail. Claude runs that check on a Windows machine before the owner merges, and comments on the PR if a test survives.
- If CI is red on your PR, read the failed step, fix it with a new commit (no force-push), at most two rounds; then stop and describe what you found.

## Tasks

One branch and one pull request per task. The file lanes do not overlap inside a wave, so a wave can run in parallel.

| Task | What | Branch | Your files | Wave |
|---|---|---|---|---|
| C1 | Tests for the stutter verdict rules that have none | `codex/verdict-tests` | `tests/make-fixtures.ps1`, `tests/fixtures/**`, `tests/disk-log.Tests.ps1` | 1 |
| C2 | Independent review of the changes after v1.0.0 | `codex/review-v1.0.1` | only the new file `docs/reviews/2026-11-codex.md` | 1 |
| C3 | Release trust chain | `codex/release-trust` | `.github/**`, `tools/build-release.ps1`, `SECURITY.md` | 1 |
| C5 | RivaTuner Statistics Server probes (code only) | `codex/rtss-probes` | `experiments/**` (new folder) | 1 |
| C4a | Stutter-log and launcher fixes with tests | `codex/disklog-fixes` | `disk-log.ps1`, `Scannx.cmd`, `tests/disk-log.Tests.ps1`, `tests/frameview.Tests.ps1`, `tests/make-fixtures.ps1`, `tests/fixtures/**` | 2 |
| C4b | Smaller scan fixes with tests | `codex/scan-minor` | `scan-check.ps1`, `tests/scan-rules.Tests.ps1` | 2 |

Wave 2 starts only when the owner says so: after C1 is merged (C4a edits the same test files) and after the C2 review has been read (its confirmed findings go into C4b). For wave 2 Claude hands `disk-log.ps1`, `Scannx.cmd` and `scan-check.ps1` over and does not touch them while the PR is open.

Never yours: `README.md`, `CHANGELOG.md`, `docs/NEXT.md`, `AGENTS.md`, this file. A change they need goes into the PR text as a proposal.

### Pull request text (every task)

```
What: <one line>
Why: docs/CODEX.md, task <C1..C5>
Evidence: <CI run result; for tests the table "test -> the change to the script that should make it fail">
Findings: <bugs or doubts outside your file lane, with file:line; or "none">
Not verified: <what you did not run or could not check>
```

## How the stutter-log tests work

- `disk-log.ps1 -Summarize <run folder>` reads `log.csv`, `events.txt` and, if present, `frames.csv` or a `FrameView_*_Log.csv` from a run folder and prints the summary with the verdict. All verdict logic is in the function `Write-Summary`; nothing else runs with `-Summarize`.
- `tests/make-fixtures.ps1` builds synthetic run folders into `tests/fixtures/<name>/`. The fixtures are committed and CI does not regenerate them: after changing the script, the generated files must be committed too. If your environment has PowerShell 7, `pwsh tests/make-fixtures.ps1` produces the same content (only the byte-order mark can differ; that is fine). If it has no PowerShell, commit the script change alone and say so under "Not verified": Claude then runs the script on Windows and adds one commit "Regenerate fixtures" to your branch (the one case where Claude pushes to a `codex/*` branch).
- `tests/disk-log.Tests.ps1` copies a fixture to a temp folder, runs `-Summarize` on it and matches the printed text (`Summarize 'name'`). `SummarizeIn` does the same under another regional format.
- The scan's rules are small functions and regex variables in `scan-check.ps1`; `tests/scan-rules.Tests.ps1` loads only those definitions through the script's syntax tree and calls them. A new rule to test goes into the `$vars` or `$funcs` list at the top of that file.

## C1: tests for the verdict rules that have none

A review found that these rules of `Write-Summary` can be deleted without any test failing. Add one fixture per rule that isolates it (everything else healthy) and one near miss that must **not** fire it. Keep the existing fixtures and tests as they are.

| # | Rule (search for this text in `disk-log.ps1`) | Fixture that must fire it | Near miss that must not |
|---|---|---|---|
| 1 | `DISK $d latency up to` (a disk slower than 50 ms) | latency 80 ms in exactly 3 rows; assert the value and "3 samples over 50 ms" | latency exactly 50 ms |
| 2 | `GPU above 95 %` (at least 3 % of the samples) | `gpuMaxPct` 99 in 3 % of the rows | 2 % of the rows; a value over 100 (counter glitch) must be ignored |
| 3 | `CPU above 90 %` (at least 3 % of the samples) | `cpu` 95 in 3 % of the rows | 2 % of the rows |
| 4 | `$memBad`, first half: available RAM under 1000 MB | `availMB` 900, `pgIn` low, commit 60 % | `availMB` exactly 1000 |
| 5 | `$memBad`, second half: paging over 50 000 pages/s | `availMB` 4000, `pgIn` 60000 | `pgIn` exactly 50000 |
| 6 | `COMMIT charge reached` (95 % or more) | `commitPct` 95 | 94.9 |
| 7 | `Windows trimmed the game's memory` | available RAM 1500 MB, game memory 7000 falling to 4000 after its peak | (a) game memory only rising 2000 to 7000: no trimming line; (b) the same fall with available RAM 3000 MB: no line; (c) a fall to exactly 80 % of the peak: no line |
| 8 | F9 mark causes `RAM/paging` by paging alone, `DISK`, `CPU`, `GPU` | one mark per cause, the cause within 3 rows of the mark | the cause 4 rows away from the mark; check both sides of the window |
| 9 | Header counts `marks (F9): N` and `auto spikes: N` | assert both numbers | |
| 10 | `summary.txt` is written | read the file in the temp folder before it is removed; it must hold the same verdict as the printed text | |
| 11 | No game process in the log (`gameOn` is 0 in every row) | header says `game NOT detected: all rows` | |
| 12 | Game starts in the middle of the log (rows with `gameOn` 0, then 1) | only the game rows are used | |
| 13 | Frame statistics at a high frame rate | 5 ms frames (200 fps) with a few 10 ms frames (no hitch: the floor is 25 ms) and one 40 ms frame (a hitch); a 2 % tail so that p99 differs from the median | |

Done means: every row has its tests, CI is green on the PR, and the PR lists for each new test the change to `disk-log.ps1` that should make it fail. If a test shows that `disk-log.ps1` itself is wrong, do **not** change the script: describe it under "Findings" (file:line, the fixture that shows it, expected and actual text).

## C2: independent review of the changes after v1.0.0

Review the three code commits on `main` after tag `v1.0.0`: the regional-format fix in `disk-log.ps1`, the scan rule changes in `scan-check.ps1` with `tests/scan-rules.Tests.ps1`, and the NVIDIA FrameView import with `tests/frameview.Tests.ps1` (`git log v1.0.0..main`). Change no code. Write one file, `docs/reviews/2026-11-codex.md`.

Look for:
- **Ways around each scan rule**: `TaskOdd`, `SvcOdd`, `BadExclusions`, `ThreatNames`, `$trusted`, `$prune`, `TryRead`, `Finish`. What does a renamed file, another folder, another registry value or an odd command line get past?
- **False positives on an ordinary gaming PC**: Steam, Epic, Discord, NVIDIA and OEM tools, anti-cheat services, VPN and Tailscale, developer tools. A rule that fires on most PCs teaches the user to ignore the flags.
- **Bugs**: Windows PowerShell 5.1 behaviour (aliases win over functions, `@($null).Count` is 1, culture-sensitive `-join` and `.ToString()`), unanchored regexes, an error path that prints "Done" or "none".
- **FrameView import**: the start time taken from the file name, the midnight wrap, quoted CSV fields, a log with several swap chains or several captures, `NA` cells, what happens when both `frames.csv` and a FrameView log exist.
- **Tests that cannot fail** or that would pass with the rule deleted.

Each finding: `file:line`, what is wrong, the input that shows it, confidence (`checked`: you traced it in the code and can give the exact input; `guess`: reasoning only, plus what would confirm it), severity (blocker / major / minor) and a minimal fix. End with "Not verified" and with "Looked at and found fine". Do not list style or taste; do not repeat `docs/NEXT.md` "Known limits" and "Open from the review".

## C3: release trust chain

The release zip is built by `.github/workflows/release.yml` with `tools/build-release.ps1`. Tighten it without changing what the user downloads (same file names inside the zip, same PresentMon 2.3.1 with the same SHA256).

1. Pin every `uses:` to a full commit SHA with the tag in a comment (`actions/checkout@<sha> # v4.x.y`). Take each SHA from the action's own repository; an annotated tag must be dereferenced to its commit. Put a table "action -> SHA -> tag -> where you read it" into the PR.
2. `permissions: contents: read` at the top of both workflows; in `release.yml` only the job that publishes gets `contents: write` (plus what step 6 needs).
3. `.github/dependabot.yml` for `github-actions`, weekly.
4. Pin PSScriptAnalyzer in `ci.yml` to the version CI installs today (`-RequiredVersion`); say in the PR which version and how you found it.
5. `SECURITY.md`: the latest release is supported; report through GitHub's private vulnerability reporting; what is in scope (a script that changes the system, sends data out or runs something it should not) and what is not (a missed detection is an ordinary issue).
6. Build provenance for the zip on tag builds only: `actions/attest-build-provenance` (SHA-pinned) with `id-token: write` and `attestations: write`; the PR text proposes the README sentence with `gh attestation verify`.
7. `tools/build-release.ps1`: zip entries with forward slashes (Windows PowerShell 5.1 `CreateFromDirectory` writes `Scannx-vX\file`; create the entries one by one with `Scannx-vX/file`), the `.sha256` file with LF and no BOM (`[IO.File]::WriteAllText`), and a check that the PresentMon exe has a valid Authenticode signature from Intel Corporation (the stutter log refuses it otherwise).
8. `release.yml`: read `CHANGELOG.md` as UTF-8 (`[IO.File]::ReadAllText`), and check that the tag's section exists and is not empty **before** the tests and the build, also on a manual run with a version input.

Not yours and not possible from a PR: repository settings (branch protection, immutable releases, secret scanning). List them in the PR text as "for the owner". Do not add third-party actions other than the ones named here. The manual `release` run on your branch is started by Claude with the owner's go-ahead.

## C5: RivaTuner Statistics Server probes

Planning for a future app (not part of the released tool). RTSS publishes per-application frame statistics and an on-screen display (OSD) through a shared memory block named `RTSSSharedMemoryV2`. Two small **experiments**, to be run by Claude on a PC that has RTSS; you only write them.

- `experiments/rtss-read.ps1`: open the mapping read-only (`[IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting`), check the signature, print the version, then every application entry that has a process ID: process ID, name, frame time and the frame-rate counters. `-Seconds N` repeats once a second. RTSS not running, or an unknown version: one clear line, exit code 1.
- `experiments/rtss-osd.ps1`: take a free OSD slot (owner name `Scannx`), show one line of text for 10 seconds, then clear the text and release the slot, also on Ctrl+C (`try`/`finally`). If no slot is free, say so and change nothing. Never touch a slot owned by another program.
- `experiments/README.md`: what each probe answers, how to run it, the layout you used (offsets and field sizes by version) and **where each offset comes from** (the SDK header that ships with RTSS, public documentation, another open-source reader: give the link). Do not copy the SDK header or other third-party source into the repo.

Windows PowerShell 5.1, no modules, no compiled helper beyond `Add-Type` if a struct needs it. Read every offset from the header fields (`dwAppEntrySize`, `dwAppArrOffset`, `dwOSDEntrySize`, `dwOSDArrOffset` and the like), never hard-code an array position. The OSD probe writes into RTSS's memory on purpose; that is allowed in `experiments/` only (see `AGENTS.md`). "Not verified" must say that nothing was run.

## C4a (wave 2): stutter-log and launcher fixes

Each with its fixture and test, in the style of C1.

1. **Midnight**: a log that runs across 00:00 gives a wrong verdict, because times are seconds of the day (`$secs`). After reading the rows, add 86400 to every row after the wrap, and use that everywhere a time is compared. The existing `midnight` fixture (a skewed PresentMon clock) must stay green.
2. **Game not found**: when no row has `gameOn` 1, the verdict covers the idle desktop. Put a first verdict line that says so and how to find the process name (Task Manager, Details tab); the "no trouble visible" line must not appear alone.
3. **NETWORK from one lost ping**: `$lossPct -ge 1` fires on a single lost ping in a short log. Require at least 3 lost pings as well.
4. **Launcher** (`Scannx.cmd`): when `scan-check.ps1` is not next to it (started from inside the zip), print "unzip first" and pause; call `fltmc` and `powershell` by full path under `%SystemRoot%\System32`. Keep the file CRLF. No test harness exists for the launcher: describe exactly what you changed and leave it under "Not verified".

From the C2 review (`docs/reviews/2026-11-codex.md`, all reproduced on Windows; tests go into `tests/frameview.Tests.ps1`):

5. **An unusable `frames.csv` blocks FrameView** (review finding 1): an empty or header-only `frames.csv` (PresentMon was blocked) selects the PresentMon branch by `Test-Path` alone, so a valid FrameView log next to it is never read and the summary says "next step: PresentMon". Read PresentMon first; when it gives no frames and FrameView logs exist, read those. Tests: an empty and a header-only `frames.csv`, each next to a valid FrameView log.
6. **FrameView logs of other applications** (finding 2): every `FrameView_*_Log.csv` in the run folder is read and the swap chain with the most frames wins, so the verdict can come from another program; the same swap chain address in two files mixes their frames. Key the frames by application (the `Application` column, or the exe in the file name) plus swap chain. When a `-Game` name matches an application, use only that one; otherwise take the application with the most frames inside the time span of the log's game rows. Name the application in the `frame source` line. The copy at the end of a live run takes only the logs of the logged game when one of its names matches. Tests: a second application with more frames; the same swap chain address in both files; two captures of the same game (they must still combine).
7. **Quoted CSV fields** (finding 8): `Split(',')` shifts the columns when a field holds a quoted comma (`"Game, Deluxe"`); with a full header the summary then shows plausible but wrong numbers. Split with quotes respected (a doubled quote inside a quoted field is one quote). Tests: a quoted comma and a doubled quote in the application name; the numbers must equal the unquoted case.

Left over from the acceptance of C1 (tests only):

8. The two surviving mutants: `fast-frames` needs one frame faster than the median, so that `$fMed = $srt[0]` fails a test; add a fixture with game rows where every row is cut from the used rows (game memory under 200 MB throughout), so that `$use = @($rows)` fails one.
9. F9 mark causes at their edges: disk exactly 50 ms, cpu exactly 90 %, gpu exactly 95 %, paging exactly 5000 pages/s must **not** give the cause; a GPU value over 100 inside the mark window (counter glitch) must be ignored.

## C4b (wave 2): smaller scan fixes

Each as a small pure function or regex variable with tests in `tests/scan-rules.Tests.ps1`.

1. Autostart values: `Where-Object Name -notmatch '^PS'` also drops a real value named `PSUpdate`. Exclude only `PSPath`, `PSParentPath`, `PSChildName`, `PSDrive`, `PSProvider`.
2. `ExeOf` and "missing file": a bare `cmd.exe`, `rundll32.exe` or `powershell.exe` is looked up relative to the current folder and reported missing. Resolve bare names through `Get-Command -CommandType Application`; do not call `Test-Path` on a UNC path (`\\host\share`), flag "autostart points to a network path" instead.
3. Software and crack names: `Crack`, `Xeno`, `KMS`, `executor` as substrings match `Crackdown`, `Xenoblade`, `ThreadPoolExecutor`. Use word boundaries and exact names, and skip uninstall keys named `Steam App <number>`.
4. `$badEx`: the hex-folder part matches date folders (`20251109`) and `miner` matches `Examiner`. Require upper-case hex with at least one letter, and `miner` as a word.
5. Hardware flag: count only Level 1 and 2 events (not warnings).
6. Winlogon `Userinit`: accept any drive letter of the Windows folder, not only `C:`.
7. Policy exclusions: read `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions` without admin too (it is readable); only `Get-MpPreference`'s list needs admin.
8. Desktop and Downloads: use the real folders (`[Environment]::GetFolderPath('Desktop')`; Downloads from `HKCU\...\Explorer\User Shell Folders`, value `{374DE290-123F-4565-9164-39C4925E467B}`), not `%USERPROFILE%\Desktop`.

From the C2 review (`docs/reviews/2026-11-codex.md`, all reproduced on Windows; confirmed by the owner):

9. **`Finish` says "Done" for half a report** (finding 3): when `Out-File` writes part of the output and then throws, the `catch` swallows the error, the file is non-empty and fresh, so `.partial` is removed and "Done" is printed. Remember the failure in the `catch` and keep `.partial` unless the write succeeded. Test: a write that leaves a non-empty file and then fails (mock `Out-File`).
10. **File walk drops unreadable folders silently** (finding 4): a folder is popped before it is read; access denied or any other error is swallowed by an empty `catch`, so the report says "left unvisited: 0" and nothing appears under `COULD NOT READ`. Count those folders, keep the first few names, and print one line in the file-walk section plus one entry in the report head (one line with the count, not one per folder: an ordinary PC has several). Move the loop body into a small function so that a test can feed it a folder that throws.
11. **The Defender folder exempts any file** (finding 5; minor, writing there needs admin): `TaskOdd` returns early for anything under `ProgramData\Microsoft\Windows Defender\` and `$sysSvc` trusts the whole folder. Limit the exemption to Defender's own programs under `Platform\<version>\` (for example `MsMpEng.exe`, `MpCmdRun.exe`, `NisSrv.exe`); take the full list from Microsoft's documentation and say in the PR where it comes from. Tests: `evil.exe` there is flagged as a task and as a service; the real names are not.
12. **Miner task names under `\Microsoft\`** (finding 6): the name check sits in the `elseif` and is skipped for every task under `\Microsoft\`. Check the name for all tasks.
13. **`$odd` matches a file name** (finding 7): the unanchored `ProgramData` flags `C:\Program Files\Vendor\ProgramDataHelper.exe`. Anchor it to the folder (`^"?[A-Z]:\\ProgramData\\`); keep `\Temp\` and `\Users\Public` as folder parts. `$odd` is also used for autostart entries and for script-host arguments, where the path is not at the start of the string: keep those working (a path inside an argument string must still match) and cover both uses with tests.
