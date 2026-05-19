#!/usr/bin/env bash
# ====================================================================
#  📷 Photo Album (Secure Full‑Stack)  —  公网安全版一键安装
#  · 前端: React + Vite（SPA）
#  · 后端: Node.js + Express + SQLite + JWT + bcrypt
#  · 安全: Helmet / CORS / Rate Limiting / 参数化查询 / 输入校验
# ====================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()  { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✔ $*${RESET}"; }
warn()  { echo -e "${YELLOW}⚠ $*${RESET}"; }
error() { echo -e "${RED}✖ $*${RESET}" >&2; exit 1; }

INSTALL_DIR="photo-album-secure"
MODE="${1:---start}"   # --dev | --build | --start

echo ""
echo -e "${BOLD}  📷 Photo Album (安全全栈版)${RESET}"
echo -e "  ──────────────────────────────"
echo ""

# ── 检查环境 ──
for cmd in node npm; do
  if ! command -v $cmd &>/dev/null; then
    error "未找到 $cmd，请先安装 Node.js 18+：https://nodejs.org"
  fi
done
node -e "if(parseInt(process.versions.node)<18)process.exit(1)" || error "Node.js 版本需 ≥ 18，当前：$(node -v)"
success "Node.js $(node -v) | npm $(npm -v)"

# ── 创建项目结构 ──
mkdir -p "$INSTALL_DIR"/{server/{routes,middleware,data},client}
cd "$INSTALL_DIR"

info "生成项目文件..."

# ======================== 根 package.json ========================
cat > package.json << 'ROOTPKG'
{
  "name": "photo-album-secure",
  "private": true,
  "scripts": {
    "install:all": "npm install && cd client && npm install",
    "dev": "concurrently \"npm run dev:server\" \"npm run dev:client\"",
    "dev:server": "node --watch server/server.js",
    "dev:client": "cd client && npm run dev",
    "build": "cd client && npm run build",
    "start": "node server/server.js",
    "db:init": "node server/db.js"
  },
  "dependencies": {
    "express": "^4.21.0",
    "better-sqlite3": "^11.6.0",
    "bcryptjs": "^2.4.3",
    "jsonwebtoken": "^9.0.2",
    "cors": "^2.8.5",
    "helmet": "^8.0.0",
    "express-rate-limit": "^7.4.1",
    "dotenv": "^16.4.5"
  },
  "devDependencies": {
    "concurrently": "^9.0.1"
  }
}
ROOTPKG

# ======================== .env 配置 ========================
cat > .env << 'ENVFILE'
PORT=3000
HOST=0.0.0.0
JWT_SECRET=change-this-to-a-random-string-at-least-32chars
ADMIN_EMAIL=admin@photoalbum.local
# 生产环境建议使用 Nginx 反代 + Let's Encrypt，本文件仅供本地/测试
ENVFILE

# ======================== server/server.js ========================
cat > server/server.js << 'SERVERJS'
import 'dotenv/config';
import express from 'express';
import helmet from 'helmet';
import cors from 'cors';
import rateLimit from 'express-rate-limit';
import path from 'path';
import { fileURLToPath } from 'url';
import { initDB } from './db.js';
import authRoutes from './routes/auth.js';
import albumRoutes from './routes/albums.js';
import categoryRoutes from './routes/categories.js';
import settingsRoutes from './routes/settings.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = process.env.PORT || 3000;
const HOST = process.env.HOST || '0.0.0.0';

// 安全中间件
app.use(helmet({ contentSecurityPolicy: false })); // CSP 可在生产自定义
app.use(cors({ origin: process.env.CORS_ORIGIN || '*' })); // 生产环境应限制具体域名
app.use(express.json({ limit: '1mb' }));

// 全局速率限制
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 分钟
  max: 200,
  standardHeaders: true,
  legacyHeaders: false,
});
app.use(limiter);

// 初始化数据库
initDB();

// API 路由
app.use('/api/auth', authRoutes);
app.use('/api/albums', albumRoutes);
app.use('/api/categories', categoryRoutes);
app.use('/api/settings', settingsRoutes);

// 生产环境：托管前端静态文件
const clientDistPath = path.join(__dirname, '..', 'client', 'dist');
app.use(express.static(clientDistPath));
app.get('*', (req, res) => {
  if (!req.path.startsWith('/api')) {
    res.sendFile(path.join(clientDistPath, 'index.html'));
  } else {
    res.status(404).json({ error: 'API endpoint not found' });
  }
});

// 启动
app.listen(PORT, HOST, () => {
  console.log(`🚀 Photo Album 安全版已启动: http://${HOST}:${PORT}`);
  console.log(`   后台入口: http://${HOST}:${PORT}/admin  (默认密码: admin123)`);
});
SERVERJS

