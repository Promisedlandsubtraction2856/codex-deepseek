# codex-deepseek

**Run the real OpenAI Codex CLI on DeepSeek models — while ChatGPT Desktop *and* the plain `codex` command keep their own ChatGPT login, models and config, completely untouched.**

[![build](https://github.com/mlangTse/codex-deepseek/actions/workflows/build.yml/badge.svg)](https://github.com/mlangTse/codex-deepseek/actions/workflows/build.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![platform: Windows](https://img.shields.io/badge/platform-Windows-0078d4.svg)](#requirements)

[中文说明](README.zh-CN.md) · [Architecture](docs/architecture.md) · [Setup log (中文)](docs/setup-log.zh-CN.md)

<p align="center">
  <img src="docs/demo.svg" alt="Terminal: codex-deepseek --version and codex-deepseek debug models --bundled return the DeepSeek catalog, then codex --version still uses the ChatGPT account" width="760">
</p>

---

## The problem this solves

Codex Desktop and the `codex` command line are two front-ends over **one shared Codex home**. Both read `%USERPROFILE%\.codex\config.toml`, both resolve credentials there, and both keep their sessions there. So the moment you point that single file at a third-party provider:

```toml
model = "deepseek-flash"
model_provider = "deepseek"
```

- **ChatGPT Desktop** loses your ChatGPT models, asks to be re-authenticated, or sits on a login screen that never finishes loading.
- **The plain `codex` CLI** stops using your ChatGPT account and starts hitting the DeepSeek endpoint as well — including the sessions you already have under `~\.codex\sessions`.

Neither symptom is fixable by retrying: a ChatGPT subscription cannot serve a `deepseek-*` model, and a DeepSeek key cannot serve `gpt-*`. Editing that one shared file back and forth, and restarting or re-logging-in every time you switch, is what everyone tries first. It does not hold up.

**This repo pins the CLI to its own Codex home.** Two isolated worlds, no shared state, no re-login:

```text
                          your machine
                               |
               +---------------+----------------+
               |                                |
      ChatGPT Desktop                    codex-deepseek
      + plain `codex` CLI                (this repo)
               |                                |
     %USERPROFILE%\.codex          %USERPROFILE%\.codex-deepseek
               |                                |
     ChatGPT login / Pro                 DeepSeek API key
               |                                |
     GPT / Codex models              deepseek-flash, deepseek-v4-pro
```

The launcher `codex-deepseek.exe` is what keeps the left column out of reach: it starts the *real* `codex.exe` with `CODEX_HOME` explicitly rewritten to `%USERPROFILE%\.codex-deepseek`, so no global config edit, no PATH juggling and no environment race can leak DeepSeek settings into ChatGPT Desktop or the `codex` command.

### What stays exactly as it was

| Consumer | Codex home | Credentials | Models |
|---|---|---|---|
| ChatGPT Desktop | `%USERPROFILE%\.codex` | ChatGPT login | GPT / Codex |
| `codex` (the plain CLI) | `%USERPROFILE%\.codex` | ChatGPT login | GPT / Codex |
| `codex-deepseek` | `%USERPROFILE%\.codex-deepseek` | DeepSeek API key | `deepseek-flash`, `deepseek-v4-pro` |

Nothing in this repo ever writes to `%USERPROFILE%\.codex`. The plain CLI keeps its own config, its own credentials and its own `~\.codex\sessions` history, so `codex`, `codex resume` and `codex exec` behave exactly as before: same ChatGPT account, same models, no re-login and no restart. Only `codex-deepseek` reads the DeepSeek home, and only `codex-deepseek` answers model discovery from the pinned catalog.

The one way to break this is to put a custom `model_provider` back into the *global* `%USERPROFILE%\.codex\config.toml`. That is the shared file, and avoiding it is the whole point — see [Gotchas](#gotchas-in-the-order-you-will-hit-them).

## What you get

| Path | What it is |
|---|---|
| `install.ps1` | One command: creates `~\.codex-deepseek`, writes the DeepSeek provider config, builds and installs the launcher, adds it to your user `PATH`. |
| `src\CodexDeepSeek.cs` | The launcher. C# compiled by the `csc.exe` already present in Windows — **no .NET SDK, no NuGet, no runtime to install**. |
| `config\models.json` | The model catalog the CLI is pinned to, so the DeepSeek models are first-class and no OpenAI model can be selected by accident. |
| `multica\` | Optional: lets the [Multica](https://github.com/multica-ai/multica) daemon offer the same DeepSeek models on a Codex runtime (see [Multica integration](#multica-integration)). |

## Requirements

- Windows 10/11. The launcher forwards standard handles and uses a Win32 job object — see [Architecture](docs/architecture.md).
- Codex CLI already installed and working: `codex --version`.
- A DeepSeek API key with access to the models you list in `config\models.json`.
- PowerShell 5.1+ (`pwsh` 7 also fine).

## Quick start

The examples use `pwsh`; if PowerShell 7 is not installed, substitute `powershell -ExecutionPolicy Bypass -File` for `pwsh -File` anywhere below.

**Option A — build it locally (two seconds, no SDK needed):**

```powershell
git clone https://github.com/mlangTse/codex-deepseek.git
cd codex-deepseek

# builds the launcher, creates ~\.codex-deepseek, installs to PATH
pwsh -File .\install.ps1

# the installer asks for your DeepSeek API key (or pass -ApiKey / set $env:DEEPSEEK_API_KEY)
```

**Option B — skip the build:** download `codex-deepseek.exe` from the [latest release](https://github.com/mlangTse/codex-deepseek/releases/latest), copy it into `%USERPROFILE%\.codex-deepseek\bin`, and add that directory to `PATH` (step 2-4 of the manual setup below). The release also carries a `SHA256SUMS.txt`.

Open a **new** terminal, then:

```powershell
codex-deepseek --version      # -> codex-cli 0.154.0  (the real CLI, not a re-implementation)
codex-deepseek exec "print the current date"
```

Your plain `codex` command is untouched: same ChatGPT login, same models, same `~\.codex\sessions` history — no re-login, no restart.

### Manual setup, if you prefer to see every step

```powershell
# 1. build the launcher
pwsh -File .\build.ps1                       # -> dist\codex-deepseek.exe

# 2. create the isolated Codex home
$deepseekHome = "$env:USERPROFILE\.codex-deepseek"
New-Item -ItemType Directory -Force -Path "$deepseekHome\bin" | Out-Null
Copy-Item .\config\models.json        "$deepseekHome\models.json"
Copy-Item .\config\config.toml.example "$deepseekHome\config.toml"
Copy-Item .\dist\codex-deepseek.exe   "$deepseekHome\bin\"

# 3. put your key in $deepseekHome\config.toml (replace the placeholder)

# 4. put the launcher on PATH once
[Environment]::SetEnvironmentVariable(
  'Path',
  [Environment]::GetEnvironmentVariable('Path','User') + ";$deepseekHome\bin",
  'User')
```

## Configuration

`%USERPROFILE%\.codex-deepseek\config.toml` is the whole story, and it never touches the Desktop app:

```toml
model = "deepseek-flash"
model_provider = "deepseek"
model_catalog_json = "C:/Users/<you>/.codex-deepseek/models.json"
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

- **`model_catalog_json` is not optional.** Without it the CLI offers the OpenAI catalog compiled into the binary, and a turn dies with `The 'deepseek-flash' model is not supported when using Codex with a ChatGPT account.`
- **`forced_login_method = "api"` plus `preferred_auth_method = "apikey"`** stop the CLI from trying to open a ChatGPT browser login. This home has no `auth.json`, on purpose.
- **`web_search = "disabled"`** because the gateway does not serve the hosted search tool.
- Do not set `service_tier`. The third-party endpoint rejects it with a bare `400`.
- Keep this file out of version control: it holds a bearer token. `install.ps1` never prints it back, and this repo's `.gitignore` excludes `config.toml`.

Prefer not to keep the key in the file? Anywhere the CLI reads `CODEX_HOME` you can export the key for the process instead of embedding it — but the embedded `experimental_bearer_token` is the form verified end to end here.

### Which models appear

The catalog in `config\models.json` decides what `codex-deepseek` can use. Edit the array and restart the CLI; nothing needs rebuilding:

```powershell
codex-deepseek debug models --bundled   # what this Codex home exposes
```

To regenerate a catalog against a new CLI build, start from the bundled catalog and replace the entries:

```powershell
codex debug models --bundled > $env:TEMP\bundled.json
# keep one entry, change slug / display_name / supported_reasoning_levels,
# and keep the long instruction fields that the CLI expects
```

## Everyday use

```powershell
codex-deepseek                      # interactive TUI on the DeepSeek models
codex-deepseek exec "fix the tests"
codex-deepseek resume               # sessions live in ~\.codex-deepseek\sessions
codex-deepseek --version

codex                               # unchanged: your ChatGPT account
```

`install.ps1` also drops two short aliases next to the launcher — `cx` for Git Bash / POSIX shells and `cx.cmd` for cmd.exe:

```bash
cx exec "explain this repository"
```

## Multica integration

If you run agents through the [Multica](https://github.com/multica-ai/multica) daemon there is one extra problem: **Multica enumerates a Codex runtime's models by running `codex debug models --bundled`**, which always returns the OpenAI catalog bundled into the binary. Your DeepSeek models never show up in the picker, and an agent configured with `model = deepseek-flash` on a plain Codex runtime fails with:

```text
{"detail":"The 'deepseek-flash' model is not supported when using Codex with a ChatGPT account."}
```

`codex-deepseek.exe` answers exactly that one invocation with the DeepSeek catalog, and forwards everything else (`--version`, `app-server`, `exec`, ...) to the real binary with the parent's standard handles, so Multica's JSON-RPC transport keeps working.

```powershell
pwsh -File .\build.ps1                        # also copies to ~\.multica\bin when that exists

multica runtime profile create `
  --display-name "Codex DeepSeek" `
  --protocol-family codex `
  --command-name codex-deepseek `
  --description "Local Codex CLI pinned to the DeepSeek gateway"

multica daemon restart
multica runtime list                          # expect "Codex DeepSeek (<machine>)" online
```

Then point agents at that runtime, or let the script do it for you (idempotent, `-DryRun` supported):

```powershell
pwsh -File .\multica\Setup-MulticaDeepSeek.ps1 -WorkspaceId <workspace-id> -DryRun
pwsh -File .\multica\Setup-MulticaDeepSeek.ps1 -WorkspaceId <workspace-id>
```

Three Multica facts that are easy to lose an evening to:

1. **`multica runtime profile set-path` is unusable on Windows.** The daemon gates the override behind a Unix executable bit (`mode & 0o111`), which no NTFS file carries, so the override is always rejected and the daemon falls back to `PATH`. Installing `codex-deepseek.exe` into a directory already on `PATH` (`~\.multica\bin`) is what actually works.
2. **Runtime profiles are workspace scoped.** A profile created in workspace A does not exist in workspace B, and agents there keep failing until you create it again — hence `Setup-MulticaDeepSeek.ps1 -WorkspaceId <id>`.
3. **Creating a profile needs workspace admin or owner.** As a plain member you get `403 insufficient permissions`; the script prints the exact command to hand to an owner. Rebinding agents you own works as a member.

Agents are not rebindable by themselves: registering the profile only makes the runtime exist. The script, or this command, moves them explicitly:

```powershell
multica --workspace-id <workspace-id> agent update <agent-id> `
  --runtime-id <deepseek-runtime-id> --model deepseek-flash --thinking-level high
```

Cost reporting: Multica's built-in price table knows `deepseek-v4-flash / v4-pro / chat / reasoner` but not `deepseek-flash`, so token counts show up while the money column stays empty until you add a custom price for `codex/deepseek-flash`.

## Gotchas, in the order you will hit them

| Symptom | Cause | Fix |
|---|---|---|
| Desktop asks to log in, or its login screen spins forever | A custom `model_provider` was written into the global `~\.codex\config.toml` | Remove `model`, `model_provider`, `model_catalog_json` and `[model_providers.*]` from `~\.codex\config.toml`; keep them only in `~\.codex-deepseek\config.toml` |
| `400` from the gateway with an empty body | The request carried `service_tier = "default"`, which the third-party endpoint rejects | Do not set `service_tier` in the DeepSeek home |
| `model_reasoning_effort = "xhigh"` rejected | That effort level is not in the catalog | Use `high`, or add the level to `models.json` |
| `The 'deepseek-flash' model is not supported when using Codex with a ChatGPT account.` | The turn ran the real `codex.exe` against the ChatGPT home | DeepSeek config leaked into `~\.codex`, or a Multica runtime is not bound to the wrapper |
| `codex-deepseek: cannot find the real codex executable` | No Codex install found | Set `CODEX_DEEPSEEK_TARGET` to the full path of `codex.exe` |
| `codex-deepseek: missing DeepSeek config at ...` | The isolated home has no `config.toml` | Run `install.ps1`, or create the home by hand |
| A cancelled Multica task leaves `codex.exe` running | — | Cannot happen: the child is placed in a kill-on-close job object, so killing the wrapper terminates Codex |

## How this was built

The full operation log — every command, every dead end, in the order it happened — is in [docs/setup-log.zh-CN.md](docs/setup-log.zh-CN.md) (Chinese). Design notes, forwarding and command-line quoting details are in [docs/architecture.md](docs/architecture.md).

## License

[MIT](LICENSE). Not affiliated with OpenAI, DeepSeek; Codex is a trademark of OpenAI.
