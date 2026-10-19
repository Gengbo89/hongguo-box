#!/usr/bin/env python3
# 短剧盒子 · 网页版：本机跑服务，iPhone 用 Safari 打开即可观看（无需 Xcode / 无需侧载）
# 用法: python3 server.py [端口]
import http.server, json, os, subprocess, socketserver, sys, urllib.parse, tempfile, threading, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
HG2 = os.path.join(HERE, "hg2")
MEDIA = os.path.join(tempfile.gettempdir(), "duanju-media")
os.makedirs(MEDIA, exist_ok=True)
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

_lock = threading.Lock()

def hg2(*args, timeout=90):
    """调用 hg2 并返回 stdout；失败返回 None"""
    try:
        r = subprocess.run([HG2] + list(args), capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception:
        return None

def jload(s):
    try:
        return json.loads(s) if s else None
    except Exception:
        return None

PAGE = r"""<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="theme-color" content="#111">
<title>短剧盒子</title>
<style>
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{overflow-x:hidden}
body{margin:0;background:#0d0d0f;color:#eee;font:16px/1.5 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;padding-bottom:env(safe-area-inset-bottom)}
header{position:sticky;top:0;z-index:10;background:rgba(13,13,15,.92);backdrop-filter:blur(12px);padding:12px 16px calc(12px + env(safe-area-inset-top));padding-top:calc(12px + env(safe-area-inset-top));display:flex;gap:10px;align-items:center;border-bottom:1px solid #222}
h1{font-size:19px;margin:0;flex:1;font-weight:600}
.back{background:#222;border:0;color:#eee;font-size:17px;border-radius:9px;padding:7px 13px}
main{padding:14px}
.row{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:11px}
.card{background:#18181c;border-radius:11px;overflow:hidden;min-width:0}
.card:active{opacity:.65}
.card img{width:100%;aspect-ratio:3/4;object-fit:cover;display:block;background:#222}
.card .t{font-size:13px;padding:6px 7px 2px;font-weight:500;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;min-height:2.6em}
.card .r{font-size:11px;color:#888;padding:0 7px 7px}
h2{font-size:16px;margin:22px 0 11px;color:#bbb;font-weight:600}
.grid{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:8px}
.ep{background:#1e1e24;border-radius:9px;text-align:center;padding:12px 0;font-size:15px}
.ep.on{background:#e8b64c;color:#111;font-weight:700}
.ep:active{opacity:.6}
video{width:100%;max-height:72vh;background:#000;border-radius:11px;display:block}
.det{display:flex;gap:13px;margin-bottom:15px}
.det img{width:118px;aspect-ratio:3/4;object-fit:cover;border-radius:11px;background:#222}
.det .info{flex:1;min-width:0}
.det .info p{font-size:13px;color:#999;margin:7px 0 0;overflow:hidden;display:-webkit-box;-webkit-line-clamp:5;-webkit-box-orient:vertical}
.tag{display:inline-block;background:#25252c;color:#bbb;font-size:11px;padding:3px 8px;border-radius:5px;margin:0 5px 5px 0}
.bar{display:flex;gap:9px;align-items:center;margin:14px 0 10px;flex-wrap:wrap}
.bar b{font-size:15px;font-weight:600}
.def{background:#222;border:1px solid #333;color:#ddd;border-radius:8px;padding:7px 13px;font-size:13px}
.def.on{background:#e8b64c;color:#111;border-color:#e8b64c;font-weight:700}
.load{text-align:center;padding:44px;color:#777;font-size:14px}
.err{background:#3a1c1c;color:#ffb4b4;padding:13px;border-radius:9px;font-size:14px;margin:11px 0}
input{flex:1;background:#1c1c22;border:1px solid #2c2c34;color:#eee;border-radius:9px;padding:11px 13px;font-size:16px;min-width:0}
</style></head><body>
<header><button class="back" id="bk" style="display:none" onclick="history.back()">‹</button><h1 id="ttl">短剧盒子</h1></header>
<main id="app"><div class="load">加载中…</div></main>
<script>
const app=document.getElementById('app'),ttl=document.getElementById('ttl'),bk=document.getElementById('bk');
let S={defs:[],eps:[],cur:'',sid:'',title:''};
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const load=t=>app.innerHTML='<div class="load">'+t+'</div>';
const err=t=>app.innerHTML='<div class="err">'+esc(t)+'</div>';
function setBack(on){bk.style.display=on?'block':'none'}
async function api(p){const r=await fetch(p);if(!r.ok)throw new Error((await r.text())||('HTTP '+r.status));return r.json()}
function card(s){return '<div class="card" onclick="go(\'d\',\''+esc(s.id)+'\')"><img loading="lazy" src="'+esc(s.cover)+'"><div class="t">'+esc(s.title)+'</div><div class="r">'+esc(s.right)+'</div></div>'}

async function home(){
  ttl.textContent='短剧盒子';setBack(false);load('加载中…');
  try{
    const secs=await api('/api/home');
    let h='';
    for(const s of secs) h+='<h2>'+esc(s.name)+'</h2><div class="row">'+s.items.map(card).join('')+'</div>';
    app.innerHTML=h||'<div class="load">暂无内容</div>';
  }catch(e){err('加载失败：'+e.message)}
}
async function detail(id){
  S.sid=id;setBack(true);load('加载中…');
  try{
    const d=await api('/api/detail?id='+encodeURIComponent(id));
    S.eps=d.vids||[];S.title=d.title;ttl.textContent=d.title;
    let h='<div class="det"><img src="'+esc(d.cover)+'"><div class="info"><b>'+esc(d.title)+'</b><div style="margin-top:7px">'+
      (d.tags||[]).map(t=>'<span class="tag">'+esc(t)+'</span>').join('')+
      '</div><p>'+esc(d.intro)+'</p><div style="font-size:12px;color:#888;margin-top:7px">共 '+d.episodes+' 集</div></div></div>';
    h+='<h2>选集</h2><div class="grid">'+S.eps.map(e=>'<div class="ep" id="ep'+e.i+'" onclick="play('+e.i+')">'+e.i+'</div>').join('')+'</div>';
    app.innerHTML=h;
  }catch(e){err('加载失败：'+e.message)}
}
async function play(i){
  const ep=S.eps.find(x=>x.i===i);if(!ep)return;
  document.querySelectorAll('.ep').forEach(x=>x.classList.remove('on'));
  const el=document.getElementById('ep'+i);if(el)el.classList.add('on');
  ttl.textContent='第'+i+'集';
  load('正在解析片源…');
  try{
    const ts=await api('/api/tracks?vid='+encodeURIComponent(ep.vid));
    if(!ts.length)throw new Error('该集暂无可用片源');
    S.defs=ts;
    let h='<div class="bar"><b>第 '+i+' 集</b>'+ts.map((t,k)=>'<button class="def'+(k===ts.length-1?' on':'')+'" data-k="'+k+'" onclick="pick('+i+','+k+')">'+esc(t.def)+'</button>').join('')+'</div>';
    h+='<video id="v" controls autoplay playsinline webkit-playsinline></video><div class="load" id="st">准备中…（首次需解密，约 10–30 秒）</div>';
    h+='<div class="bar"><button class="def" onclick="detail(\''+esc(S.sid)+'\')">‹ 返回选集</button></div>';
    app.innerHTML=h;
    pick(i,ts.length-1);
  }catch(e){err('播放失败：'+e.message)}
}
function pick(i,k){
  const t=S.defs[k];if(!t)return;
  document.querySelectorAll('.def[data-k]').forEach(b=>b.classList.toggle('on',+b.dataset.k===k));
  const v=document.getElementById('v'),st=document.getElementById('st');
  st.style.display='block';st.textContent='准备中…（首次需解密，约 10–30 秒）';
  S.cur=t.def;
  v.src='/media?vid='+encodeURIComponent(S.eps.find(x=>x.i===i).vid)+'&def='+encodeURIComponent(t.def);
  v.load();
  v.oncanplay=()=>{st.style.display='none'};
  v.onerror=()=>{st.innerHTML='播放出错，可换一个清晰度试试'};
  v.play().catch(()=>{});
}
addEventListener('popstate',()=>{if(location.hash)detail(location.hash.slice(1));else home()});
function go(k,id){if(k==='d'){location.hash=id;detail(id)}}
if(location.search.indexOf('debug=1')>=0){
  setTimeout(()=>{
    const r=document.querySelector('.row')||document.querySelector('.det')||document.body;
    const g=document.querySelector('.grid');
    const wide=[...document.querySelectorAll('*')].filter(e=>e.getBoundingClientRect().right>window.innerWidth+1)
      .slice(0,6).map(e=>e.tagName+'.'+(e.className||'').toString().slice(0,18)+'@'+Math.round(e.getBoundingClientRect().right));
    document.title='M '+JSON.stringify({iw:window.innerWidth,sw:document.documentElement.scrollWidth,bw:document.body.scrollWidth,
      rowW:r?Math.round(r.getBoundingClientRect().width):null,gw:g?Math.round(g.getBoundingClientRect().width):null,over:wide});
  },6000);
}
if(location.hash.length>1)detail(location.hash.slice(1));else home();
</script></body></html>"""

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)

        if u.path in ("/", "/index.html"):
            return self._send(200, PAGE, "text/html; charset=utf-8")

        if u.path == "/api/home":
            r = hg2("home", timeout=40)
            return self._send(200 if r else 502, r or '{"error":"首页加载失败"}')

        if u.path == "/api/detail":
            sid = (q.get("id") or [""])[0]
            if not sid:
                return self._send(400, '{"error":"缺少 id"}')
            r = hg2("detail", sid, timeout=40)
            return self._send(200 if r else 502, r or '{"error":"该短剧不存在或已下架"}')

        if u.path == "/api/tracks":
            vid = (q.get("vid") or [""])[0]
            if not vid:
                return self._send(400, '{"error":"缺少 vid"}')
            r = hg2("tracks", vid, timeout=60)
            return self._send(200 if r is not None else 502, r or '[]')

        if u.path == "/media":
            vid = (q.get("vid") or [""])[0]
            dfn = (q.get("def") or [""])[0]
            if not vid or not dfn:
                return self._send(400, '{"error":"缺少参数"}')
            key = hashlib.sha1((vid + "|" + dfn).encode()).hexdigest()
            out = os.path.join(MEDIA, key + ".mp4")
            if not os.path.exists(out) or os.path.getsize(out) == 0:
                with _lock:
                    if not os.path.exists(out) or os.path.getsize(out) == 0:
                        tmp = out + ".part"
                        r = hg2("prepare", vid, dfn, tmp, timeout=300)
                        if not r or not os.path.exists(tmp):
                            return self._send(502, "转码失败")
                        os.replace(tmp, out)
            return self._serve_file(out)

        return self._send(404, '{"error":"not found"}')

    def _serve_file(self, path):
        size = os.path.getsize(path)
        rng = self.headers.get("Range")
        start, end = 0, size - 1
        if rng and rng.startswith("bytes="):
            part = rng[6:].split(",")[0].split("-")
            try:
                if part[0]:
                    start = int(part[0]); end = int(part[1]) if len(part) > 1 and part[1] else size - 1
                else:
                    start = max(0, size - int(part[1])); end = size - 1
            except Exception:
                start, end = 0, size - 1
        start = max(0, min(start, size - 1)); end = max(start, min(end, size - 1))
        length = end - start + 1
        self.send_response(206 if rng else 200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if rng:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        try:
            with open(path, "rb") as f:
                f.seek(start)
                left = length
                while left > 0:
                    b = f.read(min(262144, left))
                    if not b:
                        break
                    self.wfile.write(b); left -= len(b)
        except Exception:
            pass

class Srv(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

if __name__ == "__main__":
    if not os.path.exists(HG2):
        print("找不到 hg2，请先编译：swiftc -parse-as-library -O HG2.swift Sources/Core/*.swift -o hg2")
        sys.exit(1)
    try:
        with Srv(("0.0.0.0", PORT), H) as httpd:
            print("短剧盒子 网页版已启动")
            print("  本机:   http://127.0.0.1:%d" % PORT)
            import socket
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                s.connect(("8.8.8.8", 80)); ip = s.getsockname()[0]; s.close()
                print("  iPhone: http://%s:%d   （需与 Mac 同一 Wi-Fi）" % (ip, PORT))
            except Exception:
                pass
            httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")
