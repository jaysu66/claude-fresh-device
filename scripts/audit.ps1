# ============================================================
# audit.ps1 — Stage 1 只读风险评估(claude-fresh-device)
#
# 零副作用:不写注册表、不改文件、不杀进程。
# 输出:控制台风险报告(默认脱敏)+ %USERPROFILE%\.fresh-device\baseline-<ts>.json
#        基线文件含本轮发现的真实标识符,供 Stage 3 verify.ps1 对照;只存本机。
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File audit.ps1          # 脱敏输出
#   powershell -ExecutionPolicy Bypass -File audit.ps1 -Full    # 显示完整标识(仅本机看)
# 每个检查项的编号对应 references/checklist.md 的依据条目。
# ============================================================
param([switch]$Full)

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$stateDir = Join-Path $env:USERPROFILE '.fresh-device'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$report = @()
function Report($m) { $script:report += $m; Write-Output $m }
function Mask($v) {
    if ($null -eq $v -or $v -eq '') { return '(空)' }
    if ($Full) { return $v }
    $s = [string]$v
    if ($s.Length -le 8) { return $s.Substring(0,2) + '***' }
    return $s.Substring(0,8) + '…(' + $s.Length + '位)'
}
function Sha256Hex($s) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
}

# 基线收集容器 —— 所有发现的标识符都进这里
$ids = [ordered]@{ machineGuid=$null; deviceId=$null; claudeJsonUserId=$null; claudeJsonMachineId=$null
    oauthEmail=$null; antDid=$null; lastKnownAccountUuid=$null; deviceIdSalt=$null
    accountUuids=@(); orgUuids=@(); exitIp=$null; auditedAt=(Get-Date -Format 'o') }
$strong = 0   # 强关联项计数
$soft   = @() # 软信号/提示

Report "==== claude-fresh-device · Stage 1 风险评估 @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===="
Report "(输出已脱敏;加 -Full 显示完整值。依据编号见 references/checklist.md)"
Report ""

# ---------- A1. 进程与命名管道 ----------
Report "## A. 运行态"
$procs = Get-Process | Where-Object { $_.ProcessName -match '^claude' }
$nativeHost = Get-Process -Name 'chrome-native-host' -ErrorAction SilentlyContinue
if ($procs) {
    Report "  [A1][实证] Claude 进程存活: $($procs.ProcessName -join ', ') —— 任何清理都会被写回,先全退"
    $script:blocked = $true
} elseif ($nativeHost) {
    Report "  [A1] claude.exe 无;chrome-native-host 存活(浏览器扩展拉起,见 B1)"
    $soft += 'chrome-native-host 在跑:登录用的浏览器 profile 里装着 Claude 扩展'
} else { Report "  [A1] 无 Claude 进程" }
$pipes = Get-ChildItem '\\.\pipe\' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'claude|anthropic' }
if ($pipes) { Report "  [A2][实测] 命名管道残留 $($pipes.Count) 条(如 $(Mask $pipes[0].Name))" } else { Report "  [A2] 无 Claude 命名管道" }

# ---------- C1. MachineGuid → device_id ----------
Report ""
Report "## C. Claude Code 身份层"
try {
    $mg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
    $ids.machineGuid = $mg
    $ids.deviceId = Sha256Hex $mg
    Report "  [C1][实证] MachineGuid=$(Mask $mg) → device_id=SHA256=$(Mask $ids.deviceId)"
    Report "       Claude Code 上报的设备主标识由它派生;不换它 = 换号不换设备"
} catch { Report "  [C1] MachineGuid 读取失败" }

# ---------- C2. ~/.claude.json ----------
$cj = Join-Path $env:USERPROFILE '.claude.json'
if (Test-Path $cj) {
    try { $j = Get-Content $cj -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $j = $null }
    if ($j) {
        $ids.claudeJsonUserId = $j.userID; $ids.claudeJsonMachineId = $j.machineID
        $hasOauth = $null -ne $j.oauthAccount
        if ($hasOauth) { $ids.oauthEmail = $j.oauthAccount.emailAddress }
        Report "  [C2][实证] ~/.claude.json 存在: userID=$(Mask $j.userID) machineID=$(Mask $j.machineID) oauthAccount=$(if($hasOauth){Mask $ids.oauthEmail}else{'无'})"
        $strong++
        $cacheKeys = @($j.PSObject.Properties.Name | Where-Object { $_ -match 'Cache|cached' })
        if ($cacheKeys.Count -gt 0) { Report "       账号状态缓存键 $($cacheKeys.Count) 个(可能藏历史 org uuid): $($cacheKeys[0..2] -join ', ')…" }
    }
} else { Report "  [C2] ~/.claude.json 不存在(未用过 CLI)" }

