#Requires -Version 5.1
<#
.SYNOPSIS
    Functional tests for src\CodexDeepSeek.cs, driven through the built exe.

.DESCRIPTION
    Compiles tests\WindowsStub.cs as a stand-in for codex.exe and points
    CODEX_DEEPSEEK_TARGET at it, so the launcher can be exercised without a real
    Codex installation. A throwaway CODEX_DEEPSEEK_HOME keeps the machine's own
    DeepSeek home out of it.

.EXAMPLE
    pwsh -File .\tests\windows-launcher-test.ps1
#>
[CmdletBinding()]
param(
    [string]$LauncherPath
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not $LauncherPath) {
    $LauncherPath = Join-Path $root 'dist\codex-deepseek.exe'
}

if (-not (Test-Path -LiteralPath $LauncherPath)) {
    throw "launcher not found: $LauncherPath - run build.ps1 first"
}

$failures = 0

function Write-Ok {
    param([string]$Text)
    Write-Host "ok   $Text" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Text)
    Write-Host "FAIL $Text" -ForegroundColor Red
    $script:failures++
}

function Assert-Contains {
    param([string]$Description, [string]$Haystack, [string]$Needle)
    if ($Haystack -like "*$Needle*") { Write-Ok $Description } else { Write-Fail "$Description (expected to find '$Needle' in '$Haystack')" }
}

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) {
    throw 'csc.exe not found'
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("codex-deepseek-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    # ------------------------------------------------------------ the stub
    $stub = Join-Path $work 'codex-stub.exe'
    & $csc /nologo /optimize+ /target:exe "/out:$stub" (Join-Path $PSScriptRoot 'WindowsStub.cs') | Out-Null
    if (-not (Test-Path -LiteralPath $stub)) { throw "could not compile the stub into $stub" }

    $deepseekHome = Join-Path $work 'home'
    New-Item -ItemType Directory -Force -Path $deepseekHome | Out-Null
    Set-Content -LiteralPath (Join-Path $deepseekHome 'config.toml') -Value 'model = "deepseek-flash"' -Encoding ASCII

    function Invoke-Launcher {
        param([string[]]$Arguments, [hashtable]$Environment = @{})

        $env:CODEX_DEEPSEEK_TARGET = $stub
        $env:CODEX_DEEPSEEK_HOME = $deepseekHome
        foreach ($key in $Environment.Keys) {
            Set-Item -Path "env:$key" -Value $Environment[$key]
        }

        # Redirecting a native command's stderr under $ErrorActionPreference =
        # 'Stop' turns the first stderr write into a terminating error before
        # $LASTEXITCODE can be read, so relax it just for this call.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $output = & $LauncherPath @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
        $ErrorActionPreference = $previousPreference

        Remove-Item Env:\CODEX_DEEPSEEK_TARGET -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_DEEPSEEK_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:\STUB_EXIT_CODE -ErrorAction SilentlyContinue

        return [pscustomobject]@{ Output = $output; ExitCode = $code }
    }

    # -------------------------------------------------------- forwarding
    $result = Invoke-Launcher -Arguments @('--version')
    Assert-Contains 'pins CODEX_HOME to the DeepSeek home' $result.Output "CODEX_HOME=$deepseekHome"
    Assert-Contains 'forwards --version to the real binary' $result.Output 'ARGS=--version'

    $result = Invoke-Launcher -Arguments @('exec', 'print hello')
    Assert-Contains 'forwards a subcommand and its argument' $result.Output 'ARGS=exec print hello'

    # No embedded double quotes here: PowerShell itself mangles those before the
    # launcher ever sees them, so the POSIX suite covers that case instead.
    $result = Invoke-Launcher -Arguments @('exec', 'a & b | c ^ d')
    Assert-Contains 'keeps spaces and shell metacharacters inside one argument' $result.Output 'ARGS=exec a & b | c ^ d'

    $result = Invoke-Launcher -Arguments @('exec', '--config=model=deepseek-flash', 'a b')
    Assert-Contains 'keeps an = assignment and a spaced argument separate' $result.Output 'ARGS=exec --config=model=deepseek-flash a b'

    $result = Invoke-Launcher -Arguments @('exec', 'two  spaces')
    Assert-Contains 'preserves internal spacing' $result.Output 'ARGS=exec two  spaces'

    $result = Invoke-Launcher -Arguments @('debug', 'models', '--bundled')
    Assert-Contains "forwards 'debug models' instead of answering it" $result.Output 'ARGS=debug models --bundled'

    $result = Invoke-Launcher -Arguments @('exec', 'x') -Environment @{ STUB_EXIT_CODE = '7' }
    if ($result.ExitCode -eq 7) { Write-Ok 'propagates the exit code of the real binary' }
    else { Write-Fail "exit code not propagated (got $($result.ExitCode))" }

    # ------------------------------------------------------------ errors
    $emptyHome = Join-Path $work 'empty'
    New-Item -ItemType Directory -Force -Path $emptyHome | Out-Null
    $env:CODEX_DEEPSEEK_TARGET = $stub
    $env:CODEX_DEEPSEEK_HOME = $emptyHome
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = & $LauncherPath exec x 2>&1 | Out-String
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    Remove-Item Env:\CODEX_DEEPSEEK_TARGET -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_DEEPSEEK_HOME -ErrorAction SilentlyContinue

    if ($code -eq 127) { Write-Ok 'exits 127 when the DeepSeek home has no config.toml' }
    else { Write-Fail "expected 127 for a missing config, got $code" }
    Assert-Contains 'names the missing config in the error message' $output 'missing DeepSeek config'

    # ------------------------------------------------ no Codex anywhere
    $standaloneReleases = Join-Path $env:USERPROFILE '.codex\packages\standalone\releases'
    $codexOnPath = Get-Command codex -ErrorAction SilentlyContinue
    if ((Test-Path -LiteralPath $standaloneReleases) -or $codexOnPath) {
        Write-Host 'skip a real Codex is installed here, cannot test the not-found path' -ForegroundColor Yellow
    }
    else {
        $env:CODEX_DEEPSEEK_HOME = $deepseekHome
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $output = & $LauncherPath --version 2>&1 | Out-String
        $code = $LASTEXITCODE
        $ErrorActionPreference = $previousPreference
        Remove-Item Env:\CODEX_DEEPSEEK_HOME -ErrorAction SilentlyContinue
        if ($code -eq 127) { Write-Ok 'exits 127 when no Codex can be found' }
        else { Write-Fail "expected 127 when Codex is missing, got $code" }
        Assert-Contains 'explains how to point at Codex' $output 'CODEX_DEEPSEEK_TARGET'
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'all windows launcher tests passed' -ForegroundColor Green
    # The runner appends `exit $LASTEXITCODE`, and the last native command we ran
    # was expected to fail (the 127 assertions).
    exit 0
}
else {
    Write-Host "$failures test(s) failed" -ForegroundColor Red
    exit 1
}
