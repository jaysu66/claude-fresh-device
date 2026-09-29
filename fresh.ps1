# claude-fresh-device: check -> clean -> check -> net, one script.
#   fresh.ps1 check                  read-only audit + login gate (PASS/FAIL)
#   fresh.ps1 clean                  DRY RUN, shows what would be removed
#   fresh.ps1 clean -Apply           backup, then remove   (add -RotateGuid for MachineGuid, needs admin)
#   fresh.ps1 net -Anchor            pin current exit IP as the account's exit
#   fresh.ps1 net                    GO / NO-GO against the pinned exit
# Evidence tags [E]=client binary, [T]=observed on real machine, [I]=inference, [C]=common knowledge; see references/checklist.md
# -SandboxHome <dir>: treat <dir> as the whole user profile; registry/process/network/credential calls are skipped (used by test/run-tests.ps1).
param([ValidateSet('check', 'clean', 'net')][string]$Mode = 'check',
    [switch]$Apply, [switch]$RotateGuid, [switch]$Force, [switch]$Anchor, [switch]$PostLogin,
    [string]$SandboxHome)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Live = ($env:OS -eq 'Windows_NT') -and -not $SandboxHome
if ($SandboxHome) { $UP = $SandboxHome; $AD = Join-Path $UP 'AppData/Roaming'; $LD = Join-Path $UP 'AppData/Local' }
else { $UP = $env:USERPROFILE; $AD = $env:APPDATA; $LD = $env:LOCALAPPDATA }
$Dot = Join-Path $UP '.claude'; $CJ = Join-Path $UP '.claude.json'; $Desk = Join-Path $AD 'Claude'
$State = Join-Path $UP '.fresh-device'; $StateFile = Join-Path $State 'state.json'; $AnchorFile = Join-Path $State 'anchor.json'

# ---- what counts as a Claude identity artifact (each has a tag in references/checklist.md) ----
$DotDirs = 'telemetry', 'cache', 'paste-cache', 'debug', 'file-history', 'audit', 'daemon', 'sessions', 'session-env', 'ide', 'channels', 'security', 'tasks', 'teams', 'workflows', 'usage-data', 'scheduled-tasks', 'jobs', 'chrome'
$DotFiles = 'daemon.log', 'stats-cache.json', 'policy-limits.json', 'usage.jsonl', 'mcp-needs-auth-cache.json', 'remote-settings.json', '.last-cleanup', '.last-update-result.json', 'scheduled_tasks.lock'
$DeskFiles = 'ant-did', 'ant-device-registry.json', 'plan-usage-history.json', 'cowork-enabled-cli-ops.json', 'bridge-state.json', 'extensions-blocklist.json', 'declarative_performance_observer.db', 'declarative_performance_observer.db-journal'
$DeskDirs = 'Partitions', 'Local Storage', 'IndexedDB', 'Session Storage', 'Network', 'WebStorage', 'SharedStorage', 'SharedStorage-wal', 'DIPS', 'DIPS-wal', 'fcache', 'InterestGroups', 'InterestGroups-wal', 'Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'blob_storage', 'File System', 'VideoDecodeStats', 'logs', 'sentry', 'Crashpad', 'claude-code-sessions', 'local-agent-mode-sessions', 'claude-code-vm', 'ChromeNativeHost'
$CjKeys = 'oauthAccount', 'cachedUsageUtilization', 'groveConfigCache', 'clientDataCacheSlots', 'cachedGrowthBookFeatures', 'cachedExperimentFeatures', 'cachedExperimentData', 'metricsStatusCache', 'hasAvailableSubscription', 'passesEligibilityCache', 'cachedExtraUsageDisabledReason', 'subscriptionNoticeCount', 'modelAccessCache', 'orgModelDefaultCache', 'autoCompactWindowsCache', 'additionalModelOptionsCache', 'additionalModelCostsCache', 'hasResetAutoModeOptInForDefaultOffer', 'remoteToolsDeviceName', 'chromeExtension.pairedDeviceId', 'chromeExtension.pairedDeviceName'
$ExtIds = 'fcoeoabgfenejglbffodgkkbkcdhcgfn', 'dihbgbndebgnbjfmelmegjepbnkhlgni', 'dngcpimnedloihjnnfngkgjoidhnaolf'
$UuidRe = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

