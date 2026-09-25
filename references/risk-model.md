# 风险模型：谁看到什么

## 三层视图

### 1. 客户端主动上报（实证，来自 Claude Code 二进制/sourcemap 分析）

- `device_id = SHA256(MachineGuid)` —— node-machine-id 读 `HKLM\...\Cryptography\MachineGuid`,SHA256 后作为设备主标识进遥测与 API 请求
- 遥测 env 块：platform、arch、node_version、terminal、version、build_time、vcs、runtimes 等 —— 同机同值
- `tengu_concurrent_sessions` —— 并发会话数 ≥2 即上报（一号多登的量化信号）
- `enrollTrustedDevice` → POST `/api/auth/trusted_devices`，带 `Claude Code on <hostname> · win32`（仅当 org 开了对应 policy 才发）
- OAuth 登录走浏览器 → 浏览器指纹（时区/语言/WebGL/分辨率）+ claude.ai 域 cookie 全程暴露

### 2. 服务端被动可见（链路自带）

- 出口 IP + IP 情报标注（住宅/机房/proxy）—— 风控看的是 Anthropic 用的情报库，不是 ip-api 的口径
- Stripe `__stripe_mid` —— 跨站设备指纹，支付层关联通道（有支付行为时才进入链路）
- 账号侧历史：注册邮箱、登录过的设备集合、并发模式 —— 本机清不掉

### 3. 本机留痕（服务端看不到，但证明链路）

- `%APPDATA%\Claude` 全套 ant-did / tokenCache / 账号 UUID 目录 / LevelDB orgUuid
- 浏览器 cookie 罐 / 历史 / magic-link URL
- 作用：决定了"新号在本机落地时会不会被旧身份接住"。清的就是这层。

## 关联成立的最小链

```
新号登录请求 ── device_id(SHA256 MachineGuid)──┐
             ── 出口 IP ───────────────────────┤──> 任一撞旧号记录 = 关联
             ── claude.ai 域 cookie/存储 ──────┘
```

三条都换新，本机侧关联链就断。本 skill 的 Stage 1-3 就是在逐项确认这三条 + 所有留痕点。

## 诚实边界（对用户必须说的）

1. **服务端风控规则不可见** —— 客户端二进制里没有封号判定逻辑，所有"封"的机制都是服务端实现。我们把客户端能看到、能改的面全部清到，但服务端还可能有时序/行为建模。
2. **清理 ≠ 保证不封** —— 它把"本机侧撞库"的概率降到接近零；账号来源（成品号找回/一号多卖/chargeback）、IP 情报库定性、行为指纹都不在本机控制内。
3. **不改的不要伪装** —— 浏览器硬件指纹改不了也不该改：真实用户带一致指纹，刻意伪装（改时区/UA 混淆）反而是更强的异常信号。
4. **报告里的 [推断] 不是实锤** —— IP×时区一致性、并发阈值等是经验推断，用证据等级标签区分，不要把推断当事实陈述给用户。
