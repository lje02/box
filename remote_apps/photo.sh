#!/usr/bin/env bash
# ============================================================
#  📷 Photo Album 全栈版 — Express + SQLite + React
#  多人公网浏览，JWT 鉴权后台管理
#  用法：bash install.sh [--dev | --build | --start]
#    --dev    启动开发模式（热更新，双进程）
#    --build  仅构建前端产物
#    --start  构建 + 启动生产服务器（默认）
# ============================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✔ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
error()   { echo -e "${RED}✖ $*${RESET}" >&2; exit 1; }

MODE="${1:---start}"
INSTALL_DIR="photo-album"

echo ""
echo -e "${BOLD}  📷 Photo Album 全栈版${RESET}"
echo -e "  ─────────────────────────────────"
echo -e "  后端：Express  ·  数据库：SQLite"
echo -e "  认证：JWT      ·  前端：React + Vite"
echo -e "  ─────────────────────────────────"
echo ""

# ── 检查 Node.js ──
if ! command -v node &>/dev/null; then
  error "未找到 Node.js，请先安装 Node.js 18+：https://nodejs.org"
fi
node -e "if(parseInt(process.versions.node)<18)process.exit(1)" \
  || error "Node.js 版本过低（需要 18+），当前：$(node -v)"
success "Node.js $(node -v)"

if ! command -v npm &>/dev/null; then
  error "未找到 npm，请重新安装 Node.js"
fi
success "npm $(npm -v)"

# ── 创建目录 ──
if [ -d "$INSTALL_DIR" ]; then
  warn "目录 $INSTALL_DIR 已存在，将覆盖文件（数据库不受影响）"
else
  mkdir -p "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"
mkdir -p src data

info "正在写入项目文件..."

# ────────────────────────────────────────
#  package.json
# ────────────────────────────────────────
cat > package.json << 'PKGJSON'
{
  "name": "photo-album",
  "private": true,
  "version": "2.0.0",
  "type": "module",
  "scripts": {
    "dev":         "concurrently -n SRV,WEB -c cyan,yellow \"node server.js\" \"vite\"",
    "dev:server":  "node --watch server.js",
    "build":       "vite build",
    "start":       "node server.js",
    "build:start": "vite build && node server.js"
  },
  "dependencies": {
    "better-sqlite3": "^11.7.0",
    "express":        "^4.19.2",
    "jsonwebtoken":   "^9.0.2",
    "react":          "^18.3.1",
    "react-dom":      "^18.3.1"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.4",
    "concurrently":         "^9.1.2",
    "vite":                 "^6.0.7"
  }
}
PKGJSON

# ────────────────────────────────────────
#  vite.config.js
# ────────────────────────────────────────
cat > vite.config.js << 'VITECFG'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    host: true,
    proxy: {
      '/api': { target: 'http://localhost:3000', changeOrigin: true }
    }
  },
  build:   { outDir: 'dist', sourcemap: false },
  preview: { port: 3000, host: true }
})
VITECFG

# ────────────────────────────────────────
#  server.js  （Express + SQLite 后端）
# ────────────────────────────────────────
cat > server.js << 'SERVERJS'
import express            from 'express'
import Database           from 'better-sqlite3'
import jwt                from 'jsonwebtoken'
import crypto             from 'crypto'
import { fileURLToPath }  from 'url'
import { dirname, join }  from 'path'
import { existsSync, mkdirSync } from 'fs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const PORT      = process.env.PORT || 3000
const DATA_DIR  = join(__dirname, 'data')
if (!existsSync(DATA_DIR)) mkdirSync(DATA_DIR, { recursive: true })

/* ── 数据库初始化 ─────────────────────────── */
const db = new Database(join(DATA_DIR, 'album.db'))
db.pragma('journal_mode = WAL')
db.pragma('foreign_keys = ON')

db.exec(`
  CREATE TABLE IF NOT EXISTS albums (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    cover       TEXT DEFAULT '',
    category    TEXT DEFAULT '',
    tags        TEXT DEFAULT '[]',
    description TEXT DEFAULT '',
    photo_count INTEGER DEFAULT 0,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS categories (
    name       TEXT PRIMARY KEY,
    sort_order INTEGER DEFAULT 0
  );
  CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );
`)

/* ── 默认设置（首次运行写入）─────────────── */
const insSet = db.prepare('INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)')
;[
  ['siteTitle',     '我的相册'],
  ['albumsPerPage', '6'],
  ['adminPassword', 'admin123'],
  ['jwtSecret',     crypto.randomBytes(40).toString('hex')]
].forEach(([k, v]) => insSet.run(k, v))

/* ── 默认分类 ─────────────────────────────── */
const insCat = db.prepare('INSERT OR IGNORE INTO categories (name, sort_order) VALUES (?, ?)')
;['旅行', '城市', '自然', '美食', '家庭'].forEach((n, i) => insCat.run(n, i))

/* ── 示例相册（仅首次）────────────────────── */
if (!db.prepare('SELECT 1 FROM albums LIMIT 1').get()) {
  const ins = db.prepare(`INSERT INTO albums
    (id,title,cover,category,tags,description,photo_count,created_at,updated_at)
    VALUES (?,?,?,?,?,?,?,?,?)`)
  ;[
    ['a1','西藏高原之旅',
      'https://images.unsplash.com/photo-1506905925346-21bda4d32df4?w=800&q=80',
      '旅行', JSON.stringify(['西藏','高原','寺庙','风景']),
      '2024年夏天走进西藏，感受高原的壮阔与宁静，探访布达拉宫与古老寺庙。',
      48,'2024-09-10T10:00:00Z','2024-09-10T10:00:00Z'],
    ['a2','上海夜景',
      'https://images.unsplash.com/photo-1474181487882-5abf3f0ba6c2?w=800&q=80',
      '城市', JSON.stringify(['上海','夜景','外滩']),
      '霓虹璀璨的魔都夜晚，漫步外滩，感受这座城市的脉搏。',
      41,'2024-08-22T10:00:00Z','2024-08-22T10:00:00Z'],
    ['a3','云南丽江',
      'https://images.unsplash.com/photo-1537531700788-d82ce5f3bebb?w=800&q=80',
      '旅行', JSON.stringify(['云南','丽江','古城','纳西族']),
      '漫步丽江古城，感受纳西族文化的独特魅力，品尝地道云南美食。',
      67,'2024-07-05T10:00:00Z','2024-07-05T10:00:00Z'],
    ['a4','春日花海',
      'https://images.unsplash.com/photo-1490750967868-88df5691166a?w=800&q=80',
      '自然', JSON.stringify(['花卉','春天','摄影','油菜花']),
      '春天里最美的花朵盛开，漫山遍野的色彩令人心旷神怡。',
      56,'2024-04-10T10:00:00Z','2024-04-10T10:00:00Z'],
    ['a5','成都美食记录',
      'https://images.unsplash.com/photo-1569050467447-ce54b3bbc37d?w=800&q=80',
      '美食', JSON.stringify(['成都','川菜','火锅','小吃']),
      '走遍成都大街小巷，寻访地道川味，记录每一份令人难忘的美食。',
      32,'2024-03-18T10:00:00Z','2024-03-18T10:00:00Z'],
    ['a6','家庭聚会 2024',
      'https://images.unsplash.com/photo-1511988617509-a57c8a288659?w=800&q=80',
      '家庭', JSON.stringify(['家庭','聚会','春节','温馨']),
      '春节家庭大聚会，温馨时刻永久留存，记录最美好的团圆记忆。',
      89,'2024-02-10T10:00:00Z','2024-02-10T10:00:00Z'],
  ].forEach(row => ins.run(...row))
}

