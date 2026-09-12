#Requires -Version 5.1
<#
.SYNOPSIS
    Compiles codex-deepseek.exe with the C# compiler that ships with Windows.

.DESCRIPTION
    Uses %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe, so no .NET SDK,
    NuGet package or runtime install is required. The result is a single
    14 KB executable with no dependencies beyond .NET Framework 4.x, which every
    supported Windows version already has.

    By default the binary is written to .\dist. Use -Install to copy it into
    %USERPROFILE%\.codex-deepseek\bin, the location install.ps1 puts on PATH.

.EXAMPLE
    pwsh -File .\build.ps1
    pwsh -File .\build.ps1 -Install
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$Install
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not reliably populated while param() defaults are evaluated,
# so the default is resolved here instead.
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $PSScriptRoot 'dist'
}

$source = Join-Path $PSScriptRoot 'src\CodexDeepSeek.cs'
$output = Join-Path $OutputDirectory 'codex-deepseek.exe'

if (-not (Test-Path -LiteralPath $source)) {
    throw "source not found: $source"
}

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) {
    throw "csc.exe not found under $env:WINDIR\Microsoft.NET - install .NET Framework 4.x"
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
if (Test-Path -LiteralPath $output) {
    Remove-Item -LiteralPath $output -Force
}

& $csc /nologo /optimize+ /target:exe "/out:$output" $source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) {
    throw "build failed: $output was not produced"
}

Write-Host "built   $output" -ForegroundColor Green

if ($Install) {
    $target = Join-Path $env:USERPROFILE '.codex-deepseek\bin'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item -LiteralPath $output -Destination $target -Force
    Write-Host "copied  $target\codex-deepseek.exe" -ForegroundColor Green
}
