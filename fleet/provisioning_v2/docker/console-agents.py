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
    'sch = Jason.decode!(File.read!(Path.join(:code.priv_dir(:lcars_fleet), '
    '"workflow/schema/workflow-map-v2.5.json"))); '
    'rd = fn dir -> dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".yaml")) '
    '|> Map.new(fn f -> p = Path.join(dir, f); '
    '{Path.rootname(f), %{"data" => YamlElixir.read_from_file!(p), "text" => File.read!(p)}} end) end; '
    'av = Path.join(to_string(:code.priv_dir(:lcars_fleet)), "observation/static/assets"); '
    'IO.puts(Jason.encode!(%{"roots" => %{"maps" => mr, "profiles" => pr, "assets" => av}, "schema" => sch, '
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
    return payload

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

def save_card(name, text):
    # YOLO assume (arbitrage user) : le clic ne produit que du valide, le vrai parseur a dit oui —
    # on ecrit DIRECTEMENT dans le workflow_maps root de la boite (chemin donne par le BEAM, jamais
    # reconstruit). Le contrat du Loader reste entier : la fleet sert son image de boot, cette
    # ecriture ne prend effet qu'au prochain start. Boite d'exploration, catalogue jetable.
    roots = (_CATALOGUE["payload"] or {}).get("roots") or {}
    maps_dir = roots.get("maps")
    if not maps_dir:
        return {"ok": False, "error": "racine du catalogue inconnue (dump pas encore fait ?)"}
    path = os.path.join(maps_dir, f"{name}.yaml")
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
    except OSError as e:
        return {"ok": False, "error": f"ecriture refusee : {e}"}
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

# ─── L'etat des MACHINES, mesure d'ou la page vit (l'interieur de la boite) ────────────────────
# La boite se lit dans /proc ; la fleet par son API ; la forge par un ping version sur l'URL que
# le RUNTIME utilise (fleet_v2.env — la verite de l'humain, pas une reconstruction) ; le runner
# n'est PAS joignable d'ici (conteneur voisin, pas de socket docker dans la boite — et c'est
# voulu) : sa preuve de vie est INDIRECTE, le dernier verdict CI du repo temoin.
_MACH = {"t": 0, "forge": None, "ci": None}

def _env_forge_url():
    try:
        for line in open(os.path.expanduser("~/.lcars/fleet_v2.env"), encoding="utf-8"):
            m = re.match(r"^(?:export\s+)?FORGE_BASE_URL=[\"']?([^\"'\s]+)", line.strip())
            if m:
                return m.group(1)
    except OSError:
        pass
    return os.environ.get("FORGE_BASE_URL") or None

def machines():
    import time
    out = {}
    try:
        out["load"] = round(os.getloadavg()[0], 2)
        out["cpus"] = os.cpu_count()
    except OSError:
        pass
    try:
        mi = {}
        for line in open("/proc/meminfo"):
            k, v = line.split(":", 1)
            mi[k] = int(v.strip().split()[0])
        out["mem_used_gb"] = round((mi["MemTotal"] - mi["MemAvailable"]) / 1048576, 1)
        out["mem_total_gb"] = round(mi["MemTotal"] / 1048576, 1)
    except Exception:
        pass
    try:
        st = os.statvfs("/home")
        out["disk_pct"] = round(100 * (1 - st.f_bavail / st.f_blocks))
    except OSError:
        pass
    now = time.monotonic()
    if now - _MACH["t"] > 15:
        _MACH["t"] = now
        url = _env_forge_url()
        if url:
            t0 = time.monotonic()
            v = get(url.rstrip("/") + "/api/v1/version")
            _MACH["forge"] = {"url": url, "version": (v or {}).get("version"),
                              "ms": round((time.monotonic() - t0) * 1000)} if v else {"url": url, "down": True}
            tok = None
            try:
                tok = open(os.path.expanduser("~/.gitea_token")).read().strip()
            except OSError:
                pass
            try:
                import urllib.request as ur
                req = ur.Request(url.rstrip("/") + "/api/v1/repos/fleet/project-template/actions/tasks")
                if tok:
                    req.add_header("Authorization", "token " + tok)
                with ur.urlopen(req, timeout=2) as r:
                    runs = (json.load(r).get("workflow_runs") or [])
                _MACH["ci"] = {"status": runs[0].get("status"), "at": (runs[0].get("updated_at") or "")[11:16]} if runs else None
            except Exception:
                _MACH["ci"] = None
        else:
            _MACH["forge"] = None
            _MACH["ci"] = None
    if _MACH["forge"]: out["forge"] = _MACH["forge"]
    if _MACH["ci"]: out["ci"] = _MACH["ci"]
    return out

