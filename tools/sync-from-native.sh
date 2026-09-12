#!/usr/bin/env bash
#
# One-way merge: native Codex home -> DeepSeek home.
#
# Merging means both sides survive. Nothing is ever deleted from the target:
#
#   * AGENTS.md  - the source is appended under a marker that records a hash of
#                  its content, so a second run is a no-op. The target's own
#                  rules stay where they are, at the top of the file. If an
#                  earlier run imported an older revision, that block is
#                  replaced rather than stacked.
#   * skills/*   - copied file by file, overwriting same-named files, leaving
#                  any skill that only exists in the target alone.
#   * skills/.system - skipped: each home gets its own copy from the Codex
#                  binary, and the CLI refreshes it.

set -euo pipefail

from_home=${CODEX_HOME:-${HOME}/.codex}
to_home=${CODEX_DEEPSEEK_HOME:-${HOME}/.codex-deepseek}
dry_run=0
include_empty=0
also_dirs=''

usage() {
    cat <<'USAGE'
Usage: sync-from-native.sh [options]

  --from DIR       native Codex home (default: $CODEX_HOME or ~/.codex)
  --to DIR         DeepSeek home (default: $CODEX_DEEPSEEK_HOME or ~/.codex-deepseek)
  --also DIR       also merge skills from DIR, an extra location whose
                   subdirectories contain a SKILL.md (repeatable)
  --dry-run        print what would happen, change nothing
  --include-empty  also copy skill folders that contain no files
  -h, --help       this message
USAGE
}

while [ $# -gt 0 ]; do
    case $1 in
        --from) from_home=$2; shift 2 ;;
        --to) to_home=$2; shift 2 ;;
        --also) also_dirs="${also_dirs}${2}
"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        --include-empty) include_empty=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *)
            printf 'unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ ! -d "$from_home" ]; then
    printf 'native Codex home not found: %s\n' "$from_home" >&2
    exit 1
fi
if [ ! -d "$to_home" ]; then
    printf 'DeepSeek home not found: %s - run install.sh (or install.ps1) first\n' "$to_home" >&2
    exit 1
fi

printf 'from %s\nto   %s\n' "$from_home" "$to_home"

hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        printf ''
    fi
}

agents_changes=0
skill_merges=0

copy_skill() {
    directory=$1
    name=$2
    if [ "$dry_run" -eq 1 ]; then
        printf 'skills/%s: would merge\n' "$name"
    else
        mkdir -p "${to_home}/skills/${name}"
        cp -R "${directory}." "${to_home}/skills/${name}/"
        printf 'skills/%s: merged\n' "$name"
    fi
    skill_merges=$((skill_merges + 1))
}

# ------------------------------------------------------------------ AGENTS.md

source_agents="${from_home}/AGENTS.md"
target_agents="${to_home}/AGENTS.md"

if [ ! -s "$source_agents" ]; then
    printf 'AGENTS.md: source is empty or missing, nothing to merge\n'
else
    digest=$(hash_file "$source_agents")
    marker="<!-- merged from ${from_home}/AGENTS.md (sha256:${digest}) -->"

    if [ -n "$digest" ] && [ -f "$target_agents" ] && grep -Fq "$marker" "$target_agents"; then
        printf 'AGENTS.md: already merged (%s), nothing to do\n' "sha256:${digest:0:12}"
    else
        # An earlier run may have imported a different revision of the same
        # file. Its block is identified by the marker, so refreshing replaces
        # it instead of stacking a second copy; anything above the marker is
        # your own content and is preserved.
        imported_line=''
        if [ -f "$target_agents" ]; then
            imported_line=$(grep -n -m1 -E '^<!-- merged from .*AGENTS\.md \(sha256:' "$target_agents" | cut -d: -f1 || true)
        fi
        if [ -n "$imported_line" ]; then
            action='refresh'
        else
            action='append'
        fi

        if [ "$dry_run" -eq 1 ]; then
            printf 'AGENTS.md: would %s with the content of %s\n' "$action" "$source_agents"
            agents_changes=$((agents_changes + 1))
        else
            if [ -f "$target_agents" ]; then
                backup="${target_agents}.bak-$(date +%Y%m%d-%H%M%S)"
                cp -f "$target_agents" "$backup"
                printf 'AGENTS.md: backup %s\n' "$backup"
            fi

            merged_tmp="${target_agents}.merged.tmp"
            if [ -z "$imported_line" ] && [ -f "$target_agents" ]; then
                cp -f "$target_agents" "$merged_tmp"
            elif [ -n "$imported_line" ] && [ "$imported_line" -gt 1 ]; then
                head -n $((imported_line - 1)) "$target_agents" >"$merged_tmp"
            else
                : >"$merged_tmp"
            fi

            {
                printf '\n%s\n' "$marker"
                cat "$source_agents"
                printf '\n'
            } >>"$merged_tmp"
            mv -f "$merged_tmp" "$target_agents"
            printf 'AGENTS.md: %s %s\n' "$action" "$source_agents"
            agents_changes=$((agents_changes + 1))
        fi
    fi
fi

# --------------------------------------------------------------------- skills

if [ ! -d "${from_home}/skills" ]; then
    printf 'skills: %s/skills does not exist, nothing to merge\n' "$from_home"
else
    mkdir -p "${to_home}/skills"
    found=0
    for directory in "${from_home}"/skills/*/; do
        [ -d "$directory" ] || continue
        name=${directory%/}
        name=${name##*/}
        [ "$name" = '.system' ] && continue
        found=$((found + 1))

        if [ -z "$(find "$directory" -mindepth 1 -print -quit 2>/dev/null)" ] && [ "$include_empty" -eq 0 ]; then
            printf 'skills/%s: empty, skipped (use --include-empty to copy it anyway)\n' "$name"
            continue
        fi

        copy_skill "$directory" "$name"
    done

    if [ "$found" -eq 0 ]; then
        printf 'skills: the source home has no user skills\n'
    fi
    printf 'skills/.system: skipped (each home gets its own copy from the Codex binary)\n'
fi

# ------------------------------------------------- also merge extra locations

if [ -n "$also_dirs" ]; then
    # Newline-delimited so paths with spaces survive, and a for loop instead of
    # a pipe so the counters above stay in this shell.
    saved_ifs=$IFS
    IFS='
'
    for extra in $also_dirs; do
        [ -n "$extra" ] || continue
        if [ ! -d "$extra" ]; then
            printf 'also %s: not found, skipped\n' "$extra"
            continue
        fi
        printf 'also %s:\n' "$extra"
        for candidate in "$extra"/*/; do
            [ -f "${candidate}SKILL.md" ] || continue
            name=${candidate%/}
            name=${name##*/}
            copy_skill "$candidate" "$name"
        done
    done
    IFS=$saved_ifs
fi

printf '\n'
if [ "$dry_run" -eq 1 ]; then
    printf 'dry run: %s AGENTS.md change(s), %s skill folder(s) would be merged\n' "$agents_changes" "$skill_merges"
elif [ "$agents_changes" -eq 0 ] && [ "$skill_merges" -eq 0 ]; then
    printf 'nothing to do - the DeepSeek home already has everything\n'
else
    printf 'AGENTS.md: %s change(s); skills: %s folder(s) merged; the native home was not touched\n' \
        "$agents_changes" "$skill_merges"
fi