# ======================== server/db.js ========================
cat > server/db.js << 'DBJS'
import Database from 'better-sqlite3';
import path from 'path';
import { fileURLToPath } from 'url';
import bcrypt from 'bcryptjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const DB_PATH = path.join(__dirname, 'data', 'photoalbum.db');

let db;

export function getDB() {
  if (!db) {
    db = new Database(DB_PATH, { /* verbose: console.log */ });
    db.pragma('journal_mode = WAL');
    db.pragma('foreign_keys = ON');
  }
  return db;
}

export function initDB() {
  const db = getDB();
  db.exec(`
    CREATE TABLE IF NOT EXISTS albums (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      cover TEXT DEFAULT '',
      category TEXT DEFAULT '未分类',
      tags TEXT DEFAULT '[]',        -- JSON array
      description TEXT DEFAULT '',
      photo_count INTEGER DEFAULT 0,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS categories (
      name TEXT PRIMARY KEY
    );
    CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      email TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL
    );
  `);

  // 初始化默认设置
  const insertSetting = db.prepare('INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)');
  insertSetting.run('site_title', '我的相册');
  insertSetting.run('albums_per_page', '6');

  // 初始化默认分类
  const insertCat = db.prepare('INSERT OR IGNORE INTO categories (name) VALUES (?)');
  ['旅行', '城市', '自然', '美食', '家庭'].forEach(c => insertCat.run(c));

  // 初始化管理员账户（如果不存在）
  const adminExists = db.prepare('SELECT id FROM users WHERE email = ?').get('admin@photoalbum.local');
  if (!adminExists) {
    const salt = bcrypt.genSaltSync(10);
    const hash = bcrypt.hashSync('admin123', salt);
    db.prepare('INSERT INTO users (email, password_hash) VALUES (?, ?)').run('admin@photoalbum.local', hash);
  }

  // 初始化示例相册（仅当表为空时）
  const count = db.prepare('SELECT COUNT(*) as cnt FROM albums').get();
  if (count.cnt === 0) {
    const insertAlbum = db.prepare(`
      INSERT INTO albums (id, title, cover, category, tags, description, photo_count, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))
    `);
    const now = new Date().toISOString();
    insertAlbum.run('a1', '西藏高原之旅', 'https://images.unsplash.com/photo-1506905925346-21bda4d32df4?w=800&q=80',
      '旅行', JSON.stringify(['西藏','高原','寺庙','风景']), '2024年夏天走进西藏，感受高原的壮阔与宁静。', 48);
    insertAlbum.run('a2', '上海夜景', 'https://images.unsplash.com/photo-1474181487882-5abf3f0ba6c2?w=800&q=80',
      '城市', JSON.stringify(['上海','夜景','都市','外滩']), '霓虹璀璨的魔都夜晚。', 41);
    insertAlbum.run('a3', '云南丽江', 'https://images.unsplash.com/photo-1537531700788-d82ce5f3bebb?w=800&q=80',
      '旅行', JSON.stringify(['云南','丽江','古城','纳西族']), '漫步丽江古城，感受纳西族文化。', 67);
    insertAlbum.run('a4', '春日花海', 'https://images.unsplash.com/photo-1490750967868-88df5691166a?w=800&q=80',
      '自然', JSON.stringify(['花卉','春天','摄影','油菜花']), '春天里最美的花朵盛开。', 56);
    insertAlbum.run('a5', '成都美食记录', 'https://images.unsplash.com/photo-1569050467447-ce54b3bbc37d?w=800&q=80',
      '美食', JSON.stringify(['成都','川菜','火锅','小吃']), '走遍成都大街小巷，寻访地道川味。', 32);
    insertAlbum.run('a6', '家庭聚会2024', 'https://images.unsplash.com/photo-1511988617509-a57c8a288659?w=800&q=80',
      '家庭', JSON.stringify(['家庭','聚会','春节','温馨']), '春节家庭大聚会，温馨时刻。', 89);
  }
  console.log('✅ 数据库初始化完成');
}
DBJS

# ======================== server/middleware/auth.js ========================
mkdir -p server/middleware
cat > server/middleware/auth.js << 'AUTHMW'
import jwt from 'jsonwebtoken';

export function authenticateToken(req, res, next) {
  const authHeader = req.headers['authorization'];
  const token = authHeader && authHeader.split(' ')[1]; // Bearer TOKEN
  if (!token) return res.status(401).json({ error: '未提供认证令牌' });

  jwt.verify(token, process.env.JWT_SECRET, (err, user) => {
    if (err) return res.status(403).json({ error: '令牌无效或已过期' });
    req.user = user; // { id, email }
    next();
  });
}
AUTHMW

# ======================== server/routes/auth.js ========================
mkdir -p server/routes
cat > server/routes/auth.js << 'AUTHROUTE'
import { Router } from 'express';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import rateLimit from 'express-rate-limit';
import { getDB } from '../db.js';

