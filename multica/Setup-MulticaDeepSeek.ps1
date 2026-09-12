#Requires -Version 5.1
<#
.SYNOPSIS
  Enable the local DeepSeek Codex runtime inside a Multica workspace.

.DESCRIPTION
  Runtime profiles are workspace scoped, so a workspace that has no "Codex
  DeepSeek" profile only offers the auto-detected "Codex (<machine>)" runtimes.
  Those spawn the real codex.exe against the ChatGPT-authenticated home, and a
  turn with model = deepseek-flash fails with
  "The 'deepseek-flash' model is not supported when using Codex with a ChatGPT
  account." This script creates the profile (command_name = codex-deepseek) in
  the target workspace and rebinds every DeepSeek agent that is still parked on
  a plain Codex runtime.

  Creating a runtime profile requires workspace admin/owner rights. A 403 is
  reported with the exact command the workspace owner has to run.

  The script is idempotent: an existing profile is reused and an agent whose
  runtime / model / thinking level already match is left untouched.

.EXAMPLE
  # Preview only; nothing is written to the Multica server.
  .\Setup-MulticaDeepSeek.ps1 -WorkspaceId 58cac22f-377e-4cec-8bd0-08fb05467fee -DryRun

.EXAMPLE
  # Create the profile and rebind every deepseek-flash agent in that workspace.
  .\Setup-MulticaDeepSeek.ps1 -WorkspaceId 58cac22f-377e-4cec-8bd0-08fb05467fee

.EXAMPLE
  # Only the profile, and restart the daemon if it does not register by itself.
  .\Setup-MulticaDeepSeek.ps1 -WorkspaceId <workspace-id> -SkipRebind -RestartDaemon

.EXAMPLE
  # Only part of the agents, on a specific runtime of a specific machine.
  .\Setup-MulticaDeepSeek.ps1 -WorkspaceId <workspace-id> `
      -Agents 'Lead Dev','Code Reviewer' -RuntimeName 'Codex DeepSeek (mlangTse)'
#>
[CmdletBinding()]
param(
    [string]$MulticaExe = (Join-Path $env:USERPROFILE '.multica\bin\multica.exe'),

    # Workspace to fix. Defaults to $env:MULTICA_WORKSPACE_ID, then to the only
    # workspace you belong to.
    [string]$WorkspaceId = $env:MULTICA_WORKSPACE_ID,

    [string]$ProfileName = 'Codex DeepSeek',
    [string]$CommandName = 'codex-deepseek',
    [string]$Description = 'Codex CLI pinned to the local DeepSeek gateway (deepseek-flash / deepseek-v4-pro)',

    # Applied to every agent the script rebinds.
    [string]$Model = 'deepseek-flash',
    [string]$ThinkingLevel = 'high',

    # Agents to rebind by name. Empty = every agent whose model is in
    # -DeepSeekModels.
    [string[]]$Agents = @(),
    [string[]]$DeepSeekModels = @('deepseek-flash', 'deepseek-v4-pro'),

    # Exact runtime to bind to, e.g. 'Codex DeepSeek (mlangTse)'. Empty = the
    # first online runtime of this profile.
    [string]$RuntimeName = '',

    [int]$WaitSeconds = 180,
    [switch]$SkipRebind,

    # Restart the daemon when the profile does not show up as a runtime in time.
    # That interrupts every run in flight on this machine.
    [switch]$RestartDaemon,

    # Print the planned actions instead of performing them.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

function Invoke-Multica {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & $MulticaExe @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw ("multica {0} failed (exit {1}):`n{2}" -f ($Arguments -join ' '), $exitCode, $text)
    }

    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Invoke-MulticaJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = Invoke-Multica -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        return @()
    }
    return ($result.Text | ConvertFrom-Json)
}

function Format-MulticaCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') { '"' + $argument.Replace('"', '\"') + '"' } else { $argument }
    }
    return "multica $($quoted -join ' ')"
}

function Assert-ProfilePermission {
    param([string]$Text)

    if ($Text -match 'insufficient permissions' -or $Text -match 'permission') {
        throw @"
Workspace $WorkspaceId does not allow this account to create runtime profiles.

Creating a runtime profile needs workspace admin/owner rights; this account is only
a member there. Ask the workspace owner to either

  1. promote this account to admin/owner, or
  2. run this once on any machine that has the codex-deepseek wrapper:

     multica --workspace-id $WorkspaceId runtime profile create `
       --display-name "$ProfileName" `
       --protocol-family codex `
       --command-name $CommandName `
       --description "$Description"

After that, re-run this script to rebind the agents.
"@
    }
}

# ---------------------------------------------------------------- environment

if (-not (Test-Path -LiteralPath $MulticaExe)) {
    $onPath = Get-Command 'multica.exe' -ErrorAction SilentlyContinue
    if ($onPath) { $MulticaExe = $onPath.Source }
    else { throw "multica CLI not found. Pass -MulticaExe or install the Multica daemon." }
}

