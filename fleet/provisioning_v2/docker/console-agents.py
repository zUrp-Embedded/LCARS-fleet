#!/usr/bin/env python3
# SOURCE: fleet/provisioning_v2/docker/console-agents.py
# AUTHOR: consultant
# STARDATE: 2026-08-02
# STATUS: EXPLORATION — une page, deux onglets : AGENTS (pods vivants x roles declares) et
#         CARTES (catalogue des workflow maps : lire, editer, valider par le VRAI parseur)
#
# CE QUE CETTE PAGE EST. La moitie produit du dashboard : les cartes SONT l'interface de
# gouvernance (la criticite est le choix d'une carte — du YAML, zero code), et les roles declares
# sont le pendant statique des pods vivants. Elle observe et propose des DRAFTS ; elle ne pilote
# rien et ne deploie rien.
#
# LES TROIS DECISIONS D'ARCHITECTURE, ET LEURS RAISONS :
#
# 1. LE PARSEUR EST LE VRAI — le release eval, jamais une reimplementation. Valider du YAML de
#    carte en Python serait creer une seconde autorite de format ; c'est la classe de defaut qui
#    a tue fleet_v2 hier (un chemin reconstruit en shell, mort au demenagement). Le bouton
#    « Valider » appelle `Fleet.Workflow.Loader.load!(name, workflow_maps_root: <tmpdir>)` par
#    `bin/fleet_umbrella eval` : meme YAML, meme schema v2.5, meme GraphValidator que le boot —
#    l'erreur affichee est celle que la fleet aurait crachee.
#
# 2. LES CHEMINS SE DEMANDENT AU BEAM. `Fleet.Catalogue` est l'unique autorite de layout du
#    catalogue ; cette page obtient ses racines par eval (`workflow_maps_root/0`,
#    `cap_profiles_root/0`) et ne reconstruit JAMAIS un chemin de priv en Python.
#
# 3. UN DRAFT N'EST PAS UN DEPLOIEMENT. Le runtime sert une IMAGE publiee au boot
#    (:persistent_term) — une carte posee sur le disque apres le boot est INERTE par contrat
#    (« redeploy = restart », Loader). Les drafts vivent dans ~/card-drafts/, clairement marques,
#    et la page repete le contrat. Le deploiement reste un geste d'operateur (et le jour ou il
#    entre ici, il passe derriere l'auth OIDC — pas avant).
#
# Un eval demarre un ERTS (~1-3 s) : le dump catalogue est mis en cache sur les mtimes des deux
# arbres, la validation est a la demande (un clic = un boot de VM, assume en exploration).

import json
import os
import re
import subprocess
import tempfile
import glob as globmod
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
CARD_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
DRAFTS_DIR = os.path.expanduser("~/card-drafts")

# ─── La porte eval — le seul chemin vers le parseur et les chemins du catalogue ─────────────────

def release_bin():
    hits = globmod.glob("/local/LCARS_v2/rel/fleet_umbrella/bin/fleet_umbrella")
    return hits[0] if hits else None

def run_eval(expr, timeout=60):
    bin_ = release_bin()
    if not bin_:
        return (127, "", "release introuvable sous /local/LCARS_v2")
    env = dict(os.environ)
    env.update({"HOME": os.path.expanduser("~"), "RELEASE_TMP": "/tmp", "LCARS_TOOL_EVAL": "1",
                "LANG": "C.UTF-8"})
    try:
        p = subprocess.run([bin_, "eval", expr], capture_output=True, text=True,
                           timeout=timeout, env=env)
        return (p.returncode, p.stdout, p.stderr)
    except subprocess.TimeoutExpired:
        return (124, "", f"eval: pas de reponse en {timeout}s")

