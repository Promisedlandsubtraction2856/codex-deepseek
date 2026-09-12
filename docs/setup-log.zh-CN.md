# 完整操作记录：codex-deepseek 是怎么搭出来的

这份记录按时间顺序还原搭建过程，包括走过的弯路。环境：Windows 11，ChatGPT 桌面版（内置原生 Codex）+ Codex CLI 0.154.0，Multica CLI + daemon。

---

## 阶段 0：起点与最初的需求

目标有三个：

1. ChatGPT 桌面版继续用原来的 ChatGPT 登录和原生模型，不要被改动。
2. Codex CLI 用 DeepSeek 的模型（`deepseek-flash` / `deepseek-v4-pro`）。
3. 让 Multica 里的 agent 也能跑在这些 DeepSeek 模型上。

初始状态：桌面版和 CLI 共用 `%USERPROFILE%\.codex`，一切正常。

## 阶段 1：弯路 —— 直接改全局 config.toml

第一反应是把 DeepSeek 的 provider 写进全局配置：

```toml
# %USERPROFILE%\.codex\config.toml
model = "deepseek-flash"
model_provider = "deepseek"
model_catalog_json = "C:/Users/mingl/.codex/models.json"

[model_providers.deepseek]
name = "deepseek"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
experimental_bearer_token = "sk-..."
```

CLI 确实能跑了，但桌面版跟着一起变：模型选择器里没有原生模型了，并要求重新登录。

当时的应对是做了一个「切换器」：改之前把 `config.toml` 备份到 `~\.codex\switcher-backups\config-<时间戳>.toml`，把当前 provider 记在 `~\.codex\desktop-deepseek-switch.json`，需要时再切回来。留下的痕迹：

```text
~\.codex\desktop-deepseek-switch.json
~\.codex\switcher-backups\config-20260911-031817-161.toml
~\.codex\switcher-backups\config-20260911-031834-682.toml
```

**结论：这条路不可取。** 桌面版和 CLI 读同一份配置，任何「切换」都是全局副作用：切一次要重启桌面版，还可能被要求重新登录，而且一旦忘记切回来，CLI 的报错信息（`... not supported when using Codex with a ChatGPT account`）和桌面版的登录状态互相干扰，排查成本极高。

## 阶段 2：拆分 Codex home

改成的最终结构：

```text
%USERPROFILE%\.codex              ChatGPT 桌面版 + 原生 codex 命令
%USERPROFILE%\.codex-deepseek     codex-deepseek（本仓库的 CLI）
```

关键点：`CODEX_HOME` 决定 Codex 去哪里读 config、凭据、会话和 SQLite 状态，改它等于整套隔离，而不是只隔离一部分。

第一步先把全局配置恢复干净 —— 从 `~\.codex\config.toml` 里删掉这些键：

```toml
model = "..."
model_provider = "deepseek"
model_catalog_json = "..."
[model_providers.deepseek]
```

桌面版随即恢复正常（原生模型 + ChatGPT 登录）。

第二步建立 DeepSeek home：

```powershell
$deepseekHome = "$env:USERPROFILE\.codex-deepseek"
New-Item -ItemType Directory -Force -Path $deepseekHome | Out-Null
```

`~\.codex-deepseek\config.toml`（实际使用的版本）：

```toml
model = "deepseek-flash"
model_provider = "deepseek"
model_catalog_json = "C:/Users/mingl/.codex-deepseek/models.json"
model_reasoning_effort = "high"
plan_mode_reasoning_effort = "high"
web_search = "disabled"
preferred_auth_method = "apikey"
forced_login_method = "api"

[model_providers.deepseek]
name = "deepseek"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
experimental_bearer_token = "sk-..."
```

这里有三处是踩坑换来的：

| 项 | 为什么 |
|---|---|
| `model_catalog_json` 指向 home 内的 `models.json` | 不指定就会退回二进制内置的 OpenAI 目录，`deepseek-flash` 直接被判定为不支持 |
| `forced_login_method = "api"` + `preferred_auth_method = "apikey"` | 阻止 CLI 去弹 ChatGPT 浏览器登录；这个 home 里故意没有 `auth.json` |
| 不写 `service_tier` | 曾经从全局配置带过来 `service_tier = "default"`，第三方网关不认，直接 `400` |

