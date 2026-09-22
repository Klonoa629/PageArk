import { socket } from '@kit.NetworkKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { LibraryManager } from './LibraryManager';

/**
 * WiFi 传书服务器：平板做 HTTP 服务器，电脑浏览器上传 PDF。
 * 协议刻意极简——浏览器 fetch POST 原始文件字节，文件名走 ?name= 查询参数，
 * 避开 multipart/form-data 解析（自研 TCP 层没有现成解析器）。
 * 请求头按字节累积到 \r\n\r\n，body 边收边写盘，不占内存。
 */

interface UploadCallbacks {
  onSaved: (fileName: string, size: number) => void;
  onError: (msg: string) => void;
}

// 每个 TCP 连接一个会话对象（在 connect 闭包里持有）
interface ClientSession {
  headerBytes: number[];
  headerDone: boolean;
  method: string;
  path: string;
  contentLength: number;
  bodyReceived: number;
  outFd: number; // -1 = 未打开目标文件
  fileName: string;
}

const PAGE_HTML: string = `<!doctype html>
<html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PageArk · 传书</title>
<style>
:root{--paper:#f4f1ea;--card:#fff;--ink:#21252b;--sub:#8a8578;--line:#e6e1d5;
--accent:#2f4bd7;--ok:#2b8a3e;--err:#c92a2a;--bar:#ece6d8}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;
background:var(--paper);color:var(--ink);min-height:100vh;display:flex;justify-content:center;padding:48px 16px}
.card{width:100%;max-width:600px;background:var(--card);border:1px solid var(--line);
border-radius:18px;box-shadow:0 12px 40px rgba(70,58,20,.08);padding:38px 34px;height:fit-content}
.head{display:flex;align-items:center;gap:13px}
.mark{width:42px;height:42px;border-radius:12px;background:var(--accent);display:flex;
align-items:center;justify-content:center;flex:none}
.mark svg{width:22px;height:22px;stroke:#fff;fill:none;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
h1{font-size:21px;font-weight:650;letter-spacing:.5px}
.sub{font-size:13px;color:var(--sub);margin:10px 0 24px 55px}
@media(max-width:480px){.sub{margin-left:0}}
.drop{border:1.5px dashed #cfc8b4;border-radius:14px;background:#faf8f1;padding:34px 18px;
text-align:center;cursor:pointer;transition:border-color .18s,background .18s}
.drop:hover,.drop.over{border-color:var(--accent);background:#f3f5ff}
.drop svg{width:32px;height:32px;stroke:#a89f88;fill:none;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round;transition:stroke .18s}
.drop:hover svg,.drop.over svg{stroke:var(--accent)}
.drop .t1{font-size:15px;font-weight:550;margin-top:10px}
.drop .t2{font-size:12px;color:var(--sub);margin-top:5px}
.file{border:1px solid var(--line);border-radius:12px;margin-top:10px;padding:11px 14px;background:#fff}
.file .r1{display:flex;align-items:center;gap:10px}
.file .nm{font-size:14px;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.file .sz{font-size:12px;color:var(--sub);flex:none}
.file .st{font-size:12px;flex:none;font-weight:550}
.file .st.ok{color:var(--ok)}.file .st.err{color:var(--err)}
.file .rm{border:0;background:none;color:#b3ab97;font-size:15px;cursor:pointer;flex:none;padding:0 2px}
.file .rm:hover{color:var(--err)}
.track{height:4px;border-radius:2px;background:var(--bar);margin-top:9px;overflow:hidden}
.fill{height:100%;border-radius:2px;background:var(--accent);width:0;transition:width .15s linear}
.fill.done{background:var(--ok)}.fill.bad{background:var(--err)}
button.up{width:100%;margin-top:22px;padding:14px;font-size:16px;font-weight:600;color:#fff;
background:var(--accent);border:0;border-radius:12px;cursor:pointer;transition:background .15s,opacity .15s;letter-spacing:2px}
button.up:hover:not(:disabled){background:#2438a8}
button.up:disabled{opacity:.4;cursor:not-allowed}
.foot{margin-top:22px;font-size:12px;color:var(--sub);text-align:center;line-height:1.8}
.hidden{display:none}
</style></head><body>
<div class="card">
  <div class="head">
    <div class="mark"><svg viewBox="0 0 24 24"><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/></svg></div>
    <h1>传书到平板</h1>
  </div>
  <p class="sub">电脑与平板连同一 WiFi · 选择或拖入 PDF，传完自动出现在书架上</p>
  <div class="drop" id="drop">
    <svg viewBox="0 0 24 24"><path d="M12 16V4"/><path d="M7 9l5-5 5 5"/><path d="M4 20h16"/></svg>
    <div class="t1">点击选择 PDF 文件</div>
    <div class="t2">或将文件拖拽到此处（支持多选）</div>
  </div>
  <input id="f" type="file" multiple accept="application/pdf,.pdf" style="display:none">
  <div id="files"></div>
  <button class="up" id="up" disabled>上传到平板</button>
  <p class="foot">PageArk · WiFi 传书<br>上传完成后在平板上查看书架，点击即可阅读</p>
</div>
<script>
var drop=document.getElementById('drop'),inp=document.getElementById('f'),
files=document.getElementById('files'),up=document.getElementById('up'),queue=[],busy=false;
function fmt(n){return n>1048576?(n/1048576).toFixed(1)+' MB':Math.max(1,Math.round(n/1024))+' KB'}
function add(fs){var n=0;for(var i=0;i<fs.length;i++){var f=fs[i];
if(!/\\.pdf$/i.test(f.name)){continue}queue.push({file:f,pct:-1,st:'wait'});n++}render()}
function render(){files.innerHTML='';
for(var i=0;i<queue.length;i++){(function(it,idx){
var row=document.createElement('div');row.className='file';
var r1=document.createElement('div');r1.className='r1';
var nm=document.createElement('span');nm.className='nm';nm.textContent=it.file.name;
var sz=document.createElement('span');sz.className='sz';sz.textContent=fmt(it.file.size);
r1.appendChild(nm);r1.appendChild(sz);
if(it.st==='ok'){var ok=document.createElement('span');ok.className='st ok';ok.textContent='已入库';r1.appendChild(ok)}
else if(it.st==='err'){var er=document.createElement('span');er.className='st err';er.textContent='失败';r1.appendChild(er)}
else if(it.st==='wait'&&!busy){var rm=document.createElement('button');rm.className='rm';rm.textContent='✕';
rm.onclick=function(){queue.splice(idx,1);render()};r1.appendChild(rm)}
row.appendChild(r1);
if(it.pct>=0){var t=document.createElement('div');t.className='track';
var fl=document.createElement('div');fl.className='fill'+(it.st==='ok'?' done':(it.st==='err'?' bad':''));
fl.style.width=(it.st==='ok'?100:it.pct)+'%';t.appendChild(fl);row.appendChild(t)}
files.appendChild(row)})(queue[i],i)}
var anyWait=false;for(var j=0;j<queue.length;j++){if(queue[j].st==='wait'){anyWait=true;break}}
up.disabled=!anyWait||busy}
drop.onclick=function(){if(!busy)inp.click()};
inp.onchange=function(){add(inp.files);inp.value=''};
drop.ondragover=function(e){e.preventDefault();drop.classList.add('over')};
drop.ondragleave=function(){drop.classList.remove('over')};
drop.ondrop=function(e){e.preventDefault();drop.classList.remove('over');add(e.dataTransfer.files)};
function postOne(it){return new Promise(function(res){
var xhr=new XMLHttpRequest();
xhr.open('POST','/upload?name='+encodeURIComponent(it.file.name));
xhr.upload.onprogress=function(e){if(e.lengthComputable){it.pct=Math.round(e.loaded/e.total*100);render()}};
xhr.onload=function(){it.st=xhr.status<300?'ok':'err';if(it.st==='err'){it.msg=xhr.responseText}render();setTimeout(res,250)};
xhr.onerror=function(){it.st='err';render();setTimeout(res,250)};
xhr.send(it.file)})}
up.onclick=async function(){if(busy)return;busy=true;render();
for(var i=0;i<queue.length;i++){if(queue[i].st==='wait'){queue[i].pct=0;await postOne(queue[i])}}
busy=false;render()};
render();
</script></body></html>`;

