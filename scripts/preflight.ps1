# ============================================================
# preflight.ps1 — 登录/使用前的出口哨兵(claude-fresh-device)
#
# 每次开 Claude 前跑一下,确认当前出口是"锚定节点"且质量合格。
# 依据:references/ip-hygiene.md(账号 IP 历史 = 每个请求的源 IP 集合)
#
# 用法:
#   选定长期节点后跑一次:   preflight.ps1 -SetBaseline     # 锚定当前出口
#   每次用 Claude 之前:     preflight.ps1                  # GO / NO-GO
#   节点永久更换后:          preflight.ps1 -SetBaseline     # 重新锚定
# ============================================================
param([switch]$SetBaseline)

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$af = Join-Path $env:USERPROFILE '.fresh-device\approved-ip.json'

try {
    $ip = Invoke-RestMethod -Uri 'http://ip-api.com/json/?fields=status,query,country,regionName,city,isp,org,as,hosting,proxy,mobile' -TimeoutSec 8
} catch {
    Write-Output "[NO-GO] ip-api 查询失败 —— 代理没开或网络不通。开代理后重试。"
    exit 1
}
if ($ip.status -ne 'success') { Write-Output "[NO-GO] 出口查询异常: $($ip.status)"; exit 1 }

$masked = ($ip.query -replace '\.\d+\.\d+$', '.x.x')
Write-Output "当前出口: $masked | $($ip.isp) | $($ip.city), $($ip.country) | hosting=$($ip.hosting) proxy=$($ip.proxy)"

if ($SetBaseline) {
    New-Item -ItemType Directory -Force -Path (Split-Path $af) | Out-Null
    @{ ip=$ip.query; isp=$ip.isp; as=$ip.as; city=$ip.city; anchoredAt=(Get-Date -Format 'o') } |
        ConvertTo-Json | Set-Content $af -Encoding UTF8
    Write-Output "[锚定] 已记录此节点为账号专用出口。此后每次用 Claude 前跑 preflight 比对。"
    if ($ip.hosting) { Write-Output "  [注意] 该出口被标 hosting(机房) —— 建议换一个 hosting=false 的再锚定" }
    exit 0
}

if (-not (Test-Path $af)) {
    Write-Output "[提示] 还没锚定节点。选好长期使用的住宅节点后跑: preflight.ps1 -SetBaseline"
    if ($ip.hosting) { Write-Output "  [NO-GO] 当前出口 hosting=true,不建议直接锚定" }
    exit 0
}

$a = Get-Content $af -Raw -Encoding UTF8 | ConvertFrom-Json
$ok = $true
if ($ip.query -eq $a.ip) {
    Write-Output "[GO] 出口与锚定节点一致"
} elseif ($ip.as -eq $a.as -and $ip.city -eq $a.city) {
    Write-Output "[GO-黄] IP 变了但同 ASN 同城(节点内漂移,可接受)"
} else {
    Write-Output "[NO-GO] 出口漂移: 锚定=$($a.isp)@$($a.city) → 当前=$($ip.isp)@$($ip.city)"
    Write-Output "       若为永久换节点,确认质量后 -SetBaseline 重新锚定;若是代理没切回来,切回去再用"
    $ok = $false
}
if ($ip.hosting) { Write-Output "[NO-GO] hosting=true —— 当前出口被标机房段,换节点"; $ok = $false }
if ($ip.proxy) { Write-Output "[黄] proxy=true —— 被识别为代理出口(弱住宅,知情即可)" }
exit $(if ($ok) { 0 } else { 1 })
