// Live progress page (HTTP + WebSocket) for a run_stepper_labs output folder.
//   bun tools/progress_dashboard.ts <run_dir> [matlab_log_file] [port=8765]
// Schedule comes from <run_dir>/queue.json (written by run_stepper_labs); a run counts as
// done when <run_dir>/<tag>.mat exists. The optional log adds the MATLAB output tail.
import { existsSync, readdirSync, readFileSync, statSync } from "fs";
import { join, resolve, relative } from "path";

const RUN_DIR = resolve(process.argv[2] ?? "");
const LOG_FILE = process.argv[3] ? resolve(process.argv[3]) : "";
const PORT = Number(process.argv[4] ?? 8765);
if (!process.argv[2] || !existsSync(join(RUN_DIR, "queue.json"))) {
  console.error("usage: bun tools/progress_dashboard.ts <run_dir with queue.json> [log_file] [port]");
  process.exit(1);
}

type Job = { lab: string; tag: string; stop_time: number; drive_label: string; accel: number; trial: number };
const OVERHEAD_S = 4.5; // model load + cooldown per run, measured on the lab PC

function snapshot() {
  const now = Date.now();
  const raw = JSON.parse(readFileSync(join(RUN_DIR, "queue.json"), "utf8"));
  const queue: Job[] = Array.isArray(raw) ? raw : [raw];
  const mats = new Map<string, number>();
  for (const f of readdirSync(RUN_DIR)) {
    if (f.endsWith(".mat")) mats.set(f.slice(0, -4), statSync(join(RUN_DIR, f)).mtimeMs);
  }
  const done = queue.filter((j) => mats.has(j.tag)).length;
  const lastMs = Math.max(0, ...queue.map((j) => mats.get(j.tag) ?? 0));
  const log = LOG_FILE && existsSync(LOG_FILE) ? readFileSync(LOG_FILE, "utf8") : "";
  const failed = /Error using|Error in /.test(log);
  const firstPending = queue.findIndex((j) => !mats.has(j.tag));
  const runs = queue.map((j, i) => ({
    i: i + 1, lab: j.lab, tag: j.tag, stop_s: j.stop_time,
    status: mats.has(j.tag) ? "done" : i === firstPending && !failed ? "running" : "pending",
  }));
  let eta = 0;
  for (const r of runs) {
    if (r.status === "pending") eta += r.stop_s + OVERHEAD_S;
    if (r.status === "running") eta += Math.max(1, r.stop_s + OVERHEAD_S - (lastMs ? (now - lastMs) / 1000 : 0));
  }
  const labs = [...new Set(queue.map((j) => j.lab))].map((lab) => {
    const sub = runs.filter((r) => r.lab === lab);
    return { lab, done: sub.filter((r) => r.status === "done").length, total: sub.length };
  });
  const status = done === queue.length ? "COMPLETED" : failed ? "ERROR" : "RUNNING";
  const logTail = log.split(/\r?\n/)
    .filter((l) => l.trim() && !/^\s*(Evaluating |Callback:|In amg_|\[> In |mxs_|try|catch|end$|clear mxs_)/.test(l))
    .slice(-40);
  const figs: string[] = [];
  for (const sub of ["figures", "figures_raw"]) {
    const p = join(RUN_DIR, sub);
    if (existsSync(p)) for (const f of readdirSync(p).sort()) if (f.endsWith(".png")) figs.push(`${sub}/${f}`);
  }
  return {
    ts: new Date(now).toLocaleTimeString(), status, done, total: queue.length,
    pct: Math.round((1000 * done) / queue.length) / 10, eta_s: status === "COMPLETED" ? 0 : Math.round(eta),
    runDir: RUN_DIR, labs, runs, logTail, figs,
  };
}

const HTML = `<!doctype html><html><head><meta charset="utf-8"><title>Stepper lab progress</title>
<style>body{font:14px system-ui,sans-serif;background:#0f172a;color:#e2e8f0;margin:20px}
.card{background:#1e293b;border:1px solid #334155;border-radius:10px;padding:14px;margin-bottom:14px}
.bar{height:12px;background:#0b1220;border-radius:6px;overflow:hidden}.fill{height:100%;background:#22c55e}
table{width:100%;border-collapse:collapse;font-size:12.5px}td,th{padding:4px 8px;border-bottom:1px solid #263348;text-align:left}
.done{color:#86efac}.running{color:#7dd3fc}.pending{color:#64748b}pre{white-space:pre-wrap;font-size:12px;max-height:380px;overflow:auto;background:#0b1220;padding:10px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:14px}img{width:100%;background:#fff;border-radius:6px}</style></head><body>
<h2>Lab 2.2 Stepper — live progress</h2><div class="card"><div id="head">connecting…</div><div class="bar"><div id="fill" class="fill" style="width:0"></div></div><div id="labs"></div></div>
<div class="grid"><div class="card" style="max-height:480px;overflow:auto"><table id="runs"></table></div><div class="card"><pre id="log"></pre></div></div>
<div class="card" id="figs"></div>
<script>
const fmt=s=>s>=60?Math.floor(s/60)+'m '+(s%60)+'s':s+'s';let figKey='';
function render(d){
 head.textContent=d.status+' · '+d.done+'/'+d.total+' runs ('+d.pct+'%) · ETA '+fmt(d.eta_s)+' · '+d.runDir+' · '+d.ts;
 fill.style.width=d.pct+'%';
 labs.textContent=d.labs.map(l=>l.lab+' '+l.done+'/'+l.total).join('   ');
 runs.innerHTML='<tr><th>#</th><th>Lab</th><th>Tag</th><th>Status</th><th>StopTime</th></tr>'+d.runs.map(r=>'<tr><td>'+r.i+'</td><td>'+r.lab+'</td><td>'+r.tag+'</td><td class="'+r.status+'">'+r.status+'</td><td>'+r.stop_s+' s</td></tr>').join('');
 log.textContent=d.logTail.join('\\n')||'(no log file given)';
 const k=d.figs.join('|');if(k!==figKey){figKey=k;figs.innerHTML=d.figs.map(f=>'<p>'+f+'</p><img src="/files/'+f+'?t='+Date.now()+'">').join('');}
}
(function connect(){const ws=new WebSocket('ws://'+location.host+'/ws');ws.onmessage=e=>render(JSON.parse(e.data));ws.onclose=()=>setTimeout(connect,1500);})();
</script></body></html>`;

const clients = new Set<any>();
Bun.serve({
  port: PORT,
  hostname: "127.0.0.1",
  fetch(req, srv) {
    const url = new URL(req.url);
    if (url.pathname === "/ws") return srv.upgrade(req) ? undefined : new Response("upgrade failed", { status: 400 });
    if (url.pathname === "/api/status") return Response.json(snapshot());
    if (url.pathname.startsWith("/files/")) {
      const fp = resolve(RUN_DIR, decodeURIComponent(url.pathname.slice(7)));
      if (relative(RUN_DIR, fp).startsWith("..") || !existsSync(fp)) return new Response("not found", { status: 404 });
      return new Response(Bun.file(fp));
    }
    return new Response(HTML, { headers: { "content-type": "text/html; charset=utf-8" } });
  },
  websocket: {
    open(ws) { clients.add(ws); ws.send(JSON.stringify(snapshot())); },
    message() {},
    close(ws) { clients.delete(ws); },
  },
});
setInterval(() => {
  if (!clients.size) return;
  const msg = JSON.stringify(snapshot());
  for (const ws of clients) ws.send(msg);
}, 1000);
console.log(`dashboard: http://127.0.0.1:${PORT}  (run dir ${RUN_DIR})`);
