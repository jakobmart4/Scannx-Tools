# Rules for AI agents working in this repo

Scannx is a small **read-only** Windows tool: `scan-check.ps1` (malware and health scan), `disk-log.ps1` (game stutter logger) and the launcher `Scannx.cmd`. Read `README.md` and `docs/NEXT.md` first.

## What must stay true

- **Read-only.** The scripts change nothing on the user's PC. They write only their own reports and logs. No new network calls. The one exception is `experiments/`: probes for a future app that never ship in the release zip; what a probe touches is written at its top and it undoes it when it ends.
- **Windows PowerShell 5.1**, nothing to install: no modules, no newer syntax (`??`, `?.`, ternary, `&&`), no `pwsh`-only cmdlets.
- **Tests use Pester 3.4** syntax (`Should Match`, `Should Be`, `Should Not Match`), the Pester that ships with Windows. Run: `Invoke-Pester tests`.
- **No real data in the repo.** Fixtures are synthetic and made by `tests/make-fixtures.ps1`. A real report or log holds a user name, paths and measurements of someone's PC: never commit one, never paste one into an issue or a PR.
- Code and comments in English. A comment says why, or what went wrong before; not what the next line does.
- No speculative features, no new files or abstractions without a need. The scripts are short on purpose.
- A test must be able to fail: break the rule it covers in a scratch copy and see the test go red. Never weaken or delete a test to get green.

## Who does what

| Who | Does |
|---|---|
| Owner | Decides: merges, releases, tags, what goes into the tool |
| Claude Code | `scan-check.ps1`, `disk-log.ps1`, `Scannx.cmd`, `tools/`, `.github/`, `README.md`, `CHANGELOG.md`, `docs/NEXT.md` |
| Codex | Independent reviews, tests and fixtures, the release workflow, and fixes in files handed over for a task, in its own `codex/*` branches. Tasks and the file lane of each: `docs/CODEX.md` |

- A file belongs to one agent at a time. When a Codex task lists one of Claude's files (for example `disk-log.ps1` in task C4a), Claude leaves it alone until that pull request is merged or closed.
- One branch and one pull request per task. Never push to `main` or to another agent's branch (the one exception is written in `docs/CODEX.md`), never merge, never tag or release.
- Stay in your file lane. Outside it: write the finding into the PR (file:line, evidence), do not fix it.
- Disagreement: both views with evidence in the PR; the owner decides.