# ---------- C3-C4. ~/.claude 目录 ----------
$dotClaude = Join-Path $env:USERPROFILE '.claude'
if (Test-Path $dotClaude) {
    $cred = Join-Path $dotClaude '.credentials.json'
    if (Test-Path $cred) {
        $c = Get-Content $cred -Raw -Encoding UTF8
        if ($c -match 'claudeAiOauth') { Report "  [C3][实证] .credentials.json 含 claudeAiOauth 令牌"; $strong++ }
        else { Report "  [C3] .credentials.json 无 OAuth 令牌(走的第三方 API)" }
    }
    $runtimeDirs = @('telemetry','sessions','jobs','session-env','debug','daemon','file-history') |
        Where-Object { Test-Path (Join-Path $dotClaude $_) }
    if ($runtimeDirs) { Report "  [C4][实测] ~/.claude 运行时目录存活: $($runtimeDirs -join ', ')"; $strong++ }
    $jobsDir = Join-Path $dotClaude 'jobs'
    if (Test-Path $jobsDir) {
        $uuidDirs = Get-ChildItem $jobsDir -Directory | Where-Object { $_.Name -match '[0-9a-f]{8}-[0-9a-f]{4}-' }
        foreach ($d in $uuidDirs) { $ids.accountUuids += $d.Name }
    }
    # 遥测继承变量
    $settings = Join-Path $dotClaude 'settings.json'
    if (Test-Path $settings) {
        $s = Get-Content $settings -Raw -Encoding UTF8
        if ($s -match 'DISABLE_NONESSENTIAL_TRAFFIC|DISABLE_TELEMETRY') { Report "  [C4] settings.json 已设遥测关闭变量 ✓" }
        else { $soft += 'settings.json 未设 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC(可选加固)' }
    }
} else { Report "  [C3/C4] ~/.claude 不存在(未用过 CLI)" }

