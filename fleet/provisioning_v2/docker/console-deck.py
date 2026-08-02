#!/usr/bin/env python3
# SOURCE: fleet/provisioning_v2/docker/console-deck.py
# AUTHOR: consultant
# STARDATE: 2026-08-02
# STATUS: PROTO-V2 — le deck de la boite : UNE page, des onglets verticaux, l'etat sonde en continu
#
# CE QUE CETTE PAGE REMPLACE, ET POURQUOI : la landing precedente etait generee UNE FOIS au
# demarrage et chaque lien QUITTAIT la page. Un operateur qui ouvre une console perdait la vue
# d'ensemble, et l'etat affiche datait du boot. Ici la coquille reste, le contenu change dans un
# cadre, et la liste des agents est relue a intervalle : ce qui est affiche est ce qui est vrai.
#
# STDLIB SEULE (http.server) : l'image n'embarque pas de framework web et n'a pas a en embarquer
# un pour une page. Mono-thread suffisant — un operateur, quelques onglets.
#
# CE QUE LE SERVEUR NE FAIT PAS : il ne PILOTE rien (aucun POST, aucune action). Il lit et il
# montre. Toute la conduite passe par les consoles (ttyd) ou l'API de la fleet.

import html
import json
import os
import re
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import urlopen

PORT = int(os.environ.get("LCARS_LANDING_PORT", "20999"))
HUMANS_SH = os.environ.get("LCARS_CONSOLE_HUMANS", "/opt/lcars/console-humans.sh")

# Le bloc de 10 ports par humain, MEME formule que bin/fleet_v2 et console.sh (`21000 + uid%500*10`).
# Recopiee ici parce que ce serveur tourne AVANT toute fleet et ne peut rien lui demander ; les
# offsets, eux, sont le contrat de la boite.
PORT_BASE, PORT_MOD, PORT_SPAN = 21000, 500, 10
OFF_API, OFF_DECK, OFF_CONSOLE, OFF_POD = 0, 1, 4, 5

POD_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def block(uid):
    base = PORT_BASE + (uid % PORT_MOD) * PORT_SPAN
    return {
        "api": base + OFF_API,
        "deck": base + OFF_DECK,
        "console": base + OFF_CONSOLE,
        "pod": base + OFF_POD,
    }


def humans():
    """Humains de la boite : uid >= 1000, shell reel — la meme population que console.sh sert."""
    out = []
    try:
        with open("/etc/passwd") as fh:
            for line in fh:
                f = line.rstrip("\n").split(":")
                if len(f) < 7:
                    continue
                name, uid, home, shell = f[0], int(f[2]), f[5], f[6]
                if uid >= 1000 and uid < 65000 and shell.endswith(("bash", "sh", "zsh")):
                    out.append({"human": name, "uid": uid, "home": home, "ports": block(uid)})
    except OSError:
        pass
    return sorted(out, key=lambda h: h["uid"])


def pod_projects():
    """
    pod_id -> nom de projet, lu dans les MONTAGES REELS du pod (`/proc/<pid>/cmdline` du bwrap).

    POURQUOI PAS LE NOM DU POD : `Fleet.Pilot.PodId` declare l'identifiant OPAQUE (« we don't
    re-parse the id, we ANCHOR it by prefix ») et il a trois formes (worker, architecte,
    permanent). Le montage `/home/projects.work/<projet>`, lui, EST le rattachement — c'est le
    projet que le pod peut lire, pas une chaine qui lui ressemble. Un pod sans ce montage n'a pas
    de projet : il est fleet-level, et c'est une reponse, pas un manque.
    """
    found = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                argv = fh.read().split(b"\0")
        except OSError:
            continue
        pod_id = project = None
        for i, a in enumerate(argv):
            if a == b"--hostname" and i + 1 < len(argv):
                v = argv[i + 1].decode("utf-8", "replace")
                if v.startswith("lcars-pod-"):
                    pod_id = v[len("lcars-pod-"):]
            elif a.startswith(b"/home/projects.work/"):
                seg = a.decode("utf-8", "replace").split("/")
                if len(seg) > 3 and seg[3]:
                    project = seg[3]
        if pod_id:
            found[pod_id] = project
    return found


