# NVIDIA FrameView log import in disk-log.ps1 -Summarize. The FrameView log here is synthetic: the column names come from FrameView's
# README, not from a real capture. It sits on top of the 'frames' fixture (healthy system, log 10:00:00-10:02:58, F9 marks at 10:01:00 and 10:02:00).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path (Split-Path -Parent $here) 'disk-log.ps1'
$head = 'Application,GPU,CPU,Resolution,Runtime,AllowsTearing,ProcessID,SwapChainAddress,SyncInterval,PresentFlags,PresentMode,Dropped,TimeInSeconds,MsBetweenPresents,MsBetweenDisplayChange,MsInPresentAPI,MsRenderPresentLatency,MsUntilDisplayed,Render Queue Depth,MsPCLatency,GPU0Clk(MHz),GPU0Util(%),GPU0Temp(C),NV Pwr(W) (API),CPUClk(MHz),CPUUtil(%),CPU Package Temp(C),CPU Package Power(W)'

# 20 fps for 150 s; one 400 ms frame 50 s in. PC latency: NA for the first 100 frames, 90 ms at the hitch, else 30 ms. 3 dropped frames.
# CPU 70 C with one 91 C reading, CPU 65 W, GPU 150 W.
function FvLog($path, $lenMs = 150000, $hitchAt = 50000) {
  $rows = New-Object Collections.Generic.List[string]; $t = 0; $i = 0
  while ($t -lt $lenMs) {
    $ms = if ($t -eq $hitchAt) { 400 } else { 50 }; $lat = if ($i -lt 100) { 'NA' } elseif ($ms -eq 400) { 90 } else { 30 }
    $rows.Add(('r5apex_dx12.exe,GPU,CPU,1920x1080,DXGI,1,1,0x1,0,0,Hardware: Independent Flip,{0},{1},{2},{2},0.1,5,10,1,{3},1800,60,60,150,4300,40,{4},65' -f $(if ($i -in 200, 300, 400) { 1 } else { 0 }), ($t / 1000).ToString([Globalization.CultureInfo]::InvariantCulture), $ms, $lat, $(if ($i -eq 500) { 91 } else { 70 })))
    $t += $ms; $i++
  }
  (@($head) + $rows) | Set-Content $path -Encoding utf8
}
# $prep gets the temp run folder and returns extra arguments for the script (or nothing)
function SummarizeFv([scriptblock]$prep, $case = 'frames') {
  $tmp = Join-Path $env:TEMP ('scannx-fv-' + [guid]::NewGuid().ToString('N'))
  Copy-Item (Join-Path $here "fixtures\$case") $tmp -Recurse
  $more = @(& $prep $tmp)
  try { & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Summarize $tmp @more | Out-String } finally { Remove-Item $tmp, "$tmp-fv" -Recurse -Force -ErrorAction SilentlyContinue }
}
$name = 'FrameView_r5apex_dx12.exe_2026_11_10T100010_Log.csv'   # the capture started at 10:00:10, so the 400 ms frame is at 10:01:00

Describe 'disk-log.ps1 -Summarize with an NVIDIA FrameView log' {
  Context 'FrameView log in the run folder, no frames.csv' {
    $out = SummarizeFv { param($d) Remove-Item (Join-Path $d 'frames.csv'); FvLog (Join-Path $d $name) }
    It 'says where the frame times come from' { $out | Should Match 'frame source\s+NVIDIA FrameView log \(1 file\)' }
    It 'reads the frame times and puts them on the clock by the file name' { $out | Should Match 'frames\s+29\d\d frames, avg 20 fps, median 50\.0 ms, p99 50\.0 ms, max 400\.0 ms, 1 hitches over 150 ms' }
    It 'gives the hitch its real time and blames it for the F9 mark' {
      $out | Should Match 'FRAME hitches: 1 frames over 150 ms, worst 400 ms at 10:01:00'
      $out | Should Match '10:01:00 .*frame max 400 ms\s+->\s+frame hitch while'
    }
    It 'adds 1 % low and 0.1 % low' { $out | Should Match '1% low 16 fps, 0\.1% low \d+ fps' }
    It 'adds PC latency without the NA frames' { $out | Should Match 'pcLatency\s+avg 30\.0 ms, max 90\.0 ms \(input to display; 28\d\d frames with data\)' }
    It 'counts the dropped frames' { $out | Should Match 'dropped frames\s+3 of 29\d\d \(0\.1 %\)' }
    It 'adds the FrameView sensors' { $out | Should Match 'sensors\s+CPU temp avg 70 / max 91 C, CPU power avg 65 / max 65 W, GPU power avg 150 / max 150 W \(from FrameView\)' }
  }
  Context 'both frames.csv and a FrameView log' {
    $out = SummarizeFv { param($d) FvLog (Join-Path $d $name) }
    It 'keeps PresentMon (it covers the whole run) and says so' { $out | Should Match 'frame source\s+PresentMon \(frames\.csv\)'; $out | Should Match '3 hitches over 150 ms' }
    It 'adds 1 % low to PresentMon frames too' { $out | Should Match '3 hitches over 150 ms, 1% low \d+ fps, 0\.1% low \d+ fps' }
    It 'adds no FrameView lines' { $out | Should Not Match 'pcLatency|dropped frames|from FrameView' }
  }
  Context '-FrameView names a log outside the run folder' {
    $out = SummarizeFv { param($d) New-Item "$d-fv" -ItemType Directory | Out-Null; $f = Join-Path "$d-fv" $name; FvLog $f; '-FrameView', $f }
    It 'uses it instead of frames.csv' { $out | Should Match 'NVIDIA FrameView log \(1 file\)'; $out | Should Match '1 hitches over 150 ms' }
  }
  Context 'the capture started 16 minutes before the log' {
    # PresentMon frames are aligned to the log by whole half hours (its clock can be hours off); FrameView times must be taken as they are
    $out = SummarizeFv { param($d) Remove-Item (Join-Path $d 'frames.csv'); FvLog (Join-Path $d 'FrameView_r5apex_dx12.exe_2026_11_10T094400_Log.csv') 1110000 1020000 }
    It 'still puts the hitch at 10:01:00' { $out | Should Match 'worst 400 ms at 10:01:00'; $out | Should Match '10:01:00 .*frame max 400 ms' }
  }
  Context 'a file name without the capture time' {
    $out = SummarizeFv { param($d) Remove-Item (Join-Path $d 'frames.csv'); FvLog (Join-Path $d 'FrameView_Summary_Log.csv') }
    It 'is left out: without the start time the frames cannot be placed' { $out | Should Not Match 'frame source|frames\s+\d+ frames'; $out | Should Match 'next step: PresentMon' }
    $out2 = SummarizeFv { param($d) Remove-Item (Join-Path $d 'frames.csv'); FvLog (Join-Path $d $name); FvLog (Join-Path $d 'FrameView_Summary_Log.csv') }
    It 'does not borrow the start time of the log read before it' { $out2 | Should Match 'NVIDIA FrameView log \(1 file\)'; $out2 | Should Match 'frames\s+29\d\d frames' }
  }
}

