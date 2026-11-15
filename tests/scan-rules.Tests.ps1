# Unit tests for the scan's rules. They load only the rule definitions (regex variables and small pure functions) from scan-check.ps1
# through its syntax tree, so nothing is scanned and no report is written on this machine.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path (Split-Path -Parent $here) 'scan-check.ps1'
$ErrorActionPreference = 'SilentlyContinue'   # like the scan itself
$ast = [Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
$vars = 'odd', 'oddArg', 'lolbin', 'sysExe', 'defDir', 'sysSvc', 'badEx', 'badExt', 'trusted', 'prune', 'mark', 'risky', 'crackName', 'userinit'
$funcs = 'N', 'TryRead', 'TaskOdd', 'SvcOdd', 'BadExclusions', 'ThreatNames', 'Finish', 'L', 'Flag',
  'ExeOf', 'StartupValues', 'AutostartInfo', 'RiskySoftware', 'HardwareErrors', 'PolicyExclusions', 'UserFolders', 'WalkRead', 'WalkFolder', 'ReportWalkFailures'
$ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $vars -contains $n.Left.VariablePath.UserPath -and $n.Right.Extent.Text -match "^'" }, $true) |
  ForEach-Object { Invoke-Expression $_.Extent.Text }
$ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $funcs -contains $n.Name }, $false) |
  ForEach-Object { Invoke-Expression $_.Extent.Text }
$unread = New-Object Collections.Generic.List[string]

# A real lazy enumerator is needed: PowerShell function output is collected before foreach.
if (-not ('ScannxTestWalkSequence' -as [type])) {
  Add-Type @'
using System;
using System.Collections;
public sealed class ScannxTestWalkSequence : IEnumerable {
  private readonly string[] paths;
  private readonly bool fail;
  public ScannxTestWalkSequence(string[] paths, bool fail) { this.paths = paths; this.fail = fail; }
  public IEnumerator GetEnumerator() {
    foreach (string path in paths) { yield return path; }
    if (fail) { throw new InvalidOperationException("Synthetic lazy enumeration failure"); }
  }
}
'@
}
function WalkSequence([string[]]$paths = @(), [switch]$fail) {
  ,([ScannxTestWalkSequence]::new($paths, $fail.IsPresent))
}

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