def fleet_pods(human):
    """
    Pods vivants d'un humain, vus par SA fleet (le deck d'observation, base+1).

    Source unique volontaire : le runtime sait ce qu'il a spawne (role, phase), la ou une
    enumeration de sockets ne rend que des noms. Fleet eteinte = liste vide, PAS une erreur :
    une boite sans fleet est un etat nominal, la page le dit ailleurs.
    """
    url = f"http://127.0.0.1:{human['ports']['deck']}/api/pods"
    try:
        with urlopen(url, timeout=2) as r:
            data = json.load(r)
    except Exception:
        return None
    return data.get("pods") or []


def state():
    projects = pod_projects()
    hs = []
    for h in humans():
        pods = fleet_pods(h)
        h = dict(h, fleet=(pods is not None), pods=[])
        for p in pods or []:
            pid = p.get("pod_id", "")
            if not POD_ID_RE.match(pid):
                continue
            h["pods"].append({
                "pod_id": pid,
                "role": p.get("role") or "?",
                "phase": p.get("phase") or "?",
                "project": projects.get(pid),
            })
        hs.append(h)
    return {"hostname": socket.gethostname(), "humans": hs}


PAGE = r"""<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LCARS &mdash; %(host)s</title>
<style>
  :root { --or:#FF9900; --am:#FFCC66; --bg:#000; --pan:#141414; --dim:#7a7a7a; --line:#262626 }
  * { box-sizing:border-box }
  html,body { height:100%% }
  body { margin:0; background:var(--bg); color:var(--am);
         font:15px/1.5 ui-monospace,"DejaVu Sans Mono",Menlo,monospace; display:flex }
  nav { width:236px; flex:0 0 236px; background:var(--pan); border-right:3px solid var(--or);
        overflow-y:auto; padding-bottom:18px }
  nav h1 { color:var(--or); font-size:15px; letter-spacing:.22em; margin:18px 0 14px 18px; font-weight:700 }
  .grp { color:var(--dim); font-size:11px; letter-spacing:.16em; margin:16px 0 4px 18px; text-transform:uppercase }
  .tab { display:block; width:100%%; text-align:left; background:none; border:0; border-left:4px solid transparent;
         padding:7px 18px; color:var(--am); font:inherit; cursor:pointer }
  .tab:hover { background:#1f1f1f; color:var(--or) }
  .tab.here { border-left-color:var(--or); color:var(--or); background:#1a1a1a }
  .tab .meta { color:var(--dim); font-size:11px; display:block }
  main { flex:1; display:flex; flex-direction:column; min-width:0 }
  header { padding:10px 18px; border-bottom:1px solid var(--line); color:var(--dim); font-size:12px;
           display:flex; gap:14px; align-items:baseline }
  header b { color:var(--or); font-weight:400; letter-spacing:.1em }
  #frame { flex:1; border:0; width:100%%; background:#000 }
  #panel { flex:1; overflow-y:auto; padding:22px 26px; display:none }
  table { border-collapse:collapse; width:100%%; max-width:820px; margin-bottom:22px }
  th,td { text-align:left; padding:6px 10px; border-bottom:1px solid var(--line) }
  th { color:var(--or); font-weight:400; width:200px; white-space:nowrap }
  .note { border-left:3px solid var(--or); background:var(--pan); padding:11px 14px; color:var(--dim); max-width:820px }
  .note b { color:var(--am); font-weight:400 }
</style>
<nav>
  <h1>LCARS</h1>
  <div id="rail"></div>
</nav>
<main>
  <header><b id="crumb">STATUT</b><span id="hint"></span></header>
  <iframe id="frame" title="contenu"></iframe>
  <div id="panel"></div>
</main>
<script>
const HOST = location.hostname;
let current = null;

function el(t, cls, txt) { const e = document.createElement(t); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; }

function show(tab) {
  current = tab.key;
  document.querySelectorAll('.tab').forEach(b => b.classList.toggle('here', b.dataset.key === tab.key));
  document.getElementById('crumb').textContent = tab.crumb;
  document.getElementById('hint').textContent = tab.hint || '';
  const frame = document.getElementById('frame'), panel = document.getElementById('panel');
  if (tab.url) {
    panel.style.display = 'none'; frame.style.display = '';
    if (frame.dataset.url !== tab.url) { frame.dataset.url = tab.url; frame.src = tab.url; }
  } else {
    frame.style.display = 'none'; panel.style.display = '';
    panel.innerHTML = ''; panel.appendChild(tab.render());
  }
}

function statusPanel(s) {
  const wrap = el('div');
  const t = el('table');
  const rows = [['hostname', s.hostname]];
  for (const h of s.humans) {
    rows.push([`humain ${h.human} (uid ${h.uid})`,
      h.fleet ? `fleet vivante — ${h.pods.length} pod(s)` : 'fleet eteinte']);
  }
  for (const [k, v] of rows) {
    const tr = el('tr'); tr.appendChild(el('th', null, k)); tr.appendChild(el('td', null, v)); t.appendChild(tr);
  }
  wrap.appendChild(t);
  const n = el('div', 'note');
  n.innerHTML = "Cette page ne <b>pilote</b> rien : elle lit et elle montre. " +
    "La liste des agents est relue toutes les 10 s — un pod qui nait ou meurt apparait ou disparait ici sans rechargement.";
  wrap.appendChild(n);
  return wrap;
}

function build(s) {
  const rail = document.getElementById('rail');
  const tabs = [];
  rail.innerHTML = '';

  const add = (group, label, meta, tab) => {
    if (group) rail.appendChild(el('div', 'grp', group));
    const b = el('button', 'tab');
    b.dataset.key = tab.key;
    b.appendChild(document.createTextNode(label));
    if (meta) b.appendChild(el('span', 'meta', meta));
    b.onclick = () => show(tab);
    rail.appendChild(b);
    tabs.push(tab);
  };

  add('boite', 'Statut', null, { key: 'status', crumb: 'STATUT', render: () => statusPanel(s) });

  for (const h of s.humans) {
    add('humain ' + h.human, 'Console', 'shell ' + h.human,
        { key: 'console-' + h.human, crumb: 'CONSOLE — ' + h.human,
          url: `http://${HOST}:${h.ports.console}` });
    add(null, 'Deck d\'observation', h.fleet ? 'fleet vivante' : 'fleet eteinte',
        { key: 'deck-' + h.human, crumb: 'DECK — ' + h.human,
          hint: h.fleet ? '' : '(la fleet de cet humain ne tourne pas)',
          url: `http://${HOST}:${h.ports.deck}` });

    // Les agents, GROUPES PAR PROJET. Le rattachement vient du montage reel du pod ; un pod sans
    // zone projet est fleet-level, il a son propre groupe au lieu d'etre range de force.
    const byProject = {};
    for (const p of h.pods) (byProject[p.project || '— fleet'] ||= []).push(p);
    for (const proj of Object.keys(byProject).sort()) {
      let first = true;
      for (const p of byProject[proj].sort((a, b) => a.pod_id.localeCompare(b.pod_id))) {
        add(first ? 'projet ' + proj : null, p.role, p.phase + ' · ' + p.pod_id,
            { key: 'pod-' + p.pod_id, crumb: p.role.toUpperCase() + ' — ' + proj,
              hint: p.pod_id,
              url: `http://${HOST}:${h.ports.pod}?arg=${encodeURIComponent(p.pod_id)}` });
        first = false;
      }
    }
  }

  const keep = tabs.find(t => t.key === current) || tabs[0];
  show(keep);
}

async function tick() {
  try {
    const s = await (await fetch('/api/state', { cache: 'no-store' })).json();
    const sig = JSON.stringify(s.humans.map(h => [h.human, h.fleet, h.pods.map(p => [p.pod_id, p.role, p.phase, p.project])]));
    if (sig !== window.__sig) { window.__sig = sig; build(s); }
  } catch (e) { /* la page survit a une sonde ratee : elle garde son dernier etat vrai */ }
}
tick(); setInterval(tick, 10000);
</script>
"""


class Deck(BaseHTTPRequestHandler):
    server_version = "lcars-deck"

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
            self._send(200, PAGE % {"host": html.escape(socket.gethostname())}, "text/html; charset=utf-8")
        elif path == "/health":
            self._send(200, "ok\n", "text/plain; charset=utf-8")
        else:
            self._send(404, "not found\n", "text/plain; charset=utf-8")

    def log_message(self, fmt, *args):  # une page consultee n'est pas un evenement
        pass


if __name__ == "__main__":
    # 0.0.0.0 DANS le conteneur : la frontiere reelle est la publication compose, qui n'expose que
    # sur la loopback de l'hote. Meme raison que ttyd (cf. console.sh) — un bind loopback ici
    # rendrait la page injoignable depuis un navigateur, donc inutile.
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Deck)
    print(f"[lcars-deck] deck servi sur :{PORT}", file=sys.stderr, flush=True)
    srv.serve_forever()
