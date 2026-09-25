# claude-fresh-device

Windows 上 Claude 换号前的三阶段流水线：**只读风险评估 → 有依据的清理 → 复查门禁**。门禁 PASS 之前不登录新号。

> 定位说明：这是本机指纹卫生工具，降低新号被关联回旧设备的概率。它不承诺绕过服务端风控 —— 账号来源、支付链、行为建模不在本机控制范围。详见 `references/risk-model.md`。

## 用法

```powershell
# 1. 风险评估(只读,零副作用,输出脱敏报告)
powershell -ExecutionPolicy Bypass -File scripts/audit.ps1

# 2. 清理(看过报告、确认后执行;含 MachineGuid 轮换需管理员)
powershell -ExecutionPolicy Bypass -File scripts/clean.ps1

# 3. 重启电脑 → 复查门禁
powershell -ExecutionPolicy Bypass -File scripts/verify.ps1
```

verify 输出 `[GATE: PASS]` + 登录 checklist 后才允许登录新号。

## 原则

- **有依据才清**：每个检查/清理项在 `references/checklist.md` 登记证据等级（实证/实测/推断/常识），没有依据的项不进清单
- **能保留就保留**：对话历史、项目记忆、技能、浏览器其他站登录态默认不动（浏览器部分首选"换个没碰过 claude.ai 的浏览器/无痕窗口"而不是清库）
- **脱敏**：audit 输出默认只显示标识符前 8 位；基线文件只存本机 `%USERPROFILE%\.fresh-device\`，已入 .gitignore
- **有退路**：clean 前全量备份到 `~/.claude/backups/`

## 文件

```
SKILL.md                      agent 入口(也可拷到 ~/.claude/skills/claude-fresh-device/ 自动触发)
scripts/audit.ps1             Stage 1 只读评估 + 基线生成
scripts/clean.ps1             Stage 2 清理(v3 实战胜出版)
scripts/verify.ps1            Stage 3 复查门禁
scripts/scan-sqlite.cjs       可选深挖:SQLite/LevelDB 明文标识(需 node;输出含敏感值,仅本机看)
scripts/clean-projects-keep-memory.cjs   -WipeHistory 时保留 memory 清会话
references/checklist.md       全量检查项 + 证据等级 + 清/留判定理由
references/risk-model.md      上报面/可见面/留痕面分层 + 诚实边界
```

## 系统要求

Windows + PowerShell 5.1+。node 可选（没有也能跑：JSON 修改退化到 PS 兜底/整文件重建）。