const router = Router();

// 登录接口速率限制：5次/分钟
const loginLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 5,
  message: { error: '登录尝试过于频繁，请1分钟后再试' },
});

router.post('/login', loginLimiter, (req, res) => {
  const { email, password } = req.body;
  if (!email || !password) {
    return res.status(400).json({ error: '邮箱和密码不能为空' });
  }

  const db = getDB();
  const user = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
  if (!user) {
    return res.status(401).json({ error: '邮箱或密码错误' });
  }

  const valid = bcrypt.compareSync(password, user.password_hash);
  if (!valid) {
    return res.status(401).json({ error: '邮箱或密码错误' });
  }

  const token = jwt.sign(
    { id: user.id, email: user.email },
    process.env.JWT_SECRET,
    { expiresIn: '12h' }
  );
  res.json({ token, email: user.email });
});

// 验证令牌有效性（用于前端检查是否登录）
router.get('/verify', (req, res) => {
  const authHeader = req.headers['authorization'];
  const token = authHeader && authHeader.split(' ')[1];
  if (!token) return res.status(401).json({ valid: false });
  try {
    jwt.verify(token, process.env.JWT_SECRET);
    res.json({ valid: true });
  } catch {
    res.status(401).json({ valid: false });
  }
});

export default router;
AUTHROUTE

# ======================== server/routes/albums.js ========================
cat > server/routes/albums.js << 'ALBUMROUTE'
import { Router } from 'express';
import { authenticateToken } from '../middleware/auth.js';
import { getDB } from '../db.js';

const router = Router();

// 公开接口：获取所有相册（支持查询参数搜索、分类、标签）
router.get('/', (req, res) => {
  const db = getDB();
  const { category, tag, search } = req.query;
  let sql = 'SELECT * FROM albums WHERE 1=1';
  const params = [];

  if (category) {
    sql += ' AND category = ?';
    params.push(category);
  }
  if (search) {
    sql += ' AND (title LIKE ? OR description LIKE ?)';
    const q = `%${search}%`;
    params.push(q, q);
  }
  // 标签过滤较复杂，这里简化：前端收到所有后自行过滤或使用 LIKE
  // 实际可按需增强
  const rows = db.prepare(sql + ' ORDER BY updated_at DESC').all(...params);
  // 将 tags 字符串转回数组
  const albums = rows.map(r => ({ ...r, tags: JSON.parse(r.tags || '[]'), photoCount: r.photo_count }));
  res.json(albums);
});