/* ── 工具函数 ─────────────────────────────── */
const getSetting = k  => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value
const getSecret  = () => getSetting('jwtSecret')
const mapAlbum   = r  => ({
  id: r.id, title: r.title, cover: r.cover,
  category: r.category, description: r.description,
  tags: JSON.parse(r.tags || '[]'),
  photoCount: r.photo_count,
  createdAt:  r.created_at,
  updatedAt:  r.updated_at
})

/* ── 简易限流（防暴力破解登录）────────────── */
const _attempts = new Map()
function loginRateLimit(ip) {
  const now = Date.now()
  let rec = _attempts.get(ip)
  if (!rec || now > rec.reset) rec = { count: 0, reset: now + 60_000 }
  rec.count++
  _attempts.set(ip, rec)
  return rec.count > 10   // 每分钟最多 10 次
}

/* ── JWT 中间件 ───────────────────────────── */
function requireAdmin(req, res, next) {
  const auth = req.headers.authorization
  if (!auth?.startsWith('Bearer ')) return res.status(401).json({ error: '未授权' })
  try {
    jwt.verify(auth.slice(7), getSecret())
    next()
  } catch {
    res.status(401).json({ error: 'Token 无效或已过期，请重新登录' })
  }
}

/* ── Express ─────────────────────────────── */
const app = express()
app.use(express.json({ limit: '2mb' }))

// CORS（允许公网跨域访问，生产中可收窄为特定域名）
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin',  '*')
  res.header('Access-Control-Allow-Methods', 'GET,POST,PUT,DELETE,OPTIONS')
  res.header('Access-Control-Allow-Headers', 'Content-Type,Authorization')
  if (req.method === 'OPTIONS') return res.sendStatus(200)
  next()
})

/* ── 路由：认证 ───────────────────────────── */
app.post('/api/auth/login', (req, res) => {
  const ip = req.ip || req.socket?.remoteAddress || 'unknown'
  if (loginRateLimit(ip)) return res.status(429).json({ error: '尝试过于频繁，请 1 分钟后再试' })
  const { password } = req.body || {}
  if (!password || password !== getSetting('adminPassword'))
    return res.status(401).json({ error: '密码错误，请重试' })
  const token = jwt.sign({ role: 'admin' }, getSecret(), { expiresIn: '7d' })
  res.json({ token })
})

app.get('/api/auth/verify', requireAdmin, (_, res) => res.json({ ok: true }))

/* ── 路由：相册（公开读取）─────────────────── */
app.get('/api/albums', (_, res) => {
  res.json(db.prepare('SELECT * FROM albums ORDER BY updated_at DESC').all().map(mapAlbum))
})

app.post('/api/albums', requireAdmin, (req, res) => {
  const { title='', cover='', category='', tags=[], description='', photoCount=0 } = req.body || {}
  if (!title.trim()) return res.status(400).json({ error: '相册名称不能为空' })
  const id  = Date.now().toString(36) + Math.random().toString(36).slice(2, 7)
  const now = new Date().toISOString()
  db.prepare(`INSERT INTO albums (id,title,cover,category,tags,description,photo_count,created_at,updated_at)
    VALUES (?,?,?,?,?,?,?,?,?)`).run(id, title.trim(), cover, category, JSON.stringify(tags), description, photoCount|0, now, now)
  res.status(201).json({ id })
})

app.put('/api/albums/:id', requireAdmin, (req, res) => {
  const { title='', cover='', category='', tags=[], description='', photoCount=0 } = req.body || {}
  if (!title.trim()) return res.status(400).json({ error: '相册名称不能为空' })
  const now = new Date().toISOString()
  const r = db.prepare(`UPDATE albums
    SET title=?,cover=?,category=?,tags=?,description=?,photo_count=?,updated_at=?
    WHERE id=?`).run(title.trim(), cover, category, JSON.stringify(tags), description, photoCount|0, now, req.params.id)
  if (!r.changes) return res.status(404).json({ error: '相册不存在' })
  res.json({ ok: true })
})

app.delete('/api/albums/:id', requireAdmin, (req, res) => {
  db.prepare('DELETE FROM albums WHERE id=?').run(req.params.id)
  res.json({ ok: true })
})

/* ── 路由：分类（公开读取）─────────────────── */
app.get('/api/categories', (_, res) => {
  res.json(db.prepare('SELECT name FROM categories ORDER BY sort_order,name').all().map(r => r.name))
})

app.post('/api/categories', requireAdmin, (req, res) => {
  const { name='' } = req.body || {}
  if (!name.trim()) return res.status(400).json({ error: '分类名不能为空' })
  const max = db.prepare('SELECT MAX(sort_order) as m FROM categories').get()?.m || 0
  try {
    db.prepare('INSERT INTO categories (name,sort_order) VALUES (?,?)').run(name.trim(), max + 1)
    res.status(201).json({ ok: true })
  } catch {
    res.status(409).json({ error: '该分类已存在' })
  }
})

app.delete('/api/categories/:name', requireAdmin, (req, res) => {
  db.prepare('DELETE FROM categories WHERE name=?').run(decodeURIComponent(req.params.name))
  res.json({ ok: true })
})

/* ── 路由：设置 ───────────────────────────── */
// 公开：仅返回前台展示所需字段
app.get('/api/settings', (_, res) => {
  res.json({
    siteTitle:     getSetting('siteTitle'),
    albumsPerPage: parseInt(getSetting('albumsPerPage')) || 6
  })
})

// 管理员：含敏感字段
app.get('/api/settings/admin', requireAdmin, (_, res) => {
  res.json({
    siteTitle:     getSetting('siteTitle'),
    albumsPerPage: parseInt(getSetting('albumsPerPage')) || 6,
    adminPassword: getSetting('adminPassword')
  })
})

app.put('/api/settings', requireAdmin, (req, res) => {
  const upd = db.prepare('INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)')
  const { siteTitle, albumsPerPage, adminPassword } = req.body || {}
  if (siteTitle     !== undefined) upd.run('siteTitle',     siteTitle)
  if (albumsPerPage !== undefined) upd.run('albumsPerPage', String(albumsPerPage))
  if (adminPassword?.trim())       upd.run('adminPassword', adminPassword.trim())
  res.json({ ok: true })
})