$Fnd = New-Object System.Collections.ArrayList
function Add-F($lvl, $tag, $msg) { [void]$Fnd.Add([pscustomobject]@{ L = $lvl; T = $tag; M = $msg }) }
function Get-Procs { if ($Live) { @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^claude' -or $_.ProcessName -eq 'chrome-native-host' }) } else { @() } }
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function New-Hex($n) { $b = New-Object byte[] $n; $r = [Security.Cryptography.RandomNumberGenerator]::Create(); $r.GetBytes($b); $r.Dispose(); ($b | ForEach-Object { $_.ToString('x2') }) -join '' }
function Read-Json($p) { try { Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } }
function Save-Json($o, $p) { $o | ConvertTo-Json -Depth 100 | Set-Content $p -Encoding UTF8 }
function Show($items) { foreach ($i in $items) { Write-Output ("  [{0}] {1}{2}" -f $i.L, $(if ($i.T) { "[$($i.T)] " } else { '' }), $i.M) } }

function Remove-JsonKey($obj, [string]$spec) {
    $parts = $spec.Split('.'); $cur = $obj
    for ($i = 0; $i -lt $parts.Length - 1; $i++) { if ($cur -and $cur.PSObject.Properties[$parts[$i]]) { $cur = $cur.($parts[$i]) } else { return $false } }
    $last = $parts[-1]
    if ($last.Contains('*')) {
        $re = '^' + ([regex]::Escape($last) -replace '\\\*', '.*') + '$'; $hit = $false
        foreach ($p in @($cur.PSObject.Properties.Name)) { if ($p -match $re) { $cur.PSObject.Properties.Remove($p); $hit = $true } }
        return $hit
    }
    if ($cur -and $cur.PSObject.Properties[$last]) { $cur.PSObject.Properties.Remove($last); return $true }
    $false
}
function Remove-UuidKeys($o) {
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) { foreach ($v in $o) { Remove-UuidKeys $v }; return }
    if ($o -is [pscustomobject]) { foreach ($n in @($o.PSObject.Properties.Name)) { if ($n -match $UuidRe) { $o.PSObject.Properties.Remove($n) } else { Remove-UuidKeys $o.$n } } }
}

# ============================== check ==============================
function Invoke-Check {
    Write-Output "==== fresh.ps1 check @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')$(if ($SandboxHome) { ' [SANDBOX]' }) ===="
    $login = if ($PostLogin) { 'INFO' } else { 'DIRTY' }

    $procs = Get-Procs
    if ($procs) { Add-F 'BLOCK' 'T' "Claude 相关进程在跑: $(($procs.ProcessName | Sort-Object -Unique) -join ', ')。清理会被写回,先全部退出(含浏览器里的 claude.ai 标签页)" }

    # C2 .claude.json
    if (Test-Path $CJ) {
        $j = Read-Json $CJ
        if ($j) {
            if ($j.PSObject.Properties['oauthAccount']) { Add-F $login 'T' '.claude.json 含 oauthAccount(账号邮箱/组织缓存)' }
            $cache = @($j.PSObject.Properties.Name | Where-Object { $_ -match 'Cache|cached' })
            if ($cache) { Add-F $login 'T' ".claude.json 含 $($cache.Count) 个账号状态缓存键(可能带历史 org uuid)" }
        }
        else { Add-F 'WARN' 'T' '.claude.json 无法解析(clean 时整文件备份后重建)' }
    }
    # C3 credentials
    $cred = Join-Path $Dot '.credentials.json'
    if ((Test-Path $cred) -and ((Get-Content $cred -Raw -Encoding UTF8) -match 'claudeAiOauth')) { Add-F $login 'T' '.credentials.json 含 OAuth 令牌' }
    # C4 runtime dirs
    $rt = @($DotDirs | Where-Object { Test-Path (Join-Path $Dot $_) }) + @($DotFiles | Where-Object { Test-Path (Join-Path $Dot $_) })
    if ($rt) { Add-F 'DIRTY' 'T' "~/.claude 运行时/遥测残留: $($rt -join ', ')" }
    # D Desktop
    foreach ($f in $DeskFiles) { if (Test-Path (Join-Path $Desk $f)) { Add-F 'DIRTY' 'T' "Desktop 文件残留: $f" } }
    $dd = @($DeskDirs | Where-Object { Test-Path (Join-Path $Desk $_) })
    if ($dd) { Add-F 'DIRTY' 'T' "Desktop 存储目录残留: $($dd -join ', ')" }
    $cfg = Join-Path $Desk 'config.json'
    if ((Test-Path $cfg) -and ((Get-Content $cfg -Raw -Encoding UTF8) -match 'lastKnownAccountUuid|"oauth:')) { Add-F $login 'T' 'Desktop config.json 含登录态键' }
    $dsk = Join-Path $Desk 'claude_desktop_config.json'
    if (Test-Path $dsk) {
        $u = [regex]::Matches((Get-Content $dsk -Raw -Encoding UTF8), '"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"\s*:').Count
        if ($u) { Add-F $login 'T' "claude_desktop_config.json 含 $u 个账号 UUID 键" }
    }
    $pref = Join-Path $Desk 'Preferences'
    if ((Test-Path $pref) -and ((Get-Content $pref -Raw -Encoding UTF8) -match 'device_id_salt')) { Add-F 'DIRTY' 'T' 'Desktop Preferences 含 device_id_salt' }
    # L
    if (Test-Path (Join-Path $LD 'Claude/Logs')) { Add-F 'DIRTY' 'T' 'LOCALAPPDATA\Claude\Logs 残留(日志含历史账号信息)' }
    if (Test-Path (Join-Path $LD 'claude-cli-nodejs/Cache')) { Add-F 'DIRTY' 'T' 'claude-cli-nodejs\Cache 残留(目录名内嵌账号 UUID)' }
    if ($Live) {
        $mg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction SilentlyContinue).MachineGuid
        if ($mg) { Add-F 'INFO' 'E' 'MachineGuid 存在: device_id = SHA256(MachineGuid) 随遥测上报;被封过的机器建议 clean -Apply -RotateGuid' }
        # B browser
        foreach ($rk in 'HKCU:\SOFTWARE\Google\Chrome\NativeMessagingHosts', 'HKCU:\SOFTWARE\Microsoft\Edge\NativeMessagingHosts') {
            if (Test-Path $rk) { $h = @(Get-ChildItem $rk | Where-Object { $_.PSChildName -match 'anthropic|claude' }); if ($h) { Add-F 'WARN' 'T' "浏览器注册了 $($h.Count) 个 Claude native host(扩展会拉起 chrome-native-host)" } }
        }
        foreach ($br in @(@('Chrome', "$LD\Google\Chrome\User Data"), @('Edge', "$LD\Microsoft\Edge\User Data"))) {
            if (-not (Test-Path $br[1])) { continue }
            foreach ($p in (Get-ChildItem $br[1] -Directory | Where-Object { $_.Name -match '^(Default|Profile \d+)$' })) {
                foreach ($e in $ExtIds) { if (Test-Path (Join-Path $p.FullName "Extensions\$e")) { Add-F 'WARN' 'T' "$($br[0])\$($p.Name) 装了 Claude 扩展。登录请用没碰过 claude.ai 的浏览器/无痕窗口" } }
            }
        }
        # proxy residue
        $is = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($is -and $is.ProxyEnable -eq 1) { Add-F 'WARN' 'C' "Windows 系统代理已开启($($is.ProxyServer -replace '\d+\.\d+$','x.x')): 建议改用 TUN 模式,系统代理只管浏览器,claude.exe 可能漏真实 IP" }
        $pe = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy') | Where-Object { [Environment]::GetEnvironmentVariable($_) }
        if ($pe) { Add-F 'WARN' 'C' "环境变量含代理: $($pe -join ', ')" }
        $ae = @(Get-ChildItem env: | Where-Object { $_.Name -match '^(ANTHROPIC|CLAUDE)_' -and $_.Name -notmatch 'CLAUDE_CODE_DISABLE' } | ForEach-Object { $_.Name })
        if ($ae) { Add-F 'WARN' 'E' "ANTHROPIC_*/CLAUDE_* 变量: $($ae -join ', ')。确认没指向中转 (BASE_URL/AUTH_TOKEN)" }
        if (Get-Command npm -ErrorAction SilentlyContinue) { $np = (npm config get proxy 2>$null); if ($np -and $np -ne 'null') { Add-F 'WARN' 'C' 'npm 配置了 proxy' } }
        if (Get-Command git -ErrorAction SilentlyContinue) { $gp = (git config --global --get http.proxy 2>$null); if ($gp) { Add-F 'WARN' 'C' 'git 全局配置了 http.proxy' } }
        $sj = Join-Path $Dot 'settings.json'
        if ((Test-Path $sj) -and ((Get-Content $sj -Raw -Encoding UTF8) -match '(?i)proxy|ANTHROPIC_BASE_URL')) { Add-F 'WARN' 'C' '~/.claude/settings.json 含 proxy/ANTHROPIC_BASE_URL 配置,确认是有意的' }
        $tun = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Meta|Wintun|TUN|Clash|sing-box' })
        if ($tun) { Add-F 'INFO' 'C' "检测到 TUN 适配器在线: $($tun[0].Name)" } else { Add-F 'WARN' 'C' '未检测到 TUN 适配器。若你靠系统代理/浏览器扩展上网,claude.exe 未必走代理' }
        $cm = @((cmdkey /list 2>$null) | Where-Object { $_ -match 'Target:.*(?i:claude|anthropic)' })
        if ($cm) { Add-F 'DIRTY' 'I' "凭据管理器有 $($cm.Count) 条 claude/anthropic 凭据" }
        Add-F 'INFO' 'C' "时区=$((Get-TimeZone).Id) 语言=$((Get-Culture).Name)。不建议为此伪装,保持与真实环境一致" 
    }
    # M memory (report only, never auto-delete)
    $mem = @()
    if (Test-Path (Join-Path $Dot 'projects')) { $mem += Get-ChildItem (Join-Path $Dot 'projects') -Recurse -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '[\\/]memory[\\/]' } }
    foreach ($m in @((Join-Path $Dot 'CLAUDE.md'))) { if (Test-Path $m) { $mem += Get-Item $m } }
    $hits = @()
    foreach ($m in $mem) {
        $t = Get-Content $m.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue; if (-not $t) { continue }
        $em = [regex]::Matches($t, '[\w.+-]+@[\w-]+\.[\w.]+').Count
        $kw = [regex]::Matches($t, '封号|被封|指纹|fingerprint|banned|device[_ ]?id|org[_-]?id|MachineGuid', 'IgnoreCase').Count
        if ($em -or $kw) { $hits += "$($m.Name)(邮箱$em/关键词$kw)" }
    }
    if ($hits) { Add-F 'WARN' 'T' "memory/CLAUDE.md 含邮箱或封号/指纹字样,会被读进新号上下文: $(($hits | Select-Object -First 8) -join ', ')。人工审阅,不要自动删" }

    Show $Fnd
    $bad = @($Fnd | Where-Object { $_.L -eq 'BLOCK' -or $_.L -eq 'DIRTY' })
    $st = if (Test-Path $StateFile) { Read-Json $StateFile } else { $null }
    Write-Output ''
    if ($bad) {
        Write-Output "==== [GATE: FAIL] $($bad.Count) 项未过。不要登录。先 fresh.ps1 clean(预览)-> clean -Apply -> 重启 -> 再 check ===="
        exit 1
    }
    if (-not $PostLogin -and $Live -and -not ($st -and $st.guidRotated)) { Write-Output '  [WARN] 本工具没轮换过 MachineGuid。这台机器若跑过被封的号,建议 clean -Apply -RotateGuid;全新机器可忽略' }
    Write-Output '==== [GATE: PASS] 本机侧无残留。登录清单: 已重启 | fresh.ps1 net 过 GO | 无痕/干净浏览器 OAuth | 一号一会话 ===='
    exit 0
}

