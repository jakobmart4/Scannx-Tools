# Unit tests for the $mark regex in scan-check.ps1 (file walk miner/proxyware markers).
# The pattern is read from the script's syntax tree: scan-check.ps1 is parsed, never executed.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path (Split-Path -Parent $here) 'scan-check.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "scan-check.ps1 not found next to the tests: $scriptPath" }

$parseTokens = $null
$parseErrors = $null
$scanAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw "scan-check.ps1 does not parse, so `$mark cannot be read: $($parseErrors[0].Message)" }

# The right-hand side is a literal string, so the pattern is read off the syntax tree and
# scan-check.ps1 is never run.
$markAssignments = @($scanAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
  $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
  $node.Left.VariablePath.UserPath -eq 'mark'
}, $true))
if ($markAssignments.Count -ne 1) { throw "expected exactly one `$mark assignment in scan-check.ps1, found $($markAssignments.Count)" }

$markRight = $markAssignments[0].Right
# Windows PowerShell 5.1 parses the right-hand side of an assignment as a CommandExpressionAst.
if ($markRight -is [System.Management.Automation.Language.CommandExpressionAst]) { $markRight = $markRight.Expression }
if ($markRight -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
  throw 'the $mark assignment is not a literal string, so the pattern cannot be read without running the script'
}
$mark = $markRight.Value
if ([string]::IsNullOrWhiteSpace($mark)) { throw '$mark is empty' }

Describe '$mark: the pattern itself' {
  It 'anchors the pattern at both ends' {
    $mark.StartsWith('^') | Should Be $true
    $mark.EndsWith('$') | Should Be $true
  }
  It 'is a valid regular expression' {
    { [regex]::IsMatch('pawns-sdk.exe', $mark) } | Should Not Throw
  }
  It 'matches an upper-case name, because the script compares with -match' {
    'XMRIG.EXE' | Should Match $mark
  }
}

# One positive per alternative, plus the suffix forms. The .* at the end of most alternatives
# is deliberate: a renamed copy (winring0.txt, srbminer-old.exe) is still the same marker.
Describe '$mark: known miner and proxyware marker names' {
  Context 'pawns-sdk' {
    It 'matches pawns-sdk.exe' { 'pawns-sdk.exe' | Should Match $mark }
    It 'matches the suffix form pawns-sdk-old.exe' { 'pawns-sdk-old.exe' | Should Match $mark }
  }
  Context 'lastgood_miner' {
    It 'matches the folder name lastgood_miner' { 'lastgood_miner' | Should Match $mark }
    It 'matches a dated copy lastgood_miner_2024' { 'lastgood_miner_2024' | Should Match $mark }
  }
  Context 'last_miner_error' {
    It 'matches last_miner_error.txt' { 'last_miner_error.txt' | Should Match $mark }
  }
  Context 'RuntimeHost.exe' {
    It 'matches RuntimeHost.exe' { 'RuntimeHost.exe' | Should Match $mark }
    It 'matches the suffix form RuntimeHost.exe.old' { 'RuntimeHost.exe.old' | Should Match $mark }
    It 'matches RUNTIMEHOST.EXE in upper case' { 'RUNTIMEHOST.EXE' | Should Match $mark }
  }
  Context 'RuntimeTask.exe' {
    It 'matches RuntimeTask.exe' { 'RuntimeTask.exe' | Should Match $mark }
  }
  Context 'RunstimeHost' {
    It 'matches the misspelled RunstimeHost' { 'RunstimeHost' | Should Match $mark }
  }
  Context 'proxies-peer' {
    It 'matches proxies-peer exactly' { 'proxies-peer' | Should Match $mark }
  }
  Context 'srbminer' {
    It 'matches a miner file name miner-srbminer.dat' { 'miner-srbminer.dat' | Should Match $mark }
    It 'matches the suffix form srbminer-old.exe' { 'srbminer-old.exe' | Should Match $mark }
  }
  Context 'xmrig' {
    It 'matches xmrig.exe' { 'xmrig.exe' | Should Match $mark }
    It 'matches the suffix form xmrig-v2.exe' { 'xmrig-v2.exe' | Should Match $mark }
  }
  Context 'winring0' {
    It 'matches winring0.dll' { 'winring0.dll' | Should Match $mark }
    It 'matches the renamed winring0.txt' { 'winring0.txt' | Should Match $mark }
  }
  Context 'acess token' {
    It 'matches the misspelled "acess token.txt"' { 'acess token.txt' | Should Match $mark }
  }
}

# Names that must stay unflagged: an ordinary program, another extension, a near miss in the
# name, and a full path (the script passes file and folder names, never paths).
Describe '$mark: names that are not markers' {
  It 'does not match an ordinary program chrome.exe' { 'chrome.exe' | Should Not Match $mark }
  It 'does not match RuntimeHost.dll (another extension)' { 'RuntimeHost.dll' | Should Not Match $mark }
  It 'does not match proxies-peers (extra s)' { 'proxies-peers' | Should Not Match $mark }
  It 'does not match access token.txt (correct spelling)' { 'access token.txt' | Should Not Match $mark }
  It 'does not match acesss token.txt (double s)' { 'acesss token.txt' | Should Not Match $mark }
  It 'does not match winring.dll (missing digit)' { 'winring.dll' | Should Not Match $mark }
  It 'does not match a path that ends in \RuntimeHost.exe' { 'malware\RuntimeHost.exe' | Should Not Match $mark }
}