/* ── 服务前端静态文件（生产模式）────────────── */
const distPath = join(__dirname, 'dist')
if (existsSync(distPath)) {
  app.use(express.static(distPath))
  app.get('*', (_, res) => res.sendFile(join(distPath, 'index.html')))
}

app.listen(PORT, '0.0.0.0', () => {
  console.log(`\n  📷 Photo Album 全栈版已启动`)
  console.log(`  ─────────────────────────────`)
  console.log(`  前台访问：http://localhost:${PORT}`)
  console.log(`  后台入口：http://localhost:${PORT}/#admin`)
  console.log(`  管理密码：${getSetting('adminPassword')}`)
  console.log(`  数据文件：${join(DATA_DIR, 'album.db')}`)
  console.log(`  ─────────────────────────────\n`)
})
SERVERJS

# ────────────────────────────────────────
#  index.html
# ────────────────────────────────────────
cat > index.html << 'INDEXHTML'
<!DOCTYPE html>
<html lang="zh-CN">
  <head>
    <meta charset="UTF-8" />
    <link rel="icon" type="image/svg+xml"
      href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>📷</text></svg>" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>我的相册</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
INDEXHTML

# ────────────────────────────────────────
#  src/main.jsx
# ────────────────────────────────────────
cat > src/main.jsx << 'MAINJSX'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App.jsx'

createRoot(document.getElementById('root')).render(
  <StrictMode><App /></StrictMode>
)
MAINJSX

# ────────────────────────────────────────
#  src/App.jsx
# ────────────────────────────────────────
cat > src/App.jsx << 'APPJSX'
import { useState, useEffect, useCallback } from "react";

const ADMIN_HASH = "#admin";

function fmtDate(iso) {
  return new Date(iso).toLocaleDateString("zh-CN", { year: "numeric", month: "short", day: "numeric" });
}

