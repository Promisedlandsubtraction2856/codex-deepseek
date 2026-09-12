# Architecture

## Two Codex homes, one machine

| | ChatGPT Desktop + `codex` | `codex-deepseek` |
|---|---|---|
| Codex home | `%USERPROFILE%\.codex` | `%USERPROFILE%\.codex-deepseek` |
| Config | `config.toml` written by the Desktop app / ChatGPT login | `config.toml` written by `install.ps1` |
| Credentials | `auth.json` + ChatGPT session | `experimental_bearer_token` (DeepSeek API key) |
| Catalog | bundled OpenAI catalog | `models.json`, pinned to DeepSeek models |
| Sessions, memories, logs | `~\.codex\...` | `~\.codex-deepseek\...` |

`CODEX_HOME` is the only switch that matters. Codex resolves its config, its
credentials, its session store and its SQLite state relative to that one
variable, so pointing it somewhere else is a complete separation, not a partial
one.

## Why a launcher instead of a `.cmd` shim

A batch shim works for a human at a keyboard:

```bat
@echo off
set "CODEX_HOME=%USERPROFILE%\.codex-deepseek"
codex %*
```

It stops working the moment something drives Codex programmatically:

- **Argument boundaries survive.** `cmd.exe` re-parses `%*`, so a quoted argument
  containing spaces, `&`, `^` or `"` can be mangled or split. The launcher
  rebuilds the command line with the standard Windows quoting algorithm that the
  C runtime's `argv` parser reverses (`QuoteArgument` in
  [src/CodexDeepSeek.cs](../src/CodexDeepSeek.cs)), so `codex-deepseek exec "a & b"`
  arrives intact.
- **Standard handles are inherited, not redirected.** Codex is started with
  `STARTF_USESTDHANDLES` and the parent's `STD_INPUT/OUTPUT/ERROR` handles, so a
  JSON-RPC client (Multica's daemon, an editor plugin, a pipe) can hold a
  conversation with it. A batch file in the middle of that pipe is a liability.
- **The exit code is the child's exit code**, not `cmd.exe`'s.
- **`CODEX_HOME` is set through an explicit environment block**, so it is the
  child's value regardless of the parent's shell, profile scripts or `setx`
  timing.

## The discovery interception

Multica enumerates a Codex runtime's models by running:

```text
codex debug models --bundled
```

That command reads the catalog compiled into the binary and never consults
`model_catalog_json`, so a runtime pinned to a third-party gateway still
advertises OpenAI models — and Multica's picker offers only those. An agent set
to `deepseek-flash` then fails at turn time with
`The 'deepseek-flash' model is not supported when using Codex with a ChatGPT account.`

The launcher intercepts **exactly that argument pair** (`debug` followed by
`models`, in any position) and writes the pinned catalog to stdout, then exits 0.
Everything else — `--version`, `app-server`, `exec`, `resume`, `login`, … — is
forwarded to the real binary.

That keeps the interception narrow: the only behaviour that differs from a real
`codex.exe` is the answer to a read-only discovery call.

## Finding the real Codex

`ResolveCodexPath()` tries, in order:

1. `%CODEX_DEEPSEEK_TARGET%` if it points at an existing file.
2. The newest `%USERPROFILE%\.codex\packages\standalone\releases\*\bin\codex.exe`,
   compared by the numeric components of the directory name.
3. `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe` (the Desktop app's copy).
4. `codex.exe` on `PATH`, skipping the launcher's own path.

If none of them exist, the launcher prints a message naming
`CODEX_DEEPSEEK_TARGET` and exits 127.

## Finding the DeepSeek home

`ResolveDeepSeekHome()` uses `%CODEX_DEEPSEEK_HOME%` when it is set, and
`%USERPROFILE%\.codex-deepseek` otherwise. `install.ps1 -DeepSeekHome <path>`
writes that variable's target, so a home on another drive is supported without
touching the launcher's default behaviour.

## Lifecycle and cancellation

After `CreateProcess` succeeds, the child is assigned to a job object created
with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. When the daemon cancels a task, times
out, or kills the wrapper for any reason, the job handle closes and Windows
terminates Codex too — no orphaned `codex.exe` accumulating in Task Manager.
`codex-deepseek.exe` itself blocks on `WaitForSingleObject(INFINITE)` and mirrors
the child's exit code.

## Threat model / what to keep private

- The DeepSeek API key lives in `%USERPROFILE%\.codex-deepseek\config.toml` as
  `experimental_bearer_token`. That directory is **not** a git repository, and
  this repo's `.gitignore` excludes `config.toml` in case someone copies this
  layout into a checkout.
- The launcher never reads, logs or transmits the key: it only passes an
  environment block and a command line to the real CLI.
- Nothing in this repo talks to the network on its own.

## File map

```text
build.ps1                        compile with the in-box csc.exe
install.ps1                      build + create home + write config + PATH
src\CodexDeepSeek.cs             the launcher
config\config.toml.example       template for ~\.codex-deepseek\config.toml
config\models.json               pinned model catalog (deepseek-flash, deepseek-v4-pro)
multica\Setup-MulticaDeepSeek.ps1  register the runtime profile in a workspace and rebind agents
```