# ============================== clean ==============================
function Invoke-Clean {
    Write-Output "==== fresh.ps1 clean $(if ($Apply) { '[APPLY]' } else { '[DRY RUN, 加 -Apply 才会动文件]' })$(if ($SandboxHome) { ' [SANDBOX]' }) ===="
    $procs = Get-Procs
    if ($procs -and -not $Force) { Write-Output "[中止] 进程在跑: $(($procs.ProcessName | Sort-Object -Unique) -join ', ')。先全退(含 claude.ai 标签页)"; exit 1 }
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'; $bak = Join-Path $State "backups/$ts"
    if ($Apply) { New-Item -ItemType Directory -Force -Path $bak | Out-Null }
    function Bak($p) { if ($Apply -and (Test-Path $p)) { $rel = ($p.Substring($UP.Length) -replace '[:\\/]+', '_').Trim('_'); Copy-Item $p (Join-Path $bak $rel) -Recurse -Force -ErrorAction SilentlyContinue } }
    function Drop($p, $why) { if (Test-Path $p) { Write-Output "  - $why : $p"; if ($Apply) { Bak $p; Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } } }
    function EditKeys($path, $keys, $uuid, $why, $set) {
        if (-not (Test-Path $path)) { return }
        $j = Read-Json $path
        if (-not $j) { Write-Output "  - $why 无法解析,整文件备份后删除让客户端重建 : $path"; if ($Apply) { Bak $path; Remove-Item $path -Force }; return }
        $n = 0; foreach ($k in $keys) { if (Remove-JsonKey $j $k) { $n++ } }
        if ($uuid) { Remove-UuidKeys $j; $n++ }
        if ($set) { foreach ($k in $set.Keys) { if ($j.PSObject.Properties[$k]) { $j.$k = $set[$k] } else { $j | Add-Member -NotePropertyName $k -NotePropertyValue $set[$k] } }; $n++ }
        if ($n) { Write-Output "  - $why : $path ($n 处)"; if ($Apply) { Bak $path; Save-Json $j $path } }
    }
    # C2/C3 (keep everything else in .claude.json: projects, mcpServers, settings)
    EditKeys $CJ $CjKeys $false '[C2] 账号缓存键 + 重随机化 userID/machineID' @{ userID = (New-Hex 32); machineID = (New-Hex 32) }
    EditKeys (Join-Path $Dot '.credentials.json') @('claudeAiOauth') $false '[C3] OAuth 令牌' $null
    foreach ($d in $DotDirs) { Drop (Join-Path $Dot $d) '[C4] 运行时/遥测' }
    foreach ($f in $DotFiles) { Drop (Join-Path $Dot $f) '[C4] 运行时' }
    # D (keep mcpServers)
    foreach ($f in $DeskFiles) { Drop (Join-Path $Desk $f) '[D1/D3] 设备 ID/账号索引' }
    EditKeys (Join-Path $Desk 'config.json') @('oauth:*', 'dxt:allowlist*', 'remote_uploads_migration_done_v1_*', 'lastKnownAccountUuid', 'windowSizeWasSignedIn', 'hasTrackedInitialActivation') $false '[D2] 登录态键' $null
    EditKeys (Join-Path $Desk 'claude_desktop_config.json') @('preferences.chromeExtension.pairedDeviceId', 'preferences.chromeExtension.pairedDeviceName', 'preferences.chromeExtension.pairedFromDeviceIds', 'preferences.remoteToolsDeviceName') $true '[D3] 账号索引(mcpServers 保留)' $null
    EditKeys (Join-Path $Desk 'Preferences') @('electron.media.device_id_salt') $false '[D4] device_id_salt' $null
    foreach ($d in $DeskDirs) { Drop (Join-Path $Desk $d) '[D5-D7] Chromium 存储/账号目录' }
    Drop (Join-Path $LD 'Claude/Logs') '[L1] 日志'
    Drop (Join-Path $LD 'claude-cli-nodejs/Cache') '[L2] MCP 缓存'
    if ($Live) {
        Drop (Join-Path $AD 'Claude Code/ChromeNativeHost') '[B1] native host'
        foreach ($rk in 'HKCU:\SOFTWARE\Google\Chrome\NativeMessagingHosts', 'HKCU:\SOFTWARE\Microsoft\Edge\NativeMessagingHosts') {
            if (Test-Path $rk) { foreach ($k in @(Get-ChildItem $rk | Where-Object { $_.PSChildName -match 'anthropic|claude' })) { Write-Output "  - [B1] 注册表 native host : $($k.PSChildName)"; if ($Apply) { Remove-Item $k.PSPath -Recurse -Force } } }
        }
        foreach ($l in @((cmdkey /list 2>$null) | Where-Object { $_ -match 'Target:.*(?i:claude|anthropic)' })) {
            $t = ($l -replace '^\s*Target:\s*', '').Trim(); Write-Output '  - [凭据管理器] claude/anthropic 凭据'; if ($Apply) { cmdkey /delete:"$t" | Out-Null }
        }
        if ($RotateGuid) {
            if (-not (Test-Admin)) { Write-Output '  ! [C1] 轮换 MachineGuid 需要管理员 PowerShell,已跳过' }
            else {
                $g = [guid]::NewGuid().ToString(); $old = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
                Write-Output '  - [C1] MachineGuid 轮换(旧值已备份到本机 backups),重启后生效'
                if ($Apply) { New-Item -ItemType Directory -Force -Path $bak | Out-Null; "old=$old`nnew=$g" | Set-Content (Join-Path $bak 'machineguid.txt'); reg.exe add 'HKLM\SOFTWARE\Microsoft\Cryptography' /v MachineGuid /t REG_SZ /d $g /f | Out-Null }
            }
        }
    }
    Write-Output "  (保护清单,永不触碰: skills/agents/plugins/commands、projects/**/memory、settings.json、CLAUDE.md、浏览器其他站数据、其他 AI 产品目录)"
    if ($Apply) {
        New-Item -ItemType Directory -Force -Path $State | Out-Null
        $rot = $false; if ($Live -and $RotateGuid) { $rot = $true }
        Save-Json @{ cleanedAt = (Get-Date -Format 'o'); guidRotated = $rot; backup = $bak } $StateFile
        Write-Output "==== 完成。备份在 $bak(含旧标识,仅本机,别外发)。下一步: 重启 -> fresh.ps1 check ===="
    }
    else { Write-Output '==== 预览结束,未改动任何文件 ====' }
}