另外 `model_reasoning_effort` 从 `xhigh` 改成 `high`：`xhigh` 不在该模型的档位里。

`models.json` 由内置目录改造而来，只保留两个条目（文件 76,323 字节，大部分体积是 CLI 要求的长 instructions 字段）：

```powershell
codex debug models --bundled > $env:TEMP\bundled.json
# 保留一个条目做模板，改 slug / display_name / supported_reasoning_levels
```

验证：

```powershell
$env:CODEX_HOME = "$env:USERPROFILE\.codex-deepseek"
codex --version
codex exec "print hello"
```

## 阶段 3：Multica 的模型发现是硬墙

把 agent 的模型设成 `deepseek-flash` 之后，任务在普通 Codex runtime 上失败：

```text
{"detail":"The 'deepseek-flash' model is not supported when using Codex with a ChatGPT account."}
```

原因：**Multica 靠 `codex debug models --bundled` 枚举运行时的模型**，而这条命令只读二进制里内置的 OpenAI 目录，从不看 `model_catalog_json`。所以 DeepSeek 模型既不会出现在模型选择器里，agent 保存下来的 `deepseek-flash` 也会在真正起任务时被拒。

结论：需要一个「只对这一条调用说谎，其余全部原样转发」的启动器。

## 阶段 4：写 wrapper（`CodexDeepSeek.cs`）

两个行为：

- 参数里出现 `debug models` → 把固定的 DeepSeek 目录写到 stdout，退出 0，不调用真 codex。
- 其它任何参数 → 找到真 `codex.exe`，用显式环境块（`CODEX_HOME = %USERPROFILE%\.codex-deepseek`）启动它，继承 stdin/stdout/stderr，透传退出码。

为什么要用 C# 而不是 `.cmd`：

- `cmd` 会二次解析 `%*`，带空格/引号/`&` 的参数会被拆坏；C# 里按 Windows 标准规则重新拼命令行（`QuoteArgument`）。
- Multica 的 daemon 需要和 Codex 保持 stdin/stdout 的 JSON-RPC 通道，中间夹一层批处理很危险。
- 子进程放进 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的 Job Object，daemon 取消任务时不会留下孤立的 `codex.exe`。

真 codex 的查找顺序：`CODEX_DEEPSEEK_TARGET` → `~\.codex\packages\standalone\releases\*\bin\codex.exe`（取版本号最大的）→ `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe` → PATH。

编译（用系统自带的编译器，不需要 SDK）：

```powershell
pwsh -File .\build.ps1
```

内部就是：

```powershell
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /optimize+ /target:exe `
  /out:dist\codex-deepseek.exe src\CodexDeepSeek.cs
```

验证：

```powershell
.\dist\codex-deepseek.exe --version        # -> codex-cli 0.154.0
.\dist\codex-deepseek.exe debug models --bundled
# -> {"models":[{"slug":"deepseek-flash",...},{"slug":"deepseek-v4-pro",...}]}
```

## 阶段 5：接进 Multica

```powershell
multica runtime profile create `
  --display-name "Codex DeepSeek" `
  --protocol-family codex `
  --command-name codex-deepseek `
  --description "Local Codex CLI pinned to the DeepSeek gateway"

multica daemon restart
multica runtime list
```

`runtime list` 里出现 `Codex DeepSeek (<机器名>)`（online），版本探测显示 `codex-cli 0.154.0`。

### 弯路：`runtime profile set-path` 在 Windows 上永远失败

本想用绝对路径固定 exe，结果 daemon 的 `profilePathExecutable` 判定依赖 Unix 可执行位（`mode & 0o111`），NTFS 文件永远没有这个位，于是覆盖总被拒绝、静默回退到 PATH。

**真正的解法**：把 `codex-deepseek.exe` 放进已经在 PATH 上的 `%USERPROFILE%\.multica\bin`。

```powershell
pwsh -File .\build.ps1 -InstallMultica
```

## 阶段 6：agent 不会自动跟着走

profile 只是让 runtime 存在，agent 还是绑在旧 runtime 上，必须显式改绑：

```powershell
multica --workspace-id <workspace-id> agent update <agent-id> `
  --runtime-id <deepseek-runtime-id> --model deepseek-flash --thinking-level high
```

