# Codex: onboarding and current task

Read in this order: `AGENTS.md` (rules), this file, `README.md` (what the tool does and what each verdict means), `docs/NEXT.md`.

## How the stutter-log tests work

- `disk-log.ps1 -Summarize <run folder>` reads `log.csv`, `events.txt` and (if present) `frames.csv` from a run folder and prints the summary with the verdict. All verdict logic is in the function `Write-Summary`; nothing else runs with `-Summarize`.
- `tests/make-fixtures.ps1` builds synthetic run folders into `tests/fixtures/<name>/`. The fixtures are committed: after changing the script, run it and commit the result.
- `tests/disk-log.Tests.ps1` copies a fixture to a temp folder, runs `-Summarize` on it and matches the printed text (`Summarize 'name'`).
- Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester tests\disk-log.Tests.ps1`. All tests are green on `main`.

## Task C1: tests for the verdict rules that have none

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

Done means: every row has its tests, `Invoke-Pester tests` is green, and the PR lists for each new test which change to `disk-log.ps1` makes it fail (break the rule in a scratch copy outside the repo, run the test, write down the result). A test that cannot fail is not done.

If a test shows that `disk-log.ps1` itself is wrong, do **not** change the script: describe the finding in the PR under "Findings" (file:line, the fixture that shows it, expected and actual text).

### File lane for C1

- Yours: `tests/make-fixtures.ps1`, `tests/fixtures/**`, `tests/disk-log.Tests.ps1`. Claude does not touch these while your PR is open.
- Not yours: everything else, in particular `disk-log.ps1`, `scan-check.ps1`, `tests/scan-rules.Tests.ps1`, `.github/`.
- Branch: `codex/verdict-tests`, from `main`. One pull request into `main`. CI runs on the PR (Windows PowerShell 5.1, Pester 3.4).

### Pull request text

```
What: <one line>
Why: review finding "verdict rules without tests" (docs/CODEX.md, task C1)
Evidence: Invoke-Pester result (passed/failed counts); table "test -> the change that makes it fail"
Findings: <bugs in disk-log.ps1 the tests showed, or "none">
Not verified: <what you did not run or could not check>
```

## Later (not started; wait for the owner)

- C2: an independent review of the scan rule changes after v1.0.0 (`scan-check.ps1`, `tests/scan-rules.Tests.ps1`): ways around each rule, false positives on an ordinary gaming PC.
