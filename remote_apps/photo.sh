<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>公开相册 - Public Album</title>
    <style>
        :root{--bg:#f5f5f5;--card-bg:#fff;--text:#333;--text-sec:#777;--border:#e0e0e0;--shadow:0 2px 12px rgba(0,0,0,0.08);--shadow-hov:0 8px 30px rgba(0,0,0,0.15);--accent:#4a90d9;--accent-hov:#357abd;--danger:#e05555;--overlay:rgba(0,0,0,0.9);--rad:12px;--rad-sm:8px;--trans:0.25s ease;--max-w:1400px;--hdr-h:60px;--gap:16px}
        @media(prefers-color-scheme:dark){:root{--bg:#1a1a1f;--card-bg:#252530;--text:#e0e0e0;--text-sec:#aaa;--border:#3a3a45;--shadow:0 2px 12px rgba(0,0,0,0.3);--shadow-hov:0 8px 30px rgba(0,0,0,0.5);--accent:#5ba0e8;--overlay:rgba(0,0,0,0.95)}}
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--text);min-height:100vh;line-height:1.6;transition:all var(--trans)}
        .header{position:sticky;top:0;z-index:100;background:var(--card-bg);border-bottom:1px solid var(--border);backdrop-filter:blur(20px);height:var(--hdr-h);display:flex;align-items:center;padding:0 20px}
        .header-inner{max-width:var(--max-w);width:100%;margin:0 auto;display:flex;justify-content:space-between;align-items:center}
        .logo{font-size:1.35rem;font-weight:700;color:var(--text);text-decoration:none;display:flex;align-items:center;gap:8px}
        .logo svg{width:28px;height:28px}
        .header-actions{display:flex;gap:10px}
        .btn{display:inline-flex;align-items:center;gap:6px;padding:8px 16px;border-radius:20px;font-size:.9rem;font-weight:500;cursor:pointer;border:1.5px solid transparent;transition:var(--trans);background:0 0;color:var(--text)}
        .btn-outline{border-color:var(--border)}.btn-outline:hover{border-color:var(--accent);color:var(--accent)}
        .btn-primary{background:var(--accent);color:#fff}.btn-primary:hover{background:var(--accent-hov)}
        .btn-danger{background:var(--danger);color:#fff}.btn-sm{padding:5px 12px;font-size:.8rem}
        .album-tabs{max-width:var(--max-w);margin:16px auto 0;padding:0 20px;display:flex;gap:8px;overflow-x:auto;scrollbar-width:none}
        .album-tabs::-webkit-scrollbar{display:none}
        .album-tab{padding:8px 18px;border-radius:20px;font-size:.9rem;cursor:pointer;border:1.5px solid transparent;background:var(--card-bg);color:var(--text-sec);white-space:nowrap;transition:var(--trans)}
        .album-tab:hover{color:var(--text);border-color:var(--border)}.album-tab.active{background:var(--accent);color:#fff;border-color:var(--accent)}
        .gallery-container{max-width:var(--max-w);margin:20px auto;padding:0 20px}
        .gallery{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:var(--gap)}
        .photo-card{position:relative;border-radius:var(--rad);overflow:hidden;background:var(--card-bg);box-shadow:var(--shadow);cursor:pointer;aspect-ratio:4/3;transition:var(--trans)}
        .photo-card:hover{transform:translateY(-4px);box-shadow:var(--shadow-hov)}
        .photo-card img{width:100%;height:100%;object-fit:cover;transition:transform .4s}
        .photo-card:hover img{transform:scale(1.05)}
        .photo-card-overlay{position:absolute;bottom:0;left:0;right:0;padding:24px 12px 12px;background:linear-gradient(transparent,rgba(0,0,0,.7));opacity:0;transition:var(--trans);pointer-events:none}
        .photo-card:hover .photo-card-overlay{opacity:1}
        .photo-card-title{color:#fff;font-size:.85rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;display:block}
        .btn-del-photo{position:absolute;top:8px;right:8px;background:var(--danger);color:#fff;border:none;border-radius:4px;padding:4px 8px;font-size:.8rem;cursor:pointer;display:none;z-index:2;pointer-events:auto}
        .photo-card.admin-mode .btn-del-photo{display:block}
        .empty-state{grid-column:1/-1;text-align:center;padding:60px 20px;color:var(--text-sec)}
        .skeleton{border-radius:var(--rad);aspect-ratio:4/3;background:linear-gradient(90deg,var(--card-bg) 25%,var(--border) 50%,var(--card-bg) 75%);background-size:200% 100%;animation:shimmer 1.5s infinite}
        @keyframes shimmer{0%{background-position:200% 0}100%{background-position:-200% 0}}
        .lightbox{position:fixed;inset:0;z-index:9999;background:var(--overlay);display:flex;align-items:center;justify-content:center;opacity:0;pointer-events:none;transition:opacity .3s}
        .lightbox.active{opacity:1;pointer-events:auto}
        .lightbox img{max-width:90vw;max-height:85vh;object-fit:contain;border-radius:8px;user-select:none}
        .lb-btn{position:absolute;background:rgba(255,255,255,.15);border:none;color:#fff;cursor:pointer;display:flex;align-items:center;justify-content:center;border-radius:50%;transition:var(--trans)}
        .lb-btn:hover{background:rgba(255,255,255,.3)}
        .lb-close{top:16px;right:20px;width:44px;height:44px;font-size:1.5rem}
        .lb-nav{top:50%;transform:translateY(-50%);width:48px;height:48px;font-size:1.5rem}
        .lb-nav.prev{left:12px}.lb-nav.next{right:12px}
        .lb-info{position:absolute;bottom:20px;color:#fff;background:rgba(0,0,0,.5);padding:6px 16px;border-radius:20px}
        .modal-overlay{position:fixed;inset:0;z-index:9000;background:rgba(0,0,0,.5);display:flex;align-items:center;justify-content:center;opacity:0;pointer-events:none;transition:.25s}
        .modal-overlay.active{opacity:1;pointer-events:auto}
        .modal{background:var(--card-bg);border-radius:var(--rad);width:100%;max-width:500px;max-height:85vh;overflow-y:auto;padding:24px;position:relative;transform:translateY(20px);transition:.25s}
        .modal-overlay.active .modal{transform:translateY(0)}
        .form-group{margin-bottom:16px}
        .form-group label{display:block;font-size:.85rem;margin-bottom:6px}
        .form-group input,.form-group textarea,.form-group select{width:100%;padding:10px;border:1.5px solid var(--border);border-radius:var(--rad-sm);background:var(--bg);color:var(--text);font-family:inherit}
        .form-group input:focus,.form-group textarea:focus{border-color:var(--accent);outline:none}
        .upload-zone{border:2px dashed var(--border);border-radius:var(--rad);padding:30px;text-align:center;cursor:pointer}
        .upload-zone:hover{border-color:var(--accent);background:rgba(74,144,217,.04)}
        .upload-preview{display:flex;gap:8px;margin-top:12px;flex-wrap:wrap}
        .upload-preview img{width:60px;height:60px;object-fit:cover;border-radius:6px}
        .toast-container{position:fixed;top:20px;right:20px;z-index:99999;display:flex;flex-direction:column;gap:8px}
        .toast{padding:12px 18px;border-radius:var(--rad-sm);color:#fff;animation:slideIn .3s,fadeOut .3s 2.5s forwards}
        .toast.success{background:#4caf84}.toast.error{background:#e05555}.toast.info{background:#5ba0e8}
        @keyframes slideIn{from{transform:translateX(120%)}to{transform:translateX(0)}}
        @keyframes fadeOut{to{opacity:0;transform:translateY(-10px)}}
        .settings-bar{max-width:var(--max-w);margin:8px auto 0;padding:0 20px;font-size:.8rem;color:var(--text-sec)}
        @media(max-width:768px){.gallery{grid-template-columns:repeat(2,1fr);gap:8px}:root{--gap:8px;--hdr-h:52px}.lb-nav{width:36px;height:36px}}
    </style>
</head>
<body>
    <header class="header">
        <div class="header-inner">
            <a href="/" class="logo">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>
                公开相册
            </a>
            <div class="header-actions">
                <button class="btn btn-outline btn-sm admin-only" id="btnAddAlbum" style="display:none">📁 新建</button>
                <button class="btn btn-primary btn-sm admin-only" id="btnAddPhoto" style="display:none">📷 添加图片</button>
                <button class="btn btn-outline btn-sm admin-only" id="btnSettings" style="display:none">⚙️ 设置</button>
                <button class="btn btn-outline btn-sm admin-only" id="btnLogout" style="display:none">退出</button>
            </div>
        </div>
    </header>

    <nav class="album-tabs" id="albumTabs"></nav>
    <div class="settings-bar admin-only" style="display:none">存储模式: <strong id="storageModeLabel">本地存储</strong></div>
    
    <main class="gallery-container">
        <div class="gallery" id="gallery"></div>
    </main>

    <!-- Lightbox -->
    <div class="lightbox" id="lightbox">
        <button class="lb-btn lb-close" id="lbClose">✕</button>
        <button class="lb-btn lb-nav prev" id="lbPrev">◀</button>
        <button class="lb-btn lb-nav next" id="lbNext">▶</button>
        <div id="lbContent"></div>
        <div class="lb-info" id="lbInfo"></div>
    </div>

    <!-- Modals -->
    <div class="modal-overlay" id="modalAuth"><div class="modal">
        <h3>🔐 管理员验证</h3>
        <div class="form-group"><input type="password" id="authPwd" placeholder="输入管理密码" autocomplete="off"></div>
        <div style="text-align:right"><button class="btn btn-primary btn-sm" id="btnAuth">验证</button></div>
    </div></div>

    <div class="modal-overlay" id="modalAlbum"><div class="modal">
        <h3 id="albumTitle">📁 新建相册</h3><input type="hidden" id="editAlbumId">
        <div class="form-group"><input type="text" id="albumName" placeholder="相册名称"></div>
        <div class="form-group"><textarea id="albumDesc" placeholder="相册描述(可选)"></textarea></div>
        <div style="display:flex;gap:10px;justify-content:flex-end">
            <button class="btn btn-danger btn-sm" id="btnDelAlbum" style="display:none">删除</button>
            <button class="btn btn-outline btn-sm close-modal">取消</button>
            <button class="btn btn-primary btn-sm" id="btnSaveAlbum">保存</button>
        </div>
    </div></div>

    <div class="modal-overlay" id="modalPhoto"><div class="modal">
        <h3>📷 添加图片</h3>
        <div class="form-group"><select id="selAlbum"></select></div>
        <div class="form-group">
            <div class="upload-zone" id="dropZone"><p>点击或拖拽图片到此处(最大20MB)</p></div>
            <input type="file" id="fileInp" accept="image/*" multiple style="display:none">
            <div class="upload-preview" id="previewBox"></div>
        </div>
        <div class="form-group">
            <textarea id="urlInp" placeholder="或粘贴图片URL，每行一个" rows="3"></textarea>
        </div>
        <div class="form-group"><input type="text" id="picTitle" placeholder="图片统一标题(可选)"></div>
        <div style="text-align:right">
            <button class="btn btn-outline btn-sm close-modal">取消</button>
            <button class="btn btn-primary btn-sm" id="btnSavePhoto">添加</button>
        </div>
    </div></div>

    <div class="modal-overlay" id="modalSettings"><div class="modal">
        <h3>⚙️ 系统设置</h3>
        <div class="form-group">
            <select id="setMode"><option value="local">本地存储</option><option value="smms">SM.MS 图床</option><option value="url_only">仅URL模式</option></select>
        </div>
        <div class="form-group" id="smmsGrp"><input type="text" id="setToken" placeholder="SM.MS API Token"></div>
        <div class="form-group"><input type="password" id="setPwd" placeholder="修改密码(不改留空)"></div>
        <div style="text-align:right"><button class="btn btn-outline btn-sm close-modal">取消</button><button class="btn btn-primary btn-sm" id="btnSaveSet">保存</button></div>
    </div></div>

    <div class="toast-container" id="toastBox"></div>

    <script>
        const $ = s => document.querySelector(s), $$ = s => document.querySelectorAll(s);
        const ST = { admin: false, tk: '', albs: [], pics: [], curAlb: 'all', lbIdx: -1, mode: 'local', files: [] };
        const esc = s => { const d=document.createElement('div'); d.textContent=s; return d.innerHTML; };
        const toast = (m, type='info') => {
            const t = document.createElement('div'); t.className = `toast ${type}`; t.textContent = m;
            $('#toastBox').appendChild(t); setTimeout(() => t.remove(), 3000);
        };

        const API = {
            async req(path, opt = {}) {
                const h = { ...opt.headers }; if (ST.tk) h['X-Admin-Token'] = ST.tk;
                if (!(opt.body instanceof FormData)) h['Content-Type'] = 'application/json';
                try {
                    const r = await fetch(path.startsWith('http') ? path : `/api${path}`, { ...opt, headers: h });
                    const d = await r.json(); if (!r.ok) throw new Error(d.detail || '请求失败'); return d;
                } catch(e) { if(e.name==='TypeError') throw new Error('网络异常，请检查连接'); throw e; }
            }
        };

        // --- Auth & Admin ---
        const updateUI = () => {
            $$('.admin-only').forEach(e => e.style.display = ST.admin ? '' : 'none');
            $$('.photo-card').forEach(c => c.classList.toggle('admin-mode', ST.admin));
        };
        const checkHash = () => {
            if (location.hash === '#/admin') {
                history.replaceState(null, null, window.location.pathname); // 清除hash
                $('.modal-overlay').classList.remove('active'); // close others
                $('#modalAuth').classList.add('active'); $('#authPwd').focus();
            }
        };
        const auth = async p => {
            try { const d = await API.req('/auth',{method:'POST',body:JSON.stringify({password:p})});
                ST.tk=d.token; ST.admin=true; localStorage.setItem('tk',d.token);
                updateUI(); $('#modalAuth').classList.remove('active'); toast('验证成功','success'); loadAll();
            } catch(e) { toast(e.message,'error'); }
        };

        // --- Core Functions ---
        const loadAll = async () => {
            try {
                const [a, p, s] = await Promise.all([API.req('/albums'), API.req(`/photos${ST.curAlb==='all'?'':`?album_id=${ST.curAlb}`}`), ST.admin?API.req('/settings'):Promise.resolve({})]);
                ST.albs = a.albums||[]; ST.pics = p.photos||[];
                if(ST.admin) { ST.mode = s.storage_mode||'local'; $('#setMode').value=ST.mode; $('#setToken').value=s.smms_token||''; $('#storageModeLabel').textContent = ST.mode==='local'?'本地存储':(ST.mode==='smms'?'SM.MS':'URL模式'); $('#smmsGrp').style.display=ST.mode==='smms'?'':'none';}
                renderTabs(); renderGal();
            } catch(e) { console.error(e); }
        };

        const renderTabs = () => {
            let h = `<button class="album-tab ${ST.curAlb==='all'?'active':''}" data-id="all">📷 全部</button>`;
            ST.albs.forEach(a => h += `<button class="album-tab ${ST.curAlb==String(a.id)?'active':''}" data-id="${a.id}">${esc(a.name)}</button>`);
            $('#albumTabs').innerHTML = h;
        };

        const renderGal = () => {
            const g = $('#gallery');
            if(!ST.pics.length) return g.innerHTML = `<div class="empty-state"><h3>暂无图片</h3></div>`;
            g.innerHTML = ST.pics.map((p,i) => `
                <div class="photo-card ${ST.admin?'admin-mode':''}" data-idx="${i}" title="${esc(p.title||'')}">
                    <img src="${esc(p.url)}" loading="lazy" onerror="this.src='data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 200 150%22><rect fill=%22%23e0e0e0%22 width=%22200%22 height=%22150%22/></svg>'">
                    <div class="photo-card-overlay">
                        <span class="photo-card-title">${esc(p.title||'无标题')}</span>
                        <button class="btn-del-photo" data-id="${p.id}" title="删除">🗑️</button>
                    </div>
                </div>`).join('');
        };

        // --- Event Binding ---
        window.addEventListener('hashchange', checkHash);
        $('#btnAuth').onclick = () => auth($('#authPwd').value);
        $('#authPwd').onkeyup = e => { if(e.key==='Enter') auth(e.target.value); };
        $('#btnLogout').onclick = () => { ST.admin=false; ST.tk=''; localStorage.removeItem('tk'); updateUI(); renderGal(); toast('已退出管理'); };
        $$('.close-modal').forEach(b => b.onclick = e => e.target.closest('.modal-overlay').classList.remove('active'));

        // Gallery Event Delegation (Click Image vs Click Delete)
        $('#gallery').onclick = async e => {
            const delBtn = e.target.closest('.btn-del-photo');
            if (delBtn && ST.admin) {
                e.stopPropagation();
                if(confirm('确定删除此图片？')) {
                    try { await API.req(`/photos/${delBtn.dataset.id}`, {method:'DELETE'}); toast('已删除','success'); loadAll(); } 
                    catch(err) { toast('删除失败','error'); }
                }
                return;
            }
            const card = e.target.closest('.photo-card');
            if (card) {
                ST.lbIdx = parseInt(card.dataset.idx); $('#lightbox').classList.add('active'); showLb();
            }
        };

        // Tabs
        $('#albumTabs').onclick = e => {
            const t = e.target.closest('.album-tab'); if(!t) return;
            ST.curAlb = t.dataset.id; renderTabs(); loadAll();
        };

        // Add Photo
        $('#btnAddPhoto').onclick = () => {
            if(!ST.albs.length) return toast('请先建相册','info');
            $('#selAlbum').innerHTML = ST.albs.map(a=>`<option value="${a.id}">${esc(a.name)}</option>`).join('');
            ST.files=[]; $('#previewBox').innerHTML=''; $('#urlInp').value=''; $('#picTitle').value='';
            $('#modalPhoto').classList.add('active');
        };
        $('#dropZone').onclick = () => $('#fileInp').click();
        $('#fileInp').onchange = e => {
            for(let f of e.target.files) {
                if(f.size > 20*1024*1024) { toast(`${f.name}超过20MB`,'error'); continue; }
                ST.files.push(f);
                const r = new FileReader(); r.onload = ev => { $('#previewBox').innerHTML += `<img src="${ev.target.result}">`; }; r.readAsDataURL(f);
            }
        };
        $('#btnSavePhoto').onclick = async () => {
            const aid = $('#selAlbum').value, t = $('#picTitle').value.trim(), urls = $('#urlInp').value.split('\n').map(u=>u.trim()).filter(u=>u);
            let c = 0;
            for(let u of urls) {
                if(!/^https?:\/\//.test(u)) { toast(`无效URL:${u.substring(0,20)}`,'error'); continue; }
                try { await API.req('/photos/url', {method:'POST',body:JSON.stringify({url:u,album_id:aid,title:t})}); c++; } catch(e){}
            }
            for(let i=0; i<ST.files.length; i++) {
                const f = ST.files[i], fd = new FormData(), ft = t ? (ST.files.length>1 ? `${t}-${i+1}`:t) : f.name.split('.')[0];
                fd.append('file', f); fd.append('album_id', aid); fd.append('title', ft);
                try { await API.req('/photos', {method:'POST',body:fd}); c++; } catch(e){}
            }
            if(c>0){ toast(`成功添加${c}张`,'success'); $('#modalPhoto').classList.remove('active'); loadAll(); }
        };

        // Album Management
        $('#btnAddAlbum').onclick = () => { $('#editAlbumId').value=''; $('#albumName').value=''; $('#albumDesc').value=''; $('#btnDelAlbum').style.display='none'; $('#modalAlbum').classList.add('active'); };
        $('#btnSaveAlbum').onclick = async () => {
            const id=$('#editAlbumId').value, n=$('#albumName').value, d=$('#albumDesc').value;
            if(!n) return toast('请输入名称','error');
            try { await API.req(id?`/albums/${id}`:'/albums', {method:id?'PUT':'POST',body:JSON.stringify({name:n,description:d})}); toast('保存成功','success'); $('#modalAlbum').classList.remove('active'); loadAll(); } catch(e) { toast(e.message,'error'); }
        };

        // Settings
        $('#btnSettings').onclick = () => $('#modalSettings').classList.add('active');
        $('#setMode').onchange = e => $('#smmsGrp').style.display = e.target.value==='smms'?'':'none';
        $('#btnSaveSet').onclick = async () => {
            const d = { storage_mode: $('#setMode').value, smms_token: $('#setToken').value || "" };
            if($('#setPwd').value) d.new_password = $('#setPwd').value;
            try { await API.req('/settings', {method:'PUT',body:JSON.stringify(d)}); toast('设置已保存','success'); $('#modalSettings').classList.remove('active'); loadAll(); } catch(e) { toast(e.message,'error'); }
        };

        // Lightbox
        const showLb = () => { const p=ST.pics[ST.lbIdx]; if(!p)return; $('#lbContent').innerHTML=`<img src="${esc(p.url)}">`; $('#lbInfo').textContent=`${p.title||'无标题'} (${ST.lbIdx+1}/${ST.pics.length})`; };
        $('#lbClose').onclick = () => $('#lightbox').classList.remove('active');
        $('#lbPrev').onclick = () => { ST.lbIdx=(ST.lbIdx-1+ST.pics.length)%ST.pics.length; showLb(); };
        $('#lbNext').onclick = () => { ST.lbIdx=(ST.lbIdx+1)%ST.pics.length; showLb(); };

        // Init
        const init = async () => {
            ST.tk = localStorage.getItem('tk');
            if (ST.tk) { try { await API.req('/verify-token'); ST.admin=true; } catch(e) { ST.tk=''; localStorage.removeItem('tk'); } }
            updateUI(); checkHash(); loadAll();
        };
        init();
    </script>
</body>
</html>
