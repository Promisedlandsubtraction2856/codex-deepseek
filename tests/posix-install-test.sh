#!/usr/bin/env bash
#
# Exercises install.sh against a throwaway HOME: no Codex install, no network,
# and nothing outside the temporary directory is touched.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

export HOME="${work_dir}/home"
mkdir -p "$HOME"

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

# A key full of characters that are special to sed, to prove the installer
# escapes the replacement text instead of corrupting the config.
tricky_key='sk-test-key-not-real & | \ / end'

bash "${script_dir}/install.sh" --api-key "$tricky_key" --no-path >"${work_dir}/install.log" 2>&1 ||
    { cat "${work_dir}/install.log"; exit 1; }

deepseek_home="${HOME}/.codex-deepseek"
config="${deepseek_home}/config.toml"
launcher="${deepseek_home}/bin/codex-deepseek"
alias_path="${deepseek_home}/bin/cx"

check "creates the default home under \$HOME" test -f "$config"
check "copies the pinned catalog" test -f "${deepseek_home}/models.json"
check "installs an executable launcher" test -x "$launcher"

# Git Bash turns `ln -s` into a copy, so assert behaviour rather than the link.
check "installs the cx alias" test -x "$alias_path"
if [ "$("$alias_path" --version 2>&1 || true)" = "$("$launcher" --version 2>&1 || true)" ]; then
    printf 'ok   cx behaves like codex-deepseek\n'
else
    fail 'cx does not behave like codex-deepseek'
fi

# chmod 600 is only meaningful where the filesystem has POSIX modes.
case $(uname -s 2>/dev/null || printf unknown) in
    MINGW* | MSYS* | CYGWIN*)
        printf 'skip MSYS/Cygwin do not report NTFS modes faithfully\n'
        ;;
    *)
        check "locks the config down to mode 600" \
            test "$(stat -c '%a' "$config" 2>/dev/null || stat -f '%Lp' "$config")" = "600"
        ;;
esac

if grep -Fq "$tricky_key" "$config"; then
    printf 'ok   writes the API key verbatim despite sed metacharacters\n'
else
    fail 'the API key did not survive the template substitution'
fi

if grep -Eq '__API_KEY__|__MODELS_JSON__|__MODEL__|__BASE_URL__|__REASONING_EFFORT__' "$config"; then
    fail 'a placeholder was left unreplaced in config.toml'
else
    printf 'ok   every placeholder was replaced\n'
fi

check "points model_catalog_json at the installed catalog" \
    grep -Fq "model_catalog_json = \"${deepseek_home}/models.json\"" "$config"
check "sets the DeepSeek provider base URL" \
    grep -Fq 'base_url = "https://api.deepseek.com/"' "$config"
check "forces the API-key login method" grep -Fq 'forced_login_method = "api"' "$config"

# --no-path must not touch any rc file.
check "--no-path leaves bash rc alone" test ! -f "${HOME}/.bashrc"
check "--no-path leaves zsh rc alone" test ! -f "${HOME}/.zshrc"

# Re-running without --force must not clobber an existing config.
before=$(cat "$config")
bash "${script_dir}/install.sh" --api-key 'sk-a-different-key' --no-path >/dev/null 2>&1
after=$(cat "$config")
if [ "$before" = "$after" ]; then
    printf 'ok   a second install leaves the existing config untouched\n'
else
    fail 'a second install overwrote config.toml without --force'
fi

# --force rewrites it, keeping a timestamped backup.
bash "${script_dir}/install.sh" --api-key 'sk-forced-key' --no-path --force >/dev/null 2>&1
check "--force rewrites the config" grep -Fq 'sk-forced-key' "$config"
if compgen -G "${config}.bak-*" >/dev/null; then
    printf 'ok   --force keeps a timestamped backup\n'
else
    fail '--force did not keep a backup'
fi

# With a known shell, the PATH line is appended once and only once.
SHELL=/bin/zsh bash "${script_dir}/install.sh" --api-key 'sk-x' --force >/dev/null 2>&1
SHELL=/bin/zsh bash "${script_dir}/install.sh" --api-key 'sk-x' --force >/dev/null 2>&1
path_line_count=$(grep -c 'codex-deepseek' "${HOME}/.zshrc" 2>/dev/null || printf '0')
if [ "$path_line_count" = "1" ]; then
    printf 'ok   the PATH export is added to .zshrc exactly once\n'
else
    fail "expected 1 PATH line in .zshrc, found ${path_line_count}"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'all posix install tests passed\n'
else
    printf '%s test(s) failed\n' "$failures" >&2
    exit 1
fi
