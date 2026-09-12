#Requires -Version 5.1
<#
.SYNOPSIS
    Installs an isolated DeepSeek Codex home plus the codex-deepseek launcher.

.DESCRIPTION
    Creates %USERPROFILE%\.codex-deepseek (or -DeepSeekHome), writes the
    DeepSeek provider config, copies the pinned model catalog, builds
    codex-deepseek.exe and puts it on the user PATH.

    Nothing here touches %USERPROFILE%\.codex, which stays dedicated to ChatGPT
    Desktop and the plain `codex` command.

    The API key is written into %USERPROFILE%\.codex-deepseek\config.toml,
    which .gitignore excludes. It is never echoed back.

.PARAMETER ApiKey
    DeepSeek API key. Defaults to $env:DEEPSEEK_API_KEY, otherwise you are
    prompted (input is hidden).

.PARAMETER DeepSeekHome
    Where the isolated Codex home lives. Defaults to %USERPROFILE%\.codex-deepseek.
    A non-default path is exported as the user-level CODEX_DEEPSEEK_HOME, because
    the launcher falls back to %USERPROFILE%\.codex-deepseek when that variable is
    not set.

.PARAMETER SkipPath
    Do not touch the user PATH. Use this when you want to call the launcher by
    full path.

.PARAMETER Force
    Overwrite an existing config.toml in the DeepSeek home (a timestamped backup
    is written first).

.EXAMPLE
    pwsh -File .\install.ps1
    pwsh -File .\install.ps1 -ApiKey $env:DEEPSEEK_API_KEY -Model deepseek-v4-pro
    pwsh -File .\install.ps1 -DeepSeekHome D:\codex-deepseek -SkipPath

    # Without PowerShell 7:
    powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding()]
param(
    [string]$DeepSeekHome = (Join-Path $env:USERPROFILE '.codex-deepseek'),
    [string]$ApiKey = $env:DEEPSEEK_API_KEY,
    [string]$BaseUrl = 'https://api.deepseek.com/',
    [string]$Model = 'deepseek-flash',
    [string]$ReasoningEffort = 'high',
    [switch]$SkipPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

function Read-ApiKey {
    $secure = Read-Host -Prompt 'DeepSeek API key' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

$template = Join-Path $PSScriptRoot 'config\config.toml.example'
$catalog = Join-Path $PSScriptRoot 'config\models.json'

foreach ($required in @($template, $catalog)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "missing file: $required - run this script from a full clone of the repository"
    }
}

Write-Step "Checking for the real Codex CLI"
$codex = Get-Command codex -ErrorAction SilentlyContinue
if ($codex) {
    Write-Host "found $($codex.Source)"
}
else {
    Write-Warning "`codex` is not on PATH. The launcher can still start it as long as it is installed in the usual places, but install and verify Codex CLI first."
}

Write-Step "Building the launcher"
& (Join-Path $PSScriptRoot 'build.ps1') -OutputDirectory (Join-Path $PSScriptRoot 'dist')

$binDirectory = Join-Path $DeepSeekHome 'bin'
New-Item -ItemType Directory -Force -Path $binDirectory | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dist\codex-deepseek.exe') -Destination $binDirectory -Force
Write-Host "installed $binDirectory\codex-deepseek.exe"

foreach ($shim in @('cx', 'cx.cmd')) {
    $shimSource = Join-Path $PSScriptRoot "bin\$shim"
    if (Test-Path -LiteralPath $shimSource) {
        Copy-Item -LiteralPath $shimSource -Destination $binDirectory -Force
    }
}

Write-Step "Creating the isolated Codex home"
Copy-Item -LiteralPath $catalog -Destination (Join-Path $DeepSeekHome 'models.json') -Force
Write-Host "catalog  $(Join-Path $DeepSeekHome 'models.json')"

$configPath = Join-Path $DeepSeekHome 'config.toml'
if ((Test-Path -LiteralPath $configPath) -and -not $Force) {
    Write-Host "config   $configPath already exists, left untouched (use -Force to rewrite)"
}
else {
    if (-not $ApiKey) {
        $ApiKey = Read-ApiKey
    }
    if (-not $ApiKey) {
        throw 'no API key supplied'
    }

    $modelsJsonPath = (Join-Path $DeepSeekHome 'models.json').Replace('\', '/')
    $text = Get-Content -LiteralPath $template -Raw
    $text = $text.Replace('__MODELS_JSON__', $modelsJsonPath)
    $text = $text.Replace('__API_KEY__', $ApiKey)
    $text = $text.Replace('__MODEL__', $Model)
    $text = $text.Replace('__BASE_URL__', $BaseUrl)
    $text = $text.Replace('__REASONING_EFFORT__', $ReasoningEffort)

    # UTF-8 without BOM: the Codex config parser is happier without one.
    if (Test-Path -LiteralPath $configPath) {
        $backup = "$configPath.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $configPath -Destination $backup -Force
        Write-Host "backup   $backup"
    }
    [IO.File]::WriteAllText($configPath, $text, (New-Object Text.UTF8Encoding($false)))
    Write-Host "config   $configPath"
}

if (-not $SkipPath) {
    Write-Step "Adding the launcher to the user PATH"
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($userPath -split ';' | Where-Object { $_ })
    if ($entries -contains $binDirectory) {
        Write-Host "$binDirectory is already on PATH"
    }
    else {
        $updated = (@($entries) + $binDirectory) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
        Write-Host "added  $binDirectory"
    }
}

$defaultHome = Join-Path $env:USERPROFILE '.codex-deepseek'
if ($DeepSeekHome.TrimEnd('\') -ne $defaultHome.TrimEnd('\')) {
    Write-Step "Recording the custom home"
    [Environment]::SetEnvironmentVariable('CODEX_DEEPSEEK_HOME', $DeepSeekHome, 'User')
    Write-Host "CODEX_DEEPSEEK_HOME (User) = $DeepSeekHome"
}

Write-Step "Next steps"
Write-Host @'
Open a NEW terminal, then:

  codex-deepseek --version            # -> codex-cli <version>
  codex-deepseek exec "print hello"   # hits your DeepSeek key

Your plain `codex` command is untouched and still uses ChatGPT.

Multica users, additionally:

  pwsh -File .\build.ps1 -InstallMultica
  multica runtime profile create --display-name "Codex DeepSeek" `
    --protocol-family codex --command-name codex-deepseek `
    --description "Local Codex CLI pinned to the DeepSeek gateway"
  pwsh -File .\multica\Setup-MulticaDeepSeek.ps1 -WorkspaceId <workspace-id>
'@
