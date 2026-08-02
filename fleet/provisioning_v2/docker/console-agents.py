#!/usr/bin/env python3
# SOURCE: fleet/provisioning_v2/docker/console-agents.py
# AUTHOR: consultant
# STARDATE: 2026-08-02
# STATUS: EXPLORATION — la vue AGENTS : trois volets, le vocabulaire de la maquette A8 sur des
#         donnees reelles de la fleet
#
# CE QUE CETTE PAGE EST, ET CE QU'ELLE N'EST PAS. Elle montre les pods VIVANTS d'un humain, leur
# phase, leur identite decodee et le flux d'evenements qui les concerne. Elle ne PILOTE rien : ni
# spawn, ni kill, ni commande. Observer et agir sont deux produits ; melanger les deux etait le
# pari du cockpit, et ce n'est pas ce qu'on teste ici.
#
# POURQUOI UN SERVEUR A PART PLUTOT QU'UNE ROUTE DU DECK : la page du deck (20999) est la porte de
# la boite et l'operateur la garde ouverte. Une exploration qui se relance toutes les deux minutes
# n'a rien a faire dans une porte. Port `base+6` du bloc de l'humain — derive de son UID comme
# tout le reste, deja publie par le compose, et libre (base+2 est RESERVE, base+4 la console,
# base+5 les consoles de pod).
#
# CE QUE LA MAQUETTE A8 APPORTE, ET QU'ON PEUT TENIR AUJOURD'HUI :
#   - le volet gauche liste des SESSIONS (ici : les pods), avec leur etat en pastille ;
#   - le volet central est un FLUX d'evenements typés, pas un journal brut ;
#   - le volet droit est le CONTEXTE de la selection : identite, conditions, mandat.
# Ce qu'elle montre et qu'on ne peut PAS tenir : les appels d'outils avec leur duree, et le budget
# d'outils. Rien ne les emet aujourd'hui — l'activite d'outil d'un pod vit dans son terminal et
# n'atteint jamais le bus. La page le DIT a la place de dessiner des colonnes vides.

import json
import os
import re
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import urlopen

PORT = int(os.environ.get("LCARS_AGENTS_PORT", "0"))
DECK_PORT = int(os.environ.get("LCARS_OBS_PORT", "0"))
POD_CONSOLE_PORT = int(os.environ.get("LCARS_POD_CONSOLE_PORT", "0"))

PORT_BASE, PORT_MOD, PORT_SPAN = 21000, 500, 10
OFF_DECK, OFF_POD, OFF_AGENTS = 1, 5, 6

if not PORT:
    base = PORT_BASE + (os.getuid() % PORT_MOD) * PORT_SPAN
    PORT = base + OFF_AGENTS
    DECK_PORT = DECK_PORT or base + OFF_DECK
    POD_CONSOLE_PORT = POD_CONSOLE_PORT or base + OFF_POD

POD_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")

# Le session_id est de l'hexspeak PORTEUR (`Fleet.Spawner.SessionId`) :
#   <X>badcafe-<UID>-4dad-babe-<REPO4>dec0de<P><R>
# On le DECODE au lieu de l'afficher brut — c'est cinq faits lisibles a l'oeil nu, et la page a
# exactement besoin de ces cinq-la. Une forme inattendue n'est pas une erreur : on rend le brut.
SESSION_RE = re.compile(r"^([0-9a-f])badcafe-(\d{4})-4dad-babe-(\d{4})dec0de([0-9a-f])([0-9a-f])$")
KILL_CLASS = {"0": "jamais tue", "1": "persistant · reprend son slot", "2": "one-shot · moissonne"}


def decode_session(sid):
    m = SESSION_RE.match(sid or "")
    if not m:
        return None
    klass, uid, repo, pool, role_idx = m.groups()
    return {
        "classe": KILL_CLASS.get(klass, f"inconnue ({klass})"),
        "uid": int(uid),
        "repo": "fleet-level" if repo == "0000" else f"depot #{int(repo)}",
        "slot": f"pool {pool} · role {role_idx}",
    }


