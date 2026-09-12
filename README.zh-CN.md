# codex-deepseek

**让真正的 OpenAI Codex CLI 跑 DeepSeek 模型，同时 ChatGPT 桌面版照旧使用自己的登录、模型和配置。**

[English](README.md) · [架构说明](docs/architecture.md) · [完整操作记录](docs/setup-log.zh-CN.md)

---

## 解决什么问题

Codex 桌面版和 Codex CLI **读的是同一份 `%USERPROFILE%\.codex\config.toml`**，也用同一个 home 目录。一旦你为了让 CLI 使用 DeepSeek 而写入：

```toml
model = "deepseek-flash"
model_provider = "deepseek"
```

桌面版就会跟着变：模型选择器里没有 ChatGPT 模型了、要求重新登录，或者登录界面一直转圈加载 —— 因为 ChatGPT 订阅不能服务 `deepseek-*` 模型，DeepSeek 的 key 也不能服务 `gpt-*`。

于是就有了「同一份文件来回改、改完还要重启/重新登录」的循环。这个仓库终结这个循环：

```text
                     你的电脑
                         |
        +----------------+-----------------+
        |                                  |
   ChatGPT 桌面版                     Codex CLI
   + 原生 Codex                       + 本仓库
        |                                  |
  %USERPROFILE%\.codex            %USERPROFILE%\.codex-deepseek
        |                                  |
  ChatGPT 登录 / Pro                你自己的 DeepSeek API Key
        |                                  |
  GPT / Codex 模型                  deepseek-flash, deepseek-v4-pro
```

关键是 `codex-deepseek.exe` 这个启动器：它用显式重写过的 `CODEX_HOME` 去启动**真正的** `codex.exe`，所以无论全局配置怎么写、PATH 怎么排、环境变量怎么传，DeepSeek 的设置都不可能漏进桌面版。

## 仓库内容

| 路径 | 作用 |
|---|---|
| `install.ps1` | 一条命令：创建 `~\.codex-deepseek`、写 DeepSeek provider 配置、编译并安装启动器、加进用户 PATH。 |
| `src\CodexDeepSeek.cs` | 启动器本身。用 Windows 自带的 `csc.exe` 编译，**不需要 .NET SDK、不需要 NuGet、不需要装运行时**。 |
| `config\models.json` | 固定给 CLI 用的模型目录，让 DeepSeek 模型成为一等公民，同时避免误选 OpenAI 模型。 |
| `multica\` | 可选：让 [Multica](https://github.com/multica-ai/multica) 的 Codex runtime 也能选到同样的 DeepSeek 模型（见下文）。 |

## 环境要求

- Windows 10/11（启动器要转发标准句柄、使用 Win32 Job Object，细节见[架构说明](docs/architecture.md)）。
- 已经装好并能正常运行的 Codex CLI：`codex --version`。
- 一个 DeepSeek API Key，且能访问你在 `config\models.json` 里列出的模型。
- PowerShell 5.1 以上（`pwsh` 7 也可以）。

## 快速开始

下面的示例用 `pwsh`；如果没有装 PowerShell 7，把 `pwsh -File` 换成 `powershell -ExecutionPolicy Bypass -File` 即可。

```powershell
git clone https://github.com/mlangTse/codex-deepseek.git
cd codex-deepseek

# 编译启动器 + 创建 ~\.codex-deepseek + 写入 PATH
pwsh -File .\install.ps1

# 安装脚本会问你的 DeepSeek API Key（也可以用 -ApiKey 参数或 $env:DEEPSEEK_API_KEY）
```

**新开**一个终端，然后：

```powershell
codex-deepseek --version      # -> codex-cli 0.154.0（真 CLI，不是重写的实现）
codex-deepseek exec "打印当前日期"
```

原来的 `codex` 命令完全不受影响，继续用你的 ChatGPT 登录。

### 手动安装（想逐步确认时）

```powershell
# 1. 编译
pwsh -File .\build.ps1                       # 产出 dist\codex-deepseek.exe