DUMP_EXPR = (
    'mr = Fleet.Catalogue.workflow_maps_root(); '
    'pr = Fleet.Catalogue.cap_profiles_root(); '
    'rd = fn dir -> dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".yaml")) '
    '|> Map.new(fn f -> p = Path.join(dir, f); '
    '{Path.rootname(f), %{"data" => YamlElixir.read_from_file!(p), "text" => File.read!(p)}} end) end; '
    'IO.puts(Jason.encode!(%{"roots" => %{"maps" => mr, "profiles" => pr}, '
    '"cards" => rd.(mr), "profiles" => rd.(pr)}))'
)

_CATALOGUE = {"stamp": None, "payload": None, "error": None}

def _tree_stamp(paths):
    st = []
    for d in paths:
        try:
            st.append((d, os.stat(d).st_mtime))
            for f in sorted(os.listdir(d)):
                if f.endswith(".yaml"):
                    st.append((f, os.stat(os.path.join(d, f)).st_mtime))
        except OSError:
            st.append((d, None))
    return tuple(st)

def catalogue():
    # Premier appel : eval complet (on ne connait pas encore les racines). Ensuite : re-eval
    # uniquement si un mtime des arbres a bouge — le catalogue est fige entre deux deploys.
    roots = (_CATALOGUE["payload"] or {}).get("roots") if _CATALOGUE["payload"] else None
    stamp = _tree_stamp([roots["maps"], roots["profiles"]]) if roots else None
    if _CATALOGUE["payload"] is not None and stamp == _CATALOGUE["stamp"]:
        payload = _CATALOGUE["payload"]
    else:
        rc, out, err = run_eval(DUMP_EXPR, timeout=90)
        if rc != 0:
            _CATALOGUE["error"] = (err or out).strip()[-800:]
            return {"error": _CATALOGUE["error"], "cards": {}, "profiles": {}, "drafts": {}}
        payload = json.loads(out.strip().splitlines()[-1])
        _CATALOGUE["payload"] = payload
        _CATALOGUE["stamp"] = _tree_stamp([payload["roots"]["maps"], payload["roots"]["profiles"]])
    # Les drafts sont TOUJOURS relus (pas caches) : c'est la partie vivante de la page.
    drafts = {}
    if os.path.isdir(DRAFTS_DIR):
        for f in sorted(os.listdir(DRAFTS_DIR)):
            if f.endswith(".yaml"):
                p = os.path.join(DRAFTS_DIR, f)
                drafts[f[:-5]] = {"text": open(p, encoding="utf-8").read(),
                                  "mtime": int(os.stat(p).st_mtime)}
    out = dict(payload)
    out["drafts"] = drafts
    return out

def validate_card(name, text):
    # Le draft est pose dans un repertoire jetable et charge par le VRAI Loader (schema + graphe).
    # L'erreur rendue est le raise d'origine, pas une paraphrase.
    if not CARD_NAME_RE.match(name or ""):
        return {"ok": False, "error": "nom de carte invalide (slug attendu : [a-z0-9-])"}
    with tempfile.TemporaryDirectory(prefix="carddraft-") as d:
        with open(os.path.join(d, f"{name}.yaml"), "w", encoding="utf-8") as f:
            f.write(text)
        expr = (f'card = Fleet.Workflow.Loader.load!("{name}", workflow_maps_root: "{d}"); '
                f'IO.puts("CARD_OK " <> card["name"])')
        rc, out, err = run_eval(expr, timeout=90)
    if rc == 0 and "CARD_OK" in out:
        return {"ok": True, "warnings": _role_warnings(text)}
    blob = (err or out)
    m = re.search(r"\*\* \(.+", blob, re.S)
    return {"ok": False, "error": (m.group(0)[:900] if m else blob.strip()[-900:])}

def _role_warnings(text):
    # Controle d'AFFICHAGE, pas d'acceptation : le vrai verrou role→profil est
    # validate_card_steps! au boot. Ici on previent seulement avant qu'il ne morde.
    profs = set(((_CATALOGUE["payload"] or {}).get("profiles") or {}).keys())
    if not profs:
        return []
    roles = set(re.findall(r"^\s*role:\s*([a-z0-9_-]+)", text, re.M))
    for j in re.findall(r"jury:\s*\[([^\]]*)\]", text):
        roles |= {r.strip() for r in j.split(",") if r.strip()}
    return [f"role « {r} » sans cap-profile — validate_card_steps! refusera ce boot au deploy"
            for r in sorted(roles) if r and r not in profs]

