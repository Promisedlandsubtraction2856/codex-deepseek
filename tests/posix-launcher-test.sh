#!/usr/bin/env bash
#
# Functional tests for src/codex-deepseek.sh.
#
# No Codex installation is required: the forwarding tests point
# CODEX_DEEPSEEK_TARGET at a stub that records what it was given.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
launcher="${script_dir}/src/codex-deepseek.sh"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

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

contains() {
    case $1 in
        *"$2"*) return 0 ;;
        *) return 1 ;;
    esac
}

expect_exit() {
    expected=$1
    description=$2
    shift 2
    set +e
    "$@" >/dev/null 2>&1
    actual=$?
    set -e
    if [ "$actual" -eq "$expected" ]; then
        printf 'ok   %s\n' "$description"
    else
        printf 'FAIL %s (expected exit %s, got %s)\n' "$description" "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
}

# ------------------------------------------------------------------ forwarding

stub="${work_dir}/codex-stub"
cat >"$stub" <<'STUB'
#!/bin/sh
printf 'CODEX_HOME=%s\n' "${CODEX_HOME:-}"
printf 'ARGS=%s\n' "$*"
exit "${STUB_EXIT_CODE:-0}"
STUB
chmod +x "$stub"

deepseek_home="${work_dir}/home"
mkdir -p "$deepseek_home"
printf 'model = "deepseek-flash"\n' >"${deepseek_home}/config.toml"

forward() {
    CODEX_DEEPSEEK_TARGET="$stub" CODEX_DEEPSEEK_HOME="$deepseek_home" "$launcher" "$@"
}

output=$(forward --version)
check "pins CODEX_HOME to the DeepSeek home" contains "$output" "CODEX_HOME=${deepseek_home}"
check "forwards --version to the real binary" contains "$output" 'ARGS=--version'

output=$(forward exec "print hello")
check "forwards a subcommand and its argument" contains "$output" 'ARGS=exec print hello'

output=$(forward exec 'a & b "c" $HOME')
check "keeps quoting and metacharacters intact" contains "$output" 'ARGS=exec a & b "c" $HOME'

output=$(forward exec 'two  spaces')
check "preserves internal spacing" contains "$output" 'ARGS=exec two  spaces'

# Nothing is intercepted any more: a bare `debug models` must reach the binary.
output=$(forward debug models --bundled)
check "forwards 'debug models' instead of answering it" contains "$output" 'ARGS=debug models --bundled'
check "'debug models' still runs under the DeepSeek home" \
    contains "$output" "CODEX_HOME=${deepseek_home}"

set +e
STUB_EXIT_CODE=7 forward exec x >/dev/null 2>&1
actual=$?
set -e
if [ "$actual" -eq 7 ]; then
    printf 'ok   propagates the exit code of the real binary\n'
else
    fail "exit code not propagated (got $actual)"
fi

# --------------------------------------------------------------------- errors

empty_home="${work_dir}/empty"
mkdir -p "$empty_home"
expect_exit 127 "exits 127 when the DeepSeek home has no config.toml" \
    env CODEX_DEEPSEEK_TARGET="$stub" CODEX_DEEPSEEK_HOME="$empty_home" "$launcher" exec x

missing_message=$(env CODEX_DEEPSEEK_TARGET="$stub" CODEX_DEEPSEEK_HOME="$empty_home" "$launcher" --version 2>&1 || true)
check "names the missing config in the error message" contains "$missing_message" 'missing DeepSeek config'

# ------------------------------------------------------------- codex resolution

# An unusable CODEX_DEEPSEEK_TARGET must fall through to the normal resolution
# order instead of failing outright: that mirrors the Windows launcher.
fallback_bin="${work_dir}/fallback-bin"
mkdir -p "$fallback_bin"
cp "$stub" "${fallback_bin}/codex"
chmod +x "${fallback_bin}/codex"
fallback_output=$(env PATH="${fallback_bin}:/usr/bin:/bin" HOME="$empty_home" \
    CODEX_DEEPSEEK_TARGET="${work_dir}/no-such-codex" CODEX_DEEPSEEK_HOME="$deepseek_home" \
    "$launcher" --version)
check "falls through to PATH when the target does not exist" \
    contains "$fallback_output" 'ARGS=--version'
check "still pins CODEX_HOME on the fall-through path" \
    contains "$fallback_output" "CODEX_HOME=${deepseek_home}"

# Nothing anywhere -> a clear message and exit 127.
if [ -x /usr/bin/codex ] || [ -x /bin/codex ]; then
    printf 'skip a codex exists in /usr/bin, cannot test the not-found path\n'
else
    not_found=$(env -u CODEX_DEEPSEEK_TARGET HOME="$empty_home" PATH=/usr/bin:/bin \
        CODEX_DEEPSEEK_HOME="$deepseek_home" "$launcher" --version 2>&1 || true)
    check "explains how to point at Codex when it cannot be found" \
        contains "$not_found" 'CODEX_DEEPSEEK_TARGET'
    expect_exit 127 "exits 127 when no Codex can be found at all" \
        env -u CODEX_DEEPSEEK_TARGET HOME="$empty_home" PATH=/usr/bin:/bin \
        CODEX_DEEPSEEK_HOME="$deepseek_home" "$launcher" --version
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'all posix launcher tests passed\n'
else
    printf '%s test(s) failed\n' "$failures" >&2
    exit 1
fi
