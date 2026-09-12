#Requires -Version 5.1
<#
.SYNOPSIS
    One-way merge: native Codex home -> DeepSeek home.

.DESCRIPTION
    Merging means both sides survive. Nothing is ever deleted from the target:

      * AGENTS.md      - the source is appended under a marker recording a hash
                         of its content, so a second run is a no-op. The target's
                         own rules stay at the top of the file.
      * skills\*       - copied file by file, overwriting same-named files,
                         leaving any skill that only exists in the target alone.
      * skills\.system - skipped: each home gets its own copy from the Codex
                         binary, and the CLI refreshes it.

.PARAMETER Also
    Extra locations to merge skills from, for skills that do not live in the
    native home's skills\ folder. Every direct subdirectory of these paths that
    contains a SKILL.md is merged, e.g.
    -Also "$env:USERPROFILE\.codex\automations\chronicle-workflow-skills".

.EXAMPLE
    pwsh -File .\tools\sync-from-native.ps1 -DryRun
    pwsh -File .\tools\sync-from-native.ps1
    pwsh -File .\tools\sync-from-native.ps1 -Also "$env:USERPROFILE\.codex\automations\chronicle-workflow-skills"
#>
[CmdletBinding()]
param(
    [string]$From = (Join-Path $env:USERPROFILE '.codex'),
    [string]$To,
    [string[]]$Also = @(),
    [switch]$DryRun,
    [switch]$IncludeEmpty
)

$ErrorActionPreference = 'Stop'

# param() defaults must be plain expressions, so the fallback chain lives here.
if (-not $To) {
    if ($env:CODEX_DEEPSEEK_HOME) { $To = $env:CODEX_DEEPSEEK_HOME }
    else { $To = Join-Path $env:USERPROFILE '.codex-deepseek' }
}

if (-not (Test-Path -LiteralPath $From)) {
    throw "native Codex home not found: $From"
}
if (-not (Test-Path -LiteralPath $To)) {
    throw "DeepSeek home not found: $To - run install.ps1 first"
}

Write-Host "from $From"
Write-Host "to   $To"

$agentsChanges = 0
$skillMerges = 0

function Copy-Skill {
    param([string]$Directory, [string]$Name)

    if ($DryRun) {
        Write-Host "skills\$Name`: would merge"
    }
    else {
        $destination = Join-Path (Join-Path $To 'skills') $Name
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        Copy-Item -Path (Join-Path $Directory '*') -Destination $destination -Recurse -Force
        Write-Host "skills\$Name`: merged"
    }
    $script:skillMerges++
}

# ------------------------------------------------------------------ AGENTS.md

$sourceAgents = Join-Path $From 'AGENTS.md'
$targetAgents = Join-Path $To 'AGENTS.md'

if (-not (Test-Path -LiteralPath $sourceAgents) -or (Get-Item -LiteralPath $sourceAgents).Length -eq 0) {
    Write-Host 'AGENTS.md: source is empty or missing, nothing to merge'
}
else {
    $digest = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceAgents).Hash.ToLower()
    $marker = "<!-- merged from $From\AGENTS.md (sha256:$digest) -->"
    $targetText = if (Test-Path -LiteralPath $targetAgents) { Get-Content -LiteralPath $targetAgents -Raw } else { '' }

    if ($targetText -and $targetText.Contains($marker)) {
        Write-Host "AGENTS.md: already merged (sha256:$($digest.Substring(0, 12))), nothing to do"
    }
    elseif ($DryRun) {
        Write-Host "AGENTS.md: would append $sourceAgents"
        $agentsChanges++
    }
    else {
        if (Test-Path -LiteralPath $targetAgents) {
            $backup = "$targetAgents.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $targetAgents -Destination $backup -Force
            Write-Host "AGENTS.md: backup $backup"
        }
        $sourceText = Get-Content -LiteralPath $sourceAgents -Raw
        $merged = "$targetText`r`n$marker`r`n$sourceText`r`n"
        [IO.File]::WriteAllText($targetAgents, $merged, (New-Object Text.UTF8Encoding($false)))
        Write-Host "AGENTS.md: appended $sourceAgents"
        $agentsChanges++
    }
}

# --------------------------------------------------------------------- skills

$sourceSkills = Join-Path $From 'skills'
if (-not (Test-Path -LiteralPath $sourceSkills)) {
    Write-Host "skills: $sourceSkills does not exist, nothing to merge"
}
else {
    $targetSkills = Join-Path $To 'skills'
    New-Item -ItemType Directory -Force -Path $targetSkills | Out-Null

    $userSkills = @(Get-ChildItem -LiteralPath $sourceSkills -Directory -Force | Where-Object { $_.Name -ne '.system' })
    if ($userSkills.Count -eq 0) {
        Write-Host 'skills: the source home has no user skills'
    }

    foreach ($skill in $userSkills) {
        $content = @(Get-ChildItem -LiteralPath $skill.FullName -Recurse -Force -File)
        if ($content.Count -eq 0 -and -not $IncludeEmpty) {
            Write-Host "skills\$($skill.Name): empty, skipped (use -IncludeEmpty to copy it anyway)"
            continue
        }

        Copy-Skill -Directory $skill.FullName -Name $skill.Name
    }

    Write-Host 'skills\.system: skipped (each home gets its own copy from the Codex binary)'
}

# ------------------------------------------------- also merge extra locations

foreach ($extra in $Also) {
    if (-not (Test-Path -LiteralPath $extra)) {
        Write-Host "also $extra`: not found, skipped"
        continue
    }
    Write-Host "also $extra`:"
    foreach ($candidate in @(Get-ChildItem -LiteralPath $extra -Directory -Force)) {
        if (-not (Test-Path -LiteralPath (Join-Path $candidate.FullName 'SKILL.md'))) { continue }
        Copy-Skill -Directory $candidate.FullName -Name $candidate.Name
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host "dry run: $agentsChanges AGENTS.md change(s), $skillMerges skill folder(s) would be merged"
}
elseif ($agentsChanges -eq 0 -and $skillMerges -eq 0) {
    Write-Host 'nothing to do - the DeepSeek home already has everything'
}
else {
    Write-Host "AGENTS.md: $agentsChanges change(s); skills: $skillMerges folder(s) merged; the native home was not touched"
}
