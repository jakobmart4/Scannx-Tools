# Static tests for Scannx.cmd. The launcher is read as bytes and as text and is never started:
# running it asks for administrator rights. A change to these rules must fail here, not on UAC.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcherPath = Join-Path (Split-Path -Parent $here) 'Scannx.cmd'
if (-not (Test-Path -LiteralPath $launcherPath)) { throw "Scannx.cmd not found: $launcherPath" }

$launcherBytes = [IO.File]::ReadAllBytes($launcherPath)
# Latin-1 maps every byte to one character, so nothing is lost or guessed on the way to text.
$launcherText = [Text.Encoding]::GetEncoding(28591).GetString($launcherBytes)
$launcherLines = @($launcherText -split "`r`n")

# Comment, echo and label lines never start a program; the rest carries the calls.
function Get-LauncherCodeLines([string[]]$lines) {
  $code = @()
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $text = $lines[$i].Trim()
    if ($text -eq '') { continue }
    if ($text -match '(?i)^(rem|::)\b') { continue }
    if ($text -match '(?i)^echo\b') { continue }
    if ($text -match '^:') { continue }
    $code += [pscustomobject]@{ Number = $i + 1; Text = $text }
  }
  return $code
}

Describe 'Scannx.cmd, read as text only' {
  It 'stores the launcher with CRLF line endings and without a bare LF' {
    $crlf = 0
    $bareLf = 0
    $bareCr = 0
    for ($i = 0; $i -lt $launcherBytes.Length; $i++) {
      $byte = $launcherBytes[$i]
      if ($byte -eq 0x0D) {
        if ($i + 1 -lt $launcherBytes.Length -and $launcherBytes[$i + 1] -eq 0x0A) {
          $crlf++
          $i++
        } else {
          $bareCr++
        }
      } elseif ($byte -eq 0x0A) {
        $bareLf++
      }
    }
    if ($launcherBytes.Length -eq 0) { throw 'Scannx.cmd is empty' }
    if ($bareLf -gt 0 -or $bareCr -gt 0) {
      throw "Scannx.cmd has $bareLf bare LF and $bareCr bare CR bytes: cmd.exe reads an LF-only file and the labels break"
    }
    if ($crlf -eq 0) { throw 'Scannx.cmd has no CRLF line ending at all' }
    $crlf -gt 0 | Should Be $true
  }

  It 'starts fltmc and PowerShell only through %SystemRoot%\System32 paths' {
    $code = Get-LauncherCodeLines $launcherLines
    $fltmcLines = @($code | Where-Object { $_.Text -match '(?i)\bfltmc' })
    $powershellLines = @($code | Where-Object { $_.Text -match '(?i)powershell' })
    $psVariable = @($code | Where-Object { $_.Text -match '(?i)^set PS=' })
    $problems = @()

    # A rule that finds nothing cannot fail; both programs must still be called.
    if ($fltmcLines.Count -eq 0) { $problems += 'the launcher no longer calls fltmc' }
    if ($powershellLines.Count -eq 0) { $problems += 'the launcher no longer calls powershell' }

    foreach ($line in $fltmcLines) {
      if ($line.Text -notmatch '(?i)%SystemRoot%\\System32\\fltmc\.exe') {
        $problems += "line $($line.Number) calls fltmc without the full path: $($line.Text)"
      }
    }
    foreach ($line in $powershellLines) {
      if ($line.Text -notmatch '(?i)%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe') {
        $problems += "line $($line.Number) calls powershell without the full path: $($line.Text)"
      }
    }
    # Every menu choice runs through %PS%, so that variable has to carry the full path as well.
    if ($psVariable.Count -ne 1) {
      $problems += "expected one 'set PS=' line, found $($psVariable.Count)"
    } elseif ($psVariable[0].Text -notmatch '(?i)^set PS="%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File$') {
      $problems += "the PS variable does not start from `"%PSEXE%`": $($psVariable[0].Text)"
    }

    if ($problems.Count -gt 0) {
      throw ("the launcher does not use full paths`n" + ($problems -join "`n"))
    }
    $problems.Count | Should Be 0
  }

  It 'has an "unzip first" branch that pauses and fails before any menu call' {
    $guardIndex = -1
    for ($i = 0; $i -lt $launcherLines.Count; $i++) {
      if ($launcherLines[$i] -match '(?i)^\s*if not exist "%~dp0scan-check\.ps1"') { $guardIndex = $i; break }
    }
    if ($guardIndex -lt 0) { throw 'no "if not exist scan-check.ps1" guard: started from inside the zip it would call a missing script' }

    # The branch runs until the closing parenthesis of the if block.
    $block = @()
    for ($i = $guardIndex + 1; $i -lt $launcherLines.Count; $i++) {
      $text = $launcherLines[$i].Trim()
      if ($text -eq ')') { break }
      $block += $text
    }
    $problems = @()
    if (@($block | Where-Object { $_ -match '(?i)Unzip first' }).Count -eq 0) { $problems += 'the guard does not say "Unzip first"' }
    if (@($block | Where-Object { $_ -match '(?i)^pause$' }).Count -eq 0) { $problems += 'the guard does not pause, so a double-click closes the window' }
    if (@($block | Where-Object { $_ -match '(?i)^exit /b' }).Count -eq 0) { $problems += 'the guard does not leave with an exit code' }

    # The guard has to come before the first script call, or the menu runs anyway.
    $firstCall = -1
    for ($i = 0; $i -lt $launcherLines.Count; $i++) {
      if ($launcherLines[$i] -match '(?i)%PS%') { $firstCall = $i; break }
    }
    if ($firstCall -ge 0 -and $firstCall -lt $guardIndex) {
      $problems += "the guard sits at line $($guardIndex + 1), after the first script call at line $($firstCall + 1)"
    }

    if ($problems.Count -gt 0) {
      throw ("the unzip guard is incomplete`n" + ($problems -join "`n"))
    }
    $problems.Count | Should Be 0
  }

  It 'gives every goto a label that exists' {
    $labels = @()
    $targets = @()
    for ($i = 0; $i -lt $launcherLines.Count; $i++) {
      $text = $launcherLines[$i].Trim()
      if ($text -match '^:([A-Za-z0-9_]+)') { $labels += $Matches[1].ToLower() }
      foreach ($match in [regex]::Matches($text, '(?i)\bgoto\s+([^\s&|"]+)')) {
        $targets += [pscustomobject]@{ Number = $i + 1; Target = $match.Groups[1].Value.ToLower() }
      }
    }
    $problems = @()
    if ($targets.Count -eq 0) { $problems += 'the launcher has no goto at all, so the menu cannot loop' }
    if ($labels.Count -eq 0) { $problems += 'the launcher has no labels at all' }
    # :eof is built in; anything else must be defined here.
    foreach ($target in $targets) {
      if ($target.Target -eq ':eof' -or $target.Target -eq 'eof') { continue }
      if ($labels -notcontains $target.Target) {
        $problems += "line $($target.Number) jumps to '$($target.Target)', which has no label"
      }
    }
    if ($problems.Count -gt 0) {
      throw ("the launcher jumps to a missing label`n" + ($problems -join "`n"))
    }
    $targets.Count -gt 0 | Should Be $true
  }
}