def save_draft(name, text):
    os.makedirs(DRAFTS_DIR, exist_ok=True)
    path = os.path.join(DRAFTS_DIR, f"{name}.yaml")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return {"ok": True, "path": path}

# ─── L'etat vivant (onglet AGENTS) ──────────────────────────────────────────────────────────────

SESSION_RE = re.compile(r"^([0-9a-f])badcafe-(\d{4})-4dad-babe-(\d{4})dec0de([0-9a-f])([0-9a-f])$")
KILL_CLASS = {"0": "jamais tue", "1": "persistant · reprend son slot", "2": "one-shot · moissonne"}

def decode_session(sid):
    m = SESSION_RE.match(sid or "")
    if not m:
        return None
    klass, uid, repo, pool, role_idx = m.groups()
    return {"classe": KILL_CLASS.get(klass, f"inconnue ({klass})"), "uid": int(uid),
            "repo": "fleet-level" if repo == "0000" else f"depot #{int(repo)}",
            "slot": f"pool {pool} · role {role_idx}"}

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
        out["pods"].append({"pod_id": pid, "role": p.get("role") or "?",
                            "phase": p.get("phase") or "?", "issue": p.get("issue_id") or "",
                            "conditions": p.get("conditions") or [],
                            "session": decode_session(p.get("session_id")),
                            "session_raw": p.get("session_id") or ""})
    return out

# ─── La page ────────────────────────────────────────────────────────────────────────────────────

