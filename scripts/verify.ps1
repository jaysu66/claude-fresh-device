# ============================================================
# verify.ps1 — Stage 3 复查门禁(claude-fresh-device)
#
# 只读。对照 %USERPROFILE%\.fresh-device\ 下的基线/清理记录逐项核查:
#   baseline.json     audit.ps1 生成,记录审计时的标识与 posture(dirty/clean)
#   post-clean.json   clean.ps1 生成,记录清理动作(MachineGuid 是否轮换等)
#
# 全 PASS → 打印登录 checklist 放行;任何 FAIL → 阻断登录。
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File verify.ps1
#   powershell -ExecutionPolicy Bypass -File verify.ps1 -AcceptSameGuid   # 明示放弃轮换
# ============================================================
param([switch]$AcceptSameGuid)

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$fail = @(); $warn = @(); $pass = @()
function Sha256Hex($s) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
}
function Tail4($v) { if ($v -and $v.Length -gt 4) { '…' + $v.Substring($v.Length - 4) } else { '(空)' } }

Write-Output "==== claude-fresh-device · Stage 3 复查门禁 @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===="
Write-Output ""

# ---------- 状态文件 ----------
$stateDir = Join-Path $env:USERPROFILE '.fresh-device'
$bf = Join-Path $stateDir 'baseline.json'
if (-not (Test-Path $bf)) { Write-Output "[FAIL] 无 baseline.json —— 先跑 audit.ps1"; exit 1 }
$b = Get-Content $bf -Raw -Encoding UTF8 | ConvertFrom-Json
$dirty = ($b.posture -eq 'dirty') -or ($b.strongCount -gt 0)
$knownIds = @($b.machineGuid,$b.deviceId,$b.claudeJsonUserId,$b.claudeJsonMachineId,
              $b.oauthEmail,$b.antDid,$b.lastKnownAccountUuid,$b.deviceIdSalt) +
            @($b.accountUuids) + @($b.orgUuids) | Where-Object { $_ } | Sort-Object -Unique
$pcFile = Join-Path $stateDir 'post-clean.json'
$pc = $null
if (Test-Path $pcFile) { $pc = Get-Content $pcFile -Raw -Encoding UTF8 | ConvertFrom-Json }
# 关键语义:基线若在清理之后才生成,它记录的就是"新身份"——当前值与基线一致是正确状态,不是残留
$baselineIsPostClean = $pc -and ([datetime]$b.auditedAt -gt [datetime]$pc.cleanedAt)
Write-Output "基线: $($b.auditedAt) · posture=$($b.posture) · 标识 $($knownIds.Count) 个$(if($baselineIsPostClean){' · 清理后基线'})"
if ($pc) { Write-Output "清理记录: $($pc.cleanedAt) · MachineGuid轮换=$($pc.machineGuidRotated)" }

# ---------- 1. 进程/管道 ----------
$procs = Get-Process | Where-Object { $_.ProcessName -match '^claude' }
if ($procs) { $fail += "claude.exe 在跑(PID $($procs.Id -join ',')) —— 登录前退出" }
else { $pass += '无 Claude 进程' }
$native = Get-Process -Name 'chrome-native-host'
if ($native) { $warn += 'chrome-native-host 在跑(浏览器扩展唤起,登录前确认用的 profile 不带 Claude 扩展)' }
$pipes = Get-ChildItem '\\.\pipe\' | Where-Object { $_.Name -match 'claude|anthropic' }
if ($pipes) { $warn += "命名管道残留 $($pipes.Count) 条(MCP 桥/扩展通道)" }

# ---------- 2. MachineGuid / device_id ----------
$mg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
$did = Sha256Hex $mg
if ($pc) {
    if ($baselineIsPostClean) {
        if ($mg -eq $b.machineGuid) { $pass += "MachineGuid 与清理后基线一致,device_id=$(Tail4 $did)" }
        else { $pass += "MachineGuid 清理后又变更过,device_id=$(Tail4 $did)" }
    } elseif ($pc.machineGuidRotated) {
        if ($mg -ne $b.machineGuid) { $pass += "MachineGuid 已轮换为全新值,device_id=$(Tail4 $did)" }
        else { $fail += '清理记录称已轮换但注册表仍是基线值 —— 可能被还原,重改并重启' }
    } else {
        if ($dirty -and -not $AcceptSameGuid) { $fail += "基线含旧身份但 MachineGuid 未轮换 —— device_id $(Tail4 $did) 服务端已记录(-AcceptSameGuid 明示豁免)" }
        elseif ($dirty) { $warn += "MachineGuid 未轮换(明示接受):device_id 维持旧值" }
        else { $pass += 'MachineGuid 未变(基线即干净,无需轮换)' }
    }
} else {
    if ($dirty) { $fail += '基线有旧身份残留且没有清理记录 —— 先跑 clean.ps1' }
    else { $pass += '无清理记录但基线本就干净' }
}

