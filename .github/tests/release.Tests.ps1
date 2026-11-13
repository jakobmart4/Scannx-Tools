# Synthetic build inputs exercise packaging without downloading or executing PresentMon.
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$build = Join-Path $repo 'tools\build-release.ps1'
$workflow = [IO.File]::ReadAllText((Join-Path $repo '.github\workflows\release.yml'))
$validation = [regex]::Match($workflow, '(?ms)      - name: Validate version[^\n]*\n.*?        run: \|\r?\n(.*?)(?=\r?\n      - name:)')
if (-not $validation.Success) { throw 'Release-note validation step not found' }
$validateNotes = [scriptblock]::Create(($validation.Groups[1].Value -replace '(?m)^          ', ''))

Describe 'Release package' {
  BeforeEach {
    $pm = Join-Path $TestDrive 'PresentMon.exe'
    $license = Join-Path $TestDrive 'PresentMon-LICENSE.txt'
    [IO.File]::WriteAllText($pm, 'synthetic executable, never run')
    [IO.File]::WriteAllText($license, 'Intel Corporation. Permission is hereby granted, free of charge')
    $out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    Mock Get-FileHash { [pscustomobject]@{ Hash = '364e5d98d4d134bd54dd25c22ed2ca2f4883f8bc3ed6502bee0c151e3436d30c' } } -ParameterFilter { $Path -eq $pm }
    Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Intel Corporation, O=Intel Corporation, C=US' } } }
  }

  It 'keeps the eight payload names and uses forward slashes' {
    & $build -Version v1.2.3 -PresentMon $pm -PresentMonLicense $license -Out $out | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $out 'Scannx-v1.2.3.zip'))
    try {
      $names = @($zip.Entries | ForEach-Object FullName | Sort-Object)
      $expected = @('Scannx.cmd', 'scan-check.ps1', 'disk-log.ps1', 'README.md', 'LICENSE', 'CHANGELOG.md', 'PresentMon-2.3.1-x64.exe', 'PresentMon-LICENSE.txt' | ForEach-Object { "Scannx-v1.2.3/$_" } | Sort-Object)
      ($names -join '|') | Should Be ($expected -join '|')
      ($names -join '|') | Should Not Match '\\'
    } finally { $zip.Dispose() }
  }

  It 'writes the real zip hash with LF and no BOM' {
    & $build -Version v1.2.3 -PresentMon $pm -PresentMonLicense $license -Out $out | Out-Null
    $zipPath = Join-Path $out 'Scannx-v1.2.3.zip'
    $hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
    $bytes = [IO.File]::ReadAllBytes("$zipPath.sha256")
    [Text.Encoding]::UTF8.GetString($bytes) | Should Be "$hash  Scannx-v1.2.3.zip`n"
    $bytes[0] | Should Not Be 239
    $bytes[-1] | Should Be 10
  }

  It 'rejects a modified executable before staging' {
    Mock Get-FileHash { [pscustomobject]@{ Hash = ('0' * 64) } } -ParameterFilter { $Path -eq $pm }
    { & $build -Version v1.2.3 -PresentMon $pm -PresentMonLicense $license -Out $out } | Should Throw 'PresentMon SHA256'
    Test-Path $out | Should Be $false
  }

  It 'rejects an invalid signature before staging' {
    Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
    { & $build -Version v1.2.3 -PresentMon $pm -PresentMonLicense $license -Out $out } | Should Throw 'valid Authenticode'
    Test-Path $out | Should Be $false
  }

  It 'rejects a damaged Intel signature even when its certificate names Intel' {
    Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Intel Corporation, O=Intel Corporation, C=US' } } }
    { & $build -Version v1.2.3 -PresentMon $pm -PresentMonLicense $license -Out $out } | Should Throw 'valid Authenticode'
    Test-Path $out | Should Be $false
  }

  It 'rejects a valid signature from an Intel-like organization' {
    Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Other, O=Intel Corporation Impostor, C=US' } } }
    { & $build -Version v1.2.3 -PresentMon $pm -PresentMonLicense $license -Out $out } | Should Throw 'valid Authenticode'
    Test-Path $out | Should Be $false
  }

  It 'rejects a version containing path separators' {
    { & $build -Version '..\elsewhere' -PresentMon $pm -PresentMonLicense $license -Out $out } | Should Throw
    Test-Path $out | Should Be $false
  }
}

