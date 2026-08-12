#!/usr/bin/env python3
# SOURCE: fleet/test/test_console_deck.py
# AUTHOR: DrDree
# STARDATE: 2026-08-08
# STATUS: actif — la sonde du deck de la boite, et sa distinction a trois etats
#
# POURQUOI CE FICHIER. `console-deck.py` interrogeait le deck d'un humain avec `timeout=2` et
# rendait `None` sur n'importe quelle exception ; l'appelant en faisait `fleet=False` et la page
# affichait « fleet eteinte ». Un silence de deux secondes devenait donc une ASSERTION
# d'extinction. C'est le piege que le read-model du runtime a ferme par
# `:live | :deaf | :unavailable`, refait a deux cents lignes de la.
#
# CE QUI EST EPINGLE : la CAUSE discrimine, pas l'echec. Connexion refusee = personne n'ecoute =
# eteinte, et c'est une mesure. Timeout = on n'a PAS mesure, et la page doit le dire.
#
# Les trois etats sont produits contre de vraies sockets — un serveur qui repond, un port ferme, un
# socket qui accepte et se tait — parce qu'un stub d'exception prouverait seulement que le `except`
# est bien ecrit, pas que la bibliotheque leve ce qu'on croit.

import importlib.util
import json
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
DECK = os.path.join(HERE, "..", "deploy", "docker", "console-deck.py")

ok = True


def check(cond, label):
    global ok
    print(("PASS" if cond else "FAIL") + ": " + label)
    ok = ok and bool(cond)


