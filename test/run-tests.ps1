# Runs entirely against a throwaway fake profile (-SandboxHome). Never touches the real registry, profile, processes or network.
param([string]$Script = (Join-Path $PSScriptRoot '../fresh.ps1'))
$ErrorActionPreference = 'Stop'
$h = Join-Path ([IO.Path]::GetTempPath()) ("fd-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fail = 0
function Ok($c, $m) { if ($c) { Write-Output "  ok   $m" } else { Write-Output "  FAIL $m"; $script:fail++ } }
function Run($a) { $o = & pwsh -NoProfile -File $Script @a -SandboxHome $h 2>&1 | Out-String; [pscustomobject]@{ Out = $o; Code = $LASTEXITCODE } }
function Mk($p, $t = 'x') { New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null; Set-Content $p $t }

$dot = "$h/.claude"; $ap = "$h/AppData/Roaming/Claude"; $ld = "$h/AppData/Local"
$oldUser = 'a' * 32; $uuid = '11111111-2222-3333-4444-555555555555'
Mk "$h/.claude.json" (@{ userID = $oldUser; machineID = $oldUser; oauthAccount = @{ emailAddress = 'old@example.com' }; clientDataCacheSlots = @{ o = $uuid }; projects = @{ p = 1 }; mcpServers = @{ keep = @{ command = 'x' } } } | ConvertTo-Json -Depth 10)
Mk "$dot/.credentials.json" '{"claudeAiOauth":{"accessToken":"t"},"other":1}'
Mk "$dot/telemetry/e.json"; Mk "$dot/jobs/$uuid/state.json"
Mk "$dot/skills/my-skill/SKILL.md" 'keep'; Mk "$dot/projects/p1/memory/MEMORY.md" 'contact me@example.com about the 封号 notes'
Mk "$dot/settings.json" '{"env":{}}'; Mk "$dot/CLAUDE.md" 'keep'
Mk "$ap/ant-did" 'did'; Mk "$ap/Cookies-dir/x"; Mk "$ap/Local Storage/leveldb/a"; Mk "$ap/claude-code-sessions/$uuid/s.json"
Mk "$ap/config.json" '{"oauth:tokenCache":"x","lastKnownAccountUuid":"u","theme":"dark"}'
Mk "$ap/claude_desktop_config.json" (@{ mcpServers = @{ keep = @{ command = 'y' } }; preferences = @{ $uuid = @{ a = 1 }; keepme = 1 } } | ConvertTo-Json -Depth 10)
Mk "$ap/Preferences" '{"electron":{"media":{"device_id_salt":"AB12"}},"x":1}'
Mk "$ld/Claude/Logs/l.log"; Mk "$ld/claude-cli-nodejs/Cache/$uuid/m"

Write-Output "T1 check on dirty profile must FAIL and print no identifiers"
$r = Run @('-Mode', 'check'); Ok ($r.Code -eq 1) 'exit 1'; Ok ($r.Out -match 'GATE: FAIL') 'gate FAIL'
Ok ($r.Out -notmatch 'old@example.com' -and $r.Out -notmatch $oldUser -and $r.Out -notmatch $uuid) 'output has no identifiers'
Ok ($r.Out -match 'MEMORY.md') 'memory review flagged'

Write-Output "T2 clean dry run must change nothing"
$before = (Get-ChildItem $h -Recurse -File | Measure-Object).Count
$r = Run @('-Mode', 'clean'); $after = (Get-ChildItem $h -Recurse -File | Measure-Object).Count
Ok ($r.Code -eq 0 -and $before -eq $after) 'file count unchanged'; Ok ($r.Out -match 'DRY RUN') 'labelled dry run'

Write-Output "T3 clean -Apply"
$r = Run @('-Mode', 'clean', '-Apply'); Ok ($r.Code -eq 0) 'exit 0'
Ok (-not (Test-Path "$dot/telemetry") -and -not (Test-Path "$dot/jobs")) 'runtime removed'
Ok (-not (Test-Path "$ap/ant-did") -and -not (Test-Path "$ap/Local Storage") -and -not (Test-Path "$ap/claude-code-sessions")) 'desktop identity removed'
Ok (-not (Test-Path "$ld/Claude/Logs") -and -not (Test-Path "$ld/claude-cli-nodejs/Cache")) 'localappdata removed'
Ok ((Test-Path "$dot/skills/my-skill/SKILL.md") -and (Test-Path "$dot/projects/p1/memory/MEMORY.md") -and (Test-Path "$dot/settings.json") -and (Test-Path "$dot/CLAUDE.md")) 'protected list intact'
$j = Get-Content "$h/.claude.json" -Raw | ConvertFrom-Json
Ok ($j.userID -ne $oldUser -and $j.machineID -ne $oldUser -and $j.userID.Length -eq 64) 'userID/machineID re-randomized'
Ok (-not $j.PSObject.Properties['oauthAccount'] -and -not $j.PSObject.Properties['clientDataCacheSlots']) 'oauth/cache keys removed'
Ok ($j.projects.p -eq 1 -and $j.mcpServers.keep.command -eq 'x') '.claude.json projects/mcpServers kept'
$c = Get-Content "$dot/.credentials.json" -Raw | ConvertFrom-Json; Ok (-not $c.PSObject.Properties['claudeAiOauth'] -and $c.other -eq 1) 'token removed, rest kept'
$d = Get-Content "$ap/claude_desktop_config.json" -Raw | ConvertFrom-Json; Ok ($d.mcpServers.keep.command -eq 'y' -and -not $d.preferences.PSObject.Properties[$uuid] -and $d.preferences.keepme -eq 1) 'desktop mcpServers kept, uuid keys purged'
$cf = Get-Content "$ap/config.json" -Raw | ConvertFrom-Json; Ok ($cf.theme -eq 'dark' -and -not $cf.PSObject.Properties['oauth:tokenCache']) 'desktop config login keys removed'
Ok ((Get-ChildItem "$h/.fresh-device/backups" -Recurse -File | Measure-Object).Count -gt 5) 'backups written'

Write-Output "T4 check after clean must PASS"
$r = Run @('-Mode', 'check'); Ok ($r.Code -eq 0 -and $r.Out -match 'GATE: PASS') 'gate PASS'

Write-Output "T5 running-process guard is bypassed only in sandbox (nothing to assert); corrupt json is rebuilt"
Mk "$h/.claude.json" '{not json'; $r = Run @('-Mode', 'clean', '-Apply'); Ok ($r.Code -eq 0 -and -not (Test-Path "$h/.claude.json")) 'corrupt .claude.json moved to backup'

Remove-Item $h -Recurse -Force
if ($fail) { Write-Output "FAILED: $fail"; exit 1 } else { Write-Output 'ALL PASS'; exit 0 }
