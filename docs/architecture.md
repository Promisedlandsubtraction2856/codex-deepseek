# Architecture

## Two Codex homes, one machine

| | ChatGPT Desktop + `codex` | `codex-deepseek` |
|---|---|---|
| Codex home | `~/.codex` (`%USERPROFILE%\.codex` on Windows) | `~/.codex-deepseek` |
| Config | written by the Desktop app / ChatGPT login | written by `install.ps1` or `install.sh` |
| Credentials | `auth.json` + ChatGPT session | `experimental_bearer_token` (DeepSeek API key) |
| Catalog | bundled OpenAI catalog | `models.json`, pinned via `model_catalog_json` |
| Sessions, memories, logs | `~/.codex/...` | `~/.codex-deepseek/...` |

`CODEX_HOME` is the only switch that matters. Codex resolves its config, its
credentials, its session store and its SQLite state relative to that one
variable, so pointing it somewhere else is a complete separation rather than a
partial one. Nothing in this project ever writes to `~/.codex`.

## Two launchers, one contract

| | Windows | macOS / Linux |
|---|---|---|
| Source | `src/CodexDeepSeek.cs` | `src/codex-deepseek.sh` |
| Artifact | `dist/codex-deepseek.exe` (14 KB, no dependencies) | executed as-is |
| Installed to | `%USERPROFILE%\.codex-deepseek\bin` | `~/.codex-deepseek/bin` |

Both do exactly the same four things:

1. Resolve the Codex home: `CODEX_DEEPSEEK_HOME` if set, otherwise
   `~/.codex-deepseek`, and refuse to run when it holds no `config.toml`.
2. Resolve the real Codex binary (see below).
3. Set `CODEX_HOME` to that home and start the real binary with the caller's own
   stdin/stdout/stderr, so pipes, redirection and interactive TUIs work.
4. Report the real binary's exit code. If no Codex can be found, print how to
   point at one and exit **127**.

Everything else about Codex — model selection, sandboxing, approvals, MCP
servers, plugins — is untouched: the launcher never rewrites arguments and never
inspects the config it hands over.

## Why a launcher instead of a `.cmd` shim or a shell alias

A batch file looks sufficient:

```bat
@echo off
set "CODEX_HOME=%USERPROFILE%\.codex-deepseek"
codex %*
```

It is not, for the same reasons a shell function is not:

- **Argument boundaries.** `cmd.exe` re-parses `%*`, so a quoted argument
  containing spaces, `&`, `^` or `"` can be mangled or split. The Windows
  launcher rebuilds the command line with the standard quoting algorithm that
  the C runtime's `argv` parser reverses (`QuoteArgument`), so
  `codex-deepseek exec "a & b"` arrives intact. On POSIX, `exec "$target" "$@"`
  passes the original argument vector through with no re-parsing at all.
- **Standard handles.** The Windows launcher starts Codex with
  `STARTF_USESTDHANDLES` and the parent's handles instead of creating a console,
  so output redirection, pipes and `codex app-server` clients keep working.
  POSIX `exec` replaces the process image outright, which is the strongest
  possible guarantee.
- **Exit codes.** The launcher mirrors the child's exit code; a `.cmd` wrapper
  would return `cmd.exe`'s.
- **Environment.** `CODEX_HOME` is passed through an explicit environment block
  (Windows) or a plain assignment (POSIX), so it is the child's value regardless
  of profile scripts or `setx` timing.
- **No orphans.** After `CreateProcess` succeeds, the Windows launcher assigns
  the child to a job object created with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`
  and blocks on it. Killing the launcher for any reason terminates Codex too.

## Finding the real Codex

Identical order on every platform:

1. `CODEX_DEEPSEEK_TARGET`, when it points at an executable file.
2. The newest `~/.codex/packages/standalone/releases/<version>/bin/codex` — the
   version is the leading dotted number of the directory name, compared
   numerically. On Windows the file is `codex.exe`.
3. `codex` on `PATH`, skipping the launcher itself so it cannot recurse.

Nothing found means a message naming `CODEX_DEEPSEEK_TARGET` and exit 127.

An unusable `CODEX_DEEPSEEK_TARGET` does not abort the search; the remaining
steps still run.

## Finding the DeepSeek home

`CODEX_DEEPSEEK_HOME` when set, otherwise `%USERPROFILE%\.codex-deepseek`
(Windows) or `~/.codex-deepseek` (POSIX). `install.ps1 -DeepSeekHome <path>`
exports the variable at user scope so a home on another drive keeps working.

## What to keep private

- The DeepSeek API key lives in `<home>/config.toml` as
  `experimental_bearer_token`. That directory is not a git repository, and this
  repo's `.gitignore` excludes `config.toml` in case someone copies the layout
  into a checkout. On POSIX the installer writes it with mode `600`.
- Neither launcher reads, logs or transmits the key: they only pass an
  environment block and an argument vector to the real CLI.
- Nothing in this repo talks to the network on its own.

## File map

```text
src/CodexDeepSeek.cs        Windows launcher
src/codex-deepseek.sh       macOS / Linux launcher
build.ps1                   compile the Windows launcher with the in-box csc.exe
install.ps1                 Windows: build + create home + write config + PATH
install.sh                  macOS / Linux: install launcher + create home + write config + PATH
config/config.toml.example  provider template (filled in by both installers)
config/models.json          pinned model catalog, referenced by model_catalog_json
tests/                      launcher and installer tests; no Codex install or network needed
```
