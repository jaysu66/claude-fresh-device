# ============================================================
# clean.ps1 — Stage 2 清理(claude-fresh-device)
#
# 每条清理动作都标注 references/checklist.md 里的依据编号([C2]/[D1]…),
# 没有依据的东西不清;保护清单见 SKILL.md「绝对保护清单」一节。
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File clean.ps1                      # 全清(含 MachineGuid,需管理员)
#   powershell -ExecutionPolicy Bypass -File clean.ps1 -SkipMachineGuid     # 不动注册表
#   powershell -ExecutionPolicy Bypass -File clean.ps1 -Stage desktop-only  # 只清 Desktop + LOCALAPPDATA
#   powershell -ExecutionPolicy Bypass -File clean.ps1 -WipeHistory         # 连会话历史一起删(默认保留)
#   powershell -ExecutionPolicy Bypass -File clean.ps1 -Force               # 跳过进程检测(危险)
#
# 前置:必须先跑 audit.ps1 生成基线(%USERPROFILE%\.fresh-device\baseline.json),
#        自检环节用它对照旧标识是否清零。
# 备份:所有被清理项先备份到 ~/.claude/backups/fingerprint-cleanup-<ts>/
# ============================================================
param([ValidateSet('all','desktop-only')][string]$Stage = 'all',
      [string]$NewMachineGuid = $null,
      [switch]$SkipMachineGuid,
      [switch]$WipeHistory,
      [switch]$Force)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak = Join-Path $env:USERPROFILE ".claude\backups\fingerprint-cleanup-$ts"
New-Item -ItemType Directory -Force -Path $bak | Out-Null
$log = @()
function Log($m) { $script:log += $m; Write-Output $m }
function Backup([string]$path) {
    if (Test-Path $path) {
        Copy-Item -Path $path -Destination (Join-Path $bak (Split-Path $path -Leaf)) -Recurse -Force -ErrorAction SilentlyContinue
        Log "  [bak] $path"
    }
}
function New-Hex($len) {
    $b = New-Object byte[] $len
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    ($b | ForEach-Object { $_.ToString('x2') }) -join ''
}

Log "==== claude-fresh-device · Stage 2 清理 @ $ts ===="
Log "备份目录: $bak"

# ---------- 0. 前置:基线 + 进程 ----------
$baselineFile = Join-Path $env:USERPROFILE '.fresh-device\baseline.json'
$knownIds = @()
if (Test-Path $baselineFile) {
    try {
        $b = Get-Content $baselineFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $knownIds = @($b.machineGuid, $b.deviceId, $b.claudeJsonUserId, $b.claudeJsonMachineId,
                      $b.oauthEmail, $b.antDid, $b.lastKnownAccountUuid, $b.deviceIdSalt) +
                    @($b.accountUuids) + @($b.orgUuids) | Where-Object { $_ } | Sort-Object -Unique
        Log "[ok] 已载入基线标识 $($knownIds.Count) 个"
    } catch { Log "[warn] 基线文件读取失败,自检将跳过" }
} else {
    Log "[warn] 未找到 baseline.json —— 建议先跑 audit.ps1;本次自检将无对照标识"
}

$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if ($nodeExe) { Log "[ok] node: $nodeExe(JSON 修改走 Node,最稳)" }
else { Log "[warn] 无 node —— JSON 修改退化到 PowerShell;若 .claude.json 解析失败将整文件备份后重建" }

if (-not $Force) {
    $alive = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^claude' }
    if ($alive) {
        Log "[中止] Claude 进程仍在运行: $($alive.ProcessName -join ',') (PID $($alive.Id -join ','))"
        Log "       先完全退出 Claude Desktop + 所有 CLI 终端再重跑(或 -Force 强跑,不推荐)"
        $log | Set-Content (Join-Path $bak 'cleanup-log.txt') -Encoding UTF8
        exit 1
    }
    Log "[ok] 无 Claude 进程"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$mgBefore = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction SilentlyContinue).MachineGuid