/* ── 全局样式 ───────────────────────────────── */
const css = `
@import url('https://fonts.googleapis.com/css2?family=Noto+Serif+SC:wght@400;500;600&family=Noto+Sans+SC:wght@300;400;500&display=swap');
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#F7F5F0;--bg2:#EFEDE7;--bg3:#E8E5DC;--surface:#FFFFFF;
  --border:rgba(0,0,0,0.09);--text:#1C1C1A;--text2:#6B6860;--text3:#AAA89F;
  --accent:#2D2D2A;--accent-light:#F0EDE5;--red:#C0392B;--red-light:#FDF2F0;
  --sidebar-w:210px;--header-h:54px;--radius:10px;--radius-sm:6px;
  --transition:0.22s cubic-bezier(0.4,0,0.2,1);
}
body{font-family:'Noto Sans SC',-apple-system,sans-serif;background:var(--bg);color:var(--text);font-size:14px;-webkit-font-smoothing:antialiased}
::-webkit-scrollbar{width:4px;height:4px}::-webkit-scrollbar-track{background:transparent}::-webkit-scrollbar-thumb{background:var(--bg3);border-radius:4px}
.hdr{position:sticky;top:0;z-index:100;height:var(--header-h);background:rgba(247,245,240,0.92);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between;padding:0 1.25rem 0 0.75rem;gap:.75rem}
.hdr-left{display:flex;align-items:center;gap:.5rem}
.sidebar-toggle{width:34px;height:34px;border:none;background:transparent;cursor:pointer;border-radius:var(--radius-sm);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:5px;transition:background var(--transition);flex-shrink:0}
.sidebar-toggle:hover{background:var(--bg3)}
.sidebar-toggle span{display:block;width:18px;height:1.5px;background:var(--text);border-radius:2px;transition:transform var(--transition),opacity var(--transition),width var(--transition)}
.sidebar-toggle.open span:nth-child(1){transform:translateY(6.5px) rotate(45deg)}
.sidebar-toggle.open span:nth-child(2){opacity:0;width:0}
.sidebar-toggle.open span:nth-child(3){transform:translateY(-6.5px) rotate(-45deg)}
.hdr-title{font-family:'Noto Serif SC',serif;font-size:16px;font-weight:500;letter-spacing:.5px;white-space:nowrap}
.hdr-search{flex:1;max-width:280px;position:relative}
.hdr-search input{width:100%;padding:6px 10px 6px 32px;background:var(--bg3);border:1px solid transparent;border-radius:20px;font-size:13px;color:var(--text);outline:none;transition:all var(--transition);font-family:inherit}
.hdr-search input::placeholder{color:var(--text3)}
.hdr-search input:focus{background:var(--surface);border-color:var(--border);box-shadow:0 2px 8px rgba(0,0,0,.06)}
.hdr-search-icon{position:absolute;left:10px;top:50%;transform:translateY(-50%);color:var(--text3);font-size:13px;pointer-events:none}
.layout{display:flex;min-height:calc(100vh - var(--header-h))}
.sidebar-wrap{position:sticky;top:var(--header-h);height:calc(100vh - var(--header-h));flex-shrink:0;overflow:hidden;width:var(--sidebar-w);transition:width var(--transition);z-index:50}
.sidebar-wrap.collapsed{width:0}
.sidebar{width:var(--sidebar-w);height:100%;background:var(--bg2);border-right:1px solid var(--border);padding:1rem .65rem;overflow-y:auto;overflow-x:hidden;display:flex;flex-direction:column;gap:1.5rem}
@media(max-width:768px){
  .sidebar-wrap{position:fixed;top:var(--header-h);left:0;height:calc(100vh - var(--header-h));width:var(--sidebar-w) !important;transform:translateX(-100%);transition:transform var(--transition);z-index:200;box-shadow:none}
  .sidebar-wrap.mobile-open{transform:translateX(0);box-shadow:4px 0 20px rgba(0,0,0,.12)}
  .sidebar-overlay{position:fixed;inset:0;background:rgba(0,0,0,.3);z-index:199;top:var(--header-h)}
}
.sb-section-label{font-size:10px;font-weight:500;letter-spacing:1.2px;text-transform:uppercase;color:var(--text3);padding:0 6px;margin-bottom:6px}
.cat-item{display:flex;align-items:center;justify-content:space-between;padding:6px 9px;border-radius:var(--radius-sm);cursor:pointer;font-size:13px;color:var(--text2);transition:all var(--transition);user-select:none;white-space:nowrap}
.cat-item:hover{background:var(--bg3);color:var(--text)}
.cat-item.active{background:var(--accent);color:#F7F5F0}
.cat-count{font-size:11px;opacity:.5;background:rgba(0,0,0,.06);padding:1px 6px;border-radius:20px}
.cat-item.active .cat-count{background:rgba(255,255,255,.15);opacity:1}
.tag-wrap{display:flex;flex-wrap:wrap;gap:5px;padding:0 2px}
.tag-btn{font-size:11px;padding:3px 9px;border-radius:20px;background:var(--bg3);color:var(--text2);border:1px solid transparent;cursor:pointer;transition:all var(--transition);font-family:inherit;white-space:nowrap}
.tag-btn:hover{background:var(--accent-light);color:var(--accent)}
.tag-btn.active{background:var(--accent);color:#F7F5F0;border-color:var(--accent)}
.main{flex:1;min-width:0;padding:1.25rem 1.5rem 2rem;transition:all var(--transition)}
.main-header{display:flex;align-items:center;justify-content:space-between;margin-bottom:1.25rem;gap:.75rem;flex-wrap:wrap}
.main-info{font-size:13px;color:var(--text3)}
.main-info strong{color:var(--text2);font-weight:500}
.clear-btn{font-size:11px;padding:4px 10px;border-radius:20px;background:var(--bg3);border:none;cursor:pointer;color:var(--text2);font-family:inherit;transition:all var(--transition)}
.clear-btn:hover{background:var(--red-light);color:var(--red)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:1rem}
@media(max-width:480px){.grid{grid-template-columns:repeat(2,1fr);gap:.65rem}.main{padding:1rem .85rem 2rem}}
.card{background:var(--surface);border-radius:var(--radius);border:1px solid var(--border);overflow:hidden;cursor:pointer;transition:transform var(--transition),box-shadow var(--transition)}
.card:hover{transform:translateY(-4px);box-shadow:0 14px 32px rgba(0,0,0,.10)}
.card:active{transform:translateY(-1px)}
.card-img{width:100%;aspect-ratio:4/3;object-fit:cover;display:block;background:var(--bg3)}
.card-no-img{width:100%;aspect-ratio:4/3;background:var(--bg3);display:flex;align-items:center;justify-content:center;font-size:32px}
.card-body{padding:.7rem .85rem .85rem}
.card-title{font-size:13px;font-weight:500;margin-bottom:6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.card-footer{display:flex;align-items:center;justify-content:space-between}
.badge{font-size:10px;padding:2px 7px;border-radius:20px;background:var(--accent-light);color:var(--text2)}
.card-count{font-size:11px;color:var(--text3)}
.card-date{font-size:11px;color:var(--text3);margin-top:4px}
.pager{display:flex;align-items:center;justify-content:center;gap:5px;margin-top:2rem}
.pager-btn{width:32px;height:32px;border-radius:var(--radius-sm);border:1px solid var(--border);background:var(--surface);cursor:pointer;font-size:13px;color:var(--text2);display:flex;align-items:center;justify-content:center;transition:all var(--transition);font-family:inherit}
.pager-btn:hover:not(:disabled){background:var(--bg3)}
.pager-btn.active{background:var(--accent);color:#F7F5F0;border-color:var(--accent)}
.pager-btn:disabled{opacity:.3;cursor:default}
.empty{text-align:center;padding:4rem 1rem;color:var(--text3)}
.empty-icon{font-size:40px;margin-bottom:.75rem;opacity:.6}
.empty-txt{font-size:14px}
.overlay{position:fixed;inset:0;background:rgba(20,20,18,.6);display:flex;align-items:center;justify-content:center;z-index:500;padding:1rem;backdrop-filter:blur(4px);animation:fadeIn .15s ease}
@keyframes fadeIn{from{opacity:0}to{opacity:1}}
.modal{background:var(--surface);border-radius:14px;width:100%;max-width:540px;overflow:hidden;max-height:90vh;overflow-y:auto;animation:slideUp .2s cubic-bezier(0.34,1.2,0.64,1);box-shadow:0 24px 60px rgba(0,0,0,.2)}
@keyframes slideUp{from{transform:translateY(20px);opacity:0}to{transform:translateY(0);opacity:1}}
.modal-img{width:100%;aspect-ratio:16/9;object-fit:cover;display:block}
.modal-body{padding:1.25rem 1.5rem 1.5rem}
.modal-top{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:10px}
.modal-title{font-family:'Noto Serif SC',serif;font-size:20px;font-weight:500;line-height:1.3}
.modal-close{width:30px;height:30px;border-radius:50%;background:var(--bg3);border:none;cursor:pointer;font-size:16px;color:var(--text2);display:flex;align-items:center;justify-content:center;transition:all var(--transition);flex-shrink:0;margin-left:.75rem}
.modal-close:hover{background:var(--bg);color:var(--text)}
.modal-meta{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:.75rem}
.modal-desc{font-size:13px;color:var(--text2);line-height:1.7}
.modal-tags{display:flex;flex-wrap:wrap;gap:5px;margin-top:1rem}
.btn{padding:6px 14px;border-radius:var(--radius-sm);font-size:12px;border:1px solid var(--border);background:var(--surface);cursor:pointer;color:var(--text2);transition:all var(--transition);display:inline-flex;align-items:center;gap:5px;font-family:inherit;white-space:nowrap}
.btn:hover{background:var(--bg3);color:var(--text)}
.btn:disabled{opacity:.5;cursor:default}
.btn-dark{background:var(--accent);color:#F7F5F0;border-color:var(--accent)}
.btn-dark:hover:not(:disabled){background:#3A3A36}
.btn-red{background:var(--red-light);color:var(--red);border-color:#F5C6C2}
.btn-red:hover{background:#FBEAE8}
.btn-sm{padding:4px 10px;font-size:11px}
.login-wrap{min-height:100vh;display:flex;align-items:center;justify-content:center;background:var(--bg)}
.login-box{background:var(--surface);border-radius:14px;padding:2rem;border:1px solid var(--border);width:100%;max-width:320px;box-shadow:0 8px 32px rgba(0,0,0,.07)}
.login-title{font-family:'Noto Serif SC',serif;font-size:20px;font-weight:500;margin-bottom:1.5rem}
.err{font-size:11px;color:var(--red);margin-top:5px}
.adm-layout{display:flex;min-height:100vh}
.adm-sb{width:190px;background:#1A1A18;color:#F7F5F0;padding:1.25rem .75rem;flex-shrink:0;display:flex;flex-direction:column;gap:3px;position:sticky;top:0;height:100vh;overflow-y:auto}
.adm-sb-title{font-family:'Noto Serif SC',serif;font-size:15px;font-weight:500;padding:0 8px;margin-bottom:1rem}
.adm-nav{padding:7px 10px;border-radius:var(--radius-sm);cursor:pointer;font-size:13px;color:#8A8A84;transition:all var(--transition);display:flex;align-items:center;gap:7px}
.adm-nav:hover{background:rgba(255,255,255,.07);color:#F7F5F0}
.adm-nav.active{background:rgba(255,255,255,.11);color:#F7F5F0}
.adm-spacer{flex:1}
.adm-divider{height:1px;background:rgba(255,255,255,.08);margin:.5rem 0}
.adm-main{flex:1;padding:1.75rem 2rem;background:var(--bg);min-width:0}
.adm-header{display:flex;align-items:center;justify-content:space-between;margin-bottom:1.5rem}
.adm-title{font-family:'Noto Serif SC',serif;font-size:18px;font-weight:500}
@media(max-width:640px){.adm-sb{width:160px}.adm-main{padding:1rem}}
.list-item{display:flex;align-items:center;gap:.9rem;padding:.7rem;border-radius:var(--radius-sm);background:var(--surface);border:1px solid var(--border);margin-bottom:.6rem}
.list-thumb{width:56px;height:42px;object-fit:cover;border-radius:5px;background:var(--bg3);flex-shrink:0}
.list-no-thumb{width:56px;height:42px;border-radius:5px;background:var(--bg3);display:flex;align-items:center;justify-content:center;font-size:20px;flex-shrink:0}
.list-info{flex:1;min-width:0}
.list-title{font-size:13px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.list-meta{font-size:11px;color:var(--text3);margin-top:2px}
.list-actions{display:flex;gap:5px;flex-shrink:0}
.fg{margin-bottom:.9rem}
.fl{font-size:10px;font-weight:500;color:var(--text3);margin-bottom:4px;display:block;text-transform:uppercase;letter-spacing:.5px}
.fi{width:100%;padding:7px 10px;border-radius:var(--radius-sm);border:1px solid var(--border);font-size:13px;background:var(--surface);color:var(--text);outline:none;transition:border-color var(--transition);font-family:inherit}
.fi:focus{border-color:var(--accent);box-shadow:0 0 0 2px rgba(45,45,42,.08)}
textarea.fi{resize:vertical;min-height:72px}
.f-overlay{position:fixed;inset:0;background:rgba(0,0,0,.45);display:flex;align-items:flex-start;justify-content:center;z-index:600;padding:1.5rem 1rem;overflow-y:auto;backdrop-filter:blur(4px)}
.f-box{background:var(--surface);border-radius:12px;width:100%;max-width:500px;padding:1.5rem;animation:slideUp .2s cubic-bezier(0.34,1.2,0.64,1);box-shadow:0 20px 50px rgba(0,0,0,.15)}
.f-title{font-family:'Noto Serif SC',serif;font-size:17px;font-weight:500;margin-bottom:1.25rem}
.cat-chip{display:inline-flex;align-items:center;gap:7px;padding:5px 10px;background:var(--surface);border-radius:var(--radius-sm);border:1px solid var(--border);font-size:13px}
.cat-del{background:none;border:none;cursor:pointer;color:var(--red);font-size:15px;line-height:1;padding:0}
.preview-img{width:100%;max-height:130px;object-fit:cover;border-radius:6px;margin-top:7px}
.spin{display:inline-block;width:12px;height:12px;border:2px solid rgba(255,255,255,.3);border-top-color:#fff;border-radius:50%;animation:spin .6s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
`;

