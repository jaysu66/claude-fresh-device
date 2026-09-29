# 检查项清单与依据

脚本里每个动作/检查项的编号都在这里登记依据。证据分四级：

- **[实证]** — Claude Code 客户端二进制/源码里直接确认的行为
- **[实测]** — 真实机器上观察到的行为（文件确实在那里、值确实长这样）
- **[推断]** — 服务端风控逻辑的合理推断（服务端规则不可见，诚实标注）
- **[常识]** — 浏览器/Chromium/网络的公开通用知识

## A. 运行态

| 编号 | 检查项 | 依据 | 判定 |
|---|---|---|---|
| A1 | claude.exe / chrome-native-host 进程存活 | [实测] 进程活着时清理的文件会被写回 | 阻塞清理，必须先退 |
| A2 | `\\.\pipe\` 下 claude/anthropic 命名管道 | [实测] 退出不干净时管道残留 | 提示项 |

## C. Claude Code(CLI)身份层

| 编号 | 检查项 | 依据 | 判定 |
|---|---|---|---|
| C1 | `HKLM\SOFTWARE\Microsoft\Cryptography` MachineGuid | [实证] Claude Code 用 node-machine-id 读它，`device_id = SHA256(MachineGuid)` 并随遥测上报 | **轮换 = 换设备身份的根**。需管理员+重启。可逆（备份旧值）。副作用：个别按设备授权的软件（企业 VPN 等）可能要求重认证 |
| C2 | `~/.claude.json` 的 userID / machineID / oauthAccount / `*Cache` 键 | [实证]+[实测] userID/machineID 进遥测身份块；oauthAccount 存旧号邮箱；clientDataCacheSlots 等缓存键实测藏历史 org uuid | 再随机化 + 删缓存键（自动重建，无损） |
| C3 | `~/.claude/.credentials.json` 的 claudeAiOauth | [实测] OAuth 令牌本体 | 删（旧号令牌留着=直接复用旧身份） |
| C4 | `~/.claude/` 下 telemetry / sessions / jobs / debug / daemon / file-history / usage*.jsonl 等 | [实测] telemetry 事件含旧 device_id；jobs/*/state.json 记 bridgeOwner*Uuid；其余是运行时垃圾 | 删（全部自动重建） |
| H1 | `~/.claude/history.jsonl`、`projects/**/*.jsonl` 会话历史 | [常识] 本地文件，不上报；telemetry 只发事件元数据不发转录 | **默认保留**（不是指纹、是用户数据）。`-WipeHistory` 才删，删时仍保 memory/ |

## D. Claude Desktop 身份层（`%APPDATA%\Claude`）

| 编号 | 检查项 | 依据 | 判定 |
|---|---|---|---|
| D1 | `ant-did` / `ant-device-registry.json` | [实测] Desktop 设备 ID 文件；删后重生为新随机值=新身份，重生同值=硬件派生（verify 会识别并拦截） | 删 |
| D2 | `config.json` 的 `oauth:*` tokenCache、`lastKnownAccountUuid`、`dxt:allowlist*` | [实测] OAuth 令牌密文 + 账号/组织 UUID | 删键不删文件 |
| D3 | `claude_desktop_config.json` 账号 UUID 索引键；`plan-usage-history.json`、`cowork-enabled-*.json`、`bridge-state.json`、`extensions-blocklist.json` | [实测] preferences 下多处按账号 UUID 索引；单文件含 org uuid / 配对设备 | 删键/删文件（**保留 mcpServers 用户配置**） |
| D4 | `Preferences` 的 `electron.media.device_id_salt` | [实测] Chromium 设备 ID 加盐种子 | 删键 |
| D5 | `Network\Cookies` 等 Chromium 存储 | [常识]+[实测] cookie 罐实测含 `anthropic-device-id`、`__stripe_mid`(Stripe 跨站设备指纹)、`ajs_*`、`intercom-device-id`、`lastActiveOrg` | 整目录删 |
| D6 | `claude-code-sessions/`、`local-agent-mode-sessions/` 下账号 UUID 子目录 | [实测] 目录名=账号 UUID | 整目录删 |
| D7 | `Local Storage`/`IndexedDB`/`Session Storage`/`Partitions`/`sentry`/`logs`/`Cache` 等 | [常识]+[实测] LevelDB 明文存 `{"orgUuid":…}`；sentry 事件含 did | 整目录删（自动重建） |
| D8 | `%APPDATA%\Claude Code\ChromeNativeHost\` | [实测] CLI↔浏览器扩展配对通道（native messaging host manifest) | 保留观察（不含标识符本体） |

## L. LOCALAPPDATA

| 编号 | 检查项 | 依据 | 判定 |
|---|---|---|---|
| L1 | `%LOCALAPPDATA%\Claude\Logs` | [实测] 日志含历史账号 email/uuid | 删 |
| L2 | `%LOCALAPPDATA%\claude-cli-nodejs\Cache` | [实测] MCP 日志缓存，目录名内嵌账号+组织 UUID | 整目录删 |

## B. 浏览器面

| 编号 | 检查项 | 依据 | 判定 |
|---|---|---|---|
| B1 | 注册表 `NativeMessagingHosts` 里 `com.anthropic.*` 项 | [实测] 表明装过 Claude 浏览器扩展/配对 | 提示项（本身不上报） |
| B2 | Chrome/Edge 各 profile `Network\Cookies` | [常识] cookie 按域隔离：claude.ai 只能收到自己域的 cookie，**看不到其他站登录态** | **不自动清库**。首选：用没碰过 claude.ai 的浏览器/无痕窗口走 OAuth；或 `chrome://settings/siteData` 手动删 `claude`/`anthropic` 域 |
| B3 | profile `Extensions\` 下 Claude 扩展 ID(fcoeoabg…/dihbgbnd…/dngcpimn…) | [实测] 扩展本地存储可能存配对设备 ID；native host 会被唤起 | 登录用哪个 profile，就确保那个 profile 里没装/已卸 |
| B4 | 浏览器指纹（UA/时区/语言/WebGL/分辨率/字体） | [常识] 全部来自 OS/硬件层，**换 profile 改不了**；所以"新浏览器"的价值只在干净的站点数据，不在指纹 | 不需要也不建议伪装（不一致反而是更强指纹） |

## N. 网络面

| 编号 | 检查项 | 依据 | 判定 |
|---|---|---|---|
| N1 | 出口 IP + ASN | [推断] 风控看 IP 情报库标注（住宅/机房/proxy)，不看 ip-api 的口径；旧号死过的 IP 段勿复用 | 换号必须换 IP；verify 里 IP 未变→WARN |
| N2 | 系统时区/语言 vs IP 地理 | [推断]+[常识] OAuth 走浏览器，网页端 JS 直接读时区/语言；错位是软信号 | 提示项（改时区更糟，见 SKILL.md 边界） |
| N4 | 系统代理 vs TUN | [常识]+[余温文章] 系统代理会在 Windows Internet Settings 留 127.0.0.1:端口 记录,只管浏览器;TUN 建虚拟网卡接管全部流量 | 提示项:用 TUN,系统代理保持关闭 |
| N5 | 残留代理配置(HTTP(S)_PROXY、npm/git proxy、settings.json) | [常识] 历史残留可能让部分流量走另一条线路 | 提示项:人工确认 |
| N3 | hostname / RegisteredOwner | [实证] `enrollTrustedDevice` 上报 `Claude Code on <hostname> · <platform>`（仅 org 开 policy 时）；RegisteredOwner 不进上报链 | 可选改（hostname 影响系统面较大，自行权衡） |

## M. 记忆与凭据

| 编号 | 检查项 | 依据 | 判定 |
|---|---|---|---|
| M1 | `projects/**/memory/*.md`、`CLAUDE.md` 里的邮箱、封号/指纹字样 | [T] memory 索引会被读进新号对话上下文,随请求发出 | **只报告不自动删**:人工审阅,可移入隔离目录;UUID 类多是本地 session id,不是账号标识 |
| M2 | Windows 凭据管理器里 claude/anthropic 条目 | [I] macOS 有 Keychain 残留(余温文章),Windows 上 Claude Code 令牌在 `.credentials.json`,此项为保险检查 | 有则清 |

## E. 环境变量

| 编号 | 检查项 | 依据 | 判定 |
|---|---|---|---|
| E1 | `ANTHROPIC_*`/`CLAUDE_*` env | [实证] CLI 只认这两个前缀；`MINIMAX_*` 等中转变量对 Claude 进程惰性 | 提示项；走官方号时确认 `ANTHROPIC_BASE_URL`/`_AUTH_TOKEN` 没指向中转 |

## 绝对不动（有依据的"保留"判定）

- `~/.claude/skills|agents|plugins|commands` —— 用户资产，非指纹
- `~/.claude/projects/**/memory/` —— 项目记忆，非指纹
- `~/.claude/settings.json`、`CLAUDE.md` —— 配置本体（遥测开关变量还在里面起作用）
- 浏览器非 claude/anthropic 域的 cookie/登录/密码/自动填充 —— 域隔离决定了 Claude 收不到，删了只伤用户
- `~/.claude/backups/` —— 清理的退路
- 其他 AI 产品数据（`~/.codex`、`%APPDATA%\Code` machineid 等）—— 平行产品，不进 Claude 上报链；要清是独立决策