def load_deck():
    spec = importlib.util.spec_from_file_location("console_deck", DECK)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def serve_pods(pods):
    """Un vrai serveur HTTP qui rend la charge attendue. Rend son port."""

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            body = json.dumps({"pods": pods}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv.server_address[1], srv


def closed_port():
    """Un port sur lequel PERSONNE n'ecoute : bind pour le reserver, puis relache."""
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def silent_port():
    """Un socket qui ACCEPTE la connexion et ne repond jamais — le cas du timeout."""
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(1)
    port = s.getsockname()[1]

    def hold():
        try:
            conn, _ = s.accept()
            time.sleep(30)
            conn.close()
        except OSError:
            pass

    threading.Thread(target=hold, daemon=True).start()
    return port, s


# LE SUJET DE CE TEST N'EST PAS DANS TOUS LES ARBRES OU CE TEST TOURNE. `console-deck.py` vit sous
# `deploy/`, et l'etage `build` de l'image exclut cet arbre par construction (le layer resterait
# invalide a chaque edition de compose, pour un gate de ~10 min). Le fichier partait donc en
# `FileNotFoundError` a l'import : exit 1 SANS une seule ligne `FAIL:`, donc un gate rouge dont le
# decompte disait `PASS=14 FAIL=0` — un rouge qui n'explique pas de quoi il est fait.
#
# Meme forme que GO-7 dans `shell_gate.sh`, et le discriminant est un FAIT, pas une devinette : un
# depot porte une entree `.git`, l'artefact n'en a aucune. Sujet absent HORS depot = perimetre
# declare ; sujet absent DANS un depot = ECHEC DUR — la, le fichier devrait etre la, et un saut
# silencieux ferait disparaitre ce garde le jour ou quelqu'un supprime son sujet.
if not os.path.isfile(DECK):
    if os.path.exists(os.path.join(HERE, "..", "..", ".git")):
        print("FAIL: console-deck.py introuvable DANS un depot (%s) — sujet manquant, pas perimetre"
              % DECK)
        sys.exit(1)
    print("--- perimetre : console-deck.py absent de cet artefact (`deploy/` hors du stage de"
          " build) — contexte hors-depot, ce test NE MESURE RIEN ici. ---")
    sys.exit(0)

deck = load_deck()
check(hasattr(deck, "fleet_pods"), "console-deck.py se charge et expose fleet_pods")

live_port, srv = serve_pods([{"pod_id": "a"}, {"pod_id": "b"}])
status, pods = deck.fleet_pods({"ports": {"deck": live_port}})
check(status == "live", "un deck qui repond -> 'live' (vu: %s)" % status)
check(len(pods) == 2, "les pods rendus sont ceux du deck (vu: %d)" % len(pods))
srv.shutdown()

status, pods = deck.fleet_pods({"ports": {"deck": closed_port()}})
check(status == "off", "connexion REFUSEE -> 'off' : personne n'ecoute, et on l'a mesure (vu: %s)" % status)
check(pods == [], "'off' ne fabrique aucun pod")

sport, ssock = silent_port()
t0 = time.monotonic()
status, pods = deck.fleet_pods({"ports": {"deck": sport}})
elapsed = time.monotonic() - t0
# LE test de ce fichier : ce cas rendait « fleet eteinte ».
check(
    status == "unknown",
    "un socket qui accepte et se TAIT -> 'unknown', jamais 'off' (vu: %s)" % status,
)
check(elapsed < 10, "la sonde reste bornee par son timeout (%.1fs)" % elapsed)
ssock.close()

check(
    deck.fleet_pods({"ports": {"deck": closed_port()}})[0]
    != deck.fleet_pods({"ports": {"deck": silent_port()[0]}})[0],
    "eteinte et non-mesuree ne sont PAS le meme etat",
)

# ─── LE RATTACHEMENT PROJET ────────────────────────────────────────────────────────────────────
# Le deck le derivait d'un montage `/home/projects.ops/` que `pod_mounts_env` a retire de tous les
# pods de projet : le scan ne repondait plus que pour les architectes, et son repli AFFIRMAIT
# « fleet-level » la ou il voulait dire « je ne sais pas ». Le slug vient desormais du runtime, qui
# le sait. Ces deux cas etaient MUETS dans ce corpus — c'est ce silence qui a laisse la derive
# vivre le temps qu'il a fallu pour la voir a l'oeil.
pport, psrv = serve_pods([
    {"pod_id": "p1", "role": "engineer", "phase": "ready", "project_slug": "vitrine"},
    {"pod_id": "p2", "role": "starfleet", "phase": "ready"},
])
_, pods = deck.fleet_pods({"ports": {"deck": pport}})
by_id = {p["pod_id"]: p for p in pods}
check(
    by_id["p1"].get("project_slug") == "vitrine",
    "le slug publie par le runtime traverse la sonde (vu: %s)" % by_id["p1"].get("project_slug"),
)
check(
    by_id["p2"].get("project_slug") is None,
    "un pod fleet-level n'a pas de projet, et c'est une reponse du runtime",
)
psrv.shutdown()



# ─── LA PORTE ──────────────────────────────────────────────────────────────────────────────────
# Le deck servait l'annuaire COMPLET des humains a qui l'ouvrait. La fleet etait deja cloisonnee
# par uid (un bloc de ports chacun) : identifier ne cree donc pas la separation, ca rend l'INDEX
# personnel. Ce qui est epingle ici, c'est exactement ce qu'une relecture ne verifie pas a l'oeil :
#
#  1. sans configuration, le deck ne sert RIEN — pas d'annuaire de repli qui rendrait l'absence
#     de configuration invisible ;
#  2. `/api/state` est filtre A LA SOURCE — un index qui n'affiche qu'un humain pendant que l'API
#     les sert tous n'a rien rendu personnel, il a cache une liste a un fetch de distance ;
#  3. un `state` inconnu au retour est REFUSE — sans ca, un tiers pose sa session dans le
#     navigateur de quelqu'un d'autre ;
#  4. un compte forge hors de l'equipe est reconnu ET refuse, et les deux se disent ;
#  5. membre de l'equipe SANS utilisateur systeme = le convergeur n'est pas passe, et ca se dit
#     autrement qu'un refus.
#
# La forge est simulee : le sujet du test est la porte, pas Gitea (dont le comportement est mesure
# sur banc, pas devine ici).
import urllib.error
import urllib.request

FAKE = {"login": "zoe", "groups": ["fleet", "fleet:humans"]}


def fake_forge():
    class H(BaseHTTPRequestHandler):
        def _json(self, code, obj):
            b = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_POST(self):
            self.rfile.read(int(self.headers.get("content-length") or 0))
            self._json(200, {"access_token": "at-probe", "token_type": "bearer",
                             "expires_in": 3600, "refresh_token": "rt-probe"})

        def do_GET(self):
            self._json(200, {"sub": "1", "preferred_username": FAKE["login"],
                             "groups": FAKE["groups"]})

        def log_message(self, *a):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv.server_address[1], srv


def start_deck():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), deck.Deck)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv.server_address[1], srv