# ---------- Node/PS 双模 JSON 编辑器 ----------
if ($nodeExe) {
    $nodeSrc = @'
const fs = require('fs');
const [, , file, removeArg, setArg, purgeArg] = process.argv;
let d;
try { d = JSON.parse(fs.readFileSync(file, 'utf8')); }
catch (e) { console.log('ERR: ' + e.message); process.exit(1); }
function esc(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
function patToRe(p) { return new RegExp('^' + p.split('*').map(esc).join('.*') + '$'); }
for (const spec of (removeArg || '').split('|').filter(Boolean)) {
  if (spec.includes('*')) {
    const re = patToRe(spec);
    for (const k of Object.keys(d)) if (re.test(k)) delete d[k];
  } else {
    const parts = spec.split('.');
    let cur = d;
    for (let i = 0; i < parts.length - 1; i++) cur = (cur && typeof cur === 'object') ? cur[parts[i]] : null;
    if (cur && typeof cur === 'object') delete cur[parts[parts.length - 1]];
  }
}
const UUID_RE = /(^|[.])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function purgeUuidKeys(o) {
  if (Array.isArray(o)) { for (const v of o) purgeUuidKeys(v); return; }
  if (o && typeof o === 'object') for (const k of Object.keys(o)) {
    if (UUID_RE.test(k)) { delete o[k]; continue; }
    purgeUuidKeys(o[k]);
  }
}
if (purgeArg === 'uuidkeys') purgeUuidKeys(d);
if (setArg) {
  const sets = JSON.parse(Buffer.from(setArg, 'base64').toString('utf8'));
  for (const k of Object.keys(sets)) d[k] = sets[k];
}
fs.writeFileSync(file, JSON.stringify(d, null, 2));
console.log('OK');
'@
    $nodeScript = Join-Path $bak '_jsonedit.cjs'
    [System.IO.File]::WriteAllText($nodeScript, $nodeSrc, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-JsonProps { # PS 5.1 兜底版(无 node 时):点路径逐层删
    param($obj, [string]$spec)
    if ($spec.Contains('*')) { return }  # 通配符只有 node 版支持
    $parts = $spec.Split('.')
    $cur = $obj
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        if ($cur -and $cur.PSObject.Properties[$parts[$i]]) { $cur = $cur.$($parts[$i]) } else { return }
    }
    if ($cur -and $cur.PSObject.Properties[$parts[-1]]) { $cur.PSObject.Properties.Remove($parts[-1]) }
}

function Edit-Json {
    param([string]$Path, [string[]]$Remove = @(), [hashtable]$Set = @{}, [string]$Purge = '')
    if (-not (Test-Path $Path)) { return $false }
    if ($nodeExe) {
        $setJson = if ($Set.Count) { ($Set | ConvertTo-Json -Compress) } else { '{}' }
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($setJson))
        $out = & $nodeExe $nodeScript $Path ($Remove -join '|') $b64 $Purge 2>&1
        if ($LASTEXITCODE -eq 0 -and ($out -join '') -match 'OK') { return $true }
        Log "  [warn] node JSON 处理失败: $Path"
        return $false
    }
    # ---- PS 兜底 ----
    try {
        $d = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in $Remove) { Remove-JsonProps $d $r }
        foreach ($k in $Set.Keys) {
            if ($d.PSObject.Properties[$k]) { $d.$k = $Set[$k] } else { $d | Add-Member -NotePropertyName $k -NotePropertyValue $Set[$k] }
        }
        $d | ConvertTo-Json -Depth 100 | Set-Content $Path -Encoding UTF8
        return $true
    } catch {
        Log "  [warn] PS JSON 解析失败($($_.Exception.Message)) → 整文件移入备份,让客户端重建"
        Backup $Path
        Remove-Item $Path -Force -ErrorAction SilentlyContinue
        return $false
    }
}

