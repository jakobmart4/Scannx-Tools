# Verifies that tests/make-fixtures.ps1 regenerates the committed tests/fixtures tree exactly.
# The generator is the only program started here: scan-check.ps1, disk-log.ps1 and Scannx.cmd are never run.
# Only an optional UTF-8 BOM and CRLF versus LF are ignored; any other difference fails a test.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$fixturesRoot = Join-Path $here 'fixtures'
$generatorPath = Join-Path $here 'make-fixtures.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach ($required in @($powershellExe, $generatorPath, $fixturesRoot)) {
  if (-not (Test-Path -LiteralPath $required)) { throw "missing: $required" }
}

# The folder name holds a space on purpose: -Root must reach the generator as one argument.
$tempRoot = Join-Path $env:TEMP ('scannx fixtures fresh ' + [guid]::NewGuid().ToString('N'))
$tempRootFull = [IO.Path]::GetFullPath($tempRoot).TrimEnd('\')

function Get-FixtureRelativePath([string]$root, [string]$file) {
  return $file.Substring($root.TrimEnd('\').Length + 1)
}

function Get-FixtureFileList([string]$root) {
  $files = [IO.Directory]::GetFiles($root, '*', [IO.SearchOption]::AllDirectories)
  $list = @()
  foreach ($file in $files) { $list += Get-FixtureRelativePath $root $file }
  return @($list | Sort-Object)
}

# Only the UTF-8 BOM and CRLF are normalised away. Spaces, blank lines, number formats,
# timestamps and a missing final newline all stay differences.
function Get-FixtureText([string]$path) {
  $bytes = [IO.File]::ReadAllBytes($path)
  if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $bytes = $bytes[3..($bytes.Length - 1)]
  }
  return [Text.Encoding]::UTF8.GetString($bytes).Replace("`r`n", "`n")
}

function Get-FixtureTextDifference([string]$committedPath, [string]$generatedPath) {
  $committed = Get-FixtureText $committedPath
  $generated = Get-FixtureText $generatedPath
  if ($committed -ceq $generated) { return '' }
  $committedLines = $committed -split "`n"
  $generatedLines = $generated -split "`n"
  $lines = [Math]::Max($committedLines.Count, $generatedLines.Count)
  for ($i = 0; $i -lt $lines; $i++) {
    $left = if ($i -lt $committedLines.Count) { $committedLines[$i] } else { '<no line>' }
    $right = if ($i -lt $generatedLines.Count) { $generatedLines[$i] } else { '<no line>' }
    if ($left -cne $right) {
      if ($left.Length -gt 120) { $left = $left.Substring(0, 120) + '...' }
      if ($right.Length -gt 120) { $right = $right.Substring(0, 120) + '...' }
      return "line $($i + 1): committed '$left', generated '$right'"
    }
  }
  return 'same lines, different bytes'
}

# Fingerprint of the committed tree: a generator that ignored -Root would write here and change it.
function Get-FixtureFingerprint([string]$root) {
  $lines = @()
  foreach ($relative in (Get-FixtureFileList $root)) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash
    $lines += "$relative $hash"
  }
  return ($lines -join "`n")
}

function Remove-FixtureTempRoot([string]$path) {
  $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
  if ($full -ne $script:fixtureTempRoot) { throw "refusing to remove '$full': not the folder this test created" }
  $tempBase = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
  if (-not $full.StartsWith($tempBase + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to remove '$full': not below '$tempBase'"
  }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
}

$committedFingerprintBefore = Get-FixtureFingerprint $fixturesRoot
$script:fixtureTempRoot = ''
$generatorExitCode = -1
$generatorOutput = ''
$generatedFiles = @()

try {
  $created = New-Item -ItemType Directory -Path $tempRootFull -Force
  $script:fixtureTempRoot = [IO.Path]::GetFullPath($created.FullName).TrimEnd('\')
  $generatorOutput = (& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $generatorPath -Root $tempRootFull 2>&1 | Out-String)
  $generatorExitCode = $LASTEXITCODE
  if (Test-Path -LiteralPath $tempRootFull) { $generatedFiles = Get-FixtureFileList $tempRootFull }

  Describe 'tests/fixtures is reproducible from tests/make-fixtures.ps1' {
    It 'runs the generator with -Root into a temporary folder and exits 0' {
      if ($generatorExitCode -ne 0) {
        throw "make-fixtures.ps1 exited $generatorExitCode. Output: $($generatorOutput.Trim())"
      }
      $generatorExitCode | Should Be 0
    }

    It 'writes the fixtures into the temporary folder and not into tests/fixtures' {
      if ($generatedFiles.Count -eq 0) {
        throw "the generator wrote no files into '$tempRootFull'. Output: $($generatorOutput.Trim())"
      }
      $after = Get-FixtureFingerprint $fixturesRoot
      if ($after -ne $committedFingerprintBefore) {
        $changed = @()
        foreach ($line in ($after -split "`n")) {
          if (($committedFingerprintBefore -split "`n") -notcontains $line) { $changed += ($line -split ' ')[0] }
        }
        throw ("the generator changed the committed fixtures: " + ($changed -join ', '))
      }
      ($after -eq $committedFingerprintBefore) | Should Be $true
    }

    It 'generates the same relative file list, with no missing and no unexpected fixture' {
      $committedFiles = Get-FixtureFileList $fixturesRoot
      $missing = @($committedFiles | Where-Object { $generatedFiles -notcontains $_ })
      $unexpected = @($generatedFiles | Where-Object { $committedFiles -notcontains $_ })
      $problems = @()
      if ($missing.Count -gt 0) {
        $problems += "missing ($($missing.Count)): " + (($missing | Select-Object -First 10) -join ', ')
      }
      if ($unexpected.Count -gt 0) {
        $problems += "unexpected ($($unexpected.Count)): " + (($unexpected | Select-Object -First 10) -join ', ')
      }
      if ($problems.Count -gt 0) {
        throw ("the generated file list differs from the committed one`n" + ($problems -join "`n") +
          "`ncommitted $($committedFiles.Count) files, generated $($generatedFiles.Count) files")
      }
      $unexpected.Count | Should Be 0
    }

    It 'generates identical content in every fixture, ignoring only a BOM and CRLF' {
      # Nothing to compare is not the same as nothing wrong: a failed generator must not pass here.
      if ($generatedFiles.Count -eq 0) { throw 'the generator produced no files, so there is no content to compare' }
      $committedFiles = Get-FixtureFileList $fixturesRoot
      $differences = @()
      foreach ($relative in $committedFiles) {
        # A missing file is the file-list test's finding; here only content is compared.
        if ($generatedFiles -notcontains $relative) { continue }
        $difference = Get-FixtureTextDifference (Join-Path $fixturesRoot $relative) (Join-Path $tempRootFull $relative)
        if ($difference) { $differences += "${relative}: $difference" }
      }
      if ($differences.Count -gt 0) {
        $shown = @($differences | Select-Object -First 10)
        throw ("$($differences.Count) fixture file(s) differ from the committed content`n" + ($shown -join "`n"))
      }
      $differences.Count | Should Be 0
    }
  }
} finally {
  try { Remove-FixtureTempRoot -Path $tempRootFull } catch { Write-Warning "temporary folder left behind: $_" }
}