def fetch(port, path, cookie=None):
    """Rend (code, corps, headers) SANS suivre les redirections — la redirection EST la mesure."""

    class NoRedir(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a):
            return None

    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path))
    if cookie:
        req.add_header("Cookie", cookie)
    try:
        with urllib.request.build_opener(NoRedir).open(req, timeout=5) as r:
            return r.getcode(), r.read().decode("utf-8", "replace"), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), dict(e.headers)


forge_port, forge_srv = fake_forge()
FORGE = "http://127.0.0.1:%d" % forge_port
cfg_path = os.path.join(HERE, "..", "tmp-deck-oidc-%d.json" % os.getpid())

# (1) NON CONFIGURE : aucun repli, et le refus nomme ce qui manque.
deck.OIDC_CONFIG = cfg_path + ".absent"
dport, dsrv = start_deck()
code, body, _ = fetch(dport, "/")
check(code == 503, "sans client OAuth2 pose, le deck refuse de servir (vu: %d)" % code)
check("NON CONFIGURE" in body and "absent" in body,
      "le refus NOMME le fichier manquant, il ne dit pas seulement non")
check(fetch(dport, "/health")[0] == 200,
      "/health repond AVANT la porte — la sonde du conteneur n'a pas de session")

with open(cfg_path, "w") as fh:
    json.dump({"client_id": "cid", "client_secret": "csec",
               "public_url": FORGE, "internal_url": FORGE}, fh)
deck.OIDC_CONFIG = cfg_path

cfg, why = deck.oidc_config()
check(cfg is not None and why is None, "une config complete se charge (why: %s)" % why)
with open(cfg_path + ".partial", "w") as fh:
    json.dump({"client_id": "cid", "public_url": FORGE}, fh)
deck.OIDC_CONFIG = cfg_path + ".partial"
_, why = deck.oidc_config()
check(why is not None and "client_secret" in why,
      "un champ manquant est NOMME (vu: %s)" % why)
deck.OIDC_CONFIG = cfg_path

# (2) PAS DE SESSION : la page invite, l'API refuse. Les deux, pas l'une des deux.
code, body, _ = fetch(dport, "/")
check(code == 200 and "identifier sur la forge" in body,
      "sans session, la page propose la forge (vu: %d)" % code)
check(fetch(dport, "/api/state")[0] == 401,
      "sans session, /api/state refuse — la porte n'est pas qu'un habillage de page")

# (3) LE RETOUR NON SOLLICITE. Un `state` qu'on n'a pas emis n'ouvre pas de session.
code, _, hdrs = fetch(dport, "/auth/callback?state=jamais-emis&code=x")
check(code == 400, "un `state` inconnu au retour est REFUSE (vu: %d)" % code)
check("Set-Cookie" not in hdrs, "et il ne pose AUCUN cookie")

# Le depart : une redirection vers la forge qui emporte un `state` et demande `groups`.
code, _, hdrs = fetch(dport, "/auth/login")
loc = hdrs.get("Location", "")
check(code == 302 and loc.startswith(FORGE + "/login/oauth/authorize"),
      "/auth/login redirige vers la forge PUBLIQUE (vu: %d %s)" % (code, loc[:60]))