/* ── App 主组件 ─────────────────────────────── */
export default function App() {
  /* ── 数据状态 ── */
  const [loading,  setLoading]  = useState(true);
  const [data, setData] = useState({
    albums: [], categories: [],
    settings: { albumsPerPage: 6, siteTitle: "我的相册" }
  });

  /* ── 认证状态 ── */
  const [token,    setToken]    = useState("");
  const [loggedIn, setLoggedIn] = useState(false);
  const [pwInput,  setPwInput]  = useState("");
  const [loginErr, setLoginErr] = useState("");

  /* ── 路由 ── */
  const [route, setRoute] = useState("public");

  /* ── 布局 ── */
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [mobileOpen,  setMobileOpen]  = useState(false);
  const [isMobile,    setIsMobile]    = useState(false);

  /* ── 前台筛选 ── */
  const [activeCategory, setActiveCategory] = useState("全部");
  const [activeTag,      setActiveTag]      = useState(null);
  const [searchQ,        setSearchQ]        = useState("");
  const [page,           setPage]           = useState(1);
  const [selectedAlbum,  setSelectedAlbum]  = useState(null);

  /* ── 后台 UI ── */
  const [adminTab,     setAdminTab]     = useState("albums");
  const [showForm,     setShowForm]     = useState(false);
  const [editingAlbum, setEditingAlbum] = useState(null);
  const [newCat,       setNewCat]       = useState("");
  const [delConfirm,   setDelConfirm]   = useState(null);
  const [saving,       setSaving]       = useState(false);
  const [form, setForm] = useState({ title:"", cover:"", category:"", tags:"", description:"", photoCount:"" });
  const [settingsForm, setSettingsForm] = useState({ siteTitle:"", albumsPerPage:6, adminPassword:"" });

  /* ── API 工具 ──────────────────────────────── */
  const loadData = useCallback(async () => {
    try {
      const [albs, cats, sett] = await Promise.all([
        fetch("/api/albums").then(r => r.json()),
        fetch("/api/categories").then(r => r.json()),
        fetch("/api/settings").then(r => r.json()),
      ]);
      setData({ albums: albs, categories: cats, settings: sett });
    } catch (e) { console.error("loadData error:", e); }
    setLoading(false);
  }, []);

  function adminFetch(method, path, body) {
    const tk = sessionStorage.getItem("adm_tk") || token;
    return fetch(`/api${path}`, {
      method,
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${tk}` },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    }).then(async r => {
      const json = await r.json();
      if (!r.ok) throw new Error(json.error || "请求失败");
      return json;
    });
  }

  /* ── 初始化 ────────────────────────────────── */
  useEffect(() => {
    // 加载公开数据
    loadData();
    // 验证已存储的 Token
    const tk = sessionStorage.getItem("adm_tk");
    if (tk) {
      fetch("/api/auth/verify", { headers: { Authorization: `Bearer ${tk}` } })
        .then(r => {
          if (r.ok) { setToken(tk); setLoggedIn(true); }
          else sessionStorage.removeItem("adm_tk");
        })
        .catch(() => {});
    }
  }, []);

  // 路由监听（hash 变化）
  useEffect(() => {
    const check = () => {
      setRoute(window.location.hash === ADMIN_HASH ? "admin" : "public");
    };
    check();
    window.addEventListener("hashchange", check);
    return () => window.removeEventListener("hashchange", check);
  }, []);

  // 响应式侧边栏
  useEffect(() => {
    const check = () => {
      const m = window.innerWidth <= 768;
      setIsMobile(m);
      if (m) setSidebarOpen(false); else setMobileOpen(false);
    };
    check();
    window.addEventListener("resize", check);
    return () => window.removeEventListener("resize", check);
  }, []);

  // 进入设置 Tab 时拉取后台设置（含密码字段）
  useEffect(() => {
    if (loggedIn && adminTab === "settings") {
      adminFetch("GET", "/settings/admin")
        .then(s => setSettingsForm(s))
        .catch(() => {});
    }
  }, [loggedIn, adminTab]);

  /* ── 认证操作 ──────────────────────────────── */
  async function handleLogin() {
    setLoginErr("");
    try {
      const res  = await fetch("/api/auth/login", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ password: pwInput }),
      });
      const json = await res.json();
      if (!res.ok) { setLoginErr(json.error || "登录失败"); return; }
      setToken(json.token);
      sessionStorage.setItem("adm_tk", json.token);
      setLoggedIn(true);
      setPwInput("");
    } catch { setLoginErr("网络错误，请稍后重试"); }
  }

  function goPublic() {
    setRoute("public");
    window.location.hash = "";
    setAdminTab("albums");
  }
  function handleLogout() {
    setLoggedIn(false); setToken("");
    sessionStorage.removeItem("adm_tk");
    setPwInput(""); goPublic();
  }

  /* ── 相册 CRUD ─────────────────────────────── */
  function openAdd() {
    setEditingAlbum(null);
    setForm({ title:"", cover:"", category: data.categories[0]||"", tags:"", description:"", photoCount:"" });
    setShowForm(true);
  }
  function openEdit(a) {
    setEditingAlbum(a);
    setForm({ title: a.title, cover: a.cover, category: a.category,
              tags: a.tags.join(", "), description: a.description,
              photoCount: String(a.photoCount) });
    setShowForm(true);
  }
  async function saveAlbum() {
    if (!form.title.trim()) return;
    setSaving(true);
    try {
      const body = {
        title:       form.title.trim(),
        cover:       form.cover.trim(),
        category:    form.category,
        tags:        form.tags.split(/[,，]/).map(t => t.trim()).filter(Boolean),
        description: form.description.trim(),
        photoCount:  parseInt(form.photoCount) || 0,
      };
      if (editingAlbum) await adminFetch("PUT",  `/albums/${editingAlbum.id}`, body);
      else              await adminFetch("POST", "/albums", body);
      await loadData();
      setShowForm(false);
    } catch (e) { alert(e.message); }
    setSaving(false);
  }
  async function doDelete(id) {
    try { await adminFetch("DELETE", `/albums/${id}`); await loadData(); setDelConfirm(null); }
    catch (e) { alert(e.message); }
  }

  /* ── 分类 CRUD ─────────────────────────────── */
  async function addCat() {
    const c = newCat.trim(); if (!c) return;
    try { await adminFetch("POST", "/categories", { name: c }); await loadData(); setNewCat(""); }
    catch (e) { alert(e.message); }
  }
  async function removeCat(c) {
    try { await adminFetch("DELETE", `/categories/${encodeURIComponent(c)}`); await loadData(); }
    catch (e) { alert(e.message); }
  }

  /* ── 设置 ──────────────────────────────────── */
  async function saveSettings() {
    setSaving(true);
    try { await adminFetch("PUT", "/settings", settingsForm); await loadData(); alert("✔ 设置已保存"); }
    catch (e) { alert(e.message); }
    setSaving(false);
  }

  /* ── 导航辅助 ──────────────────────────────── */
  function selectCat(c) { setActiveCategory(c); setActiveTag(null); setPage(1); if (isMobile) setMobileOpen(false); }
  function selectTag(t) { setActiveTag(activeTag === t ? null : t); setPage(1); if (isMobile) setMobileOpen(false); }
  function toggleSidebar() { if (isMobile) setMobileOpen(o => !o); else setSidebarOpen(o => !o); }

  /* ── 加载中 ─────────────────────────────────── */
  if (loading) return (
    <><style>{css}</style>
    <div style={{display:"flex",alignItems:"center",justifyContent:"center",height:"100vh",color:"var(--text3)",fontSize:14}}>
      加载中…
    </div></>
  );

  /* ── 后台：登录页 ───────────────────────────── */
  if (route === "admin" && !loggedIn) return (
    <><style>{css}</style>
    <div className="login-wrap">
      <div className="login-box">
        <div className="login-title">后台管理</div>
        <div className="fg">
          <label className="fl">管理密码</label>
          <input type="password" className="fi" value={pwInput}
            placeholder="输入密码" autoFocus
            onChange={e => setPwInput(e.target.value)}
            onKeyDown={e => { if (e.key === "Enter") handleLogin(); }} />
          {loginErr && <div className="err">{loginErr}</div>}
        </div>
        <div style={{display:"flex",gap:8,justifyContent:"space-between"}}>
          <button className="btn" onClick={goPublic}>← 返回前台</button>
          <button className="btn btn-dark" onClick={handleLogin}>登录</button>
        </div>
      </div>
    </div></>
  );

  /* ── 后台：管理面板 ─────────────────────────── */
  if (route === "admin" && loggedIn) {
    const sa = [...data.albums].sort((a, b) => new Date(b.updatedAt) - new Date(a.updatedAt));
    return (
      <><style>{css}</style>
      <div className="adm-layout">

        {/* 侧边导航 */}
        <div className="adm-sb">
          <div className="adm-sb-title">📷 {data.settings.siteTitle}</div>
          {[
            { k:"albums",     icon:"🖼",  label:"相册管理" },
            { k:"categories", icon:"📁",  label:"分类管理" },
            { k:"settings",   icon:"⚙️", label:"系统设置" },
          ].map(({ k, icon, label }) => (
            <div key={k} className={`adm-nav ${adminTab===k?"active":""}`} onClick={() => setAdminTab(k)}>
              {icon} {label}
            </div>
          ))}
          <div className="adm-spacer"/><div className="adm-divider"/>
          <div className="adm-nav" onClick={goPublic}>← 前台预览</div>
          <div className="adm-nav" onClick={handleLogout}>退出登录</div>
        </div>

        {/* 主内容 */}
        <div className="adm-main">

          {/* 相册管理 */}
          {adminTab === "albums" && <>
            <div className="adm-header">
              <div className="adm-title">
                相册管理
                <span style={{fontSize:13,fontWeight:400,color:"var(--text3)"}}> ({data.albums.length})</span>
              </div>
              <button className="btn btn-dark btn-sm" onClick={openAdd}>＋ 新建相册</button>
            </div>
            {sa.length === 0
              ? <div className="empty"><div className="empty-icon">🖼️</div><div className="empty-txt">还没有相册</div></div>
              : sa.map(a => (
                  <div key={a.id} className="list-item">
                    {a.cover
                      ? <img src={a.cover} alt="" className="list-thumb"/>
                      : <div className="list-no-thumb">📷</div>}
                    <div className="list-info">
                      <div className="list-title">{a.title}</div>
                      <div className="list-meta">{a.category} · {a.photoCount} 张 · {fmtDate(a.updatedAt)}</div>
                    </div>
                    <div className="list-actions">
                      <button className="btn btn-sm" onClick={() => openEdit(a)}>编辑</button>
                      {delConfirm === a.id
                        ? <>
                            <button className="btn btn-red btn-sm" onClick={() => doDelete(a.id)}>确认删除</button>
                            <button className="btn btn-sm" onClick={() => setDelConfirm(null)}>取消</button>
                          </>
                        : <button className="btn btn-red btn-sm" onClick={() => setDelConfirm(a.id)}>删除</button>}
                    </div>
                  </div>
                ))}
          </>}

          {/* 分类管理 */}
          {adminTab === "categories" && <>
            <div className="adm-header"><div className="adm-title">分类管理</div></div>
            <div style={{display:"flex",gap:8,marginBottom:16}}>
              <input className="fi" style={{maxWidth:200}} value={newCat}
                placeholder="新分类名称"
                onChange={e => setNewCat(e.target.value)}
                onKeyDown={e => e.key === "Enter" && addCat()} />
              <button className="btn btn-dark btn-sm" onClick={addCat}>添加</button>
            </div>
            <div style={{display:"flex",flexWrap:"wrap",gap:8}}>
              {data.categories.map(c => (
                <div key={c} className="cat-chip">
                  <span>{c}</span>
                  <span style={{fontSize:11,color:"var(--text3)"}}>
                    {data.albums.filter(a => a.category === c).length} 个
                  </span>
                  <button className="cat-del" onClick={() => removeCat(c)}>×</button>
                </div>
              ))}
            </div>
          </>}

          {/* 系统设置 */}
          {adminTab === "settings" && <>
            <div className="adm-header"><div className="adm-title">系统设置</div></div>
            <div style={{maxWidth:380}}>
              <div className="fg">
                <label className="fl">网站标题</label>
                <input className="fi" value={settingsForm.siteTitle || ""}
                  onChange={e => setSettingsForm({ ...settingsForm, siteTitle: e.target.value })} />
              </div>
              <div className="fg">
                <label className="fl">每页显示相册数</label>
                <select className="fi" value={settingsForm.albumsPerPage || 6}
                  onChange={e => setSettingsForm({ ...settingsForm, albumsPerPage: parseInt(e.target.value) })}>
                  {[4,6,8,9,12,15].map(n => <option key={n} value={n}>{n} 个</option>)}
                </select>
              </div>
              <div className="fg">
                <label className="fl">管理密码</label>
                <input className="fi" type="text" value={settingsForm.adminPassword || ""}
                  onChange={e => setSettingsForm({ ...settingsForm, adminPassword: e.target.value })}
                  placeholder="修改密码（留空不变）" />
              </div>
              <div className="fg" style={{background:"#FFFBEB",border:"1px solid #FDE68A",borderRadius:6,padding:"8px 12px"}}>
                <div style={{fontSize:11,color:"#92400E"}}>
                  💡 后台访问：在 URL 末尾添加 <strong>#admin</strong> 即可进入管理页
                </div>
              </div>
              <button className="btn btn-dark" disabled={saving} onClick={saveSettings}>
                {saving ? <><span className="spin"/> 保存中…</> : "保存设置"}
              </button>
            </div>
          </>}
        </div>
      </div>

      {/* 新建/编辑表单 */}
      {showForm && (
        <div className="f-overlay" onClick={e => e.target === e.currentTarget && setShowForm(false)}>
          <div className="f-box">
            <div className="f-title">{editingAlbum ? "编辑相册" : "新建相册"}</div>
            <div className="fg">
              <label className="fl">相册名称 *</label>
              <input className="fi" value={form.title} placeholder="输入相册名称"
                onChange={e => setForm({ ...form, title: e.target.value })} />
            </div>
            <div className="fg">
              <label className="fl">封面图片 URL</label>
              <input className="fi" value={form.cover} placeholder="https://..."
                onChange={e => setForm({ ...form, cover: e.target.value })} />
              {form.cover && (
                <img src={form.cover} alt="" className="preview-img"
                  onError={e => (e.target.style.display = "none")} />
              )}
            </div>
            <div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:10}}>
              <div className="fg">
                <label className="fl">分类</label>
                <select className="fi" value={form.category}
                  onChange={e => setForm({ ...form, category: e.target.value })}>
                  {data.categories.map(c => <option key={c} value={c}>{c}</option>)}
                </select>
              </div>
              <div className="fg">
                <label className="fl">照片数量</label>
                <input className="fi" type="number" min="0" value={form.photoCount}
                  placeholder="0" onChange={e => setForm({ ...form, photoCount: e.target.value })} />
              </div>
            </div>
            <div className="fg">
              <label className="fl">标签（逗号分隔）</label>
              <input className="fi" value={form.tags} placeholder="标签1, 标签2"
                onChange={e => setForm({ ...form, tags: e.target.value })} />
            </div>
            <div className="fg">
              <label className="fl">相册简介</label>
              <textarea className="fi" value={form.description} placeholder="描述这个相册…"
                onChange={e => setForm({ ...form, description: e.target.value })} />
            </div>
            <div style={{display:"flex",gap:8,justifyContent:"flex-end"}}>
              <button className="btn" onClick={() => setShowForm(false)}>取消</button>
              <button className="btn btn-dark" disabled={saving} onClick={saveAlbum}>
                {saving ? <><span className="spin"/> 保存中…</> : "保存"}
              </button>
            </div>
          </div>
        </div>
      )}
      </>
    );
  }

  /* ── 前台：公开展示页 ───────────────────────── */
  const perPage = data.settings.albumsPerPage;
  const sorted  = [...data.albums].sort((a, b) => new Date(b.updatedAt) - new Date(a.updatedAt));
  let filtered  = activeCategory === "全部" ? sorted : sorted.filter(a => a.category === activeCategory);
  if (activeTag) filtered = filtered.filter(a => a.tags.includes(activeTag));
  if (searchQ.trim()) {
    const q = searchQ.trim().toLowerCase();
    filtered = filtered.filter(a =>
      a.title.toLowerCase().includes(q) ||
      a.description.toLowerCase().includes(q) ||
      a.tags.some(t => t.toLowerCase().includes(q))
    );
  }
  const totalPages = Math.max(1, Math.ceil(filtered.length / perPage));
  const paged      = filtered.slice((page - 1) * perPage, page * perPage);
  const allTags    = [...new Set(sorted.flatMap(a => a.tags))];
  const catCounts  = Object.fromEntries(data.categories.map(c => [c, data.albums.filter(a => a.category === c).length]));
  const hasFilter  = activeCategory !== "全部" || activeTag || searchQ.trim();
  const sidebarVisible = isMobile ? mobileOpen : sidebarOpen;

  return (
    <><style>{css}</style>
    <div>
      {/* 顶部导航栏 */}
      <header className="hdr">
        <div className="hdr-left">
          <button className={`sidebar-toggle ${sidebarVisible ? "open" : ""}`}
            onClick={toggleSidebar} aria-label="切换侧栏">
            <span/><span/><span/>
          </button>
          <div className="hdr-title">📷 {data.settings.siteTitle}</div>
        </div>
        <div className="hdr-search">
          <span className="hdr-search-icon">🔍</span>
          <input value={searchQ} placeholder="搜索相册…"
            onChange={e => { setSearchQ(e.target.value); setPage(1); }} />
        </div>
        <div style={{width:1}}/>
      </header>

      <div className="layout">
        {isMobile && mobileOpen && (
          <div className="sidebar-overlay" onClick={() => setMobileOpen(false)} />
        )}

        {/* 侧边栏 */}
        <div className={`sidebar-wrap ${isMobile ? (mobileOpen ? "mobile-open" : "") : (sidebarOpen ? "" : "collapsed")}`}>
          <div className="sidebar">
            <div>
              <div className="sb-section-label">分类</div>
              <div className={`cat-item ${activeCategory === "全部" ? "active" : ""}`}
                onClick={() => selectCat("全部")}>
                <span>全部</span>
                <span className="cat-count">{data.albums.length}</span>
              </div>
              {data.categories.map(c => (
                <div key={c} className={`cat-item ${activeCategory === c ? "active" : ""}`}
                  onClick={() => selectCat(c)}>
                  <span>{c}</span>
                  <span className="cat-count">{catCounts[c] || 0}</span>
                </div>
              ))}
            </div>
            {allTags.length > 0 && (
              <div>
                <div className="sb-section-label">标签</div>
                <div className="tag-wrap">
                  {allTags.map(t => (
                    <button key={t} className={`tag-btn ${activeTag === t ? "active" : ""}`}
                      onClick={() => selectTag(t)}>#{t}</button>
                  ))}
                </div>
              </div>
            )}
          </div>
        </div>

        {/* 主内容区 */}
        <div className="main">
          <div className="main-header">
            <div className="main-info">
              {activeTag      && <><strong>#{activeTag}</strong> · </>}
              {activeCategory !== "全部" && !activeTag && <><strong>{activeCategory}</strong> · </>}
              {searchQ.trim() && <><strong>"{searchQ}"</strong> · </>}
              {filtered.length} 个相册
            </div>
            {hasFilter && (
              <button className="clear-btn" onClick={() => {
                setActiveCategory("全部"); setActiveTag(null); setSearchQ(""); setPage(1);
              }}>✕ 清除筛选</button>
            )}
          </div>

          {paged.length === 0
            ? <div className="empty"><div className="empty-icon">🔍</div><div className="empty-txt">没有找到相册</div></div>
            : <div className="grid">
                {paged.map(a => (
                  <div key={a.id} className="card" onClick={() => setSelectedAlbum(a)}>
                    {a.cover
                      ? <img src={a.cover} alt={a.title} className="card-img" loading="lazy"/>
                      : <div className="card-no-img">📷</div>}
                    <div className="card-body">
                      <div className="card-title">{a.title}</div>
                      <div className="card-footer">
                        <span className="badge">{a.category}</span>
                        <span className="card-count">{a.photoCount} 张</span>
                      </div>
                      <div className="card-date">{fmtDate(a.updatedAt)}</div>
                    </div>
                  </div>
                ))}
              </div>}

          {totalPages > 1 && (
            <div className="pager">
              <button className="pager-btn" disabled={page === 1} onClick={() => setPage(p => p - 1)}>‹</button>
              {Array.from({ length: totalPages }, (_, i) => i + 1).map(p => (
                <button key={p} className={`pager-btn ${p === page ? "active" : ""}`} onClick={() => setPage(p)}>{p}</button>
              ))}
              <button className="pager-btn" disabled={page === totalPages} onClick={() => setPage(p => p + 1)}>›</button>
            </div>
          )}
        </div>
      </div>
    </div>

    {/* 相册详情弹窗 */}
    {selectedAlbum && (
      <div className="overlay" onClick={e => e.target === e.currentTarget && setSelectedAlbum(null)}>
        <div className="modal">
          {selectedAlbum.cover && (
            <img src={selectedAlbum.cover} alt={selectedAlbum.title} className="modal-img" />
          )}
          <div className="modal-body">
            <div className="modal-top">
              <div className="modal-title">{selectedAlbum.title}</div>
              <button className="modal-close" onClick={() => setSelectedAlbum(null)}>✕</button>
            </div>
            <div className="modal-meta">
              <span className="badge">{selectedAlbum.category}</span>
              <span style={{fontSize:12,color:"var(--text3)"}}>{selectedAlbum.photoCount} 张照片</span>
              <span style={{fontSize:12,color:"var(--text3)"}}>更新 {fmtDate(selectedAlbum.updatedAt)}</span>
            </div>
            {selectedAlbum.description && (
              <div className="modal-desc">{selectedAlbum.description}</div>
            )}
            {selectedAlbum.tags.length > 0 && (
              <div className="modal-tags">
                {selectedAlbum.tags.map(t => (
                  <button key={t} className="tag-btn"
                    onClick={() => { setSelectedAlbum(null); selectTag(t); }}>
                    #{t}
                  </button>
                ))}
              </div>
            )}
          </div>
        </div>
      </div>
    )}
    </>
  );
}
APPJSX

# ────────────────────────────────────────
#  .gitignore
# ────────────────────────────────────────
cat > .gitignore << 'GITIGNORE'
node_modules/
dist/
data/
.DS_Store
*.local
.env
GITIGNORE

success "所有项目文件写入完成"

# ── 安装依赖 ──
echo ""
info "安装依赖包（better-sqlite3 含原生模块，首次约需 1 分钟）..."
info "如遇编译错误，请安装构建工具："
info "  macOS : xcode-select --install"
info "  Ubuntu: sudo apt-get install -y build-essential python3"
info "  CentOS: sudo yum groupinstall 'Development Tools'"
echo ""

# 开启 pipefail，确保管道中任何命令失败都能被捕捉
set -o pipefail

# 使用 --include=dev 确保在 NODE_ENV=production 环境下也会安装 vite
npm install --include=dev --prefer-offline --no-audit --no-fund || {
  echo ""
  error "依赖安装失败！由于 better-sqlite3 需要编译，请确保已安装 gcc/g++ 和 python3。"
}
success "依赖安装完成"

# ── 根据模式启动 ──
echo ""
echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

case "$MODE" in
  --dev|-d)
    echo -e "  ${GREEN}开发模式（热更新）${RESET}"
    echo -e "  前台：${BOLD}http://localhost:5173${RESET}"
    echo -e "  后台：${BOLD}http://localhost:5173/#admin${RESET}  密码: admin123"
    echo -e "  API ：${BOLD}http://localhost:3000/api${RESET}"
    echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    npm run dev
    ;;
  --build|-b)
    info "构建前端..."
    npm run build
    echo ""
    success "构建完成 → ./${INSTALL_DIR}/dist/"
    echo -e "  运行 ${BOLD}node server.js${RESET} 启动生产服务"
    echo ""
    ;;
  *)
    info "构建前端..."
    npm run build
    echo ""
    echo -e "  ${GREEN}生产模式${RESET}"
    echo -e "  访问地址：${BOLD}http://localhost:3000${RESET}"
    echo -e "  后台入口：${BOLD}http://localhost:3000/#admin${RESET}"
    echo -e "  ${YELLOW}默认密码：${BOLD}admin123${RESET}（请登录后台修改）"
    echo -e "${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    node server.js
    ;;
esac
