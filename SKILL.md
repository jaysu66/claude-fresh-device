---
name: claude-fresh-device
description: This skill should be used when the user needs to audit, clean, and verify a Windows machine before logging a new Claude account on it — e.g. "复盘封号", "清理 Claude 指纹", "设备指纹", "这台电脑能不能登新号", "clean Claude fingerprints", "fresh device for Claude", "风控", "换号防关联", "audit my machine before Claude login". It runs a three-stage pipeline: read-only risk audit → evidence-tagged cleanup → verification gate that must PASS before the user logs in a new account. Windows only.
---

# claude-fresh-device

Windows 上 Claude 换号前的「评估 → 清理 → 复查」流水线。目标：让 Claude 服务端看到的本机身份是一台新电脑。

**边界声明**：本 skill 处理的是本机指纹卫生，降低新号被关联到旧号/旧设备的概率。它不承诺、也无法承诺绕过 Anthropic 服务端风控；账号来源质量、支付链、服务端行为建模均不在本机控制范围内。对用户保持这个诚实口径。

## 三阶段流水线

严格按顺序执行，每段独立脚本、独立产物：

```
Stage 1  audit.ps1   只读风险评估 → 生成 baseline + 风险报告
Stage 2  clean.ps1   用户确认报告后执行清理(每项操作在 references/checklist.md 有依据编号)
Stage 3  verify.ps1  复查门禁:全部 PASS 才允许登录;任何 FAIL 阻断并列出残留
```

### Stage 1 — 风险评估(永远先跑，零副作用)

```powershell
powershell -ExecutionPolicy Bypass -File scripts/audit.ps1
```

- 只读：不写注册表、不改文件、不杀进程。
- 扫描项与依据见 `references/checklist.md` —— 每一项标注 `[实证]`(客户端二进制/源码确认)、`[实测]`(真机观察)、`[推断]`(服务端风控推断)、`[常识]`(通用浏览器/网络知识)。没有依据的项不进清单。
- 产物：`%USERPROFILE%\.fresh-device\baseline-<时间戳>.json`(本轮发现的标识符基线，供 Stage 3 对照；**只存本机，绝不提交 git**)和一份控制台风险报告。
- 报告结论分档：`READY`(本机无 Claude 痕迹)/ `NEEDS_CLEANUP`(有残留，走 Stage 2)/ `BLOCKED`(进程在跑，先退再评)。
- 输出默认脱敏(标识符只显示前 8 位)。用户要看全值时加 `-Full`。
- 可选深挖：本机有 node 时跑 `node scripts/scan-sqlite.cjs` 看 SQLite/LevelDB 里的具体标识(输出可能含个人信息，仅本机查看)。

### Stage 2 — 清理(必须先给用户看 Stage 1 报告并获确认)

```powershell
powershell -ExecutionPolicy Bypass -File scripts/clean.ps1            # 全量(含 MachineGuid 轮换,需管理员)
powershell -ExecutionPolicy Bypass -File scripts/clean.ps1 -SkipMachineGuid   # 不动注册表
powershell -ExecutionPolicy Bypass -File scripts/clean.ps1 -Stage desktop-only -Force  # 只清桌面端
```

原则——**有依据才清，能保留就保留**：

- 每条清理动作在代码注释里标注 checklist 编号(如 `[C2]` → references/checklist.md)。
- 清理前全量备份到 `~/.claude/backups/fingerprint-cleanup-<ts>/`。
- **绝不碰**保护清单(见下)——其中有用户的技能、记忆、其他网站的登录态。
- 浏览器不做自动清库：首选方案是**让用户用没碰过 claude.ai 的浏览器/无痕窗口走 OAuth**(等价于新 profile，零风险)。仅当用户明确要求定点清时，引导走 `chrome://settings/siteData` 手动删 `claude`/`anthropic` 域 —— 浏览器运行中不改它的 SQLite。
- MachineGuid 轮换需要管理员 + 重启才生效；脚本检测无管理员权限时打印命令让用户自己执行，不静默失败。

### Stage 3 — 复查门禁(清理后必跑，决定能否登录)

```powershell
powershell -ExecutionPolicy Bypass -File scripts/verify.ps1
```

- 对照 baseline 逐项核查：旧标识符零命中、MachineGuid 已是新值、进程/管道为零、Desktop 指纹文件未重生、出口 IP 已变化。
- `[PASS]` → 打印登录 checklist 放行；`[FAIL]` → 列出残留项，**明确告诉用户现在不能登录**。

### 登录 checklist(verify PASS 后逐条向用户确认)

1. 电脑已重启(MachineGuid 新值对所有消费方生效)
2. 代理已切到准备长期使用的新住宅 IP，`curl ip-api.com` 确认 ASN 不是常见机房段
3. 用没碰过 claude.ai 的浏览器或无痕窗口完成 OAuth —— 不用带旧 cookie 的 profile
4. 登录后同一账号同时只开一个 CLI 会话(并发上报是实测存在的遥测项)

## 绝对保护清单(任何阶段不得删除)

- `~/.claude/skills/`、`~/.claude/agents/`、`~/.claude/plugins/`、`~/.claude/commands/`
- `~/.claude/projects/**/memory/`(项目记忆)
- `~/.claude/settings.json`、`~/.claude/CLAUDE.md`、用户自配的 MCP 配置主体
- 浏览器里非 claude/anthropic 域的一切：cookie、登录、自动填充、密码库
- `~/.claude/backups/`(清理备份，用户自行决定何时删)
- 其他 AI 产品目录(`~/.codex`、`%APPDATA%\Code` 等)——除非用户单独要求

## 参考文档

- `references/checklist.md` —— 全量检查项 + 每项的证据等级 + 清理/保护判定理由。写报告和 review 清理项时对照它。
- `references/risk-model.md` —— 客户端上报了什么、服务端能看到什么的分层模型，以及诚实边界(哪些是实证哪些是推断)。
