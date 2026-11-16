# Static tests for Scannx.cmd. The launcher is read as bytes and as text and is never started:
# running it asks for administrator rights.

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

function Get-LauncherFirstIndex([string[]]$lines, [string]$pattern) {
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -match $pattern) { return $i }
  }
  return -1
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

  It 'has a closed "unzip first" block with a nonzero exit, before elevation and the menu' {
    $guardIndex = Get-LauncherFirstIndex $launcherLines '(?i)^if not exist "%~dp0scan-check\.ps1"'
    if ($guardIndex -lt 0) { throw 'no "if not exist scan-check.ps1" guard: started from inside the zip it would call a missing script' }

    $problems = @()
    if ($launcherLines[$guardIndex] -notmatch '\(\s*$') {
      $problems += "the guard at line $($guardIndex + 1) has no opening parenthesis, so it guards one command only"
    }

    # The block has to be closed: without the parenthesis, cmd.exe reads the rest of the file
    # as part of the if statement.
    $closerIndex = -1
    for ($i = $guardIndex + 1; $i -lt $launcherLines.Count; $i++) {
      if ($launcherLines[$i].Trim().StartsWith(')')) { $closerIndex = $i; break }
    }
    if ($closerIndex -lt 0) {
      $problems += "the guard block at line $($guardIndex + 1) has no closing parenthesis before the end of the file"
      $block = @($launcherLines[($guardIndex + 1)..($launcherLines.Count - 1)] | ForEach-Object { $_.Trim() })
    } else {
      $block = @()
      for ($i = $guardIndex + 1; $i -lt $closerIndex; $i++) { $block += $launcherLines[$i].Trim() }
    }

    if (@($block | Where-Object { $_ -match '(?i)Unzip first' }).Count -eq 0) {
      $problems += 'the guard does not say "Unzip first"'
    }
    if (@($block | Where-Object { $_ -match '(?i)^pause$' }).Count -eq 0) {
      $problems += 'the guard does not pause, so a double-click closes the window'
    }
    $exitLines = @($block | Where-Object { $_ -match '(?i)^exit\s+/b' })
    if ($exitLines.Count -eq 0) {
      $problems += 'the guard does not leave with exit /b'
    } else {
      foreach ($exitLine in $exitLines) {
        if ($exitLine -notmatch '(?i)^exit\s+/b\s+(\d+)$') {
          $problems += "the guard exits without an explicit numeric code: $exitLine"
        } elseif ([int]$Matches[1] -eq 0) {
          $problems += "the guard exits with 0, which a calling script reads as success: $exitLine"
        }
      }
    }

    # The guard is worthless after the elevation step or after the menu has been offered.
    $anchors = @(
      @{ Name = 'the elevation step'; Pattern = '(?i)(\bfltmc| -Verb RunAs)' },
      @{ Name = 'the menu label'; Pattern = '(?i)^:menu$' },
      @{ Name = 'the menu prompt'; Pattern = '(?i)^set\s+/p\s+"?c=' },
      @{ Name = 'the first script call'; Pattern = '(?i)%PS%' }
    )
    foreach ($anchor in $anchors) {
      $index = Get-LauncherFirstIndex $launcherLines $anchor.Pattern
      if ($index -lt 0) {
        $problems += "no $($anchor.Name) found, so the guard order cannot be checked"
      } elseif ($index -lt $guardIndex) {
        $problems += "the guard sits at line $($guardIndex + 1), after $($anchor.Name) at line $($index + 1)"
      }
    }

    if ($problems.Count -gt 0) {
      throw ("the unzip guard is incomplete`n" + ($problems -join "`n"))
    }
    $problems.Count | Should Be 0
  }

  It 'gives every goto in executable code a label that exists' {
    $labels = @()
    for ($i = 0; $i -lt $launcherLines.Count; $i++) {
      $text = $launcherLines[$i].Trim()
      if ($text -match '^::') { continue }
      if ($text -match '^:([A-Za-z0-9_]+)') { $labels += $Matches[1].ToLower() }
    }

    # Only code lines can jump: "goto" inside a rem or an echo is text for the user.
    $targets = @()
    foreach ($line in (Get-LauncherCodeLines $launcherLines)) {
      foreach ($match in [regex]::Matches($line.Text, '(?i)\bgoto\s+([^\s&|"]+)')) {
        $targets += [pscustomobject]@{ Number = $line.Number; Target = $match.Groups[1].Value.ToLower() }
      }
    }

    $problems = @()
    if ($targets.Count -eq 0) { $problems += 'the launcher has no goto at all, so the menu cannot loop' }
    if ($labels.Count -eq 0) { $problems += 'the launcher has no labels at all' }
    foreach ($target in $targets) {
      # :eof is the only label cmd.exe supplies itself; a plain "goto eof" needs a real label.
      if ($target.Target -eq ':eof') { continue }
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
