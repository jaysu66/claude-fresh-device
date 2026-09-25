// scan-sqlite.cjs — 只读扫描本机 Chromium/Electron SQLite 库里的指纹信息
// 用法: node scripts/scan-sqlite.cjs
// 原理: 复制目标 DB(含 -wal/-shm)到临时目录后用 node:sqlite 只读打开,
//       列出全部表 + 抽取和"身份/指纹"相关的行。绝不改原文件。
const fs = require('fs'), path = require('path'), os = require('os');
const { DatabaseSync } = require('node:sqlite');

const A = process.env.APPDATA, L = process.env.LOCALAPPDATA;
const targets = [];
const add = (label, f) => targets.push([label, f]);

// Claude Desktop(Electron)
add('Claude Desktop Cookies', `${A}\\Claude\\Network\\Cookies`);
add('Claude Desktop DIPS', `${A}\\Claude\\DIPS`);
add('Claude perf-observer.db', `${A}\\Claude\\declarative_performance_observer.db`);
// Electron partition 各自一套 Cookies
const partRoot = `${A}\\Claude\\Partitions`;
if (fs.existsSync(partRoot)) {
  for (const sub of fs.readdirSync(partRoot)) {
    for (const cand of [`${sub}\\Network\\Cookies`, `${sub}\\Cookies`])
      add(`Claude Partition ${sub} Cookies`, `${partRoot}\\${cand}`);
  }
}
// ~/.codex 里的散落 .sqlite/.db + Claude 目录下的其它 .db
const H = process.env.USERPROFILE;
const extraRoots = [`${H}\\.codex`, `${A}\\Claude`];
for (const root of extraRoots) {
  const walk = (d, depth) => {
    if (depth > 2) return;
    let es; try { es = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of es) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p, depth + 1);
      else if (/\.(sqlite\d?|db)$/i.test(e.name) && !/-(wal|shm|journal)$/i.test(e.name))
        add(`misc:${e.name}`, p);
    }
  };
  walk(root, 0);
}
// Chrome / Edge 所有 profile
for (const [browser, root] of [['Chrome', `${L}\\Google\\Chrome\\User Data`], ['Edge', `${L}\\Microsoft\\Edge\\User Data`]]) {
  if (!fs.existsSync(root)) continue;
  for (const prof of fs.readdirSync(root).filter(d => /^(Default|Profile \d+|Guest Profile)$/.test(d))) {
    add(`${browser} ${prof} Cookies`, `${root}\\${prof}\\Network\\Cookies`);
    add(`${browser} ${prof} Web Data`, `${root}\\${prof}\\Web Data`);
    add(`${browser} ${prof} Login Data`, `${root}\\${prof}\\Login Data`);
    add(`${browser} ${prof} History`, `${root}\\${prof}\\History`);
    add(`${browser} ${prof} DIPS`, `${root}\\${prof}\\DIPS`);
  }
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fpscan-'));
const isSqlite = f => {
  let fd;
  try { fd = fs.openSync(f, 'r'); } catch { return 'locked'; }
  const b = Buffer.alloc(16);
  try { fs.readSync(fd, b, 0, 16, 0); } catch { fs.closeSync(fd); return 'locked'; }
  fs.closeSync(fd);
  return b.toString('latin1').startsWith('SQLite format 3');
};
const openCopy = f => {
  const d = path.join(tmp, Math.random().toString(36).slice(2));
  fs.mkdirSync(d);
  const c = path.join(d, 'db');
  for (const s of ['', '-wal', '-shm']) { try { if (fs.existsSync(f + s)) fs.copyFileSync(f + s, c + s); } catch {} }
  if (!fs.existsSync(c)) throw new Error('copy blocked');
  return new DatabaseSync(c);
};
// 打开顺序:副本 → 原文件只读 → immutable;全失败返回 null
const tryOpen = f => {
  try { return openCopy(f); } catch {}
  try { return new DatabaseSync(f, { readOnly: true }); } catch {}
  try { return new DatabaseSync('file:' + f.replace(/\\/g, '/') + '?immutable=1', { readOnly: true }); } catch {}
  return null;
};
const ts = col => `datetime(${col}/1000000-11644473600,'unixepoch')`;
const ID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[\w.+-]+@[\w-]+\.[a-z]{2,}/gi;
const pullIds = (obj, depth) => {
  const s = typeof obj === 'string' ? obj : JSON.stringify(obj);
  return [...new Set(s.match(ID_RE) || [])];
};

for (const [label, f] of targets) {
  if (!fs.existsSync(f)) continue;
  let head = `\n##### ${label}\n  ${f} (${(fs.statSync(f).size / 1024).toFixed(0)}KB)`;
  const st = isSqlite(f);
  if (st !== true && st !== 'locked') { console.log(head + '  [非 SQLite]'); continue; }
  if (st === 'locked') head += '  [文件被进程锁定,尝试只读兜底]';
  console.log(head);
  const db = tryOpen(f);
  if (!db) { console.log('  [无法打开:被进程独占锁定,需先退进程]'); continue; }
  const q = sql => { try { return db.prepare(sql).all(); } catch { return null; } };
  const tables = (q("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name") || []).map(r => r.name);
  console.log('  tables: ' + tables.join(', '));

  if (tables.includes('cookies')) {
    const n = q('SELECT COUNT(*) c FROM cookies');
    console.log(`  cookies 总数: ${n?.[0]?.c}`);
    const rows = q(`SELECT host_key,name,${ts('expires_utc')} exp FROM cookies
      WHERE host_key LIKE '%claude%' OR host_key LIKE '%anthropic%' OR host_key LIKE '%sentry%'
         OR host_key LIKE '%openai%' OR host_key LIKE '%chatgpt%' ORDER BY host_key LIMIT 80`) || [];
    for (const r of rows) console.log(`  [cookie] ${r.host_key} | ${r.name} | exp=${r.exp}`);
  }
  if (tables.includes('bounces')) { // DIPS
    const rows = q(`SELECT site, ${ts('first_site_storage_time')} fst, ${ts('last_site_storage_time')} lst FROM bounces ORDER BY last_site_storage_time DESC LIMIT 30`) || [];
    for (const r of rows) console.log(`  [dips] ${r.site}  first=${r.fst} last=${r.lst}`);
  }
  if (tables.includes('autofill')) {
    const rows = q('SELECT name, value, count FROM autofill ORDER BY count DESC LIMIT 30') || [];
    for (const r of rows) console.log(`  [autofill] ${r.name} = ${r.value}`);
  }
  if (tables.includes('autofill_profile_emails')) {
    const rows = q('SELECT email FROM autofill_profile_emails LIMIT 20') || [];
    for (const r of rows) console.log(`  [autofill_email] ${r.email}`);
  }
  if (tables.includes('logins')) {
    const rows = q('SELECT origin_url, username_value FROM logins WHERE username_value != \'\' LIMIT 40') || [];
    for (const r of rows) console.log(`  [login] ${r.origin_url} | user=${r.username_value}`);
  }
  if (tables.includes('urls')) { // History
    const rows = q(`SELECT url,title,visit_count FROM urls WHERE url LIKE '%claude%' OR url LIKE '%anthropic%' ORDER BY last_visit_time DESC LIMIT 20`) || [];
    for (const r of rows) console.log(`  [history] ${r.url} | ${(r.title || '').slice(0, 40)} | visits=${r.visit_count}`);
  }
  // meta 表里的版本/伪随机种子也偶尔藏 id
  if (tables.includes('meta')) {
    const rows = q("SELECT key,value FROM meta WHERE key LIKE '%id%' OR key LIKE '%guid%' LIMIT 20") || [];
    for (const r of rows) console.log(`  [meta] ${r.key} = ${String(r.value).slice(0, 80)}`);
  }
  db.close();
}

// LevelDB / 其它二进制里的明文标识(Local Storage .log/.ldb, sentry json 等)
console.log('\n##### LevelDB / 二进制明文标识扫描(Claude Desktop 目录)');
const scanDirs = [`${A}\\Claude\\Local Storage`, `${A}\\Claude\\Session Storage`,
  `${A}\\Claude\\IndexedDB`, `${A}\\Claude\\sentry`, `${A}\\Claude\\Partitions`];
const interesting = /(distinct_id|device_?id|machine_?id|account_?uuid|org_?uuid|session_?key|user_?id|email|did|anthropic|claude\.ai)/i;
let hits = 0;
const walk = function* (d, depth) {
  if (depth > 4 || hits > 60) return;
  let es; try { es = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
  for (const e of es) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) yield* walk(p, depth + 1);
    else if (/\.(log|ldb|json|localstorage|state)$/i.test(e.name) && fs.statSync(p).size < 4e6) yield p;
  }
};
for (const root of scanDirs) {
  if (!fs.existsSync(root)) continue;
  for (const f of walk(root, 0)) {
    if (hits > 60) break;
    let buf; try { buf = fs.readFileSync(f); } catch { continue; }
    const txt = buf.toString('latin1');
    const lines = txt.split(/[\x00-\x08\x0b-\x1f]+/);
    const fileHits = [];
    for (const ln of lines) {
      if (ln.length > 8 && ln.length < 400 && interesting.test(ln)) {
        const ids = pullIds(ln);
        fileHits.push(ln.replace(/[^\x20-\x7e]/g, ' ').replace(/\s+/g, ' ').slice(0, 180) +
          (ids.length ? '  <<IDS: ' + ids.slice(0, 5).join(', ') + '>>' : ''));
        if (fileHits.length >= 6) break;
      }
    }
    if (fileHits.length) {
      hits += fileHits.length;
      console.log(`  --- ${f.replace(A, '%APPDATA%')}`);
      for (const h of fileHits) console.log('      ' + h);
    }
  }
}
console.log(`\n完成。临时副本在 ${tmp}(可删)`);