$wrapper = @(
    (Join-Path $env:USERPROFILE '.multica\bin\codex-deepseek.exe'),
    (Join-Path $env:USERPROFILE '.multica\bin\codex-deepseek')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $wrapper) {
    throw "codex-deepseek(.exe) not found. Run .\build.ps1 first; the daemon resolves '$CommandName' through PATH."
}

$binDir = Split-Path -Parent $wrapper
$pathEntries = @(
    [Environment]::GetEnvironmentVariable('PATH', 'User'),
    [Environment]::GetEnvironmentVariable('PATH', 'Machine'),
    $env:PATH
) | Where-Object { $_ } | ForEach-Object { $_ -split ';' } | Where-Object { $_ }

if (-not ($pathEntries | Where-Object { $_.TrimEnd('\') -ieq $binDir.TrimEnd('\') })) {
    Write-Warning "$binDir is not on PATH. The daemon resolves '$CommandName' through PATH, so it will skip this profile."
}

if (-not $WorkspaceId) {
    $workspaces = Invoke-MulticaJson -Arguments @('workspace', 'list', '--output', 'json')
    if (@($workspaces).Count -eq 1) {
        $WorkspaceId = $workspaces[0].id
        Write-Host "Using the only workspace you belong to: $($workspaces[0].name) ($WorkspaceId)"
    }
    else {
        throw "Pass -WorkspaceId (or set MULTICA_WORKSPACE_ID). Workspaces: $(($workspaces | ForEach-Object { "$($_.name)=$($_.id)" }) -join ', ')"
    }
}

$wsArgs = @('--workspace-id', $WorkspaceId)

Write-Host "Workspace : $WorkspaceId"
Write-Host "Profile   : $ProfileName (command_name=$CommandName)"
Write-Host "Wrapper   : $wrapper"
Write-Host "Model     : $Model (thinking=$ThinkingLevel)"
if ($DryRun) { Write-Host 'Mode      : DRY RUN (nothing is written)' -ForegroundColor Yellow }

# ------------------------------------------------------------------- profile

Write-Step "Runtime profile '$ProfileName'"

$profiles = Invoke-MulticaJson -Arguments ($wsArgs + @('runtime', 'profile', 'list', '--output', 'json'))
$profile = @($profiles) | Where-Object { $_.display_name -eq $ProfileName } | Select-Object -First 1

if ($profile) {
    Write-Host "already exists: profile_id=$($profile.id) enabled=$($profile.enabled) command_name=$($profile.command_name)"
    if ($profile.command_name -ne $CommandName) {
        Write-Warning "profile command_name is '$($profile.command_name)', expected '$CommandName'. Profiles cannot change protocol family; fix it in the Multica UI or recreate the profile."
    }
}
else {
    $createArgs = @(
        'runtime', 'profile', 'create',
        '--display-name', $ProfileName,
        '--protocol-family', 'codex',
        '--command-name', $CommandName,
        '--description', $Description,
        '--output', 'json'
    )

    if ($DryRun) {
        Write-Host "would run: $(Format-MulticaCommand -Arguments ($wsArgs + $createArgs))"
    }
    else {
        $result = Invoke-Multica -Arguments ($wsArgs + $createArgs) -AllowFailure
        if ($result.ExitCode -ne 0) {
            Assert-ProfilePermission -Text $result.Text
            throw "runtime profile create failed (exit $($result.ExitCode)):`n$($result.Text)"
        }
        $profile = $result.Text | ConvertFrom-Json
        Write-Host "created: profile_id=$($profile.id)" -ForegroundColor Green
    }
}

# ------------------------------------------------------------------- runtime

function Find-DeepSeekRuntime {
    $runtimes = Invoke-MulticaJson -Arguments ($wsArgs + @('runtime', 'list', '--output', 'json'))
    $candidates = @($runtimes) | Where-Object { $_.provider -eq 'codex' -and $_.profile_id }

    if ($profile) {
        $byProfile = @($candidates) | Where-Object { $_.profile_id -eq $profile.id }
        if ($byProfile) { $candidates = $byProfile }
    }

    if ($RuntimeName) {
        $candidates = @($candidates) | Where-Object { $_.name -eq $RuntimeName }
    }
    elseif (-not $profile) {
        $candidates = @($candidates) | Where-Object { $_.name -like "$ProfileName*" }
    }

    $online = @($candidates) | Where-Object { $_.status -eq 'online' } | Select-Object -First 1
    if ($online) { return $online }
    return (@($candidates) | Select-Object -First 1)
}

Write-Step 'DeepSeek runtime on this machine'

$runtime = $null
$deadline = (Get-Date).AddSeconds([Math]::Max(0, $WaitSeconds))

while (-not $runtime) {
    $runtime = Find-DeepSeekRuntime
    if ($runtime -or (Get-Date) -ge $deadline) { break }
    Write-Host 'waiting for the daemon to register the profile ...'
    Start-Sleep -Seconds 10
}

if (-not $runtime -and $RestartDaemon -and -not $DryRun) {
    Write-Step 'Restarting the daemon (interrupts runs in flight)'
    Invoke-Multica -Arguments @('daemon', 'restart') | Out-Null
    $deadline = (Get-Date).AddSeconds([Math]::Max(60, $WaitSeconds))
    while (-not $runtime -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $runtime = Find-DeepSeekRuntime
    }
}

if (-not $runtime) {
    if ($DryRun) {
        Write-Host 'dry run: the runtime is registered by the daemon after the profile exists.'
    }
    else {
        Write-Warning @"
The daemon has not (yet) published a runtime for this profile.
Restart it once and re-run the script:

  multica daemon restart

Restarting interrupts every run in flight on this machine, including this
conversation when it is itself hosted by the daemon.
"@
    }
}
else {
    Write-Host "runtime: $($runtime.name) id=$($runtime.id) status=$($runtime.status)" -ForegroundColor Green
}

# -------------------------------------------------------------------- agents

if ($SkipRebind) {
    Write-Step 'Agents'
    Write-Host 'skipped (-SkipRebind)'
    return
}

Write-Step 'Agents'

$allAgents = Invoke-MulticaJson -Arguments ($wsArgs + @('agent', 'list', '--output', 'json'))

if ($Agents.Count -gt 0) {
    $missing = @($Agents | Where-Object { $name = $_; -not (@($allAgents) | Where-Object { $_.name -eq $name }) })
    if ($missing.Count -gt 0) {
        throw "agent(s) not found in workspace $WorkspaceId : $($missing -join ', ')"
    }
    $targets = @($allAgents) | Where-Object { $Agents -contains $_.name }
}
else {
    $targets = @($allAgents) | Where-Object { $_.model -and ($DeepSeekModels -contains $_.model) }
}

if (@($targets).Count -eq 0) {
    Write-Host 'nothing to do: no DeepSeek agent in this workspace'
}

$summary = foreach ($agent in @($targets)) {
    $updateArgs = @('agent', 'update', $agent.id)
    $actions = @()

    if (-not $runtime) {
        $actions += 'runtime=blocked(no runtime registered)'
    }
    elseif ($agent.runtime_id -ne $runtime.id) {
        $updateArgs += @('--runtime-id', $runtime.id)
        $actions += "runtime=$($agent.runtime_id) -> $($runtime.id)"
    }
    else {
        $actions += 'runtime=ok'
    }

    if ($agent.model -ne $Model) {
        $updateArgs += @('--model', $Model)
        $actions += "model=$($agent.model) -> $Model"
    }
    else {
        $actions += "model=$Model"
    }

    if ($ThinkingLevel -and $agent.thinking_level -ne $ThinkingLevel) {
        $updateArgs += @('--thinking-level', $ThinkingLevel)
        $actions += "thinking=$($agent.thinking_level) -> $ThinkingLevel"
    }
    else {
        $actions += "thinking=$ThinkingLevel"
    }

    $needsUpdate = $updateArgs.Count -gt 3
    $action = if (-not $needsUpdate) { 'ok' }
              elseif ($DryRun) { 'dry-run' }
              elseif (-not $runtime) { 'blocked' }
              else { 'updating' }

    if ($needsUpdate -and -not $DryRun -and $runtime) {
        $result = Invoke-Multica -Arguments ($wsArgs + $updateArgs + @('--output', 'json')) -AllowFailure
        if ($result.ExitCode -ne 0) {
            Assert-ProfilePermission -Text $result.Text
            $action = "failed (exit $($result.ExitCode))"
            Write-Warning "agent update failed for '$($agent.name)':`n$($result.Text)"
        }
    }
    elseif ($needsUpdate -and $DryRun) {
        Write-Host "would run: $(Format-MulticaCommand -Arguments ($wsArgs + $updateArgs))"
    }

    [pscustomobject]@{
        Agent   = $agent.name
        Action  = $action
        Changes = ($actions -join '; ')
    }
}

if ($summary) {
    Write-Host ''
    $summary | Format-Table -AutoSize -Wrap | Out-String | Write-Host
}

if ($DryRun -or -not $runtime) {
    Write-Step 'Result'
    if (-not $runtime) { Write-Host 'Not finished: the workspace still has no registered DeepSeek runtime.' }
    else { Write-Host 'Dry run finished; re-run without -DryRun to apply.' }
    return
}

Write-Step 'Result'
$remaining = Invoke-MulticaJson -Arguments ($wsArgs + @('agent', 'list', '--output', 'json')) |
    Where-Object { $_.model -and ($DeepSeekModels -contains $_.model) -and $_.runtime_id -ne $runtime.id }

if (@($remaining).Count -gt 0) {
    Write-Warning "still on a non-DeepSeek runtime: $(($remaining | ForEach-Object { $_.name }) -join ', ')"
}
else {
    Write-Host "every DeepSeek agent in $WorkspaceId now runs on $($runtime.name) ($($runtime.id))." -ForegroundColor Green
}
