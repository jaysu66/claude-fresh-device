# claude-fresh-device

Windows 上给 Claude 换号前做本机卫生的小工具:**只读门禁 → 预览清理 → 执行 → 复查 → 出口检查**。一个脚本 `fresh.ps1`,没有额外依赖(PowerShell 5.1+)。

> 它只处理"本机残留的旧身份",降低新号被关联回旧设备的概率。不承诺绕过服务端风控,账号来源、支付、使用行为不在它的范围。详见 `references/risk-model.md`。

## 用法

```powershell
powershell -ExecutionPolicy Bypass -File fresh.ps1 check            # 只读,FAIL 就别登录
powershell -ExecutionPolicy Bypass -File fresh.ps1 clean            # 预览,不改任何文件
powershell -ExecutionPolicy Bypass -File fresh.ps1 clean -Apply     # 备份后清理(加 -RotateGuid 需管理员)
# 重启,再 check,PASS 后:
powershell -ExecutionPolicy Bypass -File fresh.ps1 net -Anchor      # 锚定长期出口
powershell -ExecutionPolicy Bypass -File fresh.ps1 net              # 每次开 Claude 前跑,GO 才用
```

清理前先退出 claude.exe、Claude Desktop 和所有 claude.ai 标签页。

## 原则

- **有依据才清**:每项标注证据等级 `[E]`客户端实证 `[T]`真机实测 `[I]`推断 `[C]`常识(`references/checklist.md`)
- **能保留就保留**:skills、agents、plugins、项目 memory、settings、浏览器其他站登录一律不动
- **默认不动手**:clean 是 dry run,`-Apply` 才执行,执行前全量备份到 `~/.fresh-device/backups/`
- **不输出隐私**:报告只有计数和文件名,不打印邮箱/UUID/设备 ID;状态文件只存本机
- **不自动删记忆**:memory 里若有邮箱或封号字样只提示人工审阅

## 测试

`test/run-tests.ps1` 用假 profile(`-SandboxHome`)跑完整流程,不碰真实注册表、进程、网络:

```powershell
docker run --rm --network none -v "${PWD}:/repo:ro" mcr.microsoft.com/powershell:7.4-ubuntu-22.04 pwsh -NoProfile -File /repo/test/run-tests.ps1
```

沙盒覆盖文件/JSON 清理与保护清单。注册表、凭据管理器、进程、网络分支只能在真实 Windows 上运行,其中 `check`/`net` 只读。

## 文件

```
fresh.ps1                 check / clean / net
SKILL.md                  给 AI agent 的入口(可拷到 ~/.claude/skills/claude-fresh-device/)
references/checklist.md   检查项 + 证据等级 + 保留理由
references/risk-model.md  谁看到什么 + 诚实边界
references/ip-hygiene.md  节点/IP 使用纪律
test/run-tests.ps1        沙盒测试
```

## 致谢

海外环境(时区、IP、代理、手机号、支付)的整体思路来自 [@gkxspace(余温)的教程](https://x.com/gkxspace/status/2101993381303820704)。本项目补充的是 Windows 上的本机指纹检查与清理。

## License

MIT