// 需要认证的增删改
router.post('/', authenticateToken, (req, res) => {
  const db = getDB();
  const { id, title, cover, category, tags, description, photoCount } = req.body;
  if (!title) return res.status(400).json({ error: '标题不能为空' });
  const now = new Date().toISOString();
  const albumId = id || Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
  const tagsStr = JSON.stringify(tags || []);
  db.prepare(`
    INSERT INTO albums (id, title, cover, category, tags, description, photo_count, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(albumId, title, cover || '', category || '未分类', tagsStr, description || '', photoCount || 0, now, now);
  res.status(201).json({ id: albumId });
});

router.put('/:id', authenticateToken, (req, res) => {
  const db = getDB();
  const { id } = req.params;
  const { title, cover, category, tags, description, photoCount } = req.body;
  if (!title) return res.status(400).json({ error: '标题不能为空' });
  const tagsStr = JSON.stringify(tags || []);
  const now = new Date().toISOString();
  const info = db.prepare(`
    UPDATE albums SET title=?, cover=?, category=?, tags=?, description=?, photo_count=?, updated_at=?
    WHERE id=?
  `).run(title, cover || '', category || '未分类', tagsStr, description || '', photoCount || 0, now, id);
  if (info.changes === 0) return res.status(404).json({ error: '相册不存在' });
  res.json({ success: true });
});

router.delete('/:id', authenticateToken, (req, res) => {
  const db = getDB();
  const info = db.prepare('DELETE FROM albums WHERE id = ?').run(req.params.id);
  if (info.changes === 0) return res.status(404).json({ error: '相册不存在' });
  res.json({ success: true });
});

export default router;
ALBUMROUTE

# ======================== server/routes/categories.js ========================
cat > server/routes/categories.js << 'CATROUTE'
import { Router } from 'express';
import { authenticateToken } from '../middleware/auth.js';
import { getDB } from '../db.js';

const router = Router();

router.get('/', (req, res) => {
  const db = getDB();
  const rows = db.prepare('SELECT name FROM categories ORDER BY name').all();
  res.json(rows.map(r => r.name));
});

router.post('/', authenticateToken, (req, res) => {
  const db = getDB();
  const { name } = req.body;
  if (!name) return res.status(400).json({ error: '分类名不能为空' });
  try {
    db.prepare('INSERT INTO categories (name) VALUES (?)').run(name);
    res.status(201).json({ name });
  } catch (e) {
    if (e.message.includes('UNIQUE')) return res.status(409).json({ error: '分类已存在' });
    throw e;
  }
});

router.delete('/:name', authenticateToken, (req, res) => {
  const db = getDB();
  const info = db.prepare('DELETE FROM categories WHERE name = ?').run(req.params.name);
  if (info.changes === 0) return res.status(404).json({ error: '分类不存在' });
  res.json({ success: true });
});

export default router;
CATROUTE

# ======================== server/routes/settings.js ========================
cat > server/routes/settings.js << 'SETROUTE'
import { Router } from 'express';
import { authenticateToken } from '../middleware/auth.js';
import { getDB } from '../db.js';

const router = Router();

router.get('/', (req, res) => {
  const db = getDB();
  const rows = db.prepare('SELECT key, value FROM settings').all();
  const settings = {};
  rows.forEach(r => { settings[r.key] = r.value; });
  res.json(settings);
});

router.put('/', authenticateToken, (req, res) => {
  const db = getDB();
  const { siteTitle, albumsPerPage, adminPassword } = req.body;
  const update = db.prepare('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)');
  if (siteTitle !== undefined) update.run('site_title', siteTitle);
  if (albumsPerPage !== undefined) update.run('albums_per_page', String(albumsPerPage));
  // 密码通过专门接口修改，此处暂不处理
  res.json({ success: true });
});

export default router;
SETROUTE

# ======================== 前端部分 (client/) ========================
cd client
# 创建 client 的 package.json
cat > package.json << 'CLIENTPKG'
{
  "name": "photo-album-client",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.4",
    "vite": "^6.0.7"
  }
}
CLIENTPKG

# vite.config.js
cat > vite.config.js << 'VITECFG'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  build: { outDir: 'dist', sourcemap: false },
  server: {
    port: 5173,
    proxy: {
      '/api': 'http://localhost:3000'
    }
  }
})
VITECFG

# index.html
cat > index.html << 'INDEXHTML'
<!DOCTYPE html>
<html lang="zh-CN">
  <head>
    <meta charset="UTF-8" />
    <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>📷</text></svg>" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>我的相册</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
INDEXHTML

mkdir -p src
# src/main.jsx
cat > src/main.jsx << 'MAINJSX'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App.jsx'

createRoot(document.getElementById('root')).render(
  <StrictMode><App /></StrictMode>
)
MAINJSX

# src/App.jsx (重构为从 API 获取数据)
cat > src/App.jsx << 'APPJSX'
import { useState, useEffect, useCallback } from "react";

const API_BASE = import.meta.env.VITE_API_BASE || '/api';

// 工具函数
function genId() { return Date.now().toString(36) + Math.random().toString(36).slice(2,7); }
function fmtDate(iso) { return new Date(iso).toLocaleDateString("zh-CN", { year:"numeric", month:"short", day:"numeric" }); }

// CSS 样式（与原来基本相同，略作精简）
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
.hdr{position:sticky;top:0;z-index:100;height:var(--header-h);background:rgba(247,245,240,0.92);backdrop-filter:blur(12px);border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between;padding:0 1.25rem 0 0.75rem;gap:.75rem}
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
  .sidebar-wrap{position:fixed;top:var(--header-h);left:0;height:calc(100vh - var(--header-h));width:var(--sidebar-w) !important;transform:translateX(-100%);transition:transform var(--transition);z-index:200}
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
.btn-dark{background:var(--accent);color:#F7F5F0;border-color:var(--accent)}
.btn-dark:hover{background:#3A3A36}
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
`;

export default function App() {
  const [data, setData] = useState(null);     // { albums, categories, settings }
  const [loading, setLoading] = useState(true);
  const [token, setToken] = useState(localStorage.getItem('token') || '');
  const [loggedIn, setLoggedIn] = useState(false);
  const [pwInput, setPwInput] = useState('');
  const [loginErr, setLoginErr] = useState('');
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [mobileOpen, setMobileOpen] = useState(false);
  const [isMobile, setIsMobile] = useState(false);
  const [activeCategory, setActiveCategory] = useState('全部');
  const [activeTag, setActiveTag] = useState(null);
  const [searchQ, setSearchQ] = useState('');
  const [page, setPage] = useState(1);
  const [selectedAlbum, setSelectedAlbum] = useState(null);
  const [adminTab, setAdminTab] = useState('albums');
  const [showForm, setShowForm] = useState(false);
  const [editingAlbum, setEditingAlbum] = useState(null);
  const [newCat, setNewCat] = useState('');
  const [delConfirm, setDelConfirm] = useState(null);
  const [form, setForm] = useState({ title:'', cover:'', category:'', tags:'', description:'', photoCount:'' });
  const [settingsForm, setSettingsForm] = useState(null);

  // 响应式检测
  useEffect(() => {
    const check = () => { const m = window.innerWidth <= 768; setIsMobile(m); if (m) setSidebarOpen(false); else setMobileOpen(false); };
    check(); window.addEventListener('resize', check); return () => window.removeEventListener('resize', check);
  }, []);

  // 尝试用已存 token 验证登录
  useEffect(() => {
    if (token) {
      fetch(`${API_BASE}/auth/verify`, { headers: { 'Authorization': `Bearer ${token}` } })
        .then(r => { if (r.ok) setLoggedIn(true); else { setLoggedIn(false); localStorage.removeItem('token'); setToken(''); } })
        .catch(() => { setLoggedIn(false); });
    }
  }, [token]);

  // 获取公共数据（相册、分类、设置）
  const fetchData = useCallback(async () => {
    try {
      const [albumsRes, catRes, settingsRes] = await Promise.all([
        fetch(`${API_BASE}/albums`),
        fetch(`${API_BASE}/categories`),
        fetch(`${API_BASE}/settings`)
      ]);
      const albums = await albumsRes.json();
      const categories = await catRes.json();
      const settings = await settingsRes.json();
      setData({ albums, categories, settings: { ...settings, albumsPerPage: parseInt(settings.albums_per_page) || 6 } });
    } catch (e) { console.error(e); }
    setLoading(false);
  }, []);

  useEffect(() => { fetchData(); }, [fetchData]);

  // 管理员登录
  const doLogin = async () => {
    setLoginErr('');
    try {
      const res = await fetch(`${API_BASE}/auth/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: 'admin@photoalbum.local', password: pwInput })
      });
      const result = await res.json();
      if (res.ok) {
        const newToken = result.token;
        localStorage.setItem('token', newToken);
        setToken(newToken);
        setLoggedIn(true);
        setPwInput('');
      } else {
        setLoginErr(result.error || '登录失败');
      }
    } catch { setLoginErr('网络错误'); }
  };

  const doLogout = () => {
    localStorage.removeItem('token');
    setToken('');
    setLoggedIn(false);
  };

  const apiHeaders = () => ({
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${token}`
  });

  // 增删改相册
  const openAdd = () => { setEditingAlbum(null); setForm({ title:'', cover:'', category: data.categories[0] || '', tags:'', description:'', photoCount:'' }); setShowForm(true); };
  const openEdit = (a) => { setEditingAlbum(a); setForm({ title:a.title, cover:a.cover, category:a.category, tags:a.tags.join(', '), description:a.description, photoCount:String(a.photoCount||0) }); setShowForm(true); };
  const saveAlbum = async () => {
    if (!form.title.trim()) return;
    const payload = {
      title: form.title.trim(),
      cover: form.cover.trim(),
      category: form.category,
      tags: form.tags.split(/[,，]/).map(t => t.trim()).filter(Boolean),
      description: form.description.trim(),
      photoCount: parseInt(form.photoCount) || 0
    };
    try {
      if (editingAlbum) {
        await fetch(`${API_BASE}/albums/${editingAlbum.id}`, {
          method: 'PUT',
          headers: apiHeaders(),
          body: JSON.stringify(payload)
        });
      } else {
        await fetch(`${API_BASE}/albums`, {
          method: 'POST',
          headers: apiHeaders(),
          body: JSON.stringify(payload)
        });
      }
      setShowForm(false);
      fetchData();
    } catch (e) { console.error(e); }
  };
  const doDelete = async (id) => {
    try {
      await fetch(`${API_BASE}/albums/${id}`, { method: 'DELETE', headers: apiHeaders() });
      setDelConfirm(null);
      fetchData();
    } catch (e) { console.error(e); }
  };

  // 分类管理
  const addCat = async () => {
    const c = newCat.trim();
    if (!c) return;
    try {
      await fetch(`${API_BASE}/categories`, {
        method: 'POST',
        headers: apiHeaders(),
        body: JSON.stringify({ name: c })
      });
      setNewCat('');
      fetchData();
    } catch (e) { console.error(e); }
  };
  const removeCat = async (name) => {
    try {
      await fetch(`${API_BASE}/categories/${encodeURIComponent(name)}`, { method: 'DELETE', headers: apiHeaders() });
      fetchData();
    } catch (e) { console.error(e); }
  };

  // 设置保存
  const saveSettings = async () => {
    try {
      await fetch(`${API_BASE}/settings`, {
        method: 'PUT',
        headers: apiHeaders(),
        body: JSON.stringify(settingsForm)
      });
      fetchData();
    } catch (e) { console.error(e); }
  };

  // 前台交互
  const selectCat = (c) => { setActiveCategory(c); setActiveTag(null); setPage(1); if (isMobile) setMobileOpen(false); };
  const selectTag = (t) => { setActiveTag(activeTag === t ? null : t); setPage(1); };
  const toggleSidebar = () => { if (isMobile) setMobileOpen(o => !o); else setSidebarOpen(o => !o); };

  if (loading) return <><style>{css}</style><div style={{display:'flex',alignItems:'center',justifyContent:'center',height:'100vh',color:'var(--text3)'}}>加载中…</div></>;

  // 后台管理界面
  if (loggedIn) {
    const sa = [...data.albums].sort((a,b) => new Date(b.updated_at) - new Date(a.updated_at));
    return (
      <><style>{css}</style>
      <div className="adm-layout">
        <div className="adm-sb">
          <div className="adm-sb-title">📷 {data.settings?.siteTitle || '我的相册'}</div>
          {[{k:'albums',icon:'🖼',label:'相册管理'},{k:'categories',icon:'📁',label:'分类管理'},{k:'settings',icon:'⚙️',label:'系统设置'}].map(item => (
            <div key={item.k} className={`adm-nav ${adminTab===item.k?'active':''}`} onClick={() => setAdminTab(item.k)}>{item.icon} {item.label}</div>
          ))}
          <div className="adm-spacer"/><div className="adm-divider"/>
          <div className="adm-nav" onClick={doLogout}>← 退出登录</div>
        </div>
        <div className="adm-main">
          {adminTab==='albums' && <>
            <div className="adm-header">
              <div className="adm-title">相册管理 ({data.albums.length})</div>
              <button className="btn btn-dark btn-sm" onClick={openAdd}>＋ 新建相册</button>
            </div>
            {sa.length===0 ? <div className="empty"><div className="empty-icon">🖼️</div><div className="empty-txt">还没有相册</div></div> :
              sa.map(a => (
                <div key={a.id} className="list-item">
                  {a.cover ? <img src={a.cover} alt="" className="list-thumb"/> : <div className="list-no-thumb">📷</div>}
                  <div className="list-info"><div className="list-title">{a.title}</div><div className="list-meta">{a.category} · {a.photoCount||0} 张 · {fmtDate(a.updated_at)}</div></div>
                  <div className="list-actions">
                    <button className="btn btn-sm" onClick={() => openEdit(a)}>编辑</button>
                    {delConfirm===a.id ? <><button className="btn btn-red btn-sm" onClick={() => doDelete(a.id)}>确认删除</button><button className="btn btn-sm" onClick={() => setDelConfirm(null)}>取消</button></>
                      : <button className="btn btn-red btn-sm" onClick={() => setDelConfirm(a.id)}>删除</button>}
                  </div>
                </div>
              ))
            }
          </>}
          {adminTab==='categories' && <>
            <div className="adm-header"><div className="adm-title">分类管理</div></div>
            <div style={{display:'flex',gap:8,marginBottom:16}}>
              <input className="fi" style={{maxWidth:200}} value={newCat} placeholder="新分类名称" onChange={e => setNewCat(e.target.value)} onKeyDown={e => e.key==='Enter' && addCat()}/>
              <button className="btn btn-dark btn-sm" onClick={addCat}>添加</button>
            </div>
            <div style={{display:'flex',flexWrap:'wrap',gap:8}}>
              {data.categories.map(c => (
                <div key={c} className="cat-chip">
                  <span>{c}</span><span style={{fontSize:11,color:'var(--text3)'}}>{data.albums.filter(a=>a.category===c).length} 个</span>
                  <button className="cat-del" onClick={() => removeCat(c)}>×</button>
                </div>
              ))}
            </div>
          </>}
          {adminTab==='settings' && <>
            <div className="adm-header"><div className="adm-title">系统设置</div></div>
            <div style={{maxWidth:380}}>
              <div className="fg"><label className="fl">网站标题</label>
                <input className="fi" value={settingsForm?.siteTitle||''} onChange={e => setSettingsForm({...settingsForm, siteTitle:e.target.value})}/>
              </div>
              <div className="fg"><label className="fl">每页显示相册数</label>
                <select className="fi" value={settingsForm?.albumsPerPage||6} onChange={e => setSettingsForm({...settingsForm, albumsPerPage:parseInt(e.target.value)})}>
                  {[4,6,8,9,12,15].map(n => <option key={n} value={n}>{n} 个</option>)}
                </select>
              </div>
              <button className="btn btn-dark" onClick={saveSettings}>保存设置</button>
            </div>
          </>}
        </div>
      </div>
      {showForm && (
        <div className="f-overlay" onClick={e => e.target===e.currentTarget && setShowForm(false)}>
          <div className="f-box">
            <div className="f-title">{editingAlbum?'编辑相册':'新建相册'}</div>
            <div className="fg"><label className="fl">相册名称 *</label><input className="fi" value={form.title} onChange={e => setForm({...form,title:e.target.value})}/></div>
            <div className="fg"><label className="fl">封面图片 URL</label><input className="fi" value={form.cover} onChange={e => setForm({...form,cover:e.target.value})}/></div>
            <div style={{display:'grid',gridTemplateColumns:'1fr 1fr',gap:10}}>
              <div className="fg"><label className="fl">分类</label>
                <select className="fi" value={form.category} onChange={e => setForm({...form,category:e.target.value})}>
                  {data.categories.map(c => <option key={c} value={c}>{c}</option>)}
                </select>
              </div>
              <div className="fg"><label className="fl">照片数量</label><input className="fi" type="number" min="0" value={form.photoCount} onChange={e => setForm({...form,photoCount:e.target.value})}/></div>
            </div>
            <div className="fg"><label className="fl">标签（逗号分隔）</label><input className="fi" value={form.tags} onChange={e => setForm({...form,tags:e.target.value})}/></div>
            <div className="fg"><label className="fl">相册简介</label><textarea className="fi" value={form.description} onChange={e => setForm({...form,description:e.target.value})}/></div>
            <div style={{display:'flex',gap:8,justifyContent:'flex-end'}}>
              <button className="btn" onClick={() => setShowForm(false)}>取消</button>
              <button className="btn btn-dark" onClick={saveAlbum}>保存</button>
            </div>
          </div>
        </div>
      )}
      </>
    );
  }

  // ── 前台页面 ──
  const perPage = data.settings?.albumsPerPage || 6;
  const sorted = [...data.albums].sort((a,b) => new Date(b.updated_at) - new Date(a.updated_at));
  let filtered = activeCategory === '全部' ? sorted : sorted.filter(a => a.category === activeCategory);
  if (activeTag) filtered = filtered.filter(a => (a.tags||[]).includes(activeTag));
  if (searchQ.trim()) {
    const q = searchQ.trim().toLowerCase();
    filtered = filtered.filter(a => a.title.toLowerCase().includes(q) || a.description.toLowerCase().includes(q) || (a.tags||[]).some(t => t.toLowerCase().includes(q)));
  }
  const totalPages = Math.max(1, Math.ceil(filtered.length / perPage));
  const paged = filtered.slice((page-1)*perPage, page*perPage);
  const allTags = [...new Set(sorted.flatMap(a => a.tags||[]))];
  const catCounts = {};
  data.categories.forEach(c => { catCounts[c] = data.albums.filter(a => a.category === c).length; });
  const hasFilter = activeCategory !== '全部' || activeTag || searchQ.trim();

  return (
    <><style>{css}</style>
    <div>
      <header className="hdr">
        <div className="hdr-left">
          <button className={`sidebar-toggle ${mobileOpen||sidebarOpen ? 'open' : ''}`} onClick={toggleSidebar}><span/><span/><span/></button>
          <div className="hdr-title">📷 {data.settings?.siteTitle || '我的相册'}</div>
        </div>
        <div className="hdr-search">
          <span className="hdr-search-icon">🔍</span>
          <input value={searchQ} placeholder="搜索相册…" onChange={e => { setSearchQ(e.target.value); setPage(1); }}/>
        </div>
        <div style={{display:'flex',gap:8}}>
          <button className="btn btn-sm" onClick={() => { setPwInput(''); setLoginErr(''); setLoggedIn(true); }}>🔐 管理</button>
        </div>
      </header>
      <div className="layout">
        {isMobile && mobileOpen && <div className="sidebar-overlay" onClick={() => setMobileOpen(false)}/>}
        <div className={`sidebar-wrap ${isMobile ? (mobileOpen?'mobile-open':'') : (sidebarOpen?'':'collapsed')}`}>
          <div className="sidebar">
            <div>
              <div className="sb-section-label">分类</div>
              <div className={`cat-item ${activeCategory==='全部'?'active':''}`} onClick={() => selectCat('全部')}><span>全部</span><span className="cat-count">{data.albums.length}</span></div>
              {data.categories.map(c => (
                <div key={c} className={`cat-item ${activeCategory===c?'active':''}`} onClick={() => selectCat(c)}><span>{c}</span><span className="cat-count">{catCounts[c]||0}</span></div>
              ))}
            </div>
            {allTags.length > 0 && <div><div className="sb-section-label">标签</div><div className="tag-wrap">{allTags.map(t => <button key={t} className={`tag-btn ${activeTag===t?'active':''}`} onClick={() => selectTag(t)}>#{t}</button>)}</div></div>}
          </div>
        </div>
        <div className="main">
          <div className="main-header">
            <div className="main-info">
              {activeTag && <><strong>#{activeTag}</strong> · </>}
              {activeCategory!=='全部' && !activeTag && <><strong>{activeCategory}</strong> · </>}
              {searchQ.trim() && <><strong>"{searchQ}"</strong> · </>}
              {filtered.length} 个相册
            </div>
            {hasFilter && <button className="clear-btn" onClick={() => { setActiveCategory('全部'); setActiveTag(null); setSearchQ(''); setPage(1); }}>✕ 清除筛选</button>}
          </div>
          {paged.length===0 ? <div className="empty"><div className="empty-icon">🔍</div><div className="empty-txt">没有找到相册</div></div> :
            <div className="grid">{paged.map(a => (
              <div key={a.id} className="card" onClick={() => setSelectedAlbum(a)}>
                {a.cover ? <img src={a.cover} alt={a.title} className="card-img" loading="lazy"/> : <div className="card-no-img">📷</div>}
                <div className="card-body">
                  <div className="card-title">{a.title}</div>
                  <div className="card-footer"><span className="badge">{a.category}</span><span className="card-count">{a.photoCount||0} 张</span></div>
                  <div className="card-date">{fmtDate(a.updated_at)}</div>
                </div>
              </div>
            ))}</div>
          }
          {totalPages>1 && <div className="pager">
            <button className="pager-btn" disabled={page===1} onClick={() => setPage(p=>p-1)}>‹</button>
            {Array.from({length:totalPages},(_,i)=>i+1).map(p => <button key={p} className={`pager-btn ${p===page?'active':''}`} onClick={() => setPage(p)}>{p}</button>)}
            <button className="pager-btn" disabled={page===totalPages} onClick={() => setPage(p=>p+1)}>›</button>
          </div>}
        </div>
      </div>
    </div>
    {selectedAlbum && (
      <div className="overlay" onClick={e => e.target===e.currentTarget && setSelectedAlbum(null)}>
        <div className="modal">
          {selectedAlbum.cover && <img src={selectedAlbum.cover} alt={selectedAlbum.title} className="modal-img"/>}
          <div className="modal-body">
            <div className="modal-top"><div className="modal-title">{selectedAlbum.title}</div><button className="modal-close" onClick={() => setSelectedAlbum(null)}>✕</button></div>
            <div className="modal-meta">
              <span className="badge">{selectedAlbum.category}</span>
              <span style={{fontSize:12,color:'var(--text3)'}}>{selectedAlbum.photoCount||0} 张照片</span>
              <span style={{fontSize:12,color:'var(--text3)'}}>更新 {fmtDate(selectedAlbum.updated_at)}</span>
            </div>
            {selectedAlbum.description && <div className="modal-desc">{selectedAlbum.description}</div>}
            {(selectedAlbum.tags||[]).length>0 && <div className="modal-tags">{selectedAlbum.tags.map(t => <button key={t} className="tag-btn" onClick={() => { setSelectedAlbum(null); selectTag(t); }}>#{t}</button>)}</div>}
          </div>
        </div>
      </div>
    )}
    {/* 管理员登录弹窗 */}
    {loggedIn === false && window.location.hash !== '#admin' ? null : (
      <div className="overlay" onClick={e => e.target===e.currentTarget && setLoggedIn(null)}>
        <div className="login-box">
          <div className="login-title">管理员登录</div>
          <div className="fg">
            <label className="fl">密码</label>
            <input type="password" className="fi" value={pwInput} onChange={e => setPwInput(e.target.value)} onKeyDown={e => e.key==='Enter' && doLogin()} placeholder="输入管理密码" autoFocus/>
            {loginErr && <div className="err">{loginErr}</div>}
          </div>
          <div style={{display:'flex',gap:8,justifyContent:'flex-end'}}>
            <button className="btn" onClick={() => { setLoggedIn(null); setPwInput(''); }}>取消</button>
            <button className="btn btn-dark" onClick={doLogin}>登录</button>
          </div>
        </div>
      </div>
    )}
    </>
  );
}
APPJSX

# 回到项目根目录
cd ../..

info "安装依赖（后端 + 前端）..."
npm install --prefer-offline --no-audit --no-fund
cd client && npm install --prefer-offline --no-audit --no-fund && cd ..

success "依赖安装完成"
echo ""

case "$MODE" in
  --dev|-d)
    echo -e "${GREEN}开发模式已启动（前后端热更新）${RESET}"
    echo -e "  前端: http://localhost:5173"
    echo -e "  后端: http://localhost:3000"
    npm run dev
    ;;
  --build|-b)
    npm run build
    success "构建完成 → ./$INSTALL_DIR/client/dist/"
    echo -e "  部署时只需将 dist/ 与 server/ 上传，运行 node server/server.js 即可。"
    ;;
  *)
    echo -e "${BOLD}启动生产服务器...${RESET}"
    npm run build
    npm start
    ;;
esac
