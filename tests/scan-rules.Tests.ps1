# Unit tests for the scan's rules. They load only the rule definitions (regex variables and small pure functions) from scan-check.ps1
# through its syntax tree, so nothing is scanned and no report is written on this machine.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path (Split-Path -Parent $here) 'scan-check.ps1'
$ErrorActionPreference = 'SilentlyContinue'   # like the scan itself
$ast = [Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
$vars = 'odd', 'lolbin', 'sysExe', 'defDir', 'sysSvc', 'badEx', 'badExt', 'trusted', 'prune'
$funcs = 'N', 'TryRead', 'TaskOdd', 'SvcOdd', 'BadExclusions', 'ThreatNames', 'Finish'
$ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $vars -contains $n.Left.VariablePath.UserPath -and $n.Right.Extent.Text -match "^'" }, $true) |
  ForEach-Object { Invoke-Expression $_.Extent.Text }
$ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $funcs -contains $n.Name }, $false) |
  ForEach-Object { Invoke-Expression $_.Extent.Text }
$unread = New-Object Collections.Generic.List[string]

Describe 'scan-check.ps1 rules' {
  It 'loads every rule from the script' {
    foreach ($v in $vars) { (Get-Variable $v -ValueOnly) | Should Not BeNullOrEmpty }
    foreach ($f in $funcs) { (Get-Command $f -CommandType Function) | Should Not BeNullOrEmpty }
  }
  Context 'services' {
    It 'does not trust the whole Windows folder: Windows\Temp is listed and flagged' {
      'C:\Windows\Temp\svc.exe' | Should Not Match $sysSvc
      SvcOdd 'C:\Windows\Temp\svc.exe' | Should Be $true
    }
    It 'flags a ProgramData service even when its file is called "Windows Defender"' { SvcOdd 'C:\ProgramData\evil\Windows Defender.exe' | Should Be $true }
    It 'keeps real Windows, Program Files and Defender services out of the list' {
      foreach ($p in 'C:\WINDOWS\system32\svchost.exe -k netsvcs -p', '"C:\Windows\System32\spoolsv.exe"', 'C:\Windows\servicing\TrustedInstaller.exe',
        'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\SMSvcHost.exe', '"C:\Program Files\App\app.exe" --service', '"C:\ProgramData\Microsoft\Windows Defender\Platform\4.18.1-0\MsMpEng.exe"') {
        $p | Should Match $sysSvc; SvcOdd $p | Should Be $false }
    }
    It 'lists but does not flag a service in an ordinary other place' { 'D:\Games\Launcher\svc.exe' | Should Not Match $sysSvc; SvcOdd 'D:\Games\Launcher\svc.exe' | Should Be $false }
  }
  Context 'scheduled tasks' {
    It 'checks tasks under \Microsoft\ too' {
      TaskOdd '\Microsoft\Windows\Foo\' 'Upd' 'C:\Users\Public\a.exe' '' | Should Match 'unusual place'
      TaskOdd '\Microsoft\Windows\Foo\' 'Upd' 'D:\stuff\a.exe' '' | Should Match 'outside Windows and Program Files'
    }
    It 'looks at the arguments of script hosts' {
      TaskOdd '\' 'X' 'cmd.exe' '/c C:\ProgramData\x\a.exe' | Should Match 'script host'
      TaskOdd '\' 'X' '%windir%\System32\WindowsPowerShell\v1.0\powershell.exe' '-w hidden -File C:\Users\Public\a.ps1' | Should Match 'script host'
    }
    It 'does not flag an ordinary program with a ProgramData argument' { TaskOdd '\' 'X' 'C:\Program Files\App\app.exe' '--data C:\ProgramData\App' | Should BeNullOrEmpty }
    It 'does not flag real Microsoft tasks' {
      TaskOdd '\Microsoft\Windows\Windows Defender\' 'Scan' 'C:\ProgramData\Microsoft\Windows Defender\Platform\4.18.1-0\MpCmdRun.exe' 'Scan' | Should BeNullOrEmpty
      TaskOdd '\Microsoft\Windows\X\' 'Y' '%windir%\system32\sc.exe' 'start x' | Should BeNullOrEmpty
      TaskOdd '\Microsoft\Office\' 'Z' 'C:\Program Files\Microsoft Office\root\Office16\x.exe' '' | Should BeNullOrEmpty
      TaskOdd '\Microsoft\Windows\X\' 'COM handler, no program' '' '' | Should BeNullOrEmpty
    }
    It 'still knows the miner task names outside \Microsoft\' { TaskOdd '\' 'Windows System Health' 'C:\Program Files\a\a.exe' '' | Should Match 'known miner' }
  }
  Context 'Defender exclusions' {
    It 'judges extension exclusions' {
      @(BadExclusions @() @() @('exe')).Count | Should Be 1
      @(BadExclusions @() @() @('.DLL', 'ps1')).Count | Should Be 2
      @(BadExclusions @() @() @('txt', 'log')).Count | Should Be 0
    }
    It 'still judges paths and processes' {
      @(BadExclusions @('C:\', 'D:\Games\Foo') @('C:\Users\u\AppData\Local\Temp') $null).Count | Should Be 2
      @(BadExclusions $null $null $null).Count | Should Be 0
    }
    It 'counts nothing as 0, not as 1' { N $null | Should Be 0; N @('a', '') | Should Be 1; N @('a', 'b') | Should Be 2 }
  }
  Context 'Defender detections' {
    It 'names a detection whose threat ID is not in the name table' { ThreatNames @([pscustomobject]@{ ThreatID = 5 }) @{} | Should Be 'unknown threat ID 5' }
    It 'uses the name when there is one, once' { ThreatNames @([pscustomobject]@{ ThreatID = 5 }, [pscustomobject]@{ ThreatID = 5 }) @{ 5 = 'Trojan:X' } | Should Be 'Trojan:X' }
    It 'gives nothing for no detections' { @(ThreatNames @() @{}).Count | Should Be 0 }
  }
  Context 'file walk' {
    It 'does not hide a file because a vendor name is somewhere in its path' {
      foreach ($f in 'C:\ProgramData\x\GoogleUpdater.exe', 'C:\Users\u\AppData\Roaming\steamhelper\a.exe', 'C:\Users\u\Downloads\Discord-setup\a.exe', 'C:\Users\u\AppData\Local\x\Programs\a.exe') { $f | Should Not Match $trusted }
    }
    It 'still skips well-known app folders' {
      foreach ($f in 'C:\Users\u\AppData\Local\Google\Chrome\Application\chrome.exe', 'C:\Users\u\AppData\Local\Programs\Python\python.exe', 'C:\Users\u\AppData\Roaming\Code\x.cmd', 'C:\ProgramData\Package Cache\{1}\setup.exe') { $f | Should Match $trusted }
    }
    It 'prunes big cache folders only inside an application folder' {
      foreach ($d in 'C:\Users\u\AppData\Local\Google\Chrome\User Data\Default\Cache', 'C:\Users\u\AppData\Roaming\discord\Cache', 'C:\Users\u\AppData\Local\Packages', 'C:\ProgramData\Microsoft\Windows Defender', 'C:\Users\u\AppData\Local\x\node_modules') { $d | Should Match $prune }
      foreach ($d in 'C:\ProgramData\Cache', 'C:\Users\u\AppData\Local\Cache', 'C:\ProgramData\evil\Windows Defender', 'C:\ProgramData\Packages', 'C:\Users\Public\Crashpad') { $d | Should Not Match $prune }
    }
  }
  Context 'honest report' {
    It 'records a read that failed' { $unread.Clear(); $null = TryRead 'the thing' { Get-Item 'C:\no-such-scannx-path-1' }; "$unread" | Should Match '^the thing \(' }
    It 'returns what was read and records nothing when it worked' { $unread.Clear(); TryRead 'ok' { 'value' } | Should Be 'value'; $unread.Count | Should Be 0 }
    It 'does not count "no events found" as a failed read' { $unread.Clear(); $null = TryRead 'events' { Write-Error 'none' -ErrorId NoMatchingEventsFound }; $unread.Count | Should Be 0 }
    $dir = Join-Path $env:TEMP ('scannx-rules-' + [guid]::NewGuid().ToString('N')); New-Item $dir -ItemType Directory | Out-Null
    It 'writes the report and removes the .partial file' {
      $part = Join-Path $dir 'ok.txt.partial'; 'body' | Set-Content $part
      Finish @('head') $part (Join-Path $dir 'ok.txt') (Get-Date).AddSeconds(-2) 3 | Should Match '^Done: .*\(3 flags\)'
      (Get-Content (Join-Path $dir 'ok.txt') -Raw) | Should Match 'head\s+body'; Test-Path $part | Should Be $false
    }
    It 'keeps the .partial file and says so when the report cannot be written' {
      $out = Join-Path $dir 'blocked.txt'; New-Item $out -ItemType Directory | Out-Null   # a folder in the way: Out-File fails
      $part = "$out.partial"; 'body' | Set-Content $part
      Finish @('head') $part $out (Get-Date).AddSeconds(-2) 0 | Should Match 'Could NOT write'
      Test-Path $part | Should Be $true
    }
    Remove-Item $dir -Recurse -Force
  }
}
