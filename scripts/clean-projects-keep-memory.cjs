// clean-projects-keep-memory.cjs — 清 ~/.claude/projects/<项目>/ 下除 memory/ 外的会话数据
// 由 clean.ps1 -WipeHistory 调用;也可单独: node clean-projects-keep-memory.cjs
// 删除: *.jsonl 对话记录、tool-results/、subagents/ 等会话运行时
// 保留: projects/<项目>/memory/**(项目记忆是用户资产,不是指纹)
const fs = require('fs');
const path = require('path');
const homedir = require('os').homedir();
const root = process.argv[2] || path.join(homedir, '.claude', 'projects');

let removed = 0;
function rm(t) { try { fs.rmSync(t, { recursive: true, force: true }); return true } catch { return false } }

if (!fs.existsSync(root)) { console.log('projects 目录不存在: ' + root); process.exit(0) }
for (const proj of fs.readdirSync(root)) {
  const pp = path.join(root, proj);
  let st; try { st = fs.statSync(pp) } catch { continue }
  if (!st.isDirectory()) continue;
  for (const e of fs.readdirSync(pp)) {
    if (e === 'memory') continue;
    if (rm(path.join(pp, e))) removed++;
  }
}
console.log('projects 会话数据已清(保留全部 memory),删除条目: ' + removed);
