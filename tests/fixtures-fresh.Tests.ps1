# Verifies that tests/make-fixtures.ps1 regenerates the committed tests/fixtures tree exactly,
# and that the result does not depend on the regional format: en-US, de-DE and et-EE must all
# write the same bytes. The generator is the only program started here: scan-check.ps1,
# disk-log.ps1 and Scannx.cmd are never run.
# Only an optional UTF-8 BOM and CRLF versus LF are ignored when the committed content is
# compared; the culture comparison is byte for byte.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$fixturesRoot = Join-Path $here 'fixtures'
$generatorPath = Join-Path $here 'make-fixtures.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach ($required in @($powershellExe, $generatorPath, $fixturesRoot)) {
  if (-not (Test-Path -LiteralPath $required)) { throw "missing: $required" }
}

# The folder names hold a space on purpose: -Root must reach the generator as one argument.
$tempRoot = Join-Path $env:TEMP ('scannx fixtures fresh ' + [guid]::NewGuid().ToString('N'))
$tempRootFull = [IO.Path]::GetFullPath($tempRoot).TrimEnd('\')
$cultureRoot = Join-Path $env:TEMP ('scannx fixtures cultures ' + [guid]::NewGuid().ToString('N'))
$script:cultureTempRoot = [IO.Path]::GetFullPath($cultureRoot).TrimEnd('\')
$cultures = @('en-US', 'de-DE', 'et-EE')

function Get-FixtureRelativePath([string]$root, [string]$file) {
  return $file.Substring($root.TrimEnd('\').Length + 1)
}

function Get-FixtureFileList([string]$root) {
  $files = [IO.Directory]::GetFiles($root, '*', [IO.SearchOption]::AllDirectories)
  $list = @()
  foreach ($file in $files) { $list += Get-FixtureRelativePath $root $file }
  return @($list | Sort-Object)
}

# Only the UTF-8 BOM and CRLF are normalised away, and both comparisons are ordinal: the
# current culture must not decide whether two fixtures are equal. Spaces, blank lines, number
# formats, timestamps, a NUL byte and a missing final newline all stay differences.
function Get-FixtureText([string]$path) {
  $bytes = [IO.File]::ReadAllBytes($path)
  if ($bytes.Length -eq 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $bytes = [byte[]]@()      # a file holding only the BOM reads as an empty file
  } elseif ($bytes.Length -gt 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $bytes = $bytes[3..($bytes.Length - 1)]
  }
  return [Text.Encoding]::UTF8.GetString($bytes).Replace("`r`n", "`n")
}

function Get-FixtureTextDifference([string]$committedPath, [string]$generatedPath) {
  $committed = Get-FixtureText $committedPath
  $generated = Get-FixtureText $generatedPath
  if ([string]::Equals($committed, $generated, [StringComparison]::Ordinal)) { return '' }
  $committedLines = $committed -split "`n"
  $generatedLines = $generated -split "`n"
  $lines = [Math]::Max($committedLines.Count, $generatedLines.Count)
  for ($i = 0; $i -lt $lines; $i++) {
    $left = if ($i -lt $committedLines.Count) { $committedLines[$i] } else { '<no line>' }
    $right = if ($i -lt $generatedLines.Count) { $generatedLines[$i] } else { '<no line>' }
    if (-not [string]::Equals($left, $right, [StringComparison]::Ordinal)) {
      if ($left.Length -gt 120) { $left = $left.Substring(0, 120) + '...' }
      if ($right.Length -gt 120) { $right = $right.Substring(0, 120) + '...' }
      return "line $($i + 1): committed '$left', generated '$right'"
    }
  }
  return 'same lines, different bytes'
}

# Byte for byte, no normalisation: the culture comparison must not forgive a different BOM
# or a different line ending, because both would differ from the committed tree as well.
function Test-FixtureByteDifference([string]$committedPath, [string]$generatedPath) {
  $committed = [IO.File]::ReadAllBytes($committedPath)
  $generated = [IO.File]::ReadAllBytes($generatedPath)
  if ($committed.Length -ne $generated.Length) {
    return "$($committed.Length) versus $($generated.Length) bytes"
  }
  for ($i = 0; $i -lt $committed.Length; $i++) {
    if ($committed[$i] -ne $generated[$i]) { return "bytes differ at offset $i" }
  }
  return ''
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

# Both checks stay: the target must be a folder this test created, and it must sit below %TEMP%.
function Remove-FixtureTempRoot([string]$path, [string[]]$createdRoots) {
  $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
  if ($createdRoots -notcontains $full) { throw "refusing to remove '$full': not a folder this test created" }
  $tempBase = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
  if (-not $full.StartsWith($tempBase + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to remove '$full': not below '$tempBase'"
  }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
}

# The culture has to be set inside the process that runs the generator: a culture set in this
# Pester process does not reach a child powershell.exe, and only the child's culture decides
# how a number reaches the CSV.
$wrapperText = @'
param([string]$Culture, [string]$Generator, [string]$Root)
$ErrorActionPreference = 'Stop'
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::new($Culture)
'culture=' + [Globalization.CultureInfo]::CurrentCulture.Name
& $Generator -Root $Root
exit 0
'@

$committedFingerprintBefore = Get-FixtureFingerprint $fixturesRoot
$roots = @()
$generatorExitCode = -1
$generatorOutput = ''
$generatedFiles = @()
$cultureResults = @{}

try {
  $created = New-Item -ItemType Directory -Path $tempRootFull -Force
  $roots += [IO.Path]::GetFullPath($created.FullName).TrimEnd('\')
  $generatorOutput = (& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $generatorPath -Root $tempRootFull 2>&1 | Out-String)
  $generatorExitCode = $LASTEXITCODE
  if (Test-Path -LiteralPath $tempRootFull) { $generatedFiles = Get-FixtureFileList $tempRootFull }

  $createdCultures = New-Item -ItemType Directory -Path $script:cultureTempRoot -Force
  $roots += [IO.Path]::GetFullPath($createdCultures.FullName).TrimEnd('\')
  $wrapperPath = Join-Path $script:cultureTempRoot 'run-generator.ps1'
  [IO.File]::WriteAllText($wrapperPath, $wrapperText, (New-Object Text.UTF8Encoding($false)))
  foreach ($culture in $cultures) {
    $target = Join-Path $script:cultureTempRoot ('out ' + $culture)
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $output = (& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $wrapperPath -Culture $culture -Generator $generatorPath -Root $target 2>&1 | Out-String)
    $cultureResults[$culture] = @{
      ExitCode = $LASTEXITCODE
      Output   = $output
      Root     = $target
      Files    = @(if (Test-Path -LiteralPath $target) { Get-FixtureFileList $target })
    }
  }

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

  # A decimal comma splits one value into two CSV columns, so a culture that is not invariant
  # produces rows with more columns than the header. These tests run the real generator in a
  # child powershell.exe whose own CurrentCulture is the culture under test.
  Describe 'the generated fixtures do not depend on the regional format' {
    foreach ($culture in $cultures) {
      Context $culture {
        It "generates the committed file list under $culture" {
          $result = $cultureResults[$culture]
          if ($result.ExitCode -ne 0) {
            throw "the generator exited $($result.ExitCode) under $culture. Output: $($result.Output.Trim())"
          }
          $result.Output | Should Match ('culture=' + [regex]::Escape($culture))
          $committedFiles = Get-FixtureFileList $fixturesRoot
          $missing = @($committedFiles | Where-Object { $result.Files -notcontains $_ })
          $unexpected = @($result.Files | Where-Object { $committedFiles -notcontains $_ })
          if ($missing.Count -gt 0 -or $unexpected.Count -gt 0) {
            throw ("$culture wrote a different file list: missing $($missing.Count) (" +
              (($missing | Select-Object -First 5) -join ', ') + "), unexpected $($unexpected.Count) (" +
              (($unexpected | Select-Object -First 5) -join ', ') + ")")
          }
          ($missing.Count + $unexpected.Count) | Should Be 0
        }

        It "writes fixture files byte-identical to the committed ones under $culture" {
          $result = $cultureResults[$culture]
          if ($result.Files.Count -eq 0) { throw "the generator wrote no files under $culture" }
          $differences = @()
          foreach ($relative in (Get-FixtureFileList $fixturesRoot)) {
            if ($result.Files -notcontains $relative) { continue }
            $difference = Test-FixtureByteDifference (Join-Path $fixturesRoot $relative) (Join-Path $result.Root $relative)
            if ($difference) { $differences += "${relative}: $difference" }
          }
          if ($differences.Count -gt 0) {
            throw ("$($differences.Count) file(s) differ from the committed bytes under $culture`n" +
              ((@($differences | Select-Object -First 10)) -join "`n"))
          }
          $differences.Count | Should Be 0
        }

        It "writes 24 CSV columns in clean/log.csv header and data rows under $culture" {
          $result = $cultureResults[$culture]
          $path = Join-Path $result.Root 'clean\log.csv'
          if (-not (Test-Path -LiteralPath $path)) { throw "clean/log.csv was not written under $culture" }
          $lines = @((Get-FixtureText $path) -split "`n")
          if ($lines.Count -gt 1 -and $lines[$lines.Count - 1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
          $headerColumns = @($lines[0] -split ',').Count
          $bad = @()
          for ($i = 1; $i -lt $lines.Count; $i++) {
            $columns = @($lines[$i] -split ',').Count
            if ($columns -ne $headerColumns) { $bad += "line $($i + 1) has $columns of $headerColumns columns" }
          }
          if ($headerColumns -ne 24) { throw "the header under $culture has $headerColumns columns, not 24" }
          if ($bad.Count -gt 0) {
            throw ("$culture splits clean/log.csv into extra columns: " +
              ((@($bad | Select-Object -First 5)) -join '; '))
          }
          $bad.Count | Should Be 0
        }
      }
    }
  }
} finally {
  # A cleanup failure is not downgraded to a warning: every root is attempted, then the error
  # fails the Pester run. The resolved path and the %TEMP% boundary are checked per root.
  $cleanupErrors = @()
  foreach ($root in $roots) {
    try { Remove-FixtureTempRoot -Path $root -CreatedRoots $roots } catch { $cleanupErrors += $_.Exception.Message }
  }
  if ($cleanupErrors.Count -gt 0) { throw ('cleanup failed: ' + ($cleanupErrors -join '; ')) }
}