def get(url):
    try:
        with urlopen(url, timeout=2) as r:
            return json.load(r)
    except Exception:
        return None


def state():
    pods = get(f"http://127.0.0.1:{DECK_PORT}/api/pods")
    proj = get(f"http://127.0.0.1:{DECK_PORT}/api/projection")
    out = {"fleet": pods is not None, "pods": [], "stream": [], "counts": {}, "status": None,
           "pod_console_port": POD_CONSOLE_PORT}
    if proj:
        out["stream"] = proj.get("stream") or []
        out["counts"] = proj.get("counts") or {}
        out["status"] = proj.get("_status")
    for p in (pods or {}).get("pods", []):
        pid = p.get("pod_id", "")
        if not POD_ID_RE.match(pid):
            continue
        out["pods"].append({
            "pod_id": pid,
            "role": p.get("role") or "?",
            "phase": p.get("phase") or "?",
            "issue": p.get("issue_id") or "",
            "conditions": p.get("conditions") or [],
            "session": decode_session(p.get("session_id")),
            "session_raw": p.get("session_id") or "",
        })
    return out


PAGE = r"""<!doctype html>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>LCARS &mdash; agents</title>
<style>
  :root{
    --bg:#0d1117; --pan:#131a22; --pan2:#0f151c; --line:#1e2833;
    --ink:#c9d6e2; --dim:#6b7d8f; --faint:#44525f;
    --or:#e8913c; --cy:#4fb3c4; --gr:#6cc08b; --rd:#d2646a; --am:#d9b44a; --vi:#9a8ac4;
    --mono:ui-monospace,"JetBrains Mono","SF Mono","DejaVu Sans Mono",Menlo,monospace;
  }
  *{box-sizing:border-box}
  html,body{height:100vh;overflow:hidden;margin:0}
  body{background:var(--bg);color:var(--ink);font:13.5px/1.5 var(--mono);display:flex;flex-direction:column}

  header{flex:0 0 auto;display:flex;align-items:center;gap:14px;padding:8px 14px;
         background:var(--pan);border-bottom:1px solid var(--line)}
  header .mark{color:var(--or);font-weight:700;letter-spacing:.08em}
  header .sub{color:var(--dim);font-size:12px}
  header .right{margin-left:auto;display:flex;gap:14px;align-items:center;color:var(--dim);font-size:12px}
  .live{border:1px solid var(--cy);color:var(--cy);border-radius:10px;padding:1px 9px;font-size:11px}
  .live.off{border-color:var(--rd);color:var(--rd)}

  main{flex:1;min-height:0;display:grid;grid-template-columns:250px minmax(0,1fr) 300px}
  aside,section{min-width:0;overflow-y:auto}
  aside{background:var(--pan2);border-right:1px solid var(--line)}
  .rail-r{background:var(--pan2);border-left:1px solid var(--line);padding:10px 12px}

  .grp{color:var(--faint);font-size:10.5px;letter-spacing:.14em;text-transform:uppercase;padding:12px 12px 5px}
  .row{display:block;width:100%;text-align:left;background:none;border:0;border-left:3px solid transparent;
       color:var(--ink);font:inherit;padding:7px 12px;cursor:pointer}
  .row:hover{background:#182029}
  .row.on{border-left-color:var(--or);background:#1a2330}
  .row .id{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .row .meta{display:block;color:var(--dim);font-size:11px}

  .dot{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:6px;vertical-align:1px}
  .ph-monitoring{background:var(--cy)} .ph-launching{background:var(--am)}
  .ph-projecting,.ph-injecting,.ph-allocating,.ph-cleaning{background:var(--vi)}
  .ph-releasing,.ph-publishing{background:var(--gr)} .ph-unknown{background:var(--faint)}

  .pane-head{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);
             padding:9px 14px;display:flex;gap:12px;align-items:baseline}
  .pane-head b{color:var(--or);font-weight:600}
  .pane-head .k{color:var(--dim);font-size:11.5px}
  .pane-head a{margin-left:auto;color:var(--cy);text-decoration:none;font-size:11.5px;
               border:1px solid var(--line);border-radius:4px;padding:2px 9px}
  .pane-head a:hover{border-color:var(--cy)}

  .ev{display:grid;grid-template-columns:64px 190px 110px minmax(0,1fr);gap:10px;
      padding:5px 14px;border-bottom:1px solid #16202a;white-space:nowrap}
  .ev:hover{background:#141c24}
  .ev .t{color:var(--faint);font-size:11.5px}
  .ev .ty{color:var(--or)} .ev .src{color:var(--cy);font-size:12px}
  .ev .pod{color:var(--dim);overflow:hidden;text-overflow:ellipsis}
  .ev.warn .ty{color:var(--am)} .ev.bad .ty{color:var(--rd)}

  .card{border:1px solid var(--line);border-radius:0 6px 6px 0;border-left:3px solid var(--or);
        background:var(--pan);padding:9px 11px;margin-bottom:10px}
  .card h4{margin:0 0 6px;font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:var(--faint);font-weight:400}
  .kv{display:flex;gap:8px;font-size:12.5px;margin:2px 0}
  .kv .k{color:var(--dim);min-width:78px}
  .cond{display:inline-block;border:1px solid var(--line);border-radius:9px;padding:1px 8px;
        margin:2px 3px 0 0;font-size:11px;color:var(--gr)}
  .empty{color:var(--faint);padding:22px 14px;font-size:12.5px;line-height:1.7}
  .empty b{color:var(--dim);font-weight:400}
</style>
<header>
  <span class="mark">LCARS &middot; AGENTS</span>
  <span class="sub" id="sub">&mdash;</span>
  <span class="right"><span id="counts"></span><span class="live" id="live">&bull; LIVE</span><span id="clock"></span></span>
</header>
<main>
  <aside id="rail"></aside>
  <section id="center"></section>
  <aside class="rail-r" id="ctx"></aside>
</main>
<script>
const HOST = location.hostname;
let sel = null, S = null;

const el = (t,c,x) => { const e=document.createElement(t); if(c)e.className=c; if(x!=null)e.textContent=x; return e; };
const phCls = p => 'ph-' + (['monitoring','launching','projecting','injecting','allocating','cleaning','releasing','publishing'].includes(p) ? p : 'unknown');
const evCls = t => /fail|crash|dead|error/.test(t) ? 'bad' : (/wake|retry|drift|stale/.test(t) ? 'warn' : '');

function rail(){
  const r = document.getElementById('rail'); r.innerHTML='';
  r.appendChild(el('div','grp', S.fleet ? `pods · ${S.pods.length}` : 'fleet eteinte'));
  if(!S.pods.length){ r.appendChild(el('div','empty', S.fleet ? 'aucun pod vivant' : 'demarre la fleet : fleet_v2 start')); return; }
  for(const p of S.pods){
    const b = el('button','row' + (p.pod_id===sel ? ' on' : ''));
    const id = el('span','id'); id.appendChild(el('span','dot '+phCls(p.phase))); id.append(p.role);
    b.appendChild(id);
    b.appendChild(el('span','meta', p.phase + ' · ' + p.pod_id));
    b.onclick = () => { sel = p.pod_id; draw(); };
    r.appendChild(b);
  }
}

function center(){
  const c = document.getElementById('center'); c.innerHTML='';
  const p = S.pods.find(x=>x.pod_id===sel);
  const head = el('div','pane-head');
  head.appendChild(el('b', p ? p.role.toUpperCase() : 'FLUX'));
  head.appendChild(el('span','k', p ? p.pod_id : 'tous les evenements'));
  if(p && S.pod_console_port){
    const a = el('a','', 'ouvrir la console ↗');
    a.href = `http://${HOST}:${S.pod_console_port}?arg=${encodeURIComponent(p.pod_id)}`;
    a.target = '_blank'; a.rel='noopener'; head.appendChild(a);
  }
  c.appendChild(head);

  const evs = S.stream.filter(e => !p || e.pod_id === p.pod_id);
  if(!evs.length){
    const e = el('div','empty');
    e.innerHTML = p
      ? "aucun evenement pour ce pod.<br><b>Ce que cette page ne peut pas montrer :</b> les appels d'outils et leur duree. "
        + "L'activite d'outil vit dans le terminal du pod et n'est publiee sur aucun bus — la maquette les dessine, le runtime ne les emet pas encore."
      : 'flux vide';
    c.appendChild(e); return;
  }
  for(const e of evs){
    const row = el('div','ev ' + evCls(e.type||''));
    row.appendChild(el('span','t', (e.ts||'').slice(11,19)));
    row.appendChild(el('span','ty', e.type||''));
    row.appendChild(el('span','src', e.source||''));
    row.appendChild(el('span','pod', e.pod_id||''));
    c.appendChild(row);
  }
}

function ctx(){
  const d = document.getElementById('ctx'); d.innerHTML='';
  const p = S.pods.find(x=>x.pod_id===sel);
  if(!p){ d.appendChild(el('div','empty','selectionne un agent')); return; }

  const idc = el('div','card'); idc.appendChild(el('h4',null,'identite'));
  for(const [k,v] of [['role',p.role],['phase',p.phase],['mandat',p.issue||'—']]){
    const r=el('div','kv'); r.appendChild(el('span','k',k)); r.appendChild(el('span',null,v)); idc.appendChild(r);
  }
  d.appendChild(idc);

  // Le session_id porte cinq faits ; les afficher decodes evite d'apprendre l'hexspeak par coeur.
  const sc = el('div','card'); sc.appendChild(el('h4',null,'slot de session'));
  if(p.session){
    for(const [k,v] of [['classe',p.session.classe],['humain','uid '+p.session.uid],
                        ['projet',p.session.repo],['slot',p.session.slot]]){
      const r=el('div','kv'); r.appendChild(el('span','k',k)); r.appendChild(el('span',null,v)); sc.appendChild(r);
    }
  }
  const raw=el('div','kv'); raw.appendChild(el('span','k','brut'));
  raw.appendChild(el('span',null,p.session_raw||'—')); sc.appendChild(raw);
  d.appendChild(sc);

  const cc = el('div','card'); cc.appendChild(el('h4',null,'conditions'));
  if(p.conditions.length) p.conditions.forEach(x=>cc.appendChild(el('span','cond',x)));
  else cc.appendChild(el('span','kv','aucune'));
  d.appendChild(cc);
}

function draw(){
  if(S.pods.length && !S.pods.some(p=>p.pod_id===sel)) sel = S.pods[0].pod_id;
  if(!S.pods.length) sel = null;
  document.getElementById('sub').textContent = S.status ? 'read-model ' + S.status : 'read-model injoignable';
  const live = document.getElementById('live');
  live.className = 'live' + (S.fleet ? '' : ' off');
  live.textContent = S.fleet ? '• LIVE' : '• FLEET OFF';
  const n = Object.values(S.counts).reduce((a,b)=>a+b,0);
  document.getElementById('counts').textContent = n ? n + ' evenements' : '';
  document.getElementById('clock').textContent = new Date().toTimeString().slice(0,8);
  rail(); center(); ctx();
}

async function tick(){
  try { S = await (await fetch('/api/state',{cache:'no-store'})).json(); draw(); } catch(e){}
}
tick(); setInterval(tick, 3000);
</script>
"""


class Agents(BaseHTTPRequestHandler):
    server_version = "lcars-agents"

    def _send(self, code, body, ctype):
        raw = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/state":
            self._send(200, json.dumps(state()), "application/json; charset=utf-8")
        elif path in ("/", "/index.html"):
            self._send(200, PAGE, "text/html; charset=utf-8")
        elif path == "/health":
            self._send(200, "ok\n", "text/plain; charset=utf-8")
        else:
            self._send(404, "not found\n", "text/plain; charset=utf-8")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    # 0.0.0.0 dans le conteneur : la frontiere est la publication compose (loopback de l'hote),
    # comme ttyd et le deck. Un bind loopback ici rendrait la page injoignable d'un navigateur.
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Agents)
    print(f"[lcars-agents] vue agents sur :{PORT} (deck {DECK_PORT}, consoles pod {POD_CONSOLE_PORT})", flush=True)
    srv.serve_forever()