Describe 'C4b scan fixes (synthetic inputs only)' {
  It 'uses function names that do not collide with built-in aliases' {
    $names = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object Name)
    @(Get-Alias | Where-Object { $names -contains $_.Name }).Count | Should Be 0
  }
  Context 'autostart entries' {
    It 'excludes only the five PowerShell registry metadata properties' {
      $properties = 'PSPath','PSParentPath','PSChildName','PSDrive','PSProvider','PSUpdate','PSVendor','Ordinary' | ForEach-Object { [pscustomobject]@{ Name=$_ } }
      ((StartupValues $properties).Name -join ',') | Should Be 'PSUpdate,PSVendor,Ordinary'
    }
    It 'resolves bare cmd rundll32 and powershell through application lookup' {
      Mock Get-Command { [pscustomobject]@{ Source="C:\SystemTools\$Name" } } -ParameterFilter { $CommandType -eq 'Application' }
      Mock Test-Path { $LiteralPath -like 'C:\SystemTools\*.exe' }
      foreach ($name in 'cmd.exe','rundll32.exe','powershell.exe') {
        $info = AutostartInfo "$name /c argument"
        $info.Exe | Should Be "C:\SystemTools\$name"; $info.Missing | Should Be $false
      }
      Assert-MockCalled Get-Command -Times 3 -Exactly -Scope It -ParameterFilter { $CommandType -eq 'Application' }
    }
    It 'keeps an unresolved bare executable visibly missing' {
      Mock Get-Command { $null } -ParameterFilter { $CommandType -eq 'Application' }
      Mock Test-Path { $false }
      $info = AutostartInfo 'missing-app.exe /run'
      $info.Exe | Should Be 'missing-app.exe'; $info.Missing | Should Be $true
    }
    It 'expands an environment variable before checking the executable' {
      Mock Test-Path { $true }
      $info = AutostartInfo '"%SystemRoot%\System32\cmd.exe" /c echo ok'
      $info.Exe | Should Be "$env:SystemRoot\System32\cmd.exe"
      Assert-MockCalled Test-Path -Times 1 -Exactly -Scope It -ParameterFilter { $LiteralPath -eq "$env:SystemRoot\System32\cmd.exe" }
    }
    It 'classifies both UNC slash forms without querying the network' {
      Mock Test-Path { throw 'A UNC path must never be queried' }
      foreach ($value in '\\server\share\app.exe /run','"//server/share/app.exe" /run') {
        $info = AutostartInfo $value
        $info.Network | Should Be $true; $info.Missing | Should Be $false
      }
      Assert-MockCalled Test-Path -Times 0 -Exactly -Scope It
    }
    It 'finds ProgramData inside quoted or equals-style autostart arguments' {
      Mock Test-Path { $true }
      foreach ($value in 'C:\Windows\System32\cmd.exe /c C:\ProgramData\x\a.exe', 'powershell.exe -File "C:\ProgramData\x\a.ps1"', 'C:\Tools\host.exe -arg=C:\ProgramData\x\a.exe', 'powershell.exe -Command {&C:\ProgramData\x\a.ps1}') {
        (AutostartInfo $value).Odd | Should Be $true
      }
      (AutostartInfo 'C:\Program Files\Vendor\ProgramDataHelper.exe').Odd | Should Be $false
    }
  }
  Context 'path and Defender exemptions' {
    It 'does not confuse a ProgramData filename with the actual folder' {
      foreach ($path in 'C:\Program Files\Vendor\ProgramDataHelper.exe','D:\Games\ProgramDataHelper.exe','C:\ProgramDatabase\tool.exe') {
        $path | Should Not Match $odd
        SvcOdd $path | Should Be $false
        TaskOdd '\' 'Updater' $path '' | Should BeNullOrEmpty
      }
      foreach ($path in 'D:\ProgramData\x\tool.exe','C:\Windows\Temp\tool.exe','C:\Users\Public\tool.exe') { $path | Should Match $odd }
    }
    It 'keeps ProgramData script-host arguments working without filename collisions' {
      foreach ($argument in '-File "C:\ProgramData\x\a.ps1"','-arg=C:\ProgramData\x\a.ps1','-Command {&C:\ProgramData\x\a.ps1}') {
        TaskOdd '\' 'Updater' 'powershell.exe' $argument | Should Match 'script host'
      }
      TaskOdd '\' 'Updater' 'powershell.exe' '-File "C:\Program Files\Vendor\ProgramDataHelper.exe"' | Should BeNullOrEmpty
    }
    It 'flags arbitrary and lookalike programs in the Defender tree' {
      foreach ($suffix in 'evil.exe','Platform\4.18.1-0\evil.exe','Platform\4.18.1-0\MsMpEng.exe.evil','Platform\4.18.1-0\extra\MsMpEng.exe','Platform\not-a-version\MsMpEng.exe') {
        $path = "C:\ProgramData\Microsoft\Windows Defender\$suffix"
        TaskOdd '\Microsoft\Windows\Defender\' 'Updater' $path '' | Should Match 'unusual place'
        $path | Should Not Match $sysSvc; SvcOdd $path | Should Be $true
      }
    }
    It 'exempts every documented Defender Platform program by exact filename' {
      foreach ($name in 'MsMpEng','NisSrv','ConfigSecurityPolicy','MpCopyAccelerator','MpCmdRun','MpDefenderCoreService','mpextms','MpDlpService','MpDlpCmd','MipDlp','DlpUserAgent') {
        $path = "D:\ProgramData\Microsoft\Windows Defender\Platform\4.18.1-0\$name.exe"
        TaskOdd '\Microsoft\Windows\Defender\' 'Updater' $path '' | Should BeNullOrEmpty
        "`"$path`" --service" | Should Match $sysSvc; SvcOdd "`"$path`" --service" | Should Be $false
      }
      TaskOdd '\' 'Updater' 'C:\ProgramData\Microsoft\Windows Defender\Platform\5.0.1\MsMpEng.exe' '' | Should BeNullOrEmpty
    }
    It 'checks miner task names even under Microsoft or an exempt executable' {
      foreach ($path in 'C:\Windows\System32\cmd.exe','C:\ProgramData\Microsoft\Windows Defender\Platform\4.18.1-0\MpCmdRun.exe') {
        TaskOdd '\Microsoft\Windows\Defender\' 'Windows System Health' $path '' | Should Match 'known miner'
      }
    }
  }
  Context 'name and exclusion boundaries' {
    It 'matches risky software names without matching ordinary game names' {
      foreach ($name in 'TeamViewer','AnyDesk','KMS','KMSAuto','KMSpico','Xeno','Solara','Crack','Cheat Engine','BitTorrent','uTorrent') { $name | Should Match $risky }
      foreach ($name in 'Crackdown','Xenoblade','KMSomething','ThreadPoolExecutor') { $name | Should Not Match $risky }
    }
    It 'skips numeric Steam uninstall keys even when their display name is risky' {
      $entries = @([pscustomobject]@{PSChildName='Steam App 123';DisplayName='Crack'}, [pscustomobject]@{PSChildName='Steam App text';DisplayName='Crack'}, [pscustomobject]@{PSChildName='Vendor';DisplayName='Xeno'})
      ((RiskySoftware $entries).PSChildName -join ',') | Should Be 'Steam App text,Vendor'
    }
    It 'matches whole crack names without matching Xenoblade or ThreadPoolExecutor' {
      foreach ($name in 'crack.exe','keygen.exe','kmsauto.exe','xeno-executor.exe','Solara.exe','repack.zip') { $name | Should Match $crackName }
      foreach ($name in 'Crackdown','Xenoblade','ThreadPoolExecutor.exe','activatorHelper.exe') { $name | Should Not Match $crackName }
    }
    It 'requires uppercase hexadecimal folders containing a letter' {
      foreach ($path in 'C:\Tools\1234ABCD\app.exe','C:\Tools\ABCDEF1') { @(BadExclusions @($path) @() @()).Count | Should Be 1 }
      foreach ($path in 'C:\Backups\20251109','C:\Backups\1234abcd','C:\Backups\123456789','C:\Backups\ABCDEF12z') { @(BadExclusions @($path) @() @()).Count | Should Be 0 }
    }
    It 'matches miner as a word rather than part of Examiner' {
      @(BadExclusions @('C:\Tools\miner\run.exe') @() @()).Count | Should Be 1
      @(BadExclusions @('C:\Tools\Examiner\run.exe','C:\Tools\minerHelper.exe') @() @()).Count | Should Be 0
    }
  }
  Context 'hardware persistence and user paths' {
    It 'counts only critical and error hardware events' {
      $events = @([pscustomobject]@{Level=1;ProviderName='disk'},[pscustomobject]@{Level=2;ProviderName='Microsoft-Windows-WHEA-Logger'},[pscustomobject]@{Level=3;ProviderName='disk'},[pscustomobject]@{Level=2;ProviderName='Microsoft-Windows-Kernel-Power'})
      @(HardwareErrors $events).Count | Should Be 2
      @(HardwareErrors @([pscustomobject]@{Level=3;ProviderName='disk'})).Count | Should Be 0
    }
    It 'accepts Userinit on another drive but rejects another folder or program' {
      foreach ($path in 'D:\Windows\system32\userinit.exe,','E:\WINDOWS\SYSTEM32\userinit.exe') { $path | Should Match $userinit }
      foreach ($path in 'C:\ProgramData\userinit.exe','C:\Windows\system32\other.exe','C:\Windows\system32\userinit.exe,evil.exe') { $path | Should Not Match $userinit }
    }
    It 'reads and flags policy exclusions outside the admin branch' {
      Mock Test-Path { $LiteralPath -match '\\(Paths|Extensions)$' }
      Mock Get-Item { [pscustomobject]@{ValueCount=$(if ($LiteralPath -match '\\Paths$') {2} else {0})} }
      Mock L { }
      $isAdmin = $false; $flags = New-Object Collections.Generic.List[string]; $unread.Clear()
      $assign = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$pol' })
      $assign.Count | Should Be 1
      . ([scriptblock]::Create($assign[0].Extent.Text))
      $condition = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$pol' })
      $condition.Count | Should Be 1
      . ([scriptblock]::Create($condition[0].Extent.Text))
      $pol.Count | Should Be 1; $pol[0].Kind | Should Be 'Paths'; $pol[0].Values | Should Be 2
      ($flags -join ' ') | Should Match 'set by POLICY'
      Assert-MockCalled Get-Item -Times 2 -Exactly -Scope It
    }
    It 'uses redirected Desktop and Downloads and expands registry variables' {
      $folders = @(UserFolders 'D:\Redirected Desktop' ([pscustomobject]@{'{374DE290-123F-4565-9164-39C4925E467B}'='%SystemDrive%\Redirected Downloads'}))
      $folders.Count | Should Be 2; $folders[0] | Should Be 'D:\Redirected Desktop'; $folders[1] | Should Be "$env:SystemDrive\Redirected Downloads"
      @(UserFolders 'D:\Redirected Desktop' $null).Count | Should Be 1
      $scriptText = $ast.Extent.Text
      $scriptText | Should Match "UserFolders \(\[Environment\]::GetFolderPath\('Desktop'\)\)"
      $scriptText | Should Not Match '\$env:USERPROFILE\\(Desktop|Downloads)'
    }
  }
  Context 'report failures' {
    It 'keeps the complete partial report after a nonempty final write fails' {
      $temporary = Join-Path $env:TEMP ('scannx-write-' + [guid]::NewGuid().ToString('N'))
      New-Item $temporary -ItemType Directory | Out-Null
      try {
        $part = Join-Path $temporary 'report.txt.partial'; $out = Join-Path $temporary 'report.txt'
        'complete synthetic report' | Set-Content $part
        Mock Out-File { [IO.File]::WriteAllText($FilePath,'header only'); throw 'Synthetic write failure after partial output' }
        Finish @('head') $part $out (Get-Date).AddSeconds(-2) 0 | Should Match 'Could NOT write'
        (Get-Item $out).Length | Should BeGreaterThan 0; (Get-Content $part -Raw) | Should Match 'complete synthetic report'
      } finally {
        if ((Split-Path -Parent $temporary) -ne $env:TEMP) { throw 'Unexpected scratch path' }
        Remove-Item -LiteralPath $temporary -Recurse -Force
      }
    }
  }
  Context 'file-walk failures and traversal' {
    It 'preserves marker pruning reparse and child-stack behavior' {
      $recent = Join-Path $TestDrive 'recent.exe'
      [IO.File]::WriteAllText($recent, 'synthetic')
      [IO.File]::SetLastWriteTime($recent, [datetime]'2026-01-02')
      Mock WalkRead {
        switch ($kind) {
          'files' { if ($path -eq 'C:\Synthetic\node_modules') { WalkSequence @('C:\Synthetic\node_modules\xmrig.exe') } else { WalkSequence @('C:\Synthetic\xmrig.exe', $recent) } }
          'directories' { WalkSequence @('C:\Synthetic\first', 'C:\Synthetic\node_modules', 'C:\Synthetic\junction', 'C:\Synthetic\last') }
          'attributes' { if ($path -like '*junction') { [IO.FileAttributes]::ReparsePoint } else { [IO.FileAttributes]::Directory } }
        }
      }
      $stack = New-Object Collections.Stack
      $walk = WalkFolder 'C:\Synthetic' ([datetime]'2026-01-01') $stack
      $walk.Hits.Count | Should Be 2; $walk.New.Count | Should Be 1; $walk.Failed.Count | Should Be 0
      $walk.New[0] | Should Be "2026-01-02 $recent"
      ($walk.Hits -join '|') | Should Match 'node_modules\\xmrig.exe'
      $stack.Pop() | Should Be 'C:\Synthetic\last'; $stack.Pop() | Should Be 'C:\Synthetic\first'; $stack.Count | Should Be 0
    }
    It 'retains markers emitted before a file enumeration fails' {
      Mock WalkRead { if ($kind -eq 'files') { WalkSequence @('C:\Synthetic\xmrig.exe') -fail } }
      $walk = WalkFolder 'C:\Synthetic' ([datetime]'2026-01-01') (New-Object Collections.Stack)
      $walk.Hits.Count | Should Be 1; $walk.Hits[0] | Should Be 'C:\Synthetic\xmrig.exe'; $walk.Failed.Count | Should Be 1; $walk.Failed[0] | Should Be 'C:\Synthetic'
    }
    It 'retains queued and later siblings when a pruned folder fails' {
      Mock WalkRead {
        switch ($kind) {
          'files' { if ($path -like '*node_modules') { WalkSequence @('C:\Synthetic\node_modules\xmrig.exe') -fail } }
          'directories' { WalkSequence @('C:\Synthetic\queued', 'C:\Synthetic\node_modules', 'C:\Synthetic\later') }
          'attributes' { [IO.FileAttributes]::Directory }
        }
      }
      $stack = New-Object Collections.Stack; $walk = WalkFolder 'C:\Synthetic' ([datetime]'2026-01-01') $stack
      $walk.Hits.Count | Should Be 1; $walk.Failed.Count | Should Be 1; $walk.Failed[0] | Should Be 'C:\Synthetic\node_modules'
      $stack.Count | Should Be 2; $stack.Pop() | Should Be 'C:\Synthetic\later'; $stack.Pop() | Should Be 'C:\Synthetic\queued'
    }
    It 'continues to a healthy sibling after the first child attributes fail' {
      Mock WalkRead {
        switch ($kind) {
          'directories' { WalkSequence @('C:\Synthetic\denied', 'C:\Synthetic\healthy') }
          'attributes' { if ($path -like '*denied') { throw 'Synthetic attribute failure' }; [IO.FileAttributes]::Directory }
        }
      }
      $stack = New-Object Collections.Stack; $walk = WalkFolder 'C:\Synthetic' ([datetime]'2026-01-01') $stack
      $walk.Failed.Count | Should Be 1; $walk.Failed[0] | Should Be 'C:\Synthetic\denied'
      $stack.Count | Should Be 1; $stack.Pop() | Should Be 'C:\Synthetic\healthy'
    }
    It 'retains queued children before a parent directory enumeration fails' {
      Mock WalkRead {
        switch ($kind) {
          'directories' { WalkSequence @('C:\Synthetic\queued') -fail }
          'attributes' { [IO.FileAttributes]::Directory }
        }
      }
      $stack = New-Object Collections.Stack; $walk = WalkFolder 'C:\Synthetic' ([datetime]'2026-01-01') $stack
      $walk.Failed.Count | Should Be 1; $walk.Failed[0] | Should Be 'C:\Synthetic'
      $stack.Count | Should Be 1; $stack.Pop() | Should Be 'C:\Synthetic\queued'
    }
    It 'keeps the outer walk stack order and stops before an exhausted budget' {
      $loop = $ast.Find({ param($node) $node -is [Management.Automation.Language.WhileStatementAst] -and $node.Body.Extent.Text -match 'WalkFolder' }, $true)
      Mock WalkFolder { [pscustomobject]@{Hits=@($directory);New=@();Failed=@()} }
      $stack = New-Object Collections.Stack; $stack.Push('first'); $stack.Push('last')
      $sw2 = [pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=0}}; $BudgetSec=10; $cut=[datetime]'2026-01-01'
      $hits=@(); $newx=@(); $dirs=0; $failedDirs=0; $failedSamples=New-Object Collections.Generic.List[string]
      . ([scriptblock]::Create($loop.Extent.Text))
      ($hits -join ',') | Should Be 'last,first'; $dirs | Should Be 2
      $BudgetSec=0; $dirs=0; $stack.Push('unvisited')
      . ([scriptblock]::Create($loop.Extent.Text))
      $dirs | Should Be 0; $stack.Count | Should Be 1
    }
    It 'counts every failed directory but keeps only the first three names' {
      $loop = $ast.Find({ param($node) $node -is [Management.Automation.Language.WhileStatementAst] -and $node.Body.Extent.Text -match 'WalkFolder' }, $true)
      Mock WalkFolder { [pscustomobject]@{Hits=@();New=@();Failed=@($directory)} }
      $stack=New-Object Collections.Stack; 1..5 | ForEach-Object { $stack.Push("synthetic-$_") }
      $sw2=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=0}}; $BudgetSec=10; $cut=[datetime]'2026-01-01'
      $hits=@(); $newx=@(); $dirs=0; $failedDirs=0; $failedSamples=New-Object Collections.Generic.List[string]
      . ([scriptblock]::Create($loop.Extent.Text))
      $failedDirs | Should Be 5; $failedSamples.Count | Should Be 3; ($failedSamples -join ',') | Should Be 'synthetic-5,synthetic-4,synthetic-3'
    }
    It 'accumulates findings around folders with empty result lists' {
      $loop = $ast.Find({ param($node) $node -is [Management.Automation.Language.WhileStatementAst] -and $node.Body.Extent.Text -match 'WalkFolder' }, $true)
      Mock WalkFolder {
        if ($directory -eq 'empty') { [pscustomobject]@{Hits=@();New=@();Failed=@()} }
        else { [pscustomobject]@{Hits=@("$directory-marker");New=@("2026-01-02 $directory.exe");Failed=@()} }
      }
      $stack=New-Object Collections.Stack; 'last','empty','first' | ForEach-Object { $stack.Push($_) }
      $sw2=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=0}}; $BudgetSec=10; $cut=[datetime]'2026-01-01'
      $hits=@(); $newx=@(); $dirs=0; $failedDirs=0; $failedSamples=New-Object Collections.Generic.List[string]
      . ([scriptblock]::Create($loop.Extent.Text))
      ($hits -join '|') | Should Be 'first-marker|last-marker'
      ($newx -join '|') | Should Be '2026-01-02 first.exe|2026-01-02 last.exe'
      $dirs | Should Be 3; $failedDirs | Should Be 0; $stack.Count | Should Be 0
    }
    It 'reports one aggregated failure entry in the walk and report head' {
      Mock L { }
      $unread.Clear(); ReportWalkFailures 7 @('C:\Synthetic\one','C:\Synthetic\two','C:\Synthetic\three')
      $unread.Count | Should Be 1; $unread[0] | Should Match 'could not read 7 folders'; $unread[0] | Should Match 'one.*two.*three'
      Assert-MockCalled L -Times 1 -Exactly -Scope It -ParameterFilter { $x -match 'could not read 7 folders' }
      $unread.Clear(); ReportWalkFailures 0 @(); $unread.Count | Should Be 0
    }
  }
}

