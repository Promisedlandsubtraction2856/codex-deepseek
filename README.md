# codex-deepseek

**Run the real OpenAI Codex CLI on DeepSeek models — while ChatGPT Desktop *and* the plain `codex` command keep their own ChatGPT login, models and config, completely untouched.**

[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![platforms: Windows | macOS | Linux](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-0078d4.svg)](#requirements)

[中文说明](README.zh-CN.md) · [Architecture](docs/architecture.md)

<p align="center">
  <img src="docs/demo.svg" alt="Terminal: codex-deepseek --version returns the Codex CLI pinned to its own home, then codex --version still uses the ChatGPT account" width="760">
</p>

---

## The problem this solves

Codex Desktop and the `codex` command line are two front-ends over **one shared Codex home**. Both read `~/.codex/config.toml`, both resolve credentials there, and both keep their sessions there. So the moment you point that single file at a third-party provider:

```toml
model = "deepseek-flash"
model_provider = "deepseek"
```

everything that reads it changes:

- **ChatGPT Desktop** loses your ChatGPT models, asks to be re-authenticated, or sits on a login screen that never finishes loading.
- **The plain `codex` CLI** stops using your ChatGPT account and starts hitting the DeepSeek endpoint as well — including the sessions you already have under `~/.codex/sessions`.

Neither symptom is fixable by retrying: a ChatGPT subscription cannot serve a `deepseek-*` model, and a DeepSeek key cannot serve `gpt-*`. Editing that one shared file back and forth, and restarting or re-logging-in every time you switch, is what everyone tries first. It does not hold up.

**This project pins the CLI to its own Codex home.** Two isolated worlds, no shared state, no re-login:

```text
                          your machine
                               |
               +---------------+----------------+
               |                                |
      ChatGPT Desktop                    codex-deepseek
      + plain `codex` CLI                (this project)
               |                                |
       ~/.codex  (%USERPROFILE%\.codex)   ~/.codex-deepseek
               |                                |
     ChatGPT login / subscription        your DeepSeek API key
               |                                |
     GPT / Codex models                 deepseek-flash, deepseek-v4-pro
```

The launcher is what keeps the left column out of reach: it starts the *real* `codex` binary with `CODEX_HOME` explicitly rewritten to the DeepSeek home, so no global config edit, no PATH juggling and no environment race can leak DeepSeek settings into ChatGPT Desktop or the `codex` command.

### What stays exactly as it was

| Consumer | Codex home | Credentials | Models |
|---|---|---|---|
| ChatGPT Desktop | `~/.codex` | ChatGPT login | GPT / Codex |
| `codex` (the plain CLI) | `~/.codex` | ChatGPT login | GPT / Codex |
| `codex-deepseek` | `~/.codex-deepseek` | DeepSeek API key | `deepseek-flash`, `deepseek-v4-pro` |

Nothing in this project ever writes to `~/.codex`. The plain CLI keeps its own config, its own credentials and its own `~/.codex/sessions` history, so `codex`, `codex resume` and `codex exec` behave exactly as before: same ChatGPT account, same models, no re-login and no restart.

The one way to break this is to put a custom `model_provider` back into the *global* `~/.codex/config.toml`. That is the shared file, and avoiding it is the whole point — see [Gotchas](#gotchas-in-the-order-you-will-hit-them).

## What you get

| Path | What it is |
|---|---|
| `install.ps1` / `build.ps1` | Windows: compiles the launcher with the `csc.exe` already present in Windows — **no .NET SDK, no NuGet, no runtime to install** — then creates the home, writes the config and updates your user `PATH`. |
| `install.sh` | macOS / Linux: installs the POSIX launcher, creates the home, writes the config, adds one line to your shell rc file. |
| `src/CodexDeepSeek.cs` | The Windows launcher: argument quoting, inherited standard handles, kill-on-close job object. |
| `src/codex-deepseek.sh` | The macOS / Linux launcher: ~90 lines of POSIX `sh`, no dependencies. |
| `config/models.json` | The model catalog the CLI is pinned to via `model_catalog_json`. |

## Requirements

| | |
|---|---|
| Windows | Windows 10/11, PowerShell 5.1+ (the in-box .NET Framework compiler is used). |
| macOS / Linux | POSIX `sh` and `bash`; the installer uses `install`, `sed`, `mktemp`. |
| All | Codex CLI already installed and working (`codex --version`), and a DeepSeek API key with access to the models in `config/models.json`. |

## Quick start

### Windows

**Option A — build it locally** (two seconds, no SDK needed):

```powershell
git clone https://github.com/mlangTse/codex-deepseek.git
cd codex-deepseek

# builds the launcher, creates ~\.codex-deepseek, installs to PATH
pwsh -File .\install.ps1

# the installer asks for your DeepSeek API key (or pass -ApiKey / set $env:DEEPSEEK_API_KEY)
```

Without PowerShell 7, use `powershell -ExecutionPolicy Bypass -File .\install.ps1`.

**Option B — skip the build:** download `codex-deepseek.exe` from the [latest release](https://github.com/mlangTse/codex-deepseek/releases/latest) (Windows x64; a `SHA256SUMS.txt` is provided), copy it into `%USERPROFILE%\.codex-deepseek\bin`, and follow steps 2–4 of the manual setup below.

### macOS / Linux

```sh
git clone https://github.com/mlangTse/codex-deepseek.git
cd codex-deepseek

# installs the launcher, creates ~/.codex-deepseek, writes the config,
# appends one PATH line to ~/.zshrc or ~/.bashrc
./install.sh

# the installer asks for your DeepSeek API key
# (or: DEEPSEEK_API_KEY=... ./install.sh, or ./install.sh --api-key ...)
```

Useful flags: `--home DIR`, `--model SLUG`, `--reasoning-effort LEVEL`, `--base-url URL`, `--no-path`, `--force`. Run `./install.sh --help` for the list.

No binary to download: the POSIX launcher is a shell script that is executed as-is.

### Then, on any platform

```sh
codex-deepseek --version      # -> codex-cli <version>  (the real CLI, not a re-implementation)
codex-deepseek exec "print the current date"
```

Your plain `codex` command is untouched: same ChatGPT login, same models, same sessions history — no re-login, no restart.

### Manual setup, if you prefer to see every step

```sh
# 1. get the launcher
git clone https://github.com/mlangTse/codex-deepseek.git && cd codex-deepseek
#    Windows:  pwsh -File .\build.ps1          -> dist\codex-deepseek.exe
#    macOS/Linux: no build step, use src/codex-deepseek.sh

# 2. create the isolated Codex home
mkdir -p ~/.codex-deepseek/bin
cp config/models.json          ~/.codex-deepseek/models.json
cp config/config.toml.example  ~/.codex-deepseek/config.toml
cp src/codex-deepseek.sh       ~/.codex-deepseek/bin/codex-deepseek
chmod 755 ~/.codex-deepseek/bin/codex-deepseek

# 3. edit ~/.codex-deepseek/config.toml and replace the placeholders
#    (model, catalog path, base URL, bearer token)

# 4. put the launcher on PATH once
echo 'export PATH="$HOME/.codex-deepseek/bin:$PATH"' >> ~/.zshrc   # or ~/.bashrc
```

## Configuration

`~/.codex-deepseek/config.toml` is the whole story, and it never touches the Desktop app:

```toml
model = "deepseek-flash"
model_provider = "deepseek"
model_catalog_json = "/home/<you>/.codex-deepseek/models.json"
model_reasoning_effort = "high"
web_search = "disabled"
preferred_auth_method = "apikey"
forced_login_method = "api"

[model_providers.deepseek]
name = "deepseek"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
experimental_bearer_token = "<your DeepSeek API key>"
```

The lines that cost real debugging time:

- **`model_catalog_json` is not optional.** Without it the CLI falls back to the OpenAI catalog compiled into the binary, and a turn dies with `The 'deepseek-flash' model is not supported when using Codex with a ChatGPT account.`
- **`forced_login_method = "api"` plus `preferred_auth_method = "apikey"`** stop the CLI from trying to open a ChatGPT browser login. This home has no `auth.json`, on purpose.
- **`web_search = "disabled"`** because the gateway does not serve the hosted search tool.
- Do not set `service_tier`. The third-party endpoint rejects it with a bare `400`.
- On Windows the path uses forward slashes or escaped backslashes; on macOS and Linux a normal absolute path works.
- Keep this file out of version control: it holds a bearer token. Both installers write it without ever echoing the key back, and this repo's `.gitignore` excludes `config.toml`.

### Which models appear

Model selection is driven entirely by `model_catalog_json` → `config/models.json`. Edit that array and restart the CLI; nothing needs rebuilding:

```sh
codex-deepseek exec "which model are you?"
```

To regenerate a catalog against a new CLI build, start from the bundled catalog and keep the long instruction fields:

```sh
codex debug models --bundled > "$TMPDIR/bundled.json"
# keep one entry, change slug / display_name / supported_reasoning_levels
```

## Everyday use

```sh
codex-deepseek                      # interactive TUI on the DeepSeek models
codex-deepseek exec "fix the tests"
codex-deepseek resume               # sessions live in ~/.codex-deepseek/sessions
codex-deepseek --version

codex                               # unchanged: your ChatGPT account
```

Both installers also drop a short alias next to the launcher — `cx` (macOS/Linux and Git Bash) and `cx.cmd` (cmd.exe on Windows):

```sh
cx exec "explain this repository"
```

## Keeping the two homes in sync

Skills, `AGENTS.md`, memories, plugins and sessions all live *under* `CODEX_HOME`, so the two homes never sync on their own — editing one leaves the other untouched, in both directions. When you do want to pull something across, `tools/` has a one-way merge that never deletes anything:

```powershell
# Windows
pwsh -File .\tools\sync-from-native.ps1 -DryRun
pwsh -File .\tools\sync-from-native.ps1
pwsh -File .\tools\sync-from-native.ps1 -Also "$env:USERPROFILE\.codex\automations\chronicle-workflow-skills"
```

```sh
# macOS / Linux
bash tools/sync-from-native.sh --dry-run
bash tools/sync-from-native.sh
bash tools/sync-from-native.sh --also ~/.codex/automations/chronicle-workflow-skills
```

What "merge" means here:

- **`AGENTS.md`** — the native file is appended under a marker that records a hash of its content, so the target's own rules stay at the top and a second run is a no-op. An empty native file means nothing happens.
- **`skills/`** — merged file by file. Same-named files are overwritten; a skill that only exists in the DeepSeek home is left alone. Empty folders are skipped (`-IncludeEmpty` / `--include-empty` copies them anyway), and `skills/.system` is skipped because each home gets its own copy from the Codex binary.
- **`-Also` / `--also`** — for skills kept outside `skills/`, such as automations. Every direct subdirectory that contains a `SKILL.md` is merged.

The native home is never written to, and every run prints exactly what it did. It is one-way (native → DeepSeek); to go the other way, swap `-From`/`-To` (`--from`/`--to`).

## Gotchas, in the order you will hit them

| Symptom | Cause | Fix |
|---|---|---|
| Desktop asks to log in, or its login screen spins forever | A custom `model_provider` was written into the global `~/.codex/config.toml` | Remove `model`, `model_provider`, `model_catalog_json` and `[model_providers.*]` from `~/.codex/config.toml`; keep them only in `~/.codex-deepseek/config.toml` |
| `400` from the gateway with an empty body | The request carried `service_tier = "default"` | Do not set `service_tier` in the DeepSeek home |
| `model_reasoning_effort = "xhigh"` rejected | That effort level is not in the catalog | Use `high`, or add the level to `models.json` |
| `The 'deepseek-flash' model is not supported when using Codex with a ChatGPT account.` | The turn ran the real `codex` against the ChatGPT home | You called `codex` instead of `codex-deepseek`, or DeepSeek config leaked into `~/.codex` |
| `codex-deepseek: cannot find the real codex executable` | No Codex install found | Set `CODEX_DEEPSEEK_TARGET` to the full path of the Codex binary |
| `codex-deepseek: missing DeepSeek config at ...` | The isolated home has no `config.toml` | Run the installer, or create the home by hand |
| `codex-deepseek debug models --bundled` reports OpenAI models | Since v0.2.0 the launcher forwards everything verbatim and no longer answers that call itself | Expected. Model choice comes from `model_catalog_json`, not from that command |
| A cancelled run leaves `codex` behind (Windows) | — | Cannot happen: the child lives in a kill-on-close job object |

### A note on the past

Earlier versions of this launcher also intercepted `codex debug models --bundled` to advertise a DeepSeek-only catalog to third-party tooling. That feature was removed in v0.2.0: the launcher now forwards every argument verbatim, and the only thing it does is pin `CODEX_HOME`. Behaviour for normal CLI use is unchanged.

## License

[MIT](LICENSE). Not affiliated with OpenAI or DeepSeek; Codex is a trademark of OpenAI.