# ============================== net ==============================
function Invoke-Net {
    if (-not $Live) { Write-Output '[sandbox] net 需要真实网络,跳过'; exit 0 }
    try { $ip = Invoke-RestMethod -Uri 'http://ip-api.com/json/?fields=status,query,country,city,isp,as,hosting,proxy' -TimeoutSec 8 }
    catch { Write-Output '[NO-GO] 出口查询失败: 代理没开或不通'; exit 1 }
    if ($ip.status -ne 'success') { Write-Output "[NO-GO] 查询异常: $($ip.status)"; exit 1 }
    Write-Output ("出口: {0} | {1} | {2}, {3} | hosting={4} proxy={5}" -f ($ip.query -replace '\.\d+\.\d+$', '.x.x'), $ip.isp, $ip.city, $ip.country, $ip.hosting, $ip.proxy)
    if ($Anchor) {
        New-Item -ItemType Directory -Force -Path $State | Out-Null
        Save-Json @{ ip = $ip.query; as = $ip.as; city = $ip.city; anchoredAt = (Get-Date -Format 'o') } $AnchorFile
        Write-Output '[锚定] 已记录为账号专用出口(仅本机)'; if ($ip.hosting) { Write-Output '  [注意] 被标 hosting,建议换 hosting=false 的再锚定' }
        exit 0
    }
    if (-not (Test-Path $AnchorFile)) { Write-Output '[提示] 未锚定。选好长期节点后: fresh.ps1 net -Anchor'; exit 0 }
    $a = Read-Json $AnchorFile; $ok = $true
    if ($ip.query -eq $a.ip) { Write-Output '[GO] 与锚定出口一致' }
    elseif ($ip.as -eq $a.as -and $ip.city -eq $a.city) { Write-Output '[GO-黄] IP 变了但同 ASN 同城' }
    else { Write-Output '[NO-GO] 出口漂移,切回锚定节点再用(永久换节点则重新 -Anchor)'; $ok = $false }
    if ($ip.hosting) { Write-Output '[NO-GO] hosting=true,出口被标机房'; $ok = $false }
    if ($ip.proxy) { Write-Output '[黄] proxy=true,知情即可' }
    Write-Output '提示: 关代理前先关干净 claude.exe/Desktop/claude.ai 标签页,否则真实 IP 会漏进账号历史'
    exit $(if ($ok) { 0 } else { 1 })
}

switch ($Mode) { 'check' { Invoke-Check } 'clean' { Invoke-Clean } 'net' { Invoke-Net } }