PAGE = r"""<!doctype html>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>LCARS &mdash; agents &amp; cartes</title>
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

  .tabs{display:flex;gap:2px;margin-left:20px}
  .tab{background:none;border:1px solid var(--line);color:var(--dim);font:inherit;
       font-size:11.5px;letter-spacing:.1em;padding:3px 16px;border-radius:6px;cursor:pointer}
  .tab.on{color:var(--or);border-color:var(--or)}

  main{flex:1;min-height:0;display:grid;grid-template-columns:250px minmax(0,1fr) 320px}
  main.hidden{display:none}
  aside,section{min-width:0;overflow-y:auto}
  aside{background:var(--pan2);border-right:1px solid var(--line)}
  .rail-r{background:var(--pan2);border-left:1px solid var(--line);padding:10px 12px;overflow-y:auto}

  .grp{color:var(--faint);font-size:10.5px;letter-spacing:.14em;text-transform:uppercase;padding:12px 12px 5px}
  .row{display:block;width:100%;text-align:left;background:none;border:0;border-left:3px solid transparent;
       color:var(--ink);font:inherit;padding:7px 12px;cursor:pointer}
  .row:hover{background:#182029}
  .row.on{border-left-color:var(--or);background:#1a2330}
  .row .id{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .row .meta{display:block;color:var(--dim);font-size:11px}
  .row.ghost .id{color:var(--faint)}

  .dot{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:6px;vertical-align:1px}
  .ph-monitoring{background:var(--cy)} .ph-launching{background:var(--am)}
  .ph-projecting,.ph-injecting,.ph-allocating,.ph-cleaning{background:var(--vi)}
  .ph-releasing,.ph-publishing{background:var(--gr)} .ph-unknown{background:var(--faint)}

  .pane-head{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);
             padding:9px 14px;display:flex;gap:12px;align-items:baseline;z-index:2}
  .pane-head b{color:var(--or);font-weight:600}
  .pane-head .k{color:var(--dim);font-size:11.5px}
  .pane-head .act{margin-left:auto;display:flex;gap:8px}
  .btn{background:none;border:1px solid var(--line);border-radius:4px;color:var(--cy);
       font:inherit;font-size:11.5px;padding:2px 12px;cursor:pointer}
  .btn:hover{border-color:var(--cy)}
  .btn.warn{color:var(--am)} .btn.warn:hover{border-color:var(--am)}

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
  .kv .k{color:var(--dim);min-width:78px;flex:0 0 auto}
  .cond{display:inline-block;border:1px solid var(--line);border-radius:9px;padding:1px 8px;
        margin:2px 3px 0 0;font-size:11px;color:var(--gr)}
  .chip{display:inline-block;border:1px solid var(--line);border-radius:9px;padding:1px 9px;
        margin:2px 4px 2px 0;font-size:11px;color:var(--cy)}
  .chip.int{color:var(--am)}
  .empty{color:var(--faint);padding:22px 14px;font-size:12.5px;line-height:1.7}
  .empty b{color:var(--dim);font-weight:400}

  .cbody{padding:12px 16px}
  .present{color:var(--dim);font-size:12.5px;line-height:1.65;margin:0 0 14px;max-width:72ch}
  .step{border:1px solid var(--line);border-left:3px solid var(--vi);border-radius:0 6px 6px 0;
        background:var(--pan);padding:8px 12px;margin:0 0 8px}
  .step .sname{color:var(--ink)} .step .srole{color:var(--or)}
  .step .sfacts{color:var(--dim);font-size:11.5px;margin-top:2px}
  .arrow{color:var(--faint);padding:0 10px 6px 22px;font-size:11px}

  textarea{width:100%;height:50vh;background:#0a0f14;color:var(--ink);border:1px solid var(--line);
           border-radius:6px;font:12.5px/1.5 var(--mono);padding:10px;resize:vertical}
  textarea:focus{outline:1px solid var(--or)}
  .vres{border:1px solid var(--line);border-radius:6px;background:#0a0f14;margin-top:10px;
        padding:9px 12px;font-size:12px;white-space:pre-wrap;max-height:22vh;overflow-y:auto}
  .vres.ok{border-color:var(--gr);color:var(--gr)}
  .vres.ko{border-color:var(--rd);color:var(--rd)}
  .vres.warn{border-color:var(--am);color:var(--am)}
  .notice{border:1px dashed var(--line);border-radius:6px;color:var(--faint);font-size:11.5px;
          padding:8px 11px;margin-top:10px;line-height:1.6}
</style>
<header>
  <span class="mark">LCARS</span>
  <nav class="tabs">
    <button class="tab on" id="tab-agents">AGENTS</button>
    <button class="tab" id="tab-cards">CARTES</button>
  </nav>
  <span class="sub" id="sub">&mdash;</span>
  <span class="right"><span id="counts"></span><span class="live" id="live">&bull; LIVE</span><span id="clock"></span></span>
</header>

<main id="v-agents">
  <aside id="rail"></aside>
  <section id="center"></section>
  <aside class="rail-r" id="ctx"></aside>
</main>

<main id="v-cards" class="hidden">
  <aside id="crail"></aside>
  <section id="ccenter"></section>
  <aside class="rail-r" id="cctx"></aside>
</main>

<script>
const HOST = location.hostname;
let sel = null, S = null;                      // agents
let CAT = null, csel = null, editing = false;  // cartes
let view = 'agents';

const el = (t,c,x) => { const e=document.createElement(t); if(c)e.className=c; if(x!=null)e.textContent=x; return e; };
const phCls = p => 'ph-' + (['monitoring','launching','projecting','injecting','allocating','cleaning','releasing','publishing'].includes(p) ? p : 'unknown');
const evCls = t => /fail|crash|dead|error/.test(t) ? 'bad' : (/wake|retry|drift|stale/.test(t) ? 'warn' : '');

/* ─── onglets ─── */
function switchTo(v){
  view = v;
  document.getElementById('v-agents').classList.toggle('hidden', v!=='agents');
  document.getElementById('v-cards').classList.toggle('hidden', v!=='cards');
  document.getElementById('tab-agents').classList.toggle('on', v==='agents');
  document.getElementById('tab-cards').classList.toggle('on', v==='cards');
  if(v==='cards' && !CAT) loadCatalogue();
}
document.getElementById('tab-agents').onclick = () => switchTo('agents');
document.getElementById('tab-cards').onclick = () => switchTo('cards');
if(location.hash === '#cartes') switchTo('cards');

/* ─── AGENTS ─── */
function rail(){
  const r = document.getElementById('rail'); r.innerHTML='';
  r.appendChild(el('div','grp', S.fleet ? `pods · ${S.pods.length}` : 'fleet eteinte'));
  if(!S.pods.length) r.appendChild(el('div','empty', S.fleet ? 'aucun pod vivant' : 'demarre la fleet : fleet_v2 start'));
  for(const p of S.pods){
    const b = el('button','row' + (p.pod_id===sel ? ' on' : ''));
    const id = el('span','id'); id.appendChild(el('span','dot '+phCls(p.phase))); id.append(p.role);
    b.appendChild(id);
    b.appendChild(el('span','meta', p.phase + ' · ' + p.pod_id));
    b.onclick = () => { sel = p.pod_id; draw(); };
    r.appendChild(b);
  }
  if(CAT && CAT.profiles){
    const live = new Set(S.pods.map(p=>p.role));
    const dormant = Object.keys(CAT.profiles).sort().filter(n=>!live.has(n));
    if(dormant.length){
      r.appendChild(el('div','grp','roles declares · dormants'));
      for(const name of dormant){
        const b = el('button','row ghost' + (sel==='profile:'+name ? ' on' : ''));
        b.appendChild(el('span','id', name));
        const spec = (CAT.profiles[name].data||{}).spec||{};
        b.appendChild(el('span','meta', (spec.brief_kind||'?') + ' · dormant'));
        b.onclick = () => { sel = 'profile:'+name; draw(); };
        r.appendChild(b);
      }
    }
  }
}

function center(){
  const c = document.getElementById('center'); c.innerHTML='';
  const p = S.pods.find(x=>x.pod_id===sel);
  const head = el('div','pane-head');
  head.appendChild(el('b', p ? p.role.toUpperCase() : ((sel||'').startsWith('profile:') ? sel.slice(8).toUpperCase() : 'FLUX')));
  head.appendChild(el('span','k', p ? p.pod_id : ((sel||'').startsWith('profile:') ? 'role declare, aucun pod' : 'tous les evenements')));
  if(p && S.pod_console_port){
    const act = el('span','act');
    const a = document.createElement('a'); a.className='btn'; a.textContent='ouvrir la console ↗';
    a.href = `http://${HOST}:${S.pod_console_port}?arg=${encodeURIComponent(p.pod_id)}`;
    a.target='_blank'; a.rel='noopener'; act.appendChild(a); head.appendChild(act);
  }
  c.appendChild(head);
  const evs = S.stream.filter(e => !p || e.pod_id === p.pod_id);
  if(!evs.length){
    const e = el('div','empty');
    e.innerHTML = p
      ? "aucun evenement pour ce pod.<br><b>Entre deux tool calls, rien n'emet</b> — un pod en longue reflexion est invisible d'ici ; sa console est le seul temoin."
      : ((sel||'').startsWith('profile:') ? "role declare au catalogue — aucun pod ne l'incarne en ce moment." : 'flux vide');
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
  if((sel||'').startsWith('profile:')){ profileCtx(d, sel.slice(8)); return; }
  const p = S.pods.find(x=>x.pod_id===sel);
  if(!p){ d.appendChild(el('div','empty','selectionne un agent')); return; }
  const idc = el('div','card'); idc.appendChild(el('h4',null,'identite'));
  for(const [k,v] of [['role',p.role],['phase',p.phase],['mandat',p.issue||'—']]){
    const r=el('div','kv'); r.appendChild(el('span','k',k)); r.appendChild(el('span',null,v)); idc.appendChild(r);
  }
  d.appendChild(idc);
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
  if(CAT) profileCtx(d, p.role, true);
}

function profileCtx(d, name, compact){
  const prof = CAT && CAT.profiles && CAT.profiles[name];
  if(!prof){ if(!compact) d.appendChild(el('div','empty','profil hors catalogue (charge l onglet CARTES pour peupler)')); return; }
  const spec = (prof.data||{}).spec||{}, inv = spec.invocation||{}, scope = spec.scope||{};
  const pc = el('div','card'); pc.appendChild(el('h4',null,'cap-profile · '+name));
  const rows = [['mandat', spec.brief_kind||'?'],['modele', (inv.model||'?')+' · '+(inv.effort||'?')],
                ['vie', inv.lifetime_scope||'?'],['boot', inv.boot_at_start ? 'au demarrage' : 'a la demande'],
                ['outils', (scope.allowedTools||[]).length + ' permis · ' + (scope.disallowedTools||[]).length + ' interdits'],
                ['git', (scope.git_ops_denied||[]).length ? 'denie: '+scope.git_ops_denied.join(', ') : 'libre']];
  for(const [k,v] of rows){
    const r=el('div','kv'); r.appendChild(el('span','k',k)); r.appendChild(el('span',null,v)); pc.appendChild(r);
  }
  d.appendChild(pc);
}

function draw(){
  if(S.pods.length && !sel) sel = S.pods[0].pod_id;
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
  try { S = await (await fetch('/api/state',{cache:'no-store'})).json(); if(view==='agents') draw(); } catch(e){}
}
tick(); setInterval(tick, 3000);

/* ─── CARTES ─── */
async function loadCatalogue(force){
  const c = document.getElementById('ccenter');
  if(!CAT) c.innerHTML = '<div class="empty">lecture du catalogue par le BEAM… (premier appel : quelques secondes)</div>';
  try { CAT = await (await fetch('/api/catalogue'+(force?'?refresh=1':''),{cache:'no-store'})).json(); }
  catch(e){ c.innerHTML = '<div class="empty">catalogue injoignable</div>'; return; }
  if(CAT.error){ c.innerHTML = '<div class="empty">le BEAM refuse le dump :<br>'+CAT.error+'</div>'; return; }
  if(!csel){ const names = Object.keys(CAT.cards||{}).sort(); csel = names[0] || null; }
  drawCards();
  if(view==='agents') draw();
}

function drawCards(){
  const r = document.getElementById('crail'); r.innerHTML='';
  const cards = CAT.cards||{}, drafts = CAT.drafts||{};
  r.appendChild(el('div','grp','cartes canon · '+Object.keys(cards).length));
  for(const name of Object.keys(cards).sort()){
    const meta = (cards[name].data||{}).metadata||{};
    const b = el('button','row'+(name===csel&&!editing?' on':''));
    b.appendChild(el('span','id', name));
    b.appendChild(el('span','meta', ((meta.applicable_intensity||[]).join(' ')||'—')));
    b.onclick = () => { csel = name; editing=false; drawCards(); };
    r.appendChild(b);
  }
  if(Object.keys(drafts).length){
    r.appendChild(el('div','grp','drafts (non servis)'));
    for(const name of Object.keys(drafts).sort()){
      const b = el('button','row ghost'+(name===csel&&editing?' on':''));
      b.appendChild(el('span','id', name+' ✎'));
      b.appendChild(el('span','meta','draft local'));
      b.onclick = () => { csel = name; editing=true; drawCards(); };
      r.appendChild(b);
    }
  }
  cardCenter(); cardCtx();
}

function cardCenter(){
  const c = document.getElementById('ccenter'); c.innerHTML='';
  const cards = CAT.cards||{}, drafts = CAT.drafts||{};
  const src = editing && drafts[csel] ? drafts[csel] : cards[csel];
  if(!src){ c.appendChild(el('div','empty','selectionne une carte')); return; }
  const data = src.data||{}, meta = data.metadata||{}, spec = data.spec||{};

  const head = el('div','pane-head');
  head.appendChild(el('b', (csel||'').toUpperCase()));
  head.appendChild(el('span','k', editing ? 'EDITION — draft local, jamais servi' : 'carte canon'));
  const act = el('span','act');
  if(!editing){
    const eb = el('button','btn','éditer'); eb.onclick = () => { editing=true; cardCenter(); };
    act.appendChild(eb);
  }
  const rb = el('button','btn','recharger'); rb.onclick = () => loadCatalogue(true);
  act.appendChild(rb); head.appendChild(act);
  c.appendChild(head);

  const body = el('div','cbody');
  if(editing){ editor(body, src); c.appendChild(body); return; }

  if(meta.presentation) body.appendChild(el('p','present', meta.presentation));
  const steps = spec.steps||{};
  const order = topoOrder(steps);
  for(let i=0;i<order.length;i++){
    const sname = order[i], st = steps[sname]||{};
    if((st.needs||[]).length) body.appendChild(el('div','arrow','▼ apres ' + st.needs.join(', ')));
    const sd = el('div','step');
    const l1 = el('div');
    l1.appendChild(el('span','sname', sname+' '));
    l1.appendChild(el('span','srole','→ '+(st.role||'?')));
    sd.appendChild(l1);
    const facts=[];
    if(st.judge_target) facts.push('juge: '+st.judge_target);
    if(st.brief_kind) facts.push('brief_kind: '+st.brief_kind);
    if((st.inputs||[]).length) facts.push('inputs: '+st.inputs.join(', '));
    if(facts.length) sd.appendChild(el('div','sfacts', facts.join(' · ')));
    body.appendChild(sd);
  }
  if(!order.length) body.appendChild(el('div','empty','carte sans steps (jury seul)'));
  c.appendChild(body);
}

function topoOrder(steps){
  const names = Object.keys(steps), seen = new Set(), out = [];
  let guard = names.length + 2;
  while(out.length < names.length && guard-- > 0){
    for(const n of names){
      if(seen.has(n)) continue;
      const needs = steps[n].needs||[];
      if(needs.every(x=>seen.has(x))){ seen.add(n); out.push(n); }
    }
  }
  for(const n of names) if(!seen.has(n)) out.push(n);
  return out;
}

function editor(body, src){
  const ta = document.createElement('textarea');
  ta.value = src.text || '';
  ta.spellcheck = false;
  body.appendChild(ta);

  const bar = el('div'); bar.style.cssText='display:flex;gap:10px;margin-top:10px';
  const vb = el('button','btn','valider (vrai parseur)');
  const sb = el('button','btn warn','sauver en draft');
  const cb = el('button','btn','fermer');
  bar.appendChild(vb); bar.appendChild(sb); bar.appendChild(cb);
  body.appendChild(bar);
  const res = el('div','vres'); res.style.display='none'; body.appendChild(res);

  const notice = el('div','notice');
  notice.innerHTML = "Un draft n'est <b>jamais servi</b> par la fleet : le runtime publie une "
    + "image du catalogue au boot, le disque est inerte ensuite (contrat du Loader — redeploy = "
    + "restart). « Valider » passe par <b>le parseur reel</b> (schema v2.5 + GraphValidator) via "
    + "le release eval : l'erreur affichee est celle que le boot cracherait.";
  body.appendChild(notice);

  vb.onclick = async () => {
    res.style.display='block'; res.className='vres'; res.textContent='validation par le BEAM… (quelques secondes)';
    const r = await (await fetch('/api/cards/validate', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({name: csel, text: ta.value})})).json();
    if(r.ok && (r.warnings||[]).length){ res.className='vres warn'; res.textContent='CARTE VALIDE (parseur) — mais :\n' + r.warnings.join('\n'); }
    else if(r.ok){ res.className='vres ok'; res.textContent='CARTE VALIDE — schema + graphe passes par le vrai Loader.'; }
    else { res.className='vres ko'; res.textContent=r.error||'erreur inconnue'; }
  };
  sb.onclick = async () => {
    res.style.display='block'; res.className='vres'; res.textContent='validation puis sauvegarde…';
    const r = await (await fetch('/api/cards/draft', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({name: csel, text: ta.value})})).json();
    if(r.ok){ res.className='vres ok'; res.textContent='DRAFT SAUVE : '+r.path+'\n(non servi — deploiement = geste operateur + restart)'; }
    else { res.className='vres ko'; res.textContent=r.error||'refus'; }
  };
  cb.onclick = () => { editing=false; loadCatalogue(); };
}

function cardCtx(){
  const d = document.getElementById('cctx'); d.innerHTML='';
  const cards = CAT.cards||{}; const src = cards[csel];
  if(!src){ d.appendChild(el('div','empty','—')); return; }
  const data = src.data||{}, meta = data.metadata||{}, spec = data.spec||{};

  const g = el('div','card'); g.appendChild(el('h4',null,'gouvernance'));
  const ints = el('div');
  for(const i of (meta.applicable_intensity||[])) ints.appendChild(el('span','chip int', i));
  if(!(meta.applicable_intensity||[]).length) ints.appendChild(el('span','kv','toutes criticites'));
  g.appendChild(ints);
  const jr = el('div'); jr.style.marginTop='6px';
  for(const j of (spec.jury||[])) jr.appendChild(el('span','chip', 'jury: '+j));
  g.appendChild(jr);
  const mr = el('div','kv'); mr.appendChild(el('span','k','rework max'));
  mr.appendChild(el('span',null,String(spec.max_rework_rounds ?? '—'))); g.appendChild(mr);
  d.appendChild(g);

  if(meta.description){
    const dc = el('div','card'); dc.appendChild(el('h4',null,'description'));
    dc.appendChild(el('div','kv', meta.description)); d.appendChild(dc);
  }

  const rc = el('div','card'); rc.appendChild(el('h4',null,'catalogue'));
  const rr = el('div','kv'); rr.appendChild(el('span','k','racine'));
  rr.appendChild(el('span',null,(CAT.roots||{}).maps||'?')); rc.appendChild(rr);
  const ic = el('div','kv'); ic.appendChild(el('span','k','contrat'));
  ic.appendChild(el('span',null,'image publiee au boot — le disque est inerte apres (redeploy = restart)'));
  rc.appendChild(ic);
  d.appendChild(rc);
}
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

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj), "application/json; charset=utf-8")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/state":
            self._json(state())
        elif path == "/api/catalogue":
            if "refresh=1" in self.path:
                _CATALOGUE["payload"] = None
            self._json(catalogue())
        elif path in ("/", "/index.html"):
            self._send(200, PAGE, "text/html; charset=utf-8")
        elif path == "/health":
            self._send(200, "ok\n", "text/plain; charset=utf-8")
        else:
            self._send(404, "not found\n", "text/plain; charset=utf-8")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            self._json({"ok": False, "error": "corps JSON illisible"}, 400)
            return
        name, text = body.get("name", ""), body.get("text", "")
        if path == "/api/cards/validate":
            self._json(validate_card(name, text))
        elif path == "/api/cards/draft":
            v = validate_card(name, text)
            if not v.get("ok"):
                self._json(v)
                return
            r = save_draft(name, text)
            r["warnings"] = v.get("warnings", [])
            self._json(r)
        else:
            self._send(404, "not found\n", "text/plain; charset=utf-8")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    # 0.0.0.0 dans le conteneur : la frontiere est la publication compose (loopback de l'hote),
    # comme ttyd et le deck. Un bind loopback ici rendrait la page injoignable d'un navigateur.
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Agents)
    print(f"[lcars-agents] agents+cartes sur :{PORT} (deck {DECK_PORT}, consoles pod {POD_CONSOLE_PORT})", flush=True)
    srv.serve_forever()