# ---------- D. Claude Desktop ----------
Report ""
Report "## D. Claude Desktop 身份层"
$ap = Join-Path $env:APPDATA 'Claude'
if (Test-Path $ap) {
    $ant = Join-Path $ap 'ant-did'
    if (Test-Path $ant) {
        $ids.antDid = (Get-Content $ant -Raw).Trim()
        Report "  [D1][实测] ant-did=$(Mask $ids.antDid) —— Desktop 设备 ID,不删则重启重生同值"
        $strong++
    }
    if (Test-Path (Join-Path $ap 'ant-device-registry.json')) { Report "  [D1] ant-device-registry.json 存在"; $strong++ }

    $cfg = Join-Path $ap 'config.json'
    if (Test-Path $cfg) {
        $ct = Get-Content $cfg -Raw -Encoding UTF8
        $hitKeys = @()
        foreach ($k in @('lastKnownAccountUuid','oauth:','dxt:allowlist')) { if ($ct -match [regex]::Escape($k)) { $hitKeys += $k } }
        if ($ct -match '"lastKnownAccountUuid"\s*:\s*"([0-9a-f-]{36})"') { $ids.lastKnownAccountUuid = $Matches[1] }
        if ($hitKeys) { Report "  [D2][实测] config.json 含登录态键: $($hitKeys -join ', ')"; $strong++ }
    }
    $dsk = Join-Path $ap 'claude_desktop_config.json'
    if (Test-Path $dsk) {
        $dt = Get-Content $dsk -Raw -Encoding UTF8
        $uuidHits = [regex]::Matches($dt, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') | ForEach-Object { $_.Value } | Sort-Object -Unique
        if ($uuidHits) { $ids.accountUuids += $uuidHits; Report "  [D3][实测] claude_desktop_config.json 内嵌 $($uuidHits.Count) 个 UUID(账号/组织维度映射)"; $strong++ }
    }
    $pref = Join-Path $ap 'Preferences'
    if (Test-Path $pref) {
        $pt = Get-Content $pref -Raw -Encoding UTF8
        if ($pt -match '"device_id_salt"\s*:\s*"([0-9A-Fa-f]+)"') {
            $ids.deviceIdSalt = $Matches[1]
            Report "  [D4][实测] Preferences device_id_salt=$(Mask $ids.deviceIdSalt)"; $strong++
        }
    }
    $ck = Join-Path $ap 'Network\Cookies'
    if (Test-Path $ck) {
        Report "  [D5][实证] Chromium Cookies 库存在($([math]::Round((Get-Item $ck).Length/1KB))KB)—— anthropic-device-id / __stripe_mid / intercom 指纹罐"
        $strong++
    }
    $sessDirs = @('claude-code-sessions','local-agent-mode-sessions') | ForEach-Object { Join-Path $ap $_ } | Where-Object { Test-Path $_ }
    foreach ($sd in $sessDirs) {
        $uuids = Get-ChildItem $sd -Directory | Where-Object { $_.Name -match '^[0-9a-f]{8}-' } | ForEach-Object { $_.Name }
        if ($uuids) { $ids.accountUuids += $uuids; Report "  [D6][实测] $(Split-Path $sd -Leaf) 下有 $($uuids.Count) 个账号 UUID 目录"; $strong++ }
    }
    $electronDirs = @('Local Storage','IndexedDB','Session Storage','Partitions','sentry','logs','Cache') |
        Where-Object { Test-Path (Join-Path $ap $_) }
    if ($electronDirs) { Report "  [D7][实测] Chromium 存储面存活: $($electronDirs -join ', ')"; $strong++ }
} else { Report "  %APPDATA%\Claude 不存在(未装/未用过 Desktop)" }

if (Test-Path (Join-Path $env:APPDATA 'Claude Code\ChromeNativeHost')) {
    Report "  [D8][实测] %APPDATA%\Claude Code\ChromeNativeHost 存在 —— CLI↔浏览器扩展配对通道注册过"
    $soft += 'native messaging host 已注册(重启后 chrome-native-host 会自动拉起)'
}

# ---------- L. LOCALAPPDATA ----------
$lLogs = Join-Path $env:LOCALAPPDATA 'Claude\Logs'
if (Test-Path $lLogs) { Report "  [L1][实测] %LOCALAPPDATA%\Claude\Logs 存在(日志含历史账号 email/uuid)"; $strong++ }
$cliCache = Join-Path $env:LOCALAPPDATA 'claude-cli-nodejs\Cache'
if (Test-Path $cliCache) {
    $uuidInName = Get-ChildItem $cliCache -Directory -Recurse -Depth 2 | Where-Object { $_.Name -match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-' } | ForEach-Object { $_.Name }
    if ($uuidInName) { $ids.accountUuids += $uuidInName }
    Report "  [L2][实测] claude-cli-nodejs\Cache 存在(目录名内嵌账号/组织 UUID)"
    $strong++
}

# ---------- B. 浏览器面 ----------
Report ""
Report "## B. 浏览器面"
$anthropicHosts = @('HKCU:\SOFTWARE\Google\Chrome\NativeMessagingHosts','HKCU:\SOFTWARE\Microsoft\Edge\NativeMessagingHosts')
$hostHits = @()
foreach ($rk in $anthropicHosts) {
    if (Test-Path $rk) {
        $hostHits += Get-ChildItem $rk | Where-Object { $_.PSChildName -match 'anthropic|claude' } | ForEach-Object { $_.PSChildName }
    }
}
$hostHits = @($hostHits | Sort-Object -Unique)
if ($hostHits) { Report "  [B1][实测] 注册的 Claude native messaging host: $($hostHits -join ', ')"; $soft += '存在 Claude 浏览器扩展配对(对应 chrome-native-host)' }

$claudeExtIds = @('fcoeoabgfenejglbffodgkkbkcdhcgfn','dihbgbndebgnbjfmelmegjepbnkhlgni','dngcpimnedloihjnnfngkgjoidhnaolf')
foreach ($br in @(@('Chrome', "$env:LOCALAPPDATA\Google\Chrome\User Data"), @('Edge', "$env:LOCALAPPDATA\Microsoft\Edge\User Data"))) {
    $root = $br[1]
    if (-not (Test-Path $root)) { continue }
    $profiles = Get-ChildItem $root -Directory | Where-Object { $_.Name -match '^(Default|Profile \d+|Guest Profile)$' }
    foreach ($p in $profiles) {
        $pn = "$($br[0])\$($p.Name)"
        $ckp = Join-Path $p.FullName 'Network\Cookies'
        if (Test-Path $ckp) {
            $locked = $false
            try { $fs = [System.IO.File]::Open($ckp,'Open','Read','None'); $fs.Close() } catch { $locked = $true }
            Report "  [B2] $pn Cookies 库存在($([math]::Round((Get-Item $ckp).Length/1KB))KB)$(if($locked){' [被浏览器锁定,运行 scan-sqlite.cjs 需先关浏览器]'})"
        }
        foreach ($eid in $claudeExtIds) {
            if (Test-Path (Join-Path $p.FullName "Extensions\$eid")) {
                Report "  [B3][实测] $pn 装了 Claude 扩展 $eid"
                $soft += "$pn 装过 Claude 扩展;登录用的 profile 里若还在,扩展本地存储可能存配对设备 ID"
            }
        }
    }
}

# ---------- N. 网络面 ----------
Report ""
Report "## N. 网络面"
try {
    $ip = Invoke-RestMethod -Uri 'http://ip-api.com/json/?fields=status,query,country,regionName,city,isp,org,as,hosting,proxy' -TimeoutSec 8
    $ids.exitIp = $ip.query
    $flag = if ($ip.hosting) { '[推断] ASN 标注为机房/hosting' } else { '住宅/ISP 外观' }
    Report "  [N1] 出口 IP: $(Mask $ids.exitIp) | $($ip.isp) | $($ip.city), $($ip.country) | $flag"
    if ($ip.proxy) { Report "       ip-api 标注 proxy=true" }
} catch { Report "  [N1] 出口 IP 查询失败(检查代理/网络)" }
$tz = (Get-TimeZone).Id; $cul = (Get-Culture).Name
Report "  [N2][推断] 时区=$tz / 语言=$cul —— 与 IP 地理不一致是风控软信号(改时区没用,反而更独特)"
$ro = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).RegisteredOwner
Report "  [N3] 主机名=$env:COMPUTERNAME / RegisteredOwner=$(Mask $ro)"
$soft += '主机名与 RegisteredOwner 会进 trusted_devices 上报与系统指纹(可选改)'

# ---------- E. 环境变量 ----------
$anthEnv = Get-ChildItem env: | Where-Object { $_.Name -match 'ANTHROPIC|CLAUDE' }
if ($anthEnv) { Report "  [E1] Claude 相关环境变量: $($anthEnv.Name -join ', ')" }
else { Report "  [E1] 无 ANTHROPIC_*/CLAUDE_* 环境变量(中转 CC Switch 切换无残留)" }

# ---------- 判定 ----------
Report ""
Report "==== 结论 ===="
if ($blocked) {
    Report "[BLOCKED] Claude 进程在跑 —— 先全部退出再重跑 audit,否则清理必被写回"
} elseif ($strong -gt 0) {
    Report "[NEEDS_CLEANUP] 强关联项 $strong 个 —— 这台机器上过的 Claude 身份还活着,登新号=撞库"
    Report "  下一步:运行 clean.ps1(建议含 MachineGuid 轮换),然后 verify.ps1 过门禁再登录"
} else {
    Report "[READY] 未发现强关联残留 —— 本机对 Claude 是新设备。确认 IP 是干净住宅段后可登录"
}
if ($soft.Count) { Report ""; Report "软信号(不阻塞,可选处理):"; $soft | ForEach-Object { Report "  - $_" } }
Report ""
Report "可选深挖:有 node 时跑 node scripts/scan-sqlite.cjs 看 SQLite/LevelDB 里的明文标识"

# ---------- 基线落盘(只存本机) ----------
$ids.accountUuids = @($ids.accountUuids | Sort-Object -Unique)
$ids.orgUuids = @($ids.orgUuids | Sort-Object -Unique)
$ids.strongCount = $strong
$ids.posture = if ($strong -gt 0) { 'dirty' } else { 'clean' }
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$bf = Join-Path $stateDir "baseline-$ts.json"
$ids | ConvertTo-Json -Depth 4 | Set-Content $bf -Encoding UTF8
$ids | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $stateDir 'baseline.json') -Encoding UTF8
Report ""
Report "基线已写入 $bf(供 verify.ps1 对照;含真实标识符,勿提交勿外发)"