Describe 'FrameView fallback, application identity and capture time' {
  It 'reads FrameView next to an empty PresentMon file' {
    $out = SummarizeFv { param($d) [IO.File]::WriteAllBytes((Join-Path $d 'frames.csv'), @()); FvLog (Join-Path $d $name) 2000 }
    $out | Should Match 'frame source\s+NVIDIA FrameView log \(1 file\) for r5apex_dx12.exe'
    $out | Should Match '40 frames, avg 20 fps'
  }
  It 'reads FrameView next to a header-only PresentMon file' {
    $out = SummarizeFv { param($d)
      $f = Join-Path $d 'frames.csv'; (Get-Content $f -TotalCount 1) | Set-Content $f
      FvLog (Join-Path $d $name) 2000
    }
    $out | Should Match 'frame source\s+NVIDIA FrameView log \(1 file\) for r5apex_dx12.exe'
    $out | Should Match '40 frames, avg 20 fps'
  }
  It 'uses the requested game across two captures despite a busier app reusing its chain' {
    $out = SummarizeFv { '-Game', 'aRENa.EXE' } 'fv-apps'
    $out | Should Match 'frame source\s+NVIDIA FrameView log \(2 files\) for Arena\.exe'
    $out | Should Match '40 frames, avg 50 fps, median 20\.0 ms'
  }
  It 'ranks applications by all in-game frames before selecting their busiest chain' {
    $out = SummarizeFv { '-Game', 'Unknown' } 'fv-apps'
    $out | Should Match 'frame source\s+NVIDIA FrameView log \(1 file\) for Studio\.exe'
    $out | Should Match '30 frames, avg 67 fps, median 15\.0 ms'
  }
  It 'honors an explicit game whose capture ended before gameplay' {
    $out = SummarizeFv { '-Game', 'Overlay' } 'fv-apps'
    $out | Should Match 'next step: PresentMon'
    $out | Should Not Match 'frames\s+\d+ frames'
  }
  It 'decodes a quoted comma and doubled quotes without shifting frame or sensor values' {
    $capture = { param($d, $field)
      $file = Join-Path $d $name; FvLog $file 10000
      (Get-Content $file) -replace '^r5apex_dx12\.exe,', "$field," | Set-Content $file -Encoding utf8
      '-FrameView', $file
    }
    $plain = SummarizeFv { param($d) & $capture $d 'Plain.exe' }
    $quoted = SummarizeFv { param($d) & $capture $d '"Game, ""Deluxe"".exe"' }
    $quoted | Should Match 'frame source\s+NVIDIA FrameView log \(1 file\) for Game, "Deluxe"\.exe'
    $plain | Should Match '200 frames, avg 20 fps'
    $plain | Should Match 'pcLatency\s+avg 30\.0 ms'
    $plain | Should Match 'sensors\s+CPU temp avg 70'
    $pattern = '(?m)^(frames |pcLatency |dropped frames |sensors )[^\r\n]+'
    ([regex]::Matches($quoted, $pattern).Value -join ';') | Should Be ([regex]::Matches($plain, $pattern).Value -join ';')
  }
  It 'aligns a FrameView capture starting the next day with a mark before midnight' {
    $out = SummarizeFv { param($d) Remove-Item -LiteralPath (Join-Path $d 'frames.csv') } 'midnight-play'
    $out | Should Match '97 frames, avg 10 fps'
    $out | Should Match 'worst 400 ms at 00:00:01'
    $out | Should Match '23:59:58 .*frame max 400 ms\s+->\s+frame hitch'
  }
  It 'copies only matching application logs when available and keeps candidates when none match' {
    # Exercise the file selection used at shutdown with fixture files, without starting the logger.
    $ast = [Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in 'Get-FrameViewCapture','Select-FrameViewFiles'
    }, $false)) { Invoke-Expression $fn.Extent.Text }
    $files = @(Get-ChildItem (Join-Path $here 'fixtures\fv-apps') -Filter 'FrameView_*')
    $selected = @(Select-FrameViewFiles $files @('arena','alternate') | Sort-Object Name)
    $selected.Count | Should Be 2
    $selected[0].Name | Should Be 'FrameView_Arena.exe_2000_01_01T100013_Log.csv'
    $selected[1].Name | Should Be 'FrameView_first.exe_2000_01_01T100000_Log.csv'
    @(Select-FrameViewFiles $files @('unknown')).Count | Should Be 4
  }
}
