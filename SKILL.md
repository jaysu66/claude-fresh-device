---
name: claude-fresh-device
description: This skill should be used when the user wants to audit, clean, and verify a Windows machine before logging a new Claude account into it, e.g. "清理 Claude 指纹", "设备指纹", "这台电脑能不能登新号", "Claude 封号后换号", "换号防关联", "clean Claude fingerprints", "fresh device for Claude", "check my machine before Claude login", "检查代理/IP 出口". It runs one script (fresh.ps1) with three modes, check, clean, net, where check is a read-only login gate that must PASS before the user logs in. Windows only.
---

# claude-fresh-device

Windows 上 Claude 换号前的本机卫生流程:**check(只读门禁) → clean(先预览、再执行) → check → net(出口检查)**。全部在 `fresh.ps1` 一个脚本里。

**边界**:只处理本机侧的旧身份残留,降低新号被关联到旧号/旧设备的概率。不承诺绕过服务端风控;账号来源、支付、使用行为不在本机控制内。对用户保持这个口径,`[I]` 推断项不当事实陈述。

## 安全规则(先读)

1. **先 check,再 clean 预览,用户确认后才 `-Apply`。** clean 默认是 dry run,不改任何文件。
2. **不要在用户的真实机器上做实验。** 改动脚本后先跑 `test/run-tests.ps1`(用假 profile,需要 PowerShell 7,推荐放进 Docker/`-SandboxHome`),通过后才交给用户。
3. clean 前要求所有 Claude 进程、Desktop、claude.ai 标签页已退出,否则清理会被写回。
4. 脚本输出只含计数和文件名,不打印任何 ID/邮箱;备份目录 `~/.fresh-device/backups/` 含旧标识,只留本机,不上传。
5. 保护清单永不触碰:`~/.claude/{skills,agents,plugins,commands}`、`projects/**/memory`、`settings.json`、`CLAUDE.md`、浏览器其他站数据、其他 AI 产品目录。
6. 不要在处理封号的项目目录里给新号开 Claude(项目 `CLAUDE.md` 会进新号上下文)。

## 流程

```powershell
# 1. 只读门禁。FAIL 就别登录
powershell -ExecutionPolicy Bypass -File fresh.ps1 check

# 2. 预览要清什么(不改动),给用户确认
powershell -ExecutionPolicy Bypass -File fresh.ps1 clean
# 3. 确认后执行;被封过的机器加 -RotateGuid(需管理员 PowerShell),然后重启
powershell -ExecutionPolicy Bypass -File fresh.ps1 clean -Apply [-RotateGuid]

# 4. 重启后再 check,PASS 才继续
# 5. 选定长期使用的住宅节点后锚定;此后每次开 Claude 前先跑一次
powershell -ExecutionPolicy Bypass -File fresh.ps1 net -Anchor
powershell -ExecutionPolicy Bypass -File fresh.ps1 net
```

登录新号后如需复查,用 `check -PostLogin`(登录态不再算残留)。

## check 覆盖什么

| 层 | 内容 | 判定 |
|---|---|---|
| 进程 | claude*/chrome-native-host | BLOCK |
| CLI | `.claude.json` 账号缓存、`.credentials.json` 令牌、`~/.claude` 遥测/运行时目录 | DIRTY |
| Desktop | `ant-did`、账号 UUID 目录、Chromium 存储、`device_id_salt`、登录态键 | DIRTY |
| 凭据 | 凭据管理器 claude/anthropic 条目 | DIRTY |
| 记忆 | memory/CLAUDE.md 里的邮箱、封号/指纹字样 | WARN(只报告,人工审) |
| 浏览器 | Claude 扩展、native host 注册 | WARN |
| 网络 | 系统代理、代理环境变量、npm/git proxy、TUN 适配器、ANTHROPIC_* 变量 | WARN |

BLOCK/DIRTY 任意一项 → `GATE: FAIL`。每项的证据等级见 `references/checklist.md`。

## net 模式

- `net -Anchor`:记录当前出口为账号专用出口(只存本机)。
- `net`:比对锚定出口;`hosting=true` 或出口漂移 → NO-GO。
- 使用纪律见 `references/ip-hygiene.md`:关代理前先关干净 claude.exe / Desktop / claude.ai 标签页;断线时 Claude 不应走直连。

## 浏览器

不自动清浏览器库。首选没碰过 claude.ai 的浏览器或无痕窗口走 OAuth;要定点清就在 `chrome://settings/siteData` 手动删 `claude`、`anthropic` 域。

## 参考

- `references/checklist.md`:每个检查/清理项的证据等级与保留理由
- `references/risk-model.md`:客户端上报什么、服务端能看到什么、诚实边界
- `references/ip-hygiene.md`:节点/IP 纪律
- `test/run-tests.ps1`:沙盒测试(假 profile,不碰真实系统)