# 2. 建立独立的 Codex home
$deepseekHome = "$env:USERPROFILE\.codex-deepseek"
New-Item -ItemType Directory -Force -Path "$deepseekHome\bin" | Out-Null
Copy-Item .\config\models.json         "$deepseekHome\models.json"
Copy-Item .\config\config.toml.example "$deepseekHome\config.toml"
Copy-Item .\dist\codex-deepseek.exe    "$deepseekHome\bin\"

# 3. 编辑 $deepseekHome\config.toml，把占位符换成你的 Key

# 4. 把启动器目录加入 PATH（只需一次）
[Environment]::SetEnvironmentVariable(
  'Path',
  [Environment]::GetEnvironmentVariable('Path','User') + ";$deepseekHome\bin",
  'User')
```

## 配置说明

`%USERPROFILE%\.codex-deepseek\config.toml` 就是全部，它永远不会碰到桌面版：

```toml
model = "deepseek-flash"
model_provider = "deepseek"
model_catalog_json = "C:/Users/<你的用户名>/.codex-deepseek/models.json"
model_reasoning_effort = "high"
web_search = "disabled"
preferred_auth_method = "apikey"
forced_login_method = "api"

[model_providers.deepseek]
name = "deepseek"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
experimental_bearer_token = "<你的 DeepSeek API Key>"
```

这几行都是踩过坑才留下的：

- **`model_catalog_json` 不能省。** 没有它，CLI 用二进制里内置的 OpenAI 目录，任务会直接报 `The 'deepseek-flash' model is not supported when using Codex with a ChatGPT account.`
- **`forced_login_method = "api"` + `preferred_auth_method = "apikey"`** 阻止 CLI 去弹 ChatGPT 浏览器登录；这个 home 故意没有 `auth.json`。
- **`web_search = "disabled"`**，因为第三方网关不提供托管的搜索工具。
- 不要写 `service_tier`，第三方网关会直接返回 `400`。
- 这个文件里是明文 bearer token，别提交到仓库。`.gitignore` 已经排除 `config.toml`，`install.ps1` 也不会把 Key 回显出来。

### 模型列表从哪来

CLI 能用哪些模型由 `config\models.json` 决定，改完重启 CLI 即生效，不需要重新编译：

```powershell
codex-deepseek debug models --bundled   # 当前 home 暴露的模型
```

## 日常使用

```powershell
codex-deepseek                      # 交互式 TUI，跑 DeepSeek
codex-deepseek exec "fix the tests"
codex-deepseek resume               # 会话存在 ~\.codex-deepseek\sessions
codex-deepseek --version

codex                               # 保持原样：ChatGPT 账号
```

`install.ps1` 会在启动器旁边放两个短别名：Git Bash 用 `cx`，cmd 用 `cx.cmd`。

```bash
cx exec "解释一下这个仓库"
```

## Multica 接入

如果通过 [Multica](https://github.com/multica-ai/multica) daemon 跑 agent，会多一个坑：**Multica 靠 `codex debug models --bundled` 枚举模型**，而它永远只返回二进制里内置的 OpenAI 目录。于是 DeepSeek 模型不会出现在选择器里，直接把 agent 配成 `model = deepseek-flash` 又会在普通 Codex runtime 上失败：

```text
{"detail":"The 'deepseek-flash' model is not supported when using Codex with a ChatGPT account."}
```

`codex-deepseek.exe` 只对这一条调用返回 DeepSeek 目录，其余调用（`--version`、`app-server`、`exec`……）原样转发给真 binary 并继承 stdin/stdout/stderr，Multica 的 JSON-RPC 通道不受影响。

```powershell
pwsh -File .\build.ps1                        # 存在 ~\.multica\bin 时会一并复制过去