### 弯路：profile 是按 workspace 隔离的

在 A 工作区建的 profile，B 工作区完全看不到，那边只有自动探测出来的 `Codex (<机器名>)`，agent 继续报同样的错。于是写了 `Setup-MulticaDeepSeek.ps1`：给指定 workspace 幂等地创建 profile，并把所有 `model` 还是 `deepseek-flash` / `deepseek-v4-pro` 的 agent 改绑过去。

```powershell
pwsh -File .\multica\Setup-MulticaDeepSeek.ps1 -WorkspaceId <id> -DryRun   # 预览
pwsh -File .\multica\Setup-MulticaDeepSeek.ps1 -WorkspaceId <id>           # 执行
pwsh -File .\multica\Setup-MulticaDeepSeek.ps1 -WorkspaceId <id> `
  -Agents 'Lead Dev','Code Reviewer' -RuntimeName 'Codex DeepSeek (mlangTse)'
```

### 弯路：创建工作区 profile 需要 admin/owner

普通 member 执行 `runtime profile create` 会拿到 `403 insufficient permissions`；脚本会把需要交给 owner 执行的那条命令原样打印出来。读取 runtime、改绑自己拥有的 agent 用 member 权限就够。

## 阶段 7：用量与计费

用量走 Codex app-server 的 `thread/tokenUsage/updated` 事件，模型名取自 agent 的 `model` 字段（留空会计成 `unknown`）。Multica 的内置价格表只有 `deepseek-v4-flash / v4-pro / chat / reasoner`，没有 `deepseek-flash`，所以金额列是空的，需要为 `codex/deepseek-flash` 加一条自定义价格。

## 最终校验清单

```powershell
# 1. 桌面版不受影响
codex --version                       # 原生 CLI
# 桌面版里模型选择器仍有原生模型、无需重新登录

# 2. DeepSeek CLI 正常
codex-deepseek --version              # codex-cli 0.154.0
codex-deepseek exec "print hello"     # 走 DeepSeek

# 3. 模型目录被正确劫持
codex-deepseek debug models --bundled # 只有 deepseek-flash / deepseek-v4-pro

# 4. Multica 侧
multica --workspace-id <id> runtime list          # 有 "Codex DeepSeek (<机器>)"
multica --workspace-id <id> runtime profile list  # profile_id 非空
# daemon.log: "task uses custom runtime profile command ... command_path=...\codex-deepseek.exe"
```

## 踩坑一览

| 坑 | 现象 | 解法 |
|---|---|---|
| 全局 `config.toml` 写自定义 provider | 桌面版模型消失 / 要求重新登录 | DeepSeek 相关键只放在 `~\.codex-deepseek\config.toml` |
| `service_tier = "default"` | 网关 `400`，body 为空 | 不写这个键 |
| `model_reasoning_effort = "xhigh"` | 档位不被支持 | 改成 `high`，或在目录里补档位 |
| 缺 `model_catalog_json` | 报模型不支持 | 指向 `~\.codex-deepseek\models.json` |
| Multica 只认内置目录 | 选择器里没有 DeepSeek | 用 wrapper 劫持 `debug models` |
| `runtime profile set-path` | 覆盖总被拒绝 | 装进已在 PATH 的 `~\.multica\bin` |
| profile 工作区隔离 | 别的 workspace 仍然报错 | 每个 workspace 建一次 profile |
| member 权限 | `403 insufficient permissions` | owner 执行创建命令 |
| 计费金额为空 | 只有 token 没有金额 | 加 `codex/deepseek-flash` 自定义价格 |