Describe 'file walk with real synthetic IO' {
  It 'records an actual IO failure for a nonexistent synthetic folder' {
    $absent = Join-Path $env:TEMP ('scannx-absent-' + [guid]::NewGuid().ToString('N'))
    $walk = WalkFolder $absent ([datetime]'2026-01-01') (New-Object Collections.Stack)
    $walk.Failed.Count | Should Be 1; $walk.Failed[0] | Should Be $absent
  }

  It 'walks real synthetic files and empty folders while preserving the timestamp cutoff' {
    $root = Join-Path $TestDrive 'walk-files'
    $empty = Join-Path $root 'empty'
    [void][IO.Directory]::CreateDirectory($empty)
    $newFile = Join-Path $root 'new.ps1'; $oldFile = Join-Path $root 'old.exe'
    $marker = Join-Path $root 'xmrig.exe'
    foreach ($file in $newFile, $oldFile, $marker) { [IO.File]::WriteAllText($file, 'synthetic') }
    [IO.File]::SetLastWriteTime($newFile, [datetime]'2026-01-02')
    [IO.File]::SetLastWriteTime($oldFile, [datetime]'2026-01-01')
    $stack = New-Object Collections.Stack
    $walk = WalkFolder $root ([datetime]'2026-01-01') $stack
    $walk.Hits.Count | Should Be 1; $walk.Hits[0] | Should Be $marker
    $walk.New.Count | Should Be 1; $walk.New[0] | Should Be "2026-01-02 $newFile"
    $walk.Failed.Count | Should Be 0; $stack.Count | Should Be 1
    $walk = WalkFolder $stack.Pop() ([datetime]'2026-01-01') $stack
    $walk.Hits.Count | Should Be 0; $walk.New.Count | Should Be 0; $walk.Failed.Count | Should Be 0
  }
}
