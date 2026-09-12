#!/bin/sh
#
# codex-deepseek - run the real Codex CLI against an isolated DeepSeek home.
#
# The POSIX twin of src/CodexDeepSeek.cs: exec the real codex with CODEX_HOME
# pinned to the DeepSeek home, so the DeepSeek provider config, the pinned model
# catalog, the credentials and the session store all live apart from ~/.codex -
# which stays dedicated to ChatGPT Desktop and the plain `codex` command.
#
# Environment:
#   CODEX_DEEPSEEK_TARGET   full path to the real codex binary
#   CODEX_DEEPSEEK_HOME     the isolated home (default: ~/.codex-deepseek)

set -eu

deepseek_home() {
    if [ -n "${CODEX_DEEPSEEK_HOME:-}" ]; then
        printf '%s' "$CODEX_DEEPSEEK_HOME"
    else
        printf '%s' "${HOME}/.codex-deepseek"
    fi
}

self_path() {
    if command -v pwd >/dev/null 2>&1 && [ -d "$(dirname "$0")" ]; then
        printf '%s/%s' "$(cd "$(dirname "$0")" && pwd)" "$(basename "$0")"
    else
        printf '%s' "$0"
    fi
}

# Newest ~/.codex/packages/standalone/releases/<version>/bin/codex.
# Directory names start with a dotted version, so sort numerically on the first
# three components. macOS and Linux sort agree on -t. -k1,1n.
newest_standalone_codex() {
    releases="${HOME}/.codex/packages/standalone/releases"
    [ -d "$releases" ] || return 1

    selected=$(
        for directory in "$releases"/*; do
            [ -x "$directory/bin/codex" ] || continue
            printf '%s\n' "${directory##*/}"
        done | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
    )

    [ -n "$selected" ] || return 1
    [ -x "$releases/${selected}/bin/codex" ] || return 1
    printf '%s' "$releases/${selected}/bin/codex"
}

codex_on_path() {
    self=$(self_path)
    result=''
    saved_ifs=$IFS
    IFS=:
    for directory in $PATH; do
        [ -n "$directory" ] || directory='.'
        candidate="${directory}/codex"
        [ -x "$candidate" ] || continue
        resolved="$(cd "${directory}" && pwd)/codex"
        [ "$resolved" = "$self" ] && continue
        result=$candidate
        break
    done
    IFS=$saved_ifs

    [ -n "$result" ] || return 1
    printf '%s' "$result"
}

resolve_codex() {
    if [ -n "${CODEX_DEEPSEEK_TARGET:-}" ] && [ -x "${CODEX_DEEPSEEK_TARGET}" ]; then
        printf '%s' "$CODEX_DEEPSEEK_TARGET"
        return 0
    fi

    if target=$(newest_standalone_codex); then
        printf '%s' "$target"
        return 0
    fi

    if target=$(codex_on_path); then
        printf '%s' "$target"
        return 0
    fi

    return 1
}

home=$(deepseek_home)
if [ ! -f "${home}/config.toml" ]; then
    printf '%s\n' "codex-deepseek: missing DeepSeek config at ${home}/config.toml" >&2
    exit 127
fi

if ! target=$(resolve_codex); then
    printf '%s\n' \
        'codex-deepseek: cannot find the real codex executable. Set CODEX_DEEPSEEK_TARGET to its full path.' >&2
    exit 127
fi

CODEX_HOME=$home
export CODEX_HOME
exec "$target" "$@"