Describe 'Release-note validation' {
  BeforeEach {
    $savedEnv = @{}
    foreach ($key in 'GITHUB_EVENT_NAME', 'GITHUB_REF_TYPE', 'GITHUB_REF_NAME', 'INPUT_VERSION', 'GITHUB_ENV') {
      $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
    }
    Push-Location $TestDrive
    $env:GITHUB_EVENT_NAME = 'push'; $env:GITHUB_REF_TYPE = 'tag'; $env:GITHUB_REF_NAME = 'v1.2.3'
    $env:INPUT_VERSION = ''; $env:GITHUB_ENV = Join-Path $TestDrive 'github-env.txt'
    $note = "## v1.2.3 - date`n`nRelease notes.`n`n## v1.2.4 - date`n`nOther notes.`n"
    [IO.File]::WriteAllText((Join-Path $TestDrive 'CHANGELOG.md'), $note, (New-Object Text.UTF8Encoding($false)))
  }
  AfterEach {
    Pop-Location
    foreach ($key in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process') }
  }

  It 'selects the pushed tag and keeps UTF-8 release notes' {
    $text = "Release notes: $([char]0x00F5)$([char]0x00E4)."
    [IO.File]::WriteAllText((Join-Path $TestDrive 'CHANGELOG.md'), "## v1.2.3 - date`n`n$text`n", (New-Object Text.UTF8Encoding($false)))
    & $validateNotes
    [IO.File]::ReadAllText((Join-Path $TestDrive 'notes.md')) | Should Be $text
    [IO.File]::ReadAllText($env:GITHUB_ENV) | Should Match 'RELEASE_VERSION=v1.2.3'
  }

  It 'uses the input for a manual run even when targeting a tag' {
    $env:GITHUB_EVENT_NAME = 'workflow_dispatch'; $env:INPUT_VERSION = 'v1.2.4'
    & $validateNotes
    [IO.File]::ReadAllText((Join-Path $TestDrive 'notes.md')) | Should Be 'Other notes.'
  }

  It 'allows attestation and publication only for pushed tags' {
    foreach ($step in 'Attest the release zip', 'Publish the GitHub release') {
      $guard = [regex]::Match($workflow, "(?m)      - name: $step\r?\n        if: ([^\r\n]+)")
      $guard.Success | Should Be $true
      foreach ($case in @(
        @{ Event = 'push'; Ref = 'tag'; Allowed = $true },
        @{ Event = 'workflow_dispatch'; Ref = 'tag'; Allowed = $false },
        @{ Event = 'workflow_dispatch'; Ref = 'branch'; Allowed = $false },
        @{ Event = 'push'; Ref = 'branch'; Allowed = $false }
      )) {
        $expression = $guard.Groups[1].Value.Replace('github.event_name', "'$($case.Event)'").Replace('github.ref_type', "'$($case.Ref)'").Replace(' == ', ' -eq ').Replace(' && ', ' -and ')
        (& ([scriptblock]::Create($expression))) | Should Be $case.Allowed
      }
    }
  }

  It 'rejects a missing version section' {
    $env:GITHUB_REF_NAME = 'v9.9.9'
    { & $validateNotes } | Should Throw 'no nonempty'
  }

  It 'rejects an empty version section' {
    [IO.File]::WriteAllText((Join-Path $TestDrive 'CHANGELOG.md'), "## v1.2.3 - date`n`n  `n## v1.2.4 - date`nOther notes.`n")
    { & $validateNotes } | Should Throw 'no nonempty'
  }

  It 'rejects an unsafe manual version before reading release notes' {
    $env:GITHUB_EVENT_NAME = 'workflow_dispatch'; $env:INPUT_VERSION = '..\elsewhere'
    { & $validateNotes } | Should Throw 'Invalid release version'
  }
}