multica runtime profile create `
  --display-name "Codex DeepSeek" `
  --protocol-family codex `
  --command-name codex-deepseek `
  --description "Local Codex CLI pinned to the DeepSeek gateway"

multica daemon restart
multica runtime list                          # 应出现 "Codex DeepSeek (<机器名>)" online
```

然后让脚本（幂等、支持 `-DryRun`）把 agent 也绑过去：

```powershell
pwsh -File .\multica\Setup-MulticaDeepSeek.ps1 -WorkspaceId <workspace-id> -DryRun
pwsh -File .\multica\Setup-MulticaDeepSeek.ps1 -WorkspaceId <workspace-id>
```

三个容易耗掉一晚上的事实：

1. **`multica runtime profile set-path` 在 Windows 上用不了。** daemon 的 `profilePathExecutable` 判断依赖 Unix 可执行位（`mode & 0o111`），NTFS 文件永远没有，所以覆盖总是被拒绝、回退到 PATH。真正有效的是把 `codex-deepseek.exe` 放进已在 PATH 上的 `~\.multica\bin`。
2. **Runtime profile 是按 workspace 隔离的。** 在 A 工作区创建的 profile 在 B 工作区不存在，那边的 agent 会继续报错，所以需要 `Setup-MulticaDeepSeek.ps1 -WorkspaceId <id>`。
3. **创建工作区 profile 需要 admin/owner。** 普通 member 会拿到 `403 insufficient permissions`，脚本会打印需要交给 owner 执行的完整命令；重新绑定自己拥有的 agent 用 member 权限即可。

agent 不会自己跟着 profile 走，必须显式改绑：

```powershell
multica --workspace-id <workspace-id> agent update <agent-id> `
  --runtime-id <deepseek-runtime-id> --model deepseek-flash --thinking-level high
```

用量计费：Multica 内置价格表只有 `deepseek-v4-flash / v4-pro / chat / reasoner`，没有 `deepseek-flash`，所以 token 数会显示、金额为空，直到你为 `codex/deepseek-flash` 加一条自定义价格。

## 常见故障对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| 桌面版要求重新登录，或登录界面一直转圈 | 全局 `~\.codex\config.toml` 里写了自定义 `model_provider` | 从 `~\.codex\config.toml` 删掉 `model` / `model_provider` / `model_catalog_json` / `[model_providers.*]`，只保留在 `~\.codex-deepseek\config.toml` |
| 网关返回 `400`，body 为空 | 请求里带了 `service_tier = "default"` | DeepSeek home 里不要设 `service_tier` |
| `model_reasoning_effort = "xhigh"` 被拒 | 目录里没有该档位 | 用 `high`，或在 `models.json` 里补上档位 |
| 报 `... not supported when using Codex with a ChatGPT account` | 这一轮跑的是 ChatGPT home 下的真 `codex.exe` | DeepSeek 配置漏进了 `~\.codex`，或 Multica runtime 没绑到 wrapper |
| `codex-deepseek: cannot find the real codex executable` | 找不到 Codex 安装 | 设 `CODEX_DEEPSEEK_TARGET` 为 `codex.exe` 的完整路径 |
| `codex-deepseek: missing DeepSeek config at ...` | 独立 home 里没有 `config.toml` | 跑 `install.ps1` 或手工创建 |
| Multica 取消任务后 `codex.exe` 残留 | — | 不会发生：子进程在 kill-on-close 的 Job Object 里，杀掉 wrapper 即终止 Codex |

## 这套东西是怎么来的

完整操作记录（每条命令、每个弯路、按时间顺序）在 [docs/setup-log.zh-CN.md](docs/setup-log.zh-CN.md)；转发机制、命令行引号处理等设计细节在 [docs/architecture.md](docs/architecture.md)。

## 许可

[MIT](LICENSE)。与 OpenAI、DeepSeek、Multica 均无隶属关系；Codex 是 OpenAI 的商标。