def state():
    pods = get(f"http://127.0.0.1:{DECK_PORT}/api/pods")
    proj = get(f"http://127.0.0.1:{DECK_PORT}/api/projection")
    out = {"fleet": pods is not None, "pods": [], "stream": [], "counts": {}, "status": None,
           "pod_console_port": POD_CONSOLE_PORT, "machines": machines()}
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
    --ink:#d7e2ec; --dim:#93a7ba; --faint:#71869c;
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
  .av{width:20px;height:20px;border-radius:5px;vertical-align:-5px;margin-right:7px}
  .av.big{width:34px;height:34px;border-radius:8px;vertical-align:-11px;margin-right:10px}
  .empty{color:var(--faint);padding:22px 14px;font-size:12.5px;line-height:1.7}
  .empty b{color:var(--dim);font-weight:400}

  .cbody{padding:12px 16px}
  .present{color:var(--dim);font-size:12.5px;line-height:1.65;margin:0 0 14px;max-width:72ch}
  .step{border:1px solid var(--line);border-left:3px solid var(--vi);border-radius:0 6px 6px 0;
        background:var(--pan);padding:8px 12px;margin:0 0 8px}
  .step .sname{color:var(--ink)} .step .srole{color:var(--or)}
  .step .sfacts{color:var(--dim);font-size:11.5px;margin-top:2px}
  .arrow{color:var(--faint);padding:0 10px 6px 22px;font-size:11px}

  /* ─── pipeline : les boites qui s'enchainent ─── */
  .pipe{max-width:860px}
  .pbox{border:1px solid var(--line);border-left:4px solid var(--vi);border-radius:0 8px 8px 0;
        background:var(--pan);padding:10px 14px;margin:0}
  .pbox .prole{color:var(--or);font-weight:600;font-size:14px}
  .pbox .pname{color:var(--dim);font-size:11.5px;letter-spacing:.08em;text-transform:uppercase}
  .pbox .pfacts{margin-top:5px}
  .pbox.judge{border-left-color:var(--cy)}
  .pbox.term{border-left-color:var(--gr)}
  .plink{color:var(--faint);font-size:11px;padding:2px 0 2px 26px;line-height:1.2}
  .plink::before{content:"│";display:block;padding-left:2px}
  .stage{border:1px dashed var(--line);border-radius:8px;padding:9px 12px;margin:0}
  .stage>.sttl{color:var(--faint);font-size:10.5px;letter-spacing:.14em;text-transform:uppercase;margin-bottom:8px}
  .stage .par{display:flex;gap:10px;flex-wrap:wrap}
  .stage .par .pbox{flex:1 1 240px;margin:0}
  .fact{display:inline-block;border:1px solid var(--line);border-radius:4px;padding:0 7px;
        margin:2px 4px 0 0;font-size:11px;color:var(--dim)}
  .fact b{color:var(--ink);font-weight:400}

  /* ─── editeur structure ─── */
  .fs{border:1px solid var(--line);border-radius:0 8px 8px 0;border-left:3px solid var(--am);
      background:var(--pan);padding:10px 14px;margin:0 0 12px;max-width:860px}
  .fs>.ftitle{color:var(--faint);font-size:10.5px;letter-spacing:.14em;text-transform:uppercase;margin-bottom:8px}
  .ckrow{display:flex;gap:14px;flex-wrap:wrap}
  .ck{display:flex;gap:6px;align-items:center;font-size:12.5px;color:var(--ink);cursor:pointer}
  .ck input{accent-color:#e8913c;width:14px;height:14px;cursor:pointer}
  .ck.off{color:var(--faint)}
  .frow{display:flex;gap:10px;align-items:center;margin:6px 0;flex-wrap:wrap}
  .frow label{color:var(--dim);font-size:12px;min-width:110px}
  input[type=text],input[type=number],select{background:#0a0f14;color:var(--ink);border:1px solid var(--line);
        border-radius:4px;font:12.5px var(--mono);padding:3px 8px}
  input[type=number]{width:70px}
  select{cursor:pointer}
  input:focus,select:focus{outline:1px solid var(--or)}
  .stepfs{border:1px solid var(--line);border-left:3px solid var(--vi);border-radius:0 8px 8px 0;
          background:#111820;padding:9px 12px;margin:8px 0}
  .stepfs .shead{display:flex;gap:10px;align-items:center}
  .stepfs .shead .del{margin-left:auto}
  .btn.del{color:var(--rd)} .btn.del:hover{border-color:var(--rd)}
  .mini{color:var(--faint);font-size:11px}

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
  <span class="sub" id="sub">config &mdash; le vivant se rebranche plus tard</span>
  <span class="right"><span class="sub">catalogue seul</span></span>
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
const avatar = (name, big) => { const i=document.createElement('img'); i.className='av'+(big?' big':'');
  i.src='/avatar/'+name+'.svg'; i.alt=''; i.onerror=()=>{ i.style.display='none'; }; return i; };
const phCls = p => 'ph-' + (['monitoring','launching','projecting','injecting','allocating','cleaning','releasing','publishing'].includes(p) ? p : 'unknown');
const evCls = t => /fail|crash|dead|error/.test(t) ? 'bad' : (/wake|retry|drift|stale/.test(t) ? 'warn' : '');

/* ─── onglets ─── */
function switchTo(v){
  view = v;
  document.getElementById('v-agents').classList.toggle('hidden', v!=='agents');
  document.getElementById('v-cards').classList.toggle('hidden', v!=='cards');
  document.getElementById('tab-agents').classList.toggle('on', v==='agents');
  document.getElementById('tab-cards').classList.toggle('on', v==='cards');
  if(!CAT) loadCatalogue(); else (v==='agents' ? drawAgents() : drawCards());
}
document.getElementById('tab-agents').onclick = () => switchTo('agents');
document.getElementById('tab-cards').onclick = () => switchTo('cards');
const h = location.hash||'';
if(h === '#cartes') switchTo('cards');
else if(h.startsWith('#carte-')){ csel = h.slice(7); switchTo('cards'); }
else if(h.startsWith('#edit-')){ csel = h.slice(6); editing = true; switchTo('cards'); }

/* ─── AGENTS — CONFIG SEULE (arbitrage user : ce deck est la configuration ;
   pods vivants, flux, machines se rebrancheront ailleurs plus tard) ─── */
let psel = null;

function groupsOf(){
  const P = CAT.profiles||{}; const names=Object.keys(P).sort();
  const spec = n => ((P[n]||{}).data||{}).spec||{};
  const caps = n => spec(n).capabilities||[];
  const g = {'promoteur':[], 'juges':[], 'producteurs':[], 'orchestrateurs':[], 'autres':[]};
  for(const n of names){
    if(caps(n).includes('exception_judge')) g['promoteur'].push(n);
    else if(spec(n).brief_kind==='judge') g['juges'].push(n);
    else if(caps(n).includes('producer')) g['producteurs'].push(n);
    else if(caps(n).includes('onboarder')||caps(n).includes('project_delegate')) g['orchestrateurs'].push(n);
    else g['autres'].push(n);
  }
  return g;
}

function drawAgents(){
  if(!CAT) return;
  const r = document.getElementById('rail'); r.innerHTML='';
  const g = groupsOf();
  if(!psel) psel = (g['juges'][0]||Object.keys(CAT.profiles||{})[0]||null);
  for(const grp of Object.keys(g)){
    if(!g[grp].length) continue;
    r.appendChild(el('div','grp',grp+' · '+g[grp].length));
    for(const n of g[grp]){
      const b = el('button','row'+(n===psel?' on':''));
      const idl = el('span','id'); idl.appendChild(avatar(n)); idl.append(n); b.appendChild(idl);
      const inv=(((CAT.profiles[n]||{}).data||{}).spec||{}).invocation||{};
      b.appendChild(el('span','meta',(inv.model||'?')+' · '+(inv.effort||'?')+' · '+(inv.lifetime_scope||'?')));
      b.onclick=()=>{ psel=n; drawAgents(); };
      r.appendChild(b);
    }
  }
  agentCenter(); agentRight();
}

function kvRow(box,k,v){ const r=el('div','kv'); r.appendChild(el('span','k',k)); r.appendChild(el('span',null,String(v))); box.appendChild(r); }
function chipRow(box, arr, color){ const d=el('div'); for(const a of arr){ const c=el('span','chip',a); if(color)c.style.color=color; d.appendChild(c);} if(!(arr||[]).length) d.appendChild(el('span','mini','aucun')); box.appendChild(d); }

function agentCenter(){
  const c = document.getElementById('center'); c.innerHTML='';
  const prof = (CAT.profiles||{})[psel];
  const head = el('div','pane-head');
  if(psel) head.appendChild(avatar(psel, true));
  head.appendChild(el('b',(psel||'—').toUpperCase()));
  head.appendChild(el('span','k','cap-profile — la declaration complete, rien du vivant'));
  c.appendChild(head);
  if(!prof){ c.appendChild(el('div','empty','selectionne un role')); return; }
  const d = prof.data||{}, meta=d.metadata||{}, spec=d.spec||{};
  const body = el('div','cbody');
  const sec = (title) => { const f=el('div','fs'); f.appendChild(el('div','ftitle',title)); body.appendChild(f); return f; };

  const s1 = sec('identite');
  kvRow(s1,'name', meta.name||'?'); kvRow(s1,'containment', meta.containment||'?');
  if(meta.role_index!=null) kvRow(s1,'role_index', meta.role_index+' — slot du role dans l UUID hexspeak');
  if((meta.mounts||[]).length) kvRow(s1,'mounts', meta.mounts.join(', '));

  const s2 = sec('mandat');
  kvRow(s2,'brief_kind', spec.brief_kind||'—'); kvRow(s2,'interlocutor', spec.interlocutor||'—');
  s2.appendChild(el('div','mini','capabilities — les faits que les autres surfaces derivent'));
  chipRow(s2, spec.capabilities||[], 'var(--am)');
  if(spec.deliverable_mode) kvRow(s2,'deliverable_mode', spec.deliverable_mode);

  const sc = spec.scope||{};
  const s3 = sec('scope — outils');
  s3.appendChild(el('div','mini','allowedTools · '+(sc.allowedTools||[]).length));
  chipRow(s3, sc.allowedTools||[]);
  s3.appendChild(el('div','mini','disallowedTools · '+(sc.disallowedTools||[]).length));
  chipRow(s3, sc.disallowedTools||[], 'var(--rd)');
  s3.appendChild(el('div','mini','git_ops_denied'));
  chipRow(s3, sc.git_ops_denied||[], 'var(--rd)');

  const inv = spec.invocation||{};
  const s4 = sec('invocation');
  for(const k of ['model','effort','lifetime_scope','permission_mode','boot_at_start','host_native',
                  'bridge_enabled','remote_control','wake_send_keys','subagent_template'])
    if(inv[k]!==undefined) kvRow(s4,k, inv[k]===null?'null':inv[k]);
  if((spec.timeouts||{}).response_sec) kvRow(s4,'timeouts.response_sec', spec.timeouts.response_sec+' s');

  const kn = spec.knowledge||{};
  const s5 = sec('knowledge');
  s5.appendChild(el('div','mini','skills')); chipRow(s5, kn.skills||[]);
  kvRow(s5,'monk_registry', kn.monk_registry==null?'null':kn.monk_registry);
  kvRow(s5,'monk_instance', kn.monk_instance==null?'null':kn.monk_instance);
  if('sp_template' in kn) kvRow(s5,'sp_template', kn.sp_template==null?'null':kn.sp_template);

  const mo = spec.modop_set||{};
  const s6 = sec('modop_set');
  s6.appendChild(el('div','mini','default')); chipRow(s6, mo.default||[]);
  s6.appendChild(el('div','mini','optional')); chipRow(s6, mo.optional||[]);
  s6.appendChild(el('div','mini','incompatible — PAIRES : les deux ne peuvent etre actifs ensemble'));
  (function(){ const d=el('div');
    for(const pair of (mo.incompatible||[])){
      const label = Array.isArray(pair) ? pair.join(' ⟂ ') : String(pair);
      const c=el('span','chip',label); c.style.color='var(--rd)'; d.appendChild(c);
    }
    if(!(mo.incompatible||[]).length) d.appendChild(el('span','mini','aucune'));
    s6.appendChild(d); })();

  const s7 = sec('project');
  if(spec.project){ for(const k of Object.keys(spec.project)) kvRow(s7, k, spec.project[k]==null?'null':spec.project[k]); }
  else s7.appendChild(el('div','mini','null — fleet-level, ou projete au spawn par le dispatch'));

  c.appendChild(body);
}

function agentRight(){
  const d = document.getElementById('ctx'); d.innerHTML='';
  const prof=(CAT.profiles||{})[psel];
  if(!prof){ d.appendChild(el('div','empty','—')); return; }
  const rc = el('div','card'); rc.appendChild(el('h4',null,'yaml source (lecture)'));
  const pre = document.createElement('pre');
  pre.style.cssText='font:11px/1.45 var(--mono);color:var(--dim);white-space:pre-wrap;max-height:78vh;overflow-y:auto;margin:0';
  pre.textContent = prof.text||'';
  rc.appendChild(pre); d.appendChild(rc);
}

loadCatalogue();

/* ─── CARTES ─── */
async function loadCatalogue(force){
  const c = document.getElementById('ccenter');
  if(!CAT) c.innerHTML = '<div class="empty">lecture du catalogue par le BEAM… (premier appel : quelques secondes)</div>';
  try { CAT = await (await fetch('/api/catalogue'+(force?'?refresh=1':''),{cache:'no-store'})).json(); }
  catch(e){ c.innerHTML = '<div class="empty">catalogue injoignable</div>'; return; }
  if(CAT.error){ c.innerHTML = '<div class="empty">le BEAM refuse le dump :<br>'+CAT.error+'</div>'; return; }
  if(!csel){ const names = Object.keys(CAT.cards||{}).sort(); csel = names[0] || null; }
  if(view==='cards') drawCards(); else drawAgents();
}

function newCard(){
  const name = (prompt('nom de la nouvelle carte (slug : [a-z0-9-])')||'').trim();
  if(!name) return;
  if(!/^[a-z0-9][a-z0-9-]*$/.test(name)){ alert('slug invalide'); return; }
  if((CAT.cards||{})[name]){ alert('cette carte existe deja'); return; }
  const P = pools();
  csel = name; editing = true;
  ED = {mode:'form', fits:true, text:'',
        state:{ints:[], desc:'', pres:'', jury:[], juryOn:false, rework:2,
               pre:null, audit:null, extra:[],
               producers:[{name:'build', role:P.producers[0]||'', face:'', inputs:[]}]}};
  drawCards();
}

function drawCards(){
  const r = document.getElementById('crail'); r.innerHTML='';
  const cards = CAT.cards||{};
  const nb = el('button','btn warn','+ nouvelle carte'); nb.style.margin='12px 12px 2px';
  nb.onclick = newCard; r.appendChild(nb);
  r.appendChild(el('div','grp','cartes du catalogue · '+Object.keys(cards).length));
  for(const name of Object.keys(cards).sort()){
    const meta = (cards[name].data||{}).metadata||{};
    const b = el('button','row'+(name===csel&&!editing?' on':''));
    b.appendChild(el('span','id', name));
    b.appendChild(el('span','meta', ((meta.applicable_intensity||[]).join(' ')||'—')));
    b.onclick = () => { csel = name; editing=false; ED=null; drawCards(); };
    r.appendChild(b);
  }
  cardCenter(); cardCtx();
}

function cardCenter(){
  const c = document.getElementById('ccenter'); c.innerHTML='';
  const cards = CAT.cards||{};
  const src = cards[csel] || (editing && ED ? {data:null, text:ED.text||''} : null);
  if(!src){ c.appendChild(el('div','empty','selectionne une carte, ou cree-en une')); return; }
  const data = src.data||{}, meta = data.metadata||{}, spec = data.spec||{};

  const head = el('div','pane-head');
  head.appendChild(el('b', (csel||'').toUpperCase()));
  head.appendChild(el('span','k', editing ? ((CAT.cards||{})[csel] ? 'EDITION' : 'NOUVELLE CARTE — pas encore au catalogue') : 'carte du catalogue'));
  const act = el('span','act');
  if(!editing){
    const eb = el('button','btn','éditer'); eb.onclick = () => { editing=true; ED=null; cardCenter(); };
    act.appendChild(eb);
  }
  const rb = el('button','btn','recharger'); rb.onclick = () => loadCatalogue(true);
  act.appendChild(rb); head.appendChild(act);
  c.appendChild(head);

  const body = el('div','cbody');
  if(editing){ editor(body, src); c.appendChild(body); return; }

  if(meta.presentation) body.appendChild(el('p','present', meta.presentation));

  // Le pipeline entier, boites chainees — et le JURY est un etage de plein rang, pas une note
  // de bas de page : c'est lui qui coute des tokens et rend les verdicts.
  const pipe = el('div','pipe');
  const steps = spec.steps||{};
  const order = topoOrder(steps);
  for(const sname of order){
    const st = steps[sname]||{};
    if((st.needs||[]).length) pipe.appendChild(el('div','plink','apres ' + st.needs.join(' + ')));
    pipe.appendChild(stepBox(sname, st));
  }
  if((spec.jury||[]).length){
    pipe.appendChild(el('div','plink', order.length ? 'la PR nait — jugement' : 'jugement'));
    const stg = el('div','stage');
    stg.appendChild(el('div','sttl','jury de PR · verdicts paralleles et independants'));
    const par = el('div','par');
    for(const j of spec.jury) par.appendChild(judgeBox(j));
    stg.appendChild(par);
    pipe.appendChild(stg);
  }
  pipe.appendChild(el('div','plink','tous verdicts rendus'));
  const term = el('div','pbox term');
  term.appendChild(el('div','pname','promote'));
  term.appendChild(el('div','prole',(pools().promoters.join(' + ')||'gatekeeper')+' scelle · rebase merge'));
  term.appendChild(fact({'rework max': String(spec.max_rework_rounds ?? '—'),
                         'protection': 'verrouillee par la forge',
                         'promotion': 'jamais une option — capability exception_judge'}));
  pipe.appendChild(term);
  body.appendChild(pipe);
  c.appendChild(body);
}

function stepBox(sname, st){
  const b = el('div','pbox');
  b.appendChild(el('div','pname', sname));
  const pr = el('div','prole'); if(st.role) pr.appendChild(avatar(st.role)); pr.append(st.role||'?'); b.appendChild(pr);
  const f = {};
  if(st.judge_target) f['juge'] = st.judge_target;
  if(st.brief_kind) f['brief_kind'] = st.brief_kind;
  if(st.face) f['face'] = st.face + (st.face==='ops' ? ' → livrable sur work/ops' : ' → livrable sur main');
  if((st.inputs||[]).length) f['inputs'] = st.inputs.join(', ');
  b.appendChild(fact(f));
  return b;
}

function judgeBox(name){
  const b = el('div','pbox judge');
  b.appendChild(el('div','pname','juge'));
  const pr = el('div','prole'); pr.appendChild(avatar(name)); pr.append(name); b.appendChild(pr);
  const prof = CAT.profiles && CAT.profiles[name];
  const f = {};
  if(prof){
    const spec=(prof.data||{}).spec||{}, inv=spec.invocation||{};
    f['modele'] = (inv.model||'?')+' · '+(inv.effort||'?');
    f['vie'] = inv.lifetime_scope||'?';
    if((spec.scope||{}).git_ops_denied) f['git'] = 'denie: '+spec.scope.git_ops_denied.join(',');
  } else {
    f['profil'] = 'ABSENT du catalogue';
  }
  b.appendChild(fact(f));
  return b;
}

function fact(map){
  const d = el('div','pfacts');
  for(const k of Object.keys(map)){
    const s = el('span','fact'); s.append(k+': '); const bb=document.createElement('b'); bb.textContent=map[k]; s.appendChild(bb);
    d.appendChild(s);
  }
  return d;
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

/* ─── editeur : formulaire structure + YAML, MEME sortie, MEME parseur ───
   Le formulaire est construit depuis les donnees parsees PAR LE BEAM (jamais un parse YAML en
   JS) ; il EMET du YAML naif — et l'emission a le droit d'etre naive parce que l'acceptation
   est le vrai Loader : toute betise d'emission rougit au bouton Valider. */
let ED = null;

/* Les POOLS viennent des cap-profiles (un fait = un proprietaire) :
   juge = brief_kind: judge SANS exception_judge · producteur = capabilities: producer ·
   promoteur = capabilities: exception_judge (toujours present, jamais un choix). */
function pools(){
  const P = CAT.profiles||{};
  const spec = n => ((P[n]||{}).data||{}).spec||{};
  const caps = n => spec(n).capabilities||[];
  const names = Object.keys(P).sort();
  return {
    judges: names.filter(n => spec(n).brief_kind==='judge' && !caps(n).includes('exception_judge')),
    producers: names.filter(n => caps(n).includes('producer')),
    promoters: names.filter(n => caps(n).includes('exception_judge')),
  };
}

/* Les ENUMS viennent du schema v2.5 (embarque dans le dump, lu par le BEAM). */
function enumOf(key){
  let out=null;
  (function walk(o){ if(!o||typeof o!=='object'||out) return;
    for(const k of Object.keys(o)){
      if(k===key){ const v=o[k]; const e=(v&&v.enum)||(v&&v.items&&v.items.enum); if(e){ out=e; return; } }
      walk(o[k]);
    } })(CAT.schema||{});
  return out||[];
}

/* L'OBSERVATION du canon : quels juges ont deja occupe quel siege. Les profils ne portent
   AUCUN discriminant brief-juge vs PR-juge aujourd'hui (mesure : qualifier/scoper/reviewer
   identiques hors nom) — en attendant un champ propre (judge_targets, demande au proprietaire
   du schema cap-profile), le canon fait office de mesure : un juge jamais vu sur un siege y est
   VISIBLE mais grise, avec la raison. Pool observe vide → siege ouvert a tous (pas de fantome). */
function observedSeats(){
  const o = {brief:new Set(), deliverable:new Set(), jury:new Set()};
  for(const c of Object.values(CAT.cards||{})){
    const spec=(c.data||{}).spec||{};
    for(const j of (spec.jury||[])) o.jury.add(j);
    for(const sd of Object.values(spec.steps||{})){
      if(sd.judge_target==='brief') o.brief.add(sd.role);
      if(sd.judge_target==='deliverable') o.deliverable.add(sd.role);
    }
  }
  return o;
}

/* Le MODELE A ETAGES est une MESURE des steps (judge_target du schema + pools), pas une grammaire
   posee ici : un step qui ne se classe pas rend la carte « hors grammaire » → yaml brut. */
function stageModel(data){
  const meta=(data||{}).metadata||{}, spec=(data||{}).spec||{};
  const steps=spec.steps||{}; const P=pools();
  const st={ints:(meta.applicable_intensity||[]).slice(), desc:meta.description||'',
            pres:meta.presentation||'', rework: spec.max_rework_rounds ?? 2,
            jury:(spec.jury||[]).slice(), juryOn:(spec.jury||[]).length>0,
            pre:null, producers:[], audit:null, extra:[]};
  for(const n of topoOrder(steps)){
    const sd=steps[n]||{};
    const item={name:n, role:sd.role||'', face:sd.face||'', inputs:(sd.inputs||[]).slice()};
    if(sd.judge_target==='brief' && !st.pre) st.pre=item;
    else if(sd.judge_target==='deliverable' && !st.audit) st.audit=item;
    else if(P.producers.includes(sd.role)) st.producers.push(item);
    else st.extra.push(n);
  }
  return st;
}

/* Emission NAIVE depuis les etages — needs cables par l ordre, jamais edites. Le droit d etre
   naive vient du vrai parseur : toute betise rougit au bouton Valider. */
function emitYaml(st){
  const q = s => JSON.stringify(String(s));
  const L = ['kind: WorkflowMap','metadata:',`  name: ${csel}`];
  if(st.desc) L.push(`  description: ${q(st.desc)}`);
  if(st.pres) L.push(`  presentation: ${q(st.pres)}`);
  if(st.ints.length) L.push(`  applicable_intensity: [${st.ints.join(', ')}]`);
  L.push('spec:');
  L.push(`  jury: [${st.jury.join(', ')}]`);
  L.push(`  max_rework_rounds: ${st.rework}`);
  L.push('  steps:');
  let prev = null;
  const emitStep = (item, extra) => {
    L.push(`    ${item.name}:`);
    L.push(`      role: ${item.role}`);
    for(const x of extra) L.push('      '+x);
    L.push(`      needs: [${prev ? prev : ''}]`);
    const inputs = item.inputs.length ? item.inputs : ['ticket.body'];
    L.push('      inputs:'); for(const i of inputs) L.push('        - '+i);
    prev = item.name;
  };
  if(st.pre) emitStep(st.pre, ['brief_kind: judge','judge_target: brief']);
  for(const pr of st.producers) emitStep(pr, pr.face ? [`face: ${pr.face}`] : []);
  if(st.audit) emitStep(st.audit, ['brief_kind: judge','judge_target: deliverable']);
  if(!st.pre && !st.producers.length && !st.audit) L.push('    {}');
  return L.join('\n') + '\n';
}

function editor(body, src){
  const P = pools();
  if(ED === null){
    const canonData = ((CAT.cards||{})[csel]||{}).data;
    const model = canonData ? stageModel(canonData) : null;
    const fits = !!(model && !model.extra.length);
    ED = {mode: fits ? 'form' : 'yaml', state: model, fits: fits, text: src.text || ''};
  }

  const mbar = el('div'); mbar.style.cssText='display:flex;gap:8px;margin-bottom:10px;align-items:center';
  const fb = el('button','btn'+(ED.mode==='form'?' warn':''),'formulaire');
  const yb = el('button','btn'+(ED.mode==='yaml'?' warn':''),'yaml brut');
  mbar.appendChild(fb); mbar.appendChild(yb);
  if(!ED.fits) mbar.appendChild(el('span','mini','carte HORS GRAMMAIRE (step inclassable) — yaml brut seul'));
  body.appendChild(mbar);

  const zone = el('div'); body.appendChild(zone);

  const bar = el('div'); bar.style.cssText='display:flex;gap:10px;margin-top:10px';
  const vb = el('button','btn','valider (vrai parseur)');
  const sb = el('button','btn warn','sauver au catalogue');
  const cb = el('button','btn','fermer');
  bar.appendChild(vb); bar.appendChild(sb); bar.appendChild(cb);
  body.appendChild(bar);
  const res = el('div','vres'); res.style.display='none'; body.appendChild(res);

  const notice = el('div','notice');
  notice.innerHTML = "La page ne possede AUCUN fait : sieges = capabilities, champs = enums du "
    + "schema v2.5, ordre des etages = mesure du canon — et sauver repasse par le parseur reel "
    + "avant d ecrire. L ecriture va DIRECTEMENT au catalogue de la boite (YOLO assume) ; la "
    + "fleet, elle, sert son image de boot : effet au prochain start. ⚠ Le formulaire regenere "
    + "le YAML : les commentaires ne survivent pas — carte commentee = « yaml brut ».";
  body.appendChild(notice);

  let ta = null;
  const currentText = () => ED.mode==='yaml' ? ta.value : emitYaml(ED.state);

  /* Tous les sieges du pool VISIBLES (radios) — un dropdown cache l offre, et « qui peut
     s asseoir la » est exactement l information que la page doit montrer. */
  let seatSeq = 0;
  function seatRadios(current, pool, onpick, allowNone){
    const g = el('span','ckrow'); const name = 'seat'+(seatSeq++);
    const mk = (val, label, dis, why) => {
      const lb = el('label','ck'+(val===current?'':' off'));
      if(dis){ lb.style.opacity='.42'; lb.title = why||''; lb.style.cursor='not-allowed'; }
      const rb = document.createElement('input'); rb.type='radio'; rb.name=name; rb.checked = val===current;
      rb.disabled = !!dis && val!==current;
      rb.onchange = () => onpick(val);
      lb.appendChild(rb); lb.append(' '+label+(dis?' ⌀':''));
      g.appendChild(lb);
    };
    if(allowNone) mk('', allowNone, false);
    for(const r of pool){
      if(typeof r === 'string') mk(r, r, false);
      else mk(r.name, r.name, r.off, r.why);
    }
    return g;
  }

  function stageBox(title, on, toggleable, buildBody, onToggle){
    const g = el('div','fs'); if(!on) g.style.opacity='.55';
    const head = el('div'); head.style.cssText='display:flex;align-items:center;gap:10px';
    head.appendChild(el('div','ftitle',title));
    if(toggleable){
      const lb = el('label','ck'); lb.style.marginLeft='auto';
      const ck = document.createElement('input'); ck.type='checkbox'; ck.checked=on;
      ck.onchange = () => onToggle(ck.checked);
      lb.appendChild(ck); lb.append(on ? ' active' : ' desactive'); head.appendChild(lb);
    } else {
      head.appendChild(el('span','mini', title.startsWith('④')||title.startsWith('⑤') ? 'toujours' : ''));
    }
    g.appendChild(head);
    if(on) buildBody(g);
    return g;
  }

  function renderZone(){
    zone.innerHTML='';
    fb.className = 'btn'+(ED.mode==='form'?' warn':''); yb.className = 'btn'+(ED.mode==='yaml'?' warn':'');
    if(ED.mode==='yaml'){
      sb.disabled = false; sb.style.opacity='1';
      ta = document.createElement('textarea'); ta.value = ED.text; ta.spellcheck=false;
      ta.oninput = () => { ED.text = ta.value; };
      zone.appendChild(ta);
      return;
    }
    const st = ED.state;

    const g = el('div','fs'); g.appendChild(el('div','ftitle','gouvernance'));
    const ints = el('div','ckrow');
    for(const i of enumOf('applicable_intensity')){
      const on = st.ints.includes(i);
      const lb = el('label','ck'+(on?'':' off'));
      const ck = document.createElement('input'); ck.type='checkbox'; ck.checked=on;
      ck.onchange = () => { ck.checked ? st.ints.push(i) : st.ints.splice(st.ints.indexOf(i),1);
                            st.ints.sort(); renderZone(); };
      lb.appendChild(ck); lb.append(' '+i); ints.appendChild(lb);
    }
    g.appendChild(ints);
    const rw = el('div','frow'); rw.appendChild(el('label',null,'rework max'));
    const ri = document.createElement('input'); ri.type='number'; ri.min=0; ri.max=9; ri.value=st.rework;
    ri.onchange = () => { st.rework = parseInt(ri.value||'0',10); };
    rw.appendChild(ri); g.appendChild(rw);
    zone.appendChild(g);

    zone.appendChild(stageBox('① PRE-FLIGHT — le brief est juge avant tout', !!st.pre, true, (box)=>{
      const f = el('div','frow'); f.appendChild(el('label',null,'juge du brief'));
      const obsB = observedSeats().brief;
      const poolB = P.judges.map(n => ({name:n, off: obsB.size>0 && !obsB.has(n),
        why:'jamais observe sur ce siege dans le canon — profil sans discriminant, calibrage SP inconnu'}));
      f.appendChild(seatRadios(st.pre.role, poolB, v => { st.pre.role = v; renderZone(); }));
      box.appendChild(f);
      box.appendChild(el('div','mini','⌀ = jamais vu sur ce siege dans le canon (les profils juges sont indiscrimines — champ judge_targets demande)'));
    }, on => { st.pre = on ? {name:'brief-review', role:P.judges[0]||'', face:'', inputs:[]} : null; renderZone(); }));

    const prodBox = el('div','fs');
    const ph = el('div'); ph.style.cssText='display:flex;align-items:center;gap:10px';
    ph.appendChild(el('div','ftitle','② PRODUCTION — la chaine des producteurs'));
    prodBox.appendChild(ph);
    st.producers.forEach((pr, idx) => {
      const sf = el('div','stepfs');
      const sh = el('div','shead');
      const ni = document.createElement('input'); ni.type='text'; ni.value=pr.name; ni.size=14;
      ni.onchange = () => { pr.name = ni.value.trim(); };
      sh.appendChild(ni); sh.appendChild(el('span','mini','→'));
      sh.appendChild(seatRadios(pr.role, P.producers, v => { pr.role = v; renderZone(); }));
      const faces = enumOf('face');
      if(faces.length){
        sh.appendChild(el('span','mini','· face'));
        sh.appendChild(seatRadios(pr.face, faces, v => { pr.face = v; renderZone(); }, '(moteur)'));
      }
      if(!(st.producers.length===1 && !st.audit)){
        const del = el('button','btn del','retirer'); del.onclick = () => { st.producers.splice(idx,1); renderZone(); };
        const dspan = el('span','del'); dspan.appendChild(del); sh.appendChild(dspan);
      }
      sf.appendChild(sh);
      sf.appendChild(el('div','mini', (pr.face==='ops' ? 'livrable sur work/ops (chemin ticket-doc)' : pr.face==='code' ? 'livrable sur main (chemin ticket-code)' : 'face par defaut du moteur') + ' · sieges = capabilities: producer'));
      prodBox.appendChild(sf);
    });
    const add = el('button','btn','+ producteur (enchaine apres le precedent)');
    add.onclick = () => { st.producers.push({name:'build'+(st.producers.length?'-'+(st.producers.length+1):''), role:P.producers[0]||'', face:'', inputs:[]}); renderZone(); };
    prodBox.appendChild(add);
    zone.appendChild(prodBox);

    zone.appendChild(stageBox('③ AUDIT — un juge lit le livrable', !!st.audit, true, (box)=>{
      const f = el('div','frow'); f.appendChild(el('label',null,'auditeur'));
      const obsD = observedSeats().deliverable;
      const poolD = P.judges.map(n => ({name:n, off: obsD.size>0 && !obsD.has(n),
        why:'jamais observe sur ce siege dans le canon'}));
      f.appendChild(seatRadios(st.audit.role, poolD, v => { st.audit.role = v; renderZone(); }));
      box.appendChild(f);
      if(st.producers.length===0) box.appendChild(el('div','mini','seul etage de travail de la carte — desactivation impossible'));
    }, on => { if(!on && !st.producers.length) { renderZone(); return; }
       st.audit = on ? {name:'audit', role:P.judges[0]||'', face:'', inputs:['ticket.body','audit_target']} : null; renderZone(); }));

    zone.appendChild(stageBox('④ JURY DE PR — verdicts paralleles', st.juryOn, true, (box)=>{
      const jr = el('div','ckrow');
      const obsJ = observedSeats().jury;
      for(const name of P.judges){
        const on = st.jury.includes(name);
        const off = obsJ.size>0 && !obsJ.has(name) && !on;
        const lb = el('label','ck'+(on?'':' off'));
        if(off){ lb.style.opacity='.42'; lb.title='jamais observe dans un jury du canon (vulcan : siege reserve — codex pas branche)'; }
        const ck = document.createElement('input'); ck.type='checkbox'; ck.checked=on; ck.disabled=off;
        ck.onchange = () => { ck.checked ? st.jury.push(name) : st.jury.splice(st.jury.indexOf(name),1); renderZone(); };
        lb.appendChild(ck); lb.append(' '+name+(off?' ⌀':'')); jr.appendChild(lb);
      }
      box.appendChild(jr);
      box.appendChild(el('div','mini','le promoteur n est PAS ici — il scelle toujours (etage ⑤) · ⌀ = jamais vu dans un jury canon'));
    }, on => { st.juryOn = on; if(!on) st.jury = []; renderZone(); }));

    sb.disabled = false; sb.style.opacity = '1';
    const pm = el('div','fs'); pm.style.borderLeftColor='var(--gr)';
    pm.appendChild(el('div','ftitle','⑤ PROMOTE — jamais une option'));
    pm.appendChild(el('div','kv', (P.promoters.join(' + ')||'?') + ' scelle, quoi qu on coche — capability exception_judge, pas un choix de carte'));
    zone.appendChild(pm);
  }

  fb.onclick = () => { if(ED.state && ED.fits){ ED.mode='form'; renderZone(); } };
  yb.onclick = () => { if(ED.mode==='form') ED.text = emitYaml(ED.state); ED.mode='yaml'; renderZone(); };
  renderZone();

  vb.onclick = async () => {
    res.style.display='block'; res.className='vres'; res.textContent='validation par le BEAM… (quelques secondes)';
    const r = await (await fetch('/api/cards/validate', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({name: csel, text: currentText()})})).json();
    if(r.ok && (r.warnings||[]).length){ res.className='vres warn'; res.textContent='CARTE VALIDE (parseur) — mais :\n' + r.warnings.join('\n'); }
    else if(r.ok){ res.className='vres ok'; res.textContent='CARTE VALIDE — schema + graphe passes par le vrai Loader.'; }
    else { res.className='vres ko'; res.textContent=r.error||'erreur inconnue'; }
  };
  sb.onclick = async () => {
    res.style.display='block'; res.className='vres'; res.textContent='validation puis sauvegarde…';
    const r = await (await fetch('/api/cards/save', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({name: csel, text: currentText()})})).json();
    if(r.ok){ res.className='vres ok'; res.textContent='ECRIT AU CATALOGUE : '+r.path+'\n(la fleet le servira a son prochain start — image au boot)';
      editing=false; ED=null; loadCatalogue(true); }
    else { res.className='vres ko'; res.textContent=r.error||'refus'; }
  };
  cb.onclick = () => { editing=false; ED=null; loadCatalogue(); };
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
        elif path.startswith("/avatar/"):
            name = path.split("/avatar/", 1)[1].removesuffix(".svg")
            if not CARD_NAME_RE.match(name):
                self._send(404, "no\n", "text/plain"); return
            if _CATALOGUE["payload"] is None:
                catalogue()
            adir = ((_CATALOGUE["payload"] or {}).get("roots") or {}).get("assets") or ""
            fp = os.path.join(adir, f"{name}.svg")
            try:
                raw = open(fp, "rb").read()
            except OSError:
                self._send(404, "no\n", "text/plain"); return
            self.send_response(200)
            self.send_header("Content-Type", "image/svg+xml")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "max-age=3600")
            self.end_headers()
            self.wfile.write(raw)
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
        elif path == "/api/cards/save":
            v = validate_card(name, text)
            if not v.get("ok"):
                self._json(v)
                return
            r = save_card(name, text)
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