export class TransferServer {
  private static instance: TransferServer = new TransferServer();
  private server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
  private running: boolean = false;
  private cbs: UploadCallbacks | undefined = undefined;

  static get(): TransferServer {
    return TransferServer.instance;
  }

  isRunning(): boolean {
    return this.running;
  }

  deviceIp(): string {
    try {
      const ip: number = wifiManager.getIpInfo().ipAddress;
      return `${(ip >>> 24) & 0xFF}.${(ip >>> 16) & 0xFF}.${(ip >>> 8) & 0xFF}.${ip & 0xFF}`;
    } catch (e) {
      return '0.0.0.0';
    }
  }

  start(ctx: common.Context, cbs: UploadCallbacks): Promise<void> {
    this.cbs = cbs;
    return this.server.listen({ address: '0.0.0.0', port: 8080 }).then(() => {
      this.running = true;
      this.server.on('connect', (client: socket.TCPSocketConnection) => {
        const session: ClientSession = {
          headerBytes: [], headerDone: false,
          method: '', path: '', contentLength: 0, bodyReceived: 0,
          outFd: -1, fileName: ''
        };
        client.on('message', (info: socket.SocketMessageInfo) => {
          TransferServer.instance.onChunk(ctx, client, session, new Uint8Array(info.message));
        });
        client.on('close', () => {
          if (session.outFd >= 0) {
            try {
              fs.closeSync(session.outFd);
            } catch (e) {
            }
          }
        });
      });
    });
  }