# ---------- §1-§4 仅 Stage='all' ----------
if ($Stage -eq 'all') {

# ---------- 1. [C1] MachineGuid —— device_id=SHA256(MachineGuid),实证上报主标识 ----------
if (-not $SkipMachineGuid) {
    if (-not $isAdmin) {
        Log "[C1] 无管理员权限,跳过 MachineGuid。请管理员 PowerShell 手动执行:"
        Log '     $g=[guid]::NewGuid().ToString(); reg add "HKLM\SOFTWARE\Microsoft\Cryptography" /v MachineGuid /t REG_SZ /d $g /f'
        Log '     然后重启电脑。'
    } else {
        $g = if ($NewMachineGuid) { $NewMachineGuid } else { [guid]::NewGuid().ToString() }
        try {
            $old = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
            # 实测:Set-ItemProperty 对该键静默失败,必须 reg.exe /f
            reg.exe add 'HKLM\SOFTWARE\Microsoft\Cryptography' /v MachineGuid /t REG_SZ /d $g /f | Out-Null
            $now = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
            if ($now -eq $g) {
                Log "[C1] MachineGuid 已轮换(旧值尾 4 位 …$($old.Substring($old.Length-4))) —— 重启后生效"
                "old=$old`nnew=$now" | Set-Content (Join-Path $bak 'machineguid-backup.txt') -Encoding UTF8
            } else { Log "[C1] 写入未生效!当前仍为旧值" }
        } catch { Log "[C1] FAIL: $($_.Exception.Message)" }
    }
} else { Log "[C1] -SkipMachineGuid,跳过" }

# ---------- 2. [C2] ~/.claude.json —— userID/machineID/oauthAccount/账号缓存 ----------
$cj = Join-Path $env:USERPROFILE '.claude.json'
if (Test-Path $cj) {
    Backup $cj
    $remove = @(
        'oauthAccount',                       # [C2] 旧账号 OAuth 身份缓存
        'cachedUsageUtilization','groveConfigCache','clientDataCacheSlots',  # [C2] 历史 org uuid 藏点
        'cachedGrowthBookFeatures','cachedExperimentFeatures','cachedExperimentData',
        'metricsStatusCache',
        'hasAvailableSubscription','passesEligibilityCache','cachedExtraUsageDisabledReason',
        'subscriptionNoticeCount','modelAccessCache','orgModelDefaultCache',
        'autoCompactWindowsCache','additionalModelOptionsCache','additionalModelCostsCache',
        'hasResetAutoModeOptInForDefaultOffer','remoteToolsDeviceName',
        'chromeExtension.pairedDeviceId','chromeExtension.pairedDeviceName'   # [B3] 扩展配对设备
    )
    $set = @{ userID = (New-Hex 32); machineID = (New-Hex 32) }
    if (Edit-Json -Path $cj -Remove $remove -Set $set) {
        Log "[C2] userID/machineID 已再随机化,oauthAccount + 账号状态缓存已清"
    }
}

# ---------- 2.5 [C4] jobs 后台任务状态(state.json 记历史账号/组织 uuid) ----------
$jobsDir = Join-Path $env:USERPROFILE '.claude\jobs'
if (Test-Path $jobsDir) { Remove-Item $jobsDir -Recurse -Force -ErrorAction SilentlyContinue; Log "[C4] jobs 目录已删" }

# ---------- 3. [C3] .credentials.json ----------
$cred = Join-Path $env:USERPROFILE '.claude\.credentials.json'
if (Test-Path $cred) {
    Backup $cred
    if ((Get-Content $cred -Raw -Encoding UTF8) -match 'claudeAiOauth') {
        if (Edit-Json -Path $cred -Remove @('claudeAiOauth')) { Log "[C3] claudeAiOauth 令牌已清" }
    } else { Log "[C3] 无 claudeAiOauth(第三方 API 用户,正常)" }
}

# ---------- 4. [C4] ~/.claude 运行时/遥测/缓存 ----------
$dotClaude = Join-Path $env:USERPROFILE '.claude'
$tel = Join-Path $dotClaude 'telemetry'
if (Test-Path $tel) { Remove-Item $tel -Recurse -Force -ErrorAction SilentlyContinue; Log "[C4] telemetry 已删(存旧 device_id 事件)" }
foreach ($d in @('cache','paste-cache','debug','file-history','audit','daemon','sessions','session-env',
    'ide','channels','security','tasks','teams','workflows','usage-data','scheduled-tasks')) {
    $dp = Join-Path $dotClaude $d
    if (Test-Path $dp) { Remove-Item $dp -Recurse -Force -ErrorAction SilentlyContinue }
}
foreach ($f in @('daemon.log','stats-cache.json','policy-limits.json','usage.jsonl','usage.with-fix.jsonl',
    'mcp-needs-auth-cache.json','remote-settings.json','.last-cleanup','.last-update-result.json',
    'scheduled_tasks.lock')) {
    $fp = Join-Path $dotClaude $f
    if (Test-Path $fp) { Remove-Item $fp -Force -ErrorAction SilentlyContinue }
}
Log "[C4] 运行时/遥测/缓存已清"

# [H1] 会话历史:默认保留(本地数据不上报);-WipeHistory 才删
$projDir = Join-Path $dotClaude 'projects'
if ($WipeHistory) {
    foreach ($f in @('history.jsonl')) { $fp = Join-Path $dotClaude $f; if (Test-Path $fp) { Backup $fp; Remove-Item $fp -Force } }
    if (Test-Path $projDir) {
        Backup $projDir
        if ($nodeExe) {
            $cleaner = Join-Path (Split-Path -Parent $PSCommandPath) 'clean-projects-keep-memory.cjs'
            if (Test-Path $cleaner) { Log "[H1] $((& $nodeExe $cleaner 2>&1) -join '')" }
        } else {
            # 无 node 兜底:projects/<proj>/ 下除 memory 外全删
            Get-ChildItem $projDir -Directory | ForEach-Object {
                Get-ChildItem $_.FullName | Where-Object { $_.Name -ne 'memory' } |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
            Log "[H1] projects 会话数据已清(保留 memory)"
        }
    }
} else { Log "[H1] 会话历史保留(默认;要删用 -WipeHistory)" }

} # end Stage='all'

# ---------- 5. [D*] Claude Desktop: %APPDATA%\Claude ----------
$ap = Join-Path $env:APPDATA 'Claude'
if (Test-Path $ap) {
    foreach ($f in @('ant-did','ant-device-registry.json')) {   # [D1]
        $fp = Join-Path $ap $f
        if (Test-Path $fp) { Backup $fp; Remove-Item $fp -Force; Log "[D1] $f 已删" }
    }
    $cfg = Join-Path $ap 'config.json'                          # [D2]
    if (Test-Path $cfg) {
        Backup $cfg
        if (Edit-Json -Path $cfg -Remove @('oauth:*','dxt:allowlist*','remote_uploads_migration_done_v1_*',
            'lastKnownAccountUuid','windowSizeWasSignedIn','hasTrackedInitialActivation')) {
            Log "[D2] config.json 登录态/token/org 键已清"
        }
    }
    $dsk = Join-Path $ap 'claude_desktop_config.json'           # [D3] 保留 mcpServers,只删账号映射
    if (Test-Path $dsk) {
        Backup $dsk
        if (Edit-Json -Path $dsk -Remove @('preferences.chromeExtension.pairedDeviceId',
            'preferences.chromeExtension.pairedDeviceName','preferences.chromeExtension.pairedFromDeviceIds',
            'preferences.remoteToolsDeviceName') -Purge 'uuidkeys') {
            Log "[D3] claude_desktop_config.json 账号索引映射已清(mcpServers 保留)"
        }
    }
    $pref = Join-Path $ap 'Preferences'                          # [D4]
    if (Test-Path $pref) {
        Backup $pref
        if ((Get-Content $pref -Raw -Encoding UTF8) -match 'device_id_salt') {
            if (Edit-Json -Path $pref -Remove @('electron.media.device_id_salt')) { Log "[D4] device_id_salt 已清" }
        }
    }
    foreach ($dir in @('Partitions','Local Storage','IndexedDB','Session Storage','Network','WebStorage',  # [D5][D7]
        'SharedStorage','SharedStorage-wal','DIPS','DIPS-wal','fcache','InterestGroups','InterestGroups-wal',
        'Cache','Code Cache','GPUCache','DawnGraphiteCache','DawnWebGPUCache','blob_storage','File System',
        'VideoDecodeStats','logs','sentry','Crashpad',
        'claude-code-sessions','local-agent-mode-sessions','claude-code-vm')) {                           # [D6]
        $dp = Join-Path $ap $dir
        if (Test-Path $dp) { Remove-Item $dp -Recurse -Force -ErrorAction SilentlyContinue; Log "[D5-D7] $dir 已清" }
    }
    foreach ($f in @('plan-usage-history.json','cowork-enabled-cli-ops.json','bridge-state.json',
        'extensions-blocklist.json','declarative_performance_observer.db','declarative_performance_observer.db-journal')) {
        $fp = Join-Path $ap $f
        if (Test-Path $fp) {
            if ($f -like 'plan-usage*' -or $f -like 'cowork*' -or $f -like 'bridge-state*') { Backup $fp }
            Remove-Item $fp -Force -ErrorAction SilentlyContinue; Log "[D3] $f 已删"
        }
    }
} else { Log "[D] %APPDATA%\Claude 不存在" }

# ---------- 6. [L1][L2] %LOCALAPPDATA% ----------
$lLogs = Join-Path $env:LOCALAPPDATA 'Claude\Logs'
if (Test-Path $lLogs) { Backup $lLogs; Remove-Item $lLogs -Recurse -Force -ErrorAction SilentlyContinue; Log "[L1] Desktop Logs 已清(含旧账号 email/uuid)" }
$cliCache = Join-Path $env:LOCALAPPDATA 'claude-cli-nodejs\Cache'
if (Test-Path $cliCache) { Remove-Item $cliCache -Recurse -Force -ErrorAction SilentlyContinue; Log "[L2] claude-cli-nodejs\Cache 已清(目录名内嵌账号 UUID)" }

# ---------- 7. 自检:基线标识零残留 ----------
Log ""
Log "==== 自检(对照 baseline)===="
$stale = @()
function Scan-File($path, $label) {
    if (-not $path -or -not (Test-Path $path)) { return }
    $t = Get-Content $path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $t) { return }
    foreach ($id in $script:knownIds) {
        if ($t.Contains($id)) { $script:stale += "$label 仍含 $($id.Substring(0,[Math]::Min(12,$id.Length)))…" }
    }
}
Scan-File $cj '~/.claude.json'
Scan-File $cred '~/.claude/.credentials.json'
Scan-File (Join-Path $ap 'config.json') 'Desktop config.json'
Scan-File (Join-Path $ap 'claude_desktop_config.json') 'Desktop claude_desktop_config.json'
Scan-File (Join-Path $ap 'Preferences') 'Desktop Preferences'
foreach ($root in @($ap, (Join-Path $env:LOCALAPPDATA 'claude-cli-nodejs'))) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $n = $_.Name
        if (($script:knownIds | Where-Object { $n -like "*$_*" }).Count -gt 0) { $script:stale += "目录名残留: $($_.FullName)" }
    }
}
if ($stale.Count -eq 0) { Log "[PASS] 活跃配置与目录树零残留" }
else { Log "[WARN] 残留:"; $stale | Select-Object -First 10 | ForEach-Object { Log "   - $_" } }

# ---------- 8. 记录清理后状态(verify.ps1 的门禁依据) ----------
$mgAfter = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction SilentlyContinue).MachineGuid
$stateDir = Join-Path $env:USERPROFILE '.fresh-device'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
@{
    cleanedAt          = Get-Date -Format 'o'
    machineGuidBefore  = $mgBefore
    machineGuidAfter   = $mgAfter
    machineGuidRotated = ($mgAfter -ne $mgBefore)
    backupDir          = $bak
} | ConvertTo-Json | Set-Content (Join-Path $stateDir 'post-clean.json') -Encoding UTF8

Log ""
Log "==== 完成。下一步:重启电脑 → 跑 verify.ps1 过门禁 → PASS 后才允许登录 ===="
$log | Set-Content (Join-Path $bak 'cleanup-log.txt') -Encoding UTF8
