#!/usr/bin/env bash
#
# Exercises tools/sync-from-native.sh against two throwaway homes: it must merge
# without deleting anything on either side, and be idempotent.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sync="${script_dir}/tools/sync-from-native.sh"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

native="${work_dir}/native"
deep="${work_dir}/deep"

mkdir -p "${native}/skills/copied" "${native}/skills/empty-one" "${native}/skills/.system/builtin"
mkdir -p "${deep}/skills/target-only"

printf '# native rules\n- always verify\n' >"${native}/AGENTS.md"
printf '# deepseek rules\n- keep me\n' >"${deep}/AGENTS.md"
printf -- '---\nname: copied\n---\nbody\n' >"${native}/skills/copied/SKILL.md"
printf 'builtin\n' >"${native}/skills/.system/builtin/SKILL.md"
printf -- '---\nname: target-only\n---\nbody\n' >"${deep}/skills/target-only/SKILL.md"

failures=0

check() {
    description=$1
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'ok   %s\n' "$description"
    else
        printf 'FAIL %s\n' "$description" >&2
        failures=$((failures + 1))
    fi
}

fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

bash "$sync" --from "$native" --to "$deep" >"${work_dir}/run1.log" 2>&1 ||
    { cat "${work_dir}/run1.log"; exit 1; }

merged_agents=$(cat "${deep}/AGENTS.md")
check "keeps the target's own rules" grep -Fq 'keep me' "${deep}/AGENTS.md"
check "appends the native rules" grep -Fq 'always verify' "${deep}/AGENTS.md"
check "records where the appended block came from" grep -Fq 'merged from' "${deep}/AGENTS.md"
check "keeps the target's own rules above the appended block" \
    test "$(printf '%s\n' "$merged_agents" | head -n 1)" = "# deepseek rules"

check "copies a skill that only exists natively" test -f "${deep}/skills/copied/SKILL.md"
check "leaves a skill that only exists in the target" test -f "${deep}/skills/target-only/SKILL.md"
check "skips empty skill folders by default" test ! -d "${deep}/skills/empty-one"
check "does not copy the managed .system folder" test ! -d "${deep}/skills/.system"
check "backs the target AGENTS.md up before appending" \
    bash -c "compgen -G '${deep}/AGENTS.md.bak-*' >/dev/null"

# The native home must be untouched: no backups, no merged marker.
check "never modifies the native AGENTS.md" \
    bash -c "[ \"\$(cat '${native}/AGENTS.md')\" = \"\$(printf '# native rules\n- always verify')\" ]"
check "writes no backup into the native home" \
    bash -c "! compgen -G '${native}/AGENTS.md.bak-*' >/dev/null"

# Second run: idempotent.
bash "$sync" --from "$native" --to "$deep" >"${work_dir}/run2.log" 2>&1
check "reports the AGENTS.md merge as already done" grep -Fq 'already merged' "${work_dir}/run2.log"
occurrences=$(grep -c 'always verify' "${deep}/AGENTS.md")
if [ "$occurrences" = "1" ]; then
    printf 'ok   does not append the same rules twice\n'
else
    fail "native rules appear ${occurrences} times after two runs"
fi

# --dry-run must not write anything.
before=$(cat "${deep}/AGENTS.md")
bash "$sync" --from "$native" --to "$deep" --dry-run >"${work_dir}/run3.log" 2>&1
if [ "$before" = "$(cat "${deep}/AGENTS.md")" ]; then
    printf 'ok   --dry-run changes nothing\n'
else
    fail '--dry-run modified AGENTS.md'
fi

# --include-empty copies the empty folder too.
bash "$sync" --from "$native" --to "$deep" --include-empty >"${work_dir}/run4.log" 2>&1
check "--include-empty copies empty skill folders" test -d "${deep}/skills/empty-one"

# --also merges skills that live outside the native home's skills/ folder, such
# as automations, and ignores directories that hold no SKILL.md.
extra="${work_dir}/extra"
mkdir -p "${extra}/extra-skill" "${extra}/not-a-skill"
printf -- '---\nname: extra-skill\n---\nbody\n' >"${extra}/extra-skill/SKILL.md"
printf 'notes\n' >"${extra}/not-a-skill/readme.md"

bash "$sync" --from "$native" --to "$deep" --also "$extra" >"${work_dir}/run5.log" 2>&1
check "--also merges a skill from an extra location" test -f "${deep}/skills/extra-skill/SKILL.md"
check "--also ignores folders without a SKILL.md" test ! -d "${deep}/skills/not-a-skill"
check "--also still leaves the target's own skills alone" test -f "${deep}/skills/target-only/SKILL.md"

# --also with a path that does not exist is reported, not fatal.
bash "$sync" --from "$native" --to "$deep" --also "${work_dir}/nope" >"${work_dir}/run6.log" 2>&1
check "an --also path that does not exist is skipped, not fatal" \
    grep -Fq 'not found, skipped' "${work_dir}/run6.log"

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'all posix sync tests passed\n'
else
    printf '%s test(s) failed\n' "$failures" >&2
    exit 1
fi