qs = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query)
check("groups" in (qs.get("scope") or [""])[0],
      "le scope demande `groups` — c'est lui qui porte l'appartenance a l'equipe")
issued = (qs.get("state") or [""])[0]
check(bool(issued), "un `state` est emis")

# (4) RECONNU, PAS MEMBRE. Le compte existe et fonctionne ; il n'ouvre rien ici.
FAKE["groups"] = ["fleet"]
code, body, hdrs = fetch(dport, "/auth/callback?state=%s&code=abc" % issued)
check(code == 403, "hors de l'equipe humans -> refuse (vu: %d)" % code)
check("COMPTE RECONNU" in body,
      "et le refus dit que le compte EXISTE — c'est un enrollment qui manque, pas une panne")
check("Set-Cookie" not in hdrs, "aucune session n'est ouverte pour un non-membre")

# (5) MEMBRE, MAIS AUCUN UTILISATEUR SYSTEME : le convergeur n'est pas passe.
FAKE["groups"] = ["fleet", "fleet:humans"]
deck.humans = lambda: []
code, _, hdrs = fetch(dport, "/auth/login")
issued = (urllib.parse.parse_qs(urllib.parse.urlparse(hdrs["Location"]).query)["state"])[0]
code, body, hdrs = fetch(dport, "/auth/callback?state=%s&code=abc" % issued)
check(code == 302, "un membre de l'equipe OUVRE une session (vu: %d)" % code)
cookie = hdrs.get("Set-Cookie", "").split(";")[0]
check(cookie.startswith(deck.SESSION_COOKIE + "="), "et recoit son cookie de session")
code, body, _ = fetch(dport, "/", cookie)
check(code == 200 and "PAS ENCORE DE BLOC" in body,
      "membre sans utilisateur systeme : on le DIT, on ne refuse pas (vu: %d)" % code)
check(fetch(dport, "/api/state", cookie)[0] == 409,
      "et l'API porte le meme etat, distinct d'un 401")

# (6) LE FILTRE EST A LA SOURCE. Deux humains sur la boite, une seule ligne servie.
deck.humans = lambda: [
    {"human": "zoe", "uid": 1001, "home": "/home/zoe", "ports": deck.block(1001)},
    {"human": "autre", "uid": 1002, "home": "/home/autre", "ports": deck.block(1002)},
]
code, body, _ = fetch(dport, "/api/state", cookie)
served = json.loads(body)["humans"]
check(code == 200 and len(served) == 1 and served[0]["human"] == "zoe",
      "/api/state ne sert QUE l'humain de la session (vu: %s)"
      % [h["human"] for h in served])
check("autre" not in body, "le voisin n'apparait nulle part dans la charge")
check(len(deck.state()["humans"]) == 2,
      "et le filtre est un ARGUMENT, pas une amputation : state() sans filtre voit les deux")

# (7) SORTIR. La session meurt cote serveur, pas seulement dans le navigateur.
code, _, hdrs = fetch(dport, "/auth/logout", cookie)
check(code == 302, "/auth/logout redirige (vu: %d)" % code)
check(fetch(dport, "/api/state", cookie)[0] == 401,
      "et le MEME cookie ne vaut plus rien — la session est tuee au serveur")

# (8) L'EXPIRATION EST LUE, PAS PLANIFIEE. Une session perimee ne survit pas a sa relecture.
deck._sessions["perime"] = {"login": "zoe", "groups": [], "exp": time.time() - 1}
check(deck.session_of(deck.SESSION_COOKIE + "=perime") is None,
      "une session expiree est refusee A LA LECTURE (aucun timer a rater)")

dsrv.shutdown()
forge_srv.shutdown()
for f in (cfg_path, cfg_path + ".partial"):
    try:
        os.unlink(f)
    except OSError:
        pass

sys.exit(0 if ok else 1)
