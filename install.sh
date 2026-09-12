#!/usr/bin/env bash
#
# install.sh - macOS / Linux installer for codex-deepseek.
#
# Creates an isolated Codex home, writes the DeepSeek provider config, installs
# the POSIX launcher and puts it on PATH. Nothing here touches ~/.codex, which
# stays dedicated to ChatGPT Desktop and the plain `codex` command.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

deepseek_home=${CODEX_DEEPSEEK_HOME:-${HOME}/.codex-deepseek}
api_key=${DEEPSEEK_API_KEY:-}
base_url='https://api.deepseek.com/'
model='deepseek-flash'
reasoning_effort='high'
force=0
add_to_path=1

usage() {
    cat <<'USAGE'
Usage: ./install.sh [options]

  --home DIR                isolated Codex home (default: ~/.codex-deepseek)
  --api-key KEY             DeepSeek API key (default: $DEEPSEEK_API_KEY, else prompted)
  --base-url URL            provider base URL (default: https://api.deepseek.com/)
  --model SLUG              default model (default: deepseek-flash)
  --reasoning-effort LEVEL  default reasoning effort (default: high)
  --no-path                 do not touch your shell rc file
  --force                   rewrite an existing config.toml (a backup is kept)
  -h, --help                this message
USAGE
}

step() {
    printf '\n== %s\n' "$1"
}

while [ $# -gt 0 ]; do
    case $1 in
        --home) deepseek_home=$2; shift 2 ;;
        --api-key) api_key=$2; shift 2 ;;
        --base-url) base_url=$2; shift 2 ;;
        --model) model=$2; shift 2 ;;
        --reasoning-effort) reasoning_effort=$2; shift 2 ;;
        --no-path) add_to_path=0; shift ;;
        --force) force=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *)
            printf 'unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

template="${script_dir}/config/config.toml.example"
catalog="${script_dir}/config/models.json"
launcher="${script_dir}/src/codex-deepseek.sh"
bin_dir="${deepseek_home}/bin"
config="${deepseek_home}/config.toml"

for required in "$template" "$catalog" "$launcher"; do
    if [ ! -f "$required" ]; then
        printf 'missing file: %s - run this script from a full clone of the repository\n' "$required" >&2
        exit 1
    fi
done

step 'Checking for the real Codex CLI'
if codex_path=$(command -v codex 2>/dev/null); then
    printf 'found %s\n' "$codex_path"
else
    printf 'warning: no codex on PATH yet. The launcher still finds a Codex installed in the usual places, but install the Codex CLI first.\n' >&2
fi

step 'Installing the launcher'
mkdir -p "$bin_dir"
install -m 0755 "$launcher" "${bin_dir}/codex-deepseek"
ln -sf codex-deepseek "${bin_dir}/cx"
printf 'installed %s\n' "${bin_dir}/codex-deepseek"

step 'Creating the isolated Codex home'
mkdir -p "$deepseek_home"
cp -f "$catalog" "${deepseek_home}/models.json"
printf 'catalog  %s\n' "${deepseek_home}/models.json"

if [ -f "$config" ] && [ "$force" -eq 0 ]; then
    printf 'config   %s already exists, left untouched (use --force to rewrite)\n' "$config"
else
    if [ -z "$api_key" ] && [ -t 0 ]; then
        printf 'DeepSeek API key: ' >&2
        read -r -s api_key
        printf '\n' >&2
    fi
    if [ -z "$api_key" ]; then
        printf 'no API key supplied\n' >&2
        exit 1
    fi

    if [ -f "$config" ]; then
        backup="${config}.bak-$(date +%Y%m%d-%H%M%S)"
        cp -f "$config" "$backup"
        printf 'backup   %s\n' "$backup"
    fi

    # sed replacement text treats \ & and the delimiter specially; escape them
    # so a key containing any of those characters survives.
    escape_sed_replacement() {
        printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
    }

    sed \
        -e "s|__MODELS_JSON__|$(escape_sed_replacement "${deepseek_home}/models.json")|g" \
        -e "s|__API_KEY__|$(escape_sed_replacement "$api_key")|g" \
        -e "s|__BASE_URL__|$(escape_sed_replacement "$base_url")|g" \
        -e "s|__MODEL__|$(escape_sed_replacement "$model")|g" \
        -e "s|__REASONING_EFFORT__|$(escape_sed_replacement "$reasoning_effort")|g" \
        "$template" > "$config"
    chmod 600 "$config"
    printf 'config   %s (mode 600)\n' "$config"
fi

if [ "$add_to_path" -eq 1 ]; then
    step 'Adding the launcher to your PATH'
    path_line="export PATH=\"${bin_dir}:\$PATH\"  # codex-deepseek"

    case ${SHELL:-} in
        */zsh) rc_file="${HOME}/.zshrc" ;;
        */bash) rc_file="${HOME}/.bashrc" ;;
        *) rc_file='' ;;
    esac

    if [ -n "$rc_file" ] && [ -f "$rc_file" ] && grep -Fq "$bin_dir" "$rc_file"; then
        printf '%s already mentions %s\n' "$rc_file" "$bin_dir"
    elif [ -n "$rc_file" ]; then
        printf '\n%s\n' "$path_line" >> "$rc_file"
        printf 'added to %s:\n  %s\n' "$rc_file" "$path_line"
    else
        printf 'could not tell which login shell you use; add this line yourself:\n  %s\n' "$path_line"
    fi
fi

step 'Next steps'
cat <<EOF
Open a NEW terminal, then:

  codex-deepseek --version            # -> codex-cli <version>
  codex-deepseek exec "print hello"   # hits your DeepSeek key

Your plain \`codex\` command is untouched: same ChatGPT login, same models,
same ~/.codex/sessions history.
EOF