  stop(): void {
    try {
      this.server.off('connect');
      this.server.close();
    } catch (e) {
    }
    this.running = false;
    this.cbs = undefined;
  }

  /** 在 headerBytes 中找 \r\n\r\n 的分隔下标，未找到返回 -1 */
  private static findHeaderEnd(bytes: number[]): number {
    for (let i = 3; i < bytes.length; i++) {
      if (bytes[i] === 10 && bytes[i - 1] === 13 && bytes[i - 2] === 10 && bytes[i - 3] === 13) {
        return i + 1;
      }
    }
    return -1;
  }

  private sanitizeFileName(raw: string): string {
    let base: string = raw;
    try {
      base = decodeURIComponent(raw);
    } catch (e) {
      // 名字解码失败就用原始串
    }
    base = base.replace(/[\\/:*?"<>|\u0000-\u001f]/g, '').trim();
    if (base === '' || base === '.' || base === '..') {
      base = `book-${Date.now()}.pdf`;
    }
    if (!/\.pdf$/i.test(base)) {
      base = base + '.pdf';
    }
    if (base.length > 120) {
      base = base.substring(base.length - 120);
    }
    return base;
  }

  private onChunk(ctx: common.Context, client: socket.TCPSocketConnection,
    session: ClientSession, chunk: Uint8Array): void {
    let offset: number = 0;
    if (!session.headerDone) {
      for (let i = 0; i < chunk.length; i++) {
        session.headerBytes.push(chunk[i]);
      }
      const end: number = TransferServer.findHeaderEnd(session.headerBytes);
      if (end < 0) {
        return; // 头还没收完
      }
      // 请求行与头部都是 ASCII（文件名在 URL 里是 percent-encoding，同属 ASCII）
      const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
      const headerText: string = decoder.decode(new Uint8Array(session.headerBytes.slice(0, end)));
      const lines: string[] = headerText.split('\r\n');
      const parts: string[] = lines[0].split(' ');
      session.method = parts.length > 0 ? parts[0] : '';
      session.path = parts.length > 1 ? parts[1] : '';
      for (let i = 1; i < lines.length; i++) {
        const kv: string[] = lines[i].split(':');
        if (kv.length >= 2 && kv[0].trim().toLowerCase() === 'content-length') {
          session.contentLength = parseInt(kv[1].trim(), 10) || 0;
        }
      }
      session.headerDone = true;
      offset = end;
      if (!this.route(ctx, client, session)) {
        return; // 非法请求已回绝并关连接
      }
    }
    // body 部分（可能同分片里带了一部分）
    if (session.outFd >= 0 && offset < chunk.length) {
      try {
        fs.writeSync(session.outFd, chunk.slice(offset).buffer);
      } catch (e) {
        this.fail(client, session, 'write error');
        return;
      }
      session.bodyReceived += chunk.length - offset;
      if (session.bodyReceived >= session.contentLength) {
        this.finishUpload(ctx, client, session);
      }
    }
  }

  /** 路由：GET / 回上传页；POST /upload 开文件准备接收。返回 false 表示已回绝 */
  private route(ctx: common.Context, client: socket.TCPSocketConnection, session: ClientSession): boolean {
    if (session.method === 'GET') {
      this.respondHtml(client, PAGE_HTML);
      return false;
    }
    if (session.method === 'POST' && session.path.startsWith('/upload')) {
      let name: string = '';
      const q: number = session.path.indexOf('?');
      if (q >= 0) {
        const params: string[] = session.path.substring(q + 1).split('&');
        for (const p of params) {
          if (p.startsWith('name=')) {
            name = p.substring(5);
          }
        }
      }
      session.fileName = this.sanitizeFileName(name);
      try {
        const dst: string = LibraryManager.booksDir(ctx) + '/' + session.fileName;
        session.outFd = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC).fd;
        return true;
      } catch (e) {
        this.respondJson(client, 500, 'save failed');
        return false;
      }
    }
    this.respondJson(client, 404, 'not found');
    return false;
  }

  private finishUpload(ctx: common.Context, client: socket.TCPSocketConnection, session: ClientSession): void {
    let size: number = 0;
    try {
      fs.closeSync(session.outFd);
      size = fs.statSync(LibraryManager.booksDir(ctx) + '/' + session.fileName).size;
    } catch (e) {
    }
    session.outFd = -1;
    this.respondJson(client, 200, session.fileName);
    setTimeout(() => {
      try {
        client.close();
      } catch (e) {
      }
    }, 300);
    if (this.cbs !== undefined) {
      this.cbs.onSaved(session.fileName, size);
    }
  }

  private fail(client: socket.TCPSocketConnection, session: ClientSession, msg: string): void {
    if (session.outFd >= 0) {
      try {
        fs.closeSync(session.outFd);
      } catch (e) {
      }
      session.outFd = -1;
    }
    this.respondJson(client, 500, msg);
    if (this.cbs !== undefined) {
      this.cbs.onError(msg);
    }
  }

  private respondHtml(client: socket.TCPSocketConnection, html: string): void {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(html);
    const head: string = 'HTTP/1.1 200 OK\r\n' +
      'Content-Type: text/html; charset=utf-8\r\n' +
      `Content-Length: ${bytes.length}\r\n` +
      'Connection: close\r\n\r\n';
    const headBytes: Uint8Array = new util.TextEncoder().encodeInto(head);
    const all: Uint8Array = new Uint8Array(headBytes.length + bytes.length);
    all.set(headBytes, 0);
    all.set(bytes, headBytes.length);
    client.send({ data: all.buffer }).catch(() => {
    });
    setTimeout(() => {
      try {
        client.close();
      } catch (e) {
      }
    }, 300);
  }

  private respondJson(client: socket.TCPSocketConnection, code: number, body: string): void {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(body);
    const head: string = `HTTP/1.1 ${code} ${code === 200 ? 'OK' : 'ERR'}\r\n` +
      'Content-Type: text/plain; charset=utf-8\r\n' +
      `Content-Length: ${bytes.length}\r\n` +
      'Connection: close\r\n\r\n';
    const headBytes: Uint8Array = new util.TextEncoder().encodeInto(head);
    const all: Uint8Array = new Uint8Array(headBytes.length + bytes.length);
    all.set(headBytes, 0);
    all.set(bytes, headBytes.length);
    client.send({ data: all.buffer }).catch(() => {
    });
  }
}