# ---------- 3. ~/.claude.json / credentials ----------
$cj = Join-Path $env:USERPROFILE '.claude.json'
if (Test-Path $cj) {
    $t = Get-Content $cj -Raw -Encoding UTF8
    $hits = @($knownIds | Where-Object { $_ -and $t.Contains($_) })
    if ($hits -and $dirty -and -not $baselineIsPostClean) { $fail += ".claude.json 仍含基线旧标识 $($hits.Count) 个" }
    elseif ($t -match '"oauthAccount"') { $warn += '.claude.json 已有 oauthAccount —— 确认登的是新号' }
    else { $pass += '.claude.json 无旧标识' }
}
$cred = Join-Path $env:USERPROFILE '.claude\.credentials.json'
if (Test-Path $cred) {
    if ((Get-Content $cred -Raw -Encoding UTF8) -match 'claudeAiOauth') { $warn += '.credentials.json 含 OAuth 令牌 —— 确认属新号' }
    else { $pass += '.credentials.json 无旧令牌' }
}

# ---------- 4. Desktop 目录树 ----------
$ap = Join-Path $env:APPDATA 'Claude'
if (Test-Path $ap) {
    $ant = Join-Path $ap 'ant-did'
    if (Test-Path $ant) {
        $cur = (Get-Content $ant -Raw).Trim()
        if ($b.antDid -and $cur -eq $b.antDid) { $fail += 'ant-did 重生为同一值 → 硬件派生 ID,别再启动 Desktop' }
        else { $warn += "ant-did 重生为新随机值 $(Tail4 $cur)(可接受)" }
    } else { $pass += 'ant-did 不存在' }
    $treeHits = @()
    Get-ChildItem $ap -Recurse -Force | ForEach-Object {
        $n = $_.Name
        if (($knownIds | Where-Object { $_ -and $n -like "*$_*" }).Count -gt 0) { $treeHits += $_.FullName }
    }
    if ($treeHits) { $fail += "Desktop 目录名残留基线 UUID: $($treeHits[0])" }
    else { $pass += 'Desktop 目录树零残留' }
    $cfg = Join-Path $ap 'config.json'
    if (Test-Path $cfg) {
        $ct = Get-Content $cfg -Raw -Encoding UTF8
        if ($ct -match 'lastKnownAccountUuid|oauth:tokenCache') { $fail += 'Desktop config.json 仍含登录态键' }
    }
    foreach ($d in @('Local Storage','IndexedDB','Session Storage','Partitions','sentry')) {
        $dd = Join-Path $ap $d
        if ((Test-Path $dd) -and (Get-ChildItem $dd -Recurse -File | Select-Object -First 1)) {
            $warn += "Desktop $d 重生且有内容(Desktop 被打开过,需重跑 clean)"
        }
    }
}

# ---------- 5. LOCALAPPDATA ----------
if (Test-Path (Join-Path $env:LOCALAPPDATA 'Claude\Logs')) { $warn += 'Desktop Logs 目录已重生(chrome-native-host 拉起所致,正常)' }
if (Test-Path (Join-Path $env:LOCALAPPDATA 'claude-cli-nodejs\Cache')) { $warn += 'claude-cli-nodejs\Cache 已重生' }

# ---------- 6. 重启检测 ----------
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$ref = if ($pc) { [datetime]$pc.cleanedAt } else { [datetime]$b.auditedAt }
if ($boot -lt $ref) { $warn += "上次重启($($boot.ToString('MM-dd HH:mm')))早于清理时间 —— MachineGuid 变更后必须重启" }
else { $pass += '清理/审计之后已重启过' }

# ---------- 7. 网络 ----------
try {
    $ip = Invoke-RestMethod -Uri 'http://ip-api.com/json/?fields=status,query,isp,as,hosting,proxy' -TimeoutSec 8
    if ($b.exitIp -and $ip.query -eq $b.exitIp) { $warn += "出口 IP 未变 —— 若旧号死在这个 IP/段上,必须换节点再登" }
    else { $pass += "出口 IP 与基线不同: $($ip.isp)" }
    if ($ip.hosting) { $warn += 'ASN 标注为机房/hosting —— 需要住宅出口的话换节点' }
} catch { $warn += 'IP 查询失败(代理未开?登录前务必确认出口)' }

# ---------- 8. 浏览器(软信号) ----------
$hostHits = @()
foreach ($rk in @('HKCU:\SOFTWARE\Google\Chrome\NativeMessagingHosts','HKCU:\SOFTWARE\Microsoft\Edge\NativeMessagingHosts')) {
    if (Test-Path $rk) { $hostHits += Get-ChildItem $rk | Where-Object { $_.PSChildName -match 'anthropic|claude' } | ForEach-Object { $_.PSChildName } }
}
if ($hostHits) { $warn += 'Claude native host 注册仍在 —— 无害;但登录用 profile 若装 Claude 扩展,扩展本地存储可能带旧配对设备 ID' }

# ---------- 门禁 ----------
Write-Output ""
foreach ($m in $pass) { Write-Output "  [PASS] $m" }
foreach ($m in $warn) { Write-Output "  [WARN] $m" }
foreach ($m in $fail) { Write-Output "  [FAIL] $m" }
Write-Output ""
if ($fail.Count -eq 0) {
    Write-Output "==== [GATE: PASS] 可以登录。登录 checklist: ===="
    Write-Output "  1. 已重启电脑(MachineGuid 新值全局生效)"
    Write-Output "  2. 代理已切到长期使用的干净住宅 IP —— 现在就到目标节点再登"
    Write-Output "  3. 用没碰过 claude.ai 的浏览器或无痕窗口走 OAuth"
    Write-Output "  4. 同账号同时只开一个 CLI 会话"
    exit 0
} else {
    Write-Output "==== [GATE: FAIL] $($fail.Count) 项未过 —— 现在登录会把新号关联回旧身份 ===="
    exit 1
}
