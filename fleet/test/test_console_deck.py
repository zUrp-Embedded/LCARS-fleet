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

import atexit
import importlib.util
import json
import os
import shutil
import socket
import socketserver
import sys
import tempfile
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

# ─── LA SONDE PARLE A UNE SOCKET, PLUS A UN PORT — 6-072 ───────────────────────────────────────
# CE BLOC EST REMPLACE, PAS COMPLETE. Il epinglait `{"ports": {"deck": <port>}}` : ce contrat
# n'existe plus, le deck d'observation n'a plus d'adresse. Garder les deux formes aurait epingle un
# transport que plus rien n'honore.
#
# CE QUI SURVIT INTACT, ET C'EST L'ESSENTIEL DE CE FICHIER : la discrimination par la CAUSE. Une
# fleet eteinte est un etat NOMINAL ; un deck qu'on n'a pas pu joindre est une mesure RATEE. Les
# causes changent de nature avec AF_UNIX, la regle non.
#
# ⚠ ET IL Y EN A UNE DE PLUS, SANS EQUIVALENT TCP : `EACCES`. Sur un port, ne pas avoir le droit de
# se connecter n'existe pas ; sur une socket, c'est le mode du repertoire qui tranche. La ranger
# dans « eteinte » aurait recree exactement le mensonge que ce fichier a ferme.
sock_probe_root = tempfile.mkdtemp(dir="/tmp", prefix="lcp.")
deck.CONSOLE_SOCK_ROOT = sock_probe_root


def serve_pods_unix(login, pods, projection=None):
    """
    Un vrai serveur HTTP sur la socket AF_UNIX de cet humain, servant LES DEUX routes du deck.

    Les deux, parce que le landing en consomme deux : `/api/pods` alimente un panneau, la projection
    les six autres. Une doublure qui n'aurait servi que les pods aurait laisse passer un rendu qui
    perd six panneaux.
    """

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith("/api/projection"):
                payload = projection if projection is not None else {"_status": "live", "total": 0}
            else:
                payload = {"pods": pods}
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    class S(ThreadingHTTPServer):
        address_family = socket.AF_UNIX

        # `HTTPServer.server_bind` derive un nom d'hote de `server_address[:2]`, ce qui n'a aucun
        # sens pour un chemin. On garde le bind de socketserver et on pose les deux champs a la main.
        def server_bind(self):
            socketserver.TCPServer.server_bind(self)
            self.server_name = "lcars"
            self.server_port = 0

    d = os.path.join(sock_probe_root, login)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "deck.sock")
    if os.path.exists(path):
        os.unlink(path)
    srv = S(path, H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


live_srv = serve_pods_unix("zoe", [{"pod_id": "a"}, {"pod_id": "b"}])
status, pods = deck.fleet_pods({"human": "zoe"})
check(status == "live", "un deck qui repond sur SA socket -> 'live' (vu: %s)" % status)
check(len(pods) == 2, "les pods rendus sont ceux du deck (vu: %d)" % len(pods))
live_srv.shutdown()
live_srv.server_close()

# PAS DE SOCKET = personne n'ecoute, et c'est une MESURE : le listener retire son fichier en
# s'arretant, precisement pour rendre cet etat lisible.
status, pods = deck.fleet_pods({"human": "absent"})
check(status == "off", "socket ABSENTE -> 'off' : personne n'ecoute (vu: %s)" % status)
check(pods == [], "'off' ne fabrique aucun pod")

# SOCKET RESIDUELLE d'un BEAM tue : le fichier survit, plus personne n'accepte. Meme verdict, autre
# chemin — et c'est le cas qui n'existait pas du tout avec un port, ou le noyau reclame la ressource.
_d = os.path.join(sock_probe_root, "residu")
os.makedirs(_d, exist_ok=True)
_stale = socket.socket(socket.AF_UNIX)
_stale.bind(os.path.join(_d, "deck.sock"))
_stale.close()
status, _ = deck.fleet_pods({"human": "residu"})
check(status == "off", "socket RESIDUELLE (fichier sans ecoutant) -> 'off' (vu: %s)" % status)

# ⚠ L'ETAT NEUF. Le deck ecoute ; on n'a pas le droit d'ouvrir. Le repertoire en 0000 reproduit
# exactement ce que produirait un landing sans son groupe supplementaire, ou un repertoire d'humain
# au mauvais mode.
_dn = os.path.join(sock_probe_root, "interdit")
os.makedirs(_dn, exist_ok=True)
_denied_srv = None
try:
    _denied_srv = serve_pods_unix("interdit", [])
    os.chmod(_dn, 0o000)
    status, pods = deck.fleet_pods({"human": "interdit"})
    check(status == "denied",
          "ouverture REFUSEE -> 'denied', jamais 'off' : le deck ecoute, c'est nous qui n'entrons "
          "pas (vu: %s)" % status)
    check(pods == [], "'denied' ne fabrique aucun pod")
finally:
    os.chmod(_dn, 0o755)
    if _denied_srv:
        _denied_srv.shutdown()
        _denied_srv.server_close()

# UN ECOUTANT QUI SE TAIT -> 'unknown', jamais 'off'. LE test de ce fichier : ce cas rendait
# « fleet eteinte », c'est-a-dire une assertion d'extinction tiree d'une absence de reponse.
_ds = os.path.join(sock_probe_root, "muet")
os.makedirs(_ds, exist_ok=True)
_silent = socket.socket(socket.AF_UNIX)
_silent.bind(os.path.join(_ds, "deck.sock"))
_silent.listen(1)
threading.Thread(target=lambda: (_silent.accept(), time.sleep(30)), daemon=True).start()
t0 = time.monotonic()
status_muet, pods = deck.fleet_pods({"human": "muet"})
elapsed = time.monotonic() - t0
check(status_muet == "unknown",
      "une socket qui accepte et se TAIT -> 'unknown', jamais 'off' (vu: %s)" % status_muet)
check(elapsed < 10, "la sonde reste bornee par son timeout (%.1fs)" % elapsed)
_silent.close()

# LES ETATS SONT DISTINCTS, ET ON COMPARE LES VERDICTS DEJA RENDUS — pas de nouvelle sonde. Premiere
# version de ce garde : il re-sondait « muet » APRES avoir ferme son ecoutant, ce qui rendait 'off'
# et faisait echouer un test qui avait raison. Un temoin qui mesure autre chose que ce qu'il annonce
# accuse le code a la place du harnais.
_seen = {status_muet, deck.fleet_pods({"human": "absent"})[0]}
check(len(_seen) == 2, "eteinte et non-mesuree ne sont PAS le meme etat (vu: %s)" % _seen)

# ─── LA PROJECTION : LA SECONDE SOURCE, ET SA CICATRICE ────────────────────────────────────────
# Six des sept panneaux du deck d'observation viennent de `/api/projection`, que ce landing
# n'appelait pas. Ce qui est epingle ici n'est pas « on l'appelle » mais ce qui rend l'appel utile :
# un read-model MORT rend `total:0` et des listes vides — exactement ce que rend une fleet paisible.
# Sans le `_status`, la page affirme le calme sur un aveuglement.
_ps = serve_pods_unix("proj_live", [], {"_status": "live", "total": 7, "stream": ["e1"]})
st, proj = deck.fleet_projection({"human": "proj_live"})
check(st == "live" and proj.get("total") == 7,
      "une projection saine remonte avec son contenu (vu: %s, total=%s)" % (st, proj.get("total")))
_ps.shutdown()
_ps.server_close()

_pd = serve_pods_unix("proj_deaf", [], {"_status": "deaf", "total": 0, "stream": []})
st, proj = deck.fleet_projection({"human": "proj_deaf"})
check(st == "deaf",
      "un read-model SOURD est rendu 'deaf', PAS 'live' : flux fige, pas flotte calme (vu: %s)" % st)
check(proj.get("total") == 0,
      "et sa charge vide traverse quand meme — c'est le statut qui la qualifie, pas l'inverse")
_pd.shutdown()
_pd.server_close()

st, _ = deck.fleet_projection({"human": "absent"})
check(st == "off", "pas de socket -> 'off' pour la projection aussi (vu: %s)" % st)

# `state()` EXPOSE LES DEUX STATUTS SEPAREMENT. Le transport peut etre bon et le flux fige : un seul
# champ ne peut pas porter les deux, et les aplatir rendrait le cas sourd invisible depuis la page.
_full = serve_pods_unix("zoe", [{"pod_id": "a"}], {"_status": "deaf", "total": 0})
# ─── `humans()` DEMANDE LA LISTE, IL NE LA RECONSTRUIT PLUS ──────────────────────────────────────
# Ce bloc execute le VRAI chemin. La fonction portait sa propre regle (`/etc/passwd`, uid < 65000,
# shell en bash|sh|zsh) en affirmant servir « la meme population que console.sh » — faux sur trois
# bornes, dont celle qui mordait : un compte SANS home etait liste ici et refuse par le script, donc
# le deck affichait un siege dont aucune console n'avait jamais ete demarree.
#
# ⚠ ET RIEN N'EXECUTAIT CE CHEMIN : les 14 sites de test remplacent `deck.humans`. Une fonction que
# toute la suite stube est une fonction que la suite ne verifie pas — c'est l'onglet admin de ce
# matin, dans un autre fichier.
_hdir = tempfile.mkdtemp(prefix="lcars-humans.")
atexit.register(shutil.rmtree, _hdir, ignore_errors=True)


def _fake_humans_sh(name, body):
    p = os.path.join(_hdir, name)
    with open(p, "w") as fh:
        fh.write("#!/usr/bin/env bash\n" + body)
    os.chmod(p, 0o755)
    return p


_humans_sh_saved = deck.HUMANS_SH
deck.HUMANS_SH = _fake_humans_sh("ok.sh", "printf 'zoe 1015 /home/zoe\\nmax 1016 /home/max\\n'\n")
_parsed = deck.humans()
check([h["human"] for h in _parsed] == ["zoe", "max"],
      "humans() rend ce que le SCRIPT dit, dans l'ordre des uid (vu: %s)"
      % [h["human"] for h in _parsed])
check(_parsed[0]["uid"] == 1015 and _parsed[0]["home"] == "/home/zoe",
      "et il en prend l'uid ET le home — le home est deja VALIDE par le script, on ne le re-derive pas")

# ⚠ LA DISTINCTION QUI PORTE TOUT : un script qui echoue n'est pas une boite sans humains. Repondre
# `[]` ferait dire a la porte « tu n'as pas de siege » a tout le monde, ce qui accuse le convergeur
# d'un tort qui n'est pas le sien, aupres de gens qui n'ont rien a corriger.
deck.HUMANS_SH = _fake_humans_sh("bad.sh", "echo boom >&2\nexit 3\n")
try:
    deck.humans()
    check(False, "un script en ECHEC doit lever, pas rendre une liste vide")
except OSError as _e:
    check("exited 3" in str(_e), "un script en ECHEC leve et NOMME son code de sortie (vu: %s)" % _e)

deck.HUMANS_SH = _fake_humans_sh("junk.sh", "printf 'pas-un-uid abc /home/x\\nzoe 1015 /home/zoe\\n'\n")
check([h["human"] for h in deck.humans()] == ["zoe"],
      "une ligne qui n'a pas la forme attendue est IGNOREE, elle ne fabrique pas un humain")

deck.HUMANS_SH = _humans_sh_saved

_real_humans = deck.humans
deck.humans = lambda: [{"human": "zoe", "uid": 1001, "home": "/nonexistent", "ports": {}}]
try:
    st = deck.state(only="zoe")
    h0 = st["humans"][0]
    check(h0["fleet_status"] == "live",
          "le transport est vivant (vu: %s)" % h0["fleet_status"])
    check(h0["projection_status"] == "deaf",
          "ET la projection est sourde — deux champs, deux verites (vu: %s)"
          % h0["projection_status"])
finally:
    deck.humans = _real_humans
    _full.shutdown()
    _full.server_close()

# ─── LE RATTACHEMENT PROJET ────────────────────────────────────────────────────────────────────
# Le deck le derivait d'un montage `/home/projects.ops/` que `pod_mounts_env` a retire de tous les
# pods de projet : le scan ne repondait plus que pour les architectes, et son repli AFFIRMAIT
# « fleet-level » la ou il voulait dire « je ne sais pas ». Le slug vient desormais du runtime, qui
# le sait. Ces deux cas etaient MUETS dans ce corpus — c'est ce silence qui a laisse la derive
# vivre le temps qu'il a fallu pour la voir a l'oeil.
psrv = serve_pods_unix("proj", [
    {"pod_id": "p1", "role": "engineer", "phase": "ready", "project_slug": "vitrine"},
    {"pod_id": "p2", "role": "starfleet", "phase": "ready"},
])
_, pods = deck.fleet_pods({"human": "proj"})
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
psrv.server_close()



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
            # Sert l'userinfo OIDC ET le /api/v1/user que forge_is_admin lit. `is_admin` defaut False
            # -> les tests qui ne le posent pas voient une session ordinaire (comportement d'avant).
            self._json(200, {"sub": "1", "preferred_username": FAKE["login"],
                             "groups": FAKE["groups"], "is_admin": FAKE.get("is_admin", False)})

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
# ⚠ HORS DU DEPOT, ET NETTOYE PAR `atexit` — LES DEUX MOITIES COMPTENT. Ces fichiers etaient ecrits
# dans la RACINE du depot (`HERE/..`) et effaces par un `os.unlink` en DERNIERE ligne du script.
# Deux consequences composees : (1) un run qui meurt avant la fin — une assertion qui leve, un
# module qui a perdu une fonction pendant une contre-epreuve — ne nettoie rien ; (2) le debris
# atterrit dans `git status`, c'est-a-dire exactement dans ce qu'un `git add -A` emporte sans qu'on
# l'ait regarde. Un test qui salit l'arbre de travail est un piege pour le commit suivant, pas une
# nuisance esthetique.
#
# LES DEUX MOITIES NE FONT PAS LE MEME TRAVAIL, et la mesure le dit : sous `SIGKILL`, `atexit` NE
# TOURNE PAS et le repertoire de /tmp reste — mais l'arbre du depot, lui, est propre. C'est donc
# l'EMPLACEMENT qui porte la garantie ; `atexit` n'est que l'hygiene, sur les sorties qu'il peut
# voir (fin normale et exception).
_cfg_dir = tempfile.mkdtemp(prefix="lcars-deck-oidc.")
atexit.register(shutil.rmtree, _cfg_dir, ignore_errors=True)
cfg_path = os.path.join(_cfg_dir, "client.json")

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

# (1-bis) L'ENTREE NON DECLAREE, REFUSEE ICI ET PAS PAR LA FORGE. OAuth2 compare le `redirect_uri`
# a une liste enregistree ; une entree absente donne une 400 de Gitea au titre generique qui ne
# nomme meme pas `redirect_uri` (mesure 2026-08-12), APRES l'identification, sur une page qui n'est
# pas la notre. On a la liste : on tranche avant d'y envoyer quelqu'un.
with open(cfg_path, "w") as fh:
    json.dump({"client_id": "cid", "client_secret": "csec",
               "public_url": FORGE, "internal_url": FORGE,
               "redirect_uris": ["http://declaree:20999/auth/callback"]}, fh)
code, body, _ = fetch(dport, "/auth/login")
check(code == 409 and "CETTE ENTREE N'EST PAS DECLAREE" in body,
      "une entree hors liste est refusee AVANT la forge (vu: %d)" % code)
check("declaree:20999" in body, "et le refus ENUMERE les entrees declarees")
check("LCARS_DECK_ORIGINS" in body, "et nomme le reglage qui l'ajouterait")
# Une config d'avant cette version n'a pas la liste : on n'invente aucun refus, la forge tranche.
with open(cfg_path, "w") as fh:
    json.dump({"client_id": "cid", "client_secret": "csec",
               "public_url": FORGE, "internal_url": FORGE}, fh)
check(fetch(dport, "/auth/login")[0] == 302,
      "sans liste dans la config, on laisse passer — l'absence n'accuse rien")

# (2) PAS DE SESSION : la page invite, l'API refuse. Les deux, pas l'une des deux.
code, body, _ = fetch(dport, "/")
check(code == 200 and "identifier sur la forge" in body,
      "sans session, la page propose la forge (vu: %d)" % code)
check(fetch(dport, "/api/state")[0] == 401,
      "sans session, /api/state refuse — la porte n'est pas qu'un habillage de page")

# (2-bis) LA DECONNEXION DOIT DECONNECTER, et le lien vers la forge ferme la boucle. On ne fermait
# que NOTRE session ; celle de la forge survivait, et comme l'app est deja autorisee le login suivant
# traverse sans une question. Vu du dehors : un aller-retour avec des etapes en plus. Et le deck ne
# montrait aucun lien vers la forge — donc sans connaitre son URL, impossible d'aller s'y deconnecter.
code, body, _ = fetch(dport, "/")
check(FORGE in body, "la page d'invite PORTE l'adresse de la forge (sortie de boucle)")

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

# (4-bis) ADMIRAL : hors de l'equipe humans MAIS site-admin (is_admin) -> il ENTRE par la porte ADMIN.
# admiral est le master/sysadmin : il n'est pas un worker (pas dans fleet:humans), mais il a sa
# console web (root via sudo une fois dedans, Guard B lui interdisant de lancer une fleet).
FAKE["groups"] = ["fleet"]        # PAS fleet:humans
FAKE["is_admin"] = True
code, _, hdrs = fetch(dport, "/auth/login")
issued = (urllib.parse.parse_qs(urllib.parse.urlparse(hdrs["Location"]).query)["state"])[0]
code, body, hdrs = fetch(dport, "/auth/callback?state=%s&code=abc" % issued)
check(code == 302, "admiral (site-admin hors fleet:humans) ENTRE par is_admin (vu: %d)" % code)
check(hdrs.get("Set-Cookie", "").startswith(deck.SESSION_COOKIE + "="),
      "et recoit sa session (la porte admin s'ouvre)")
FAKE["is_admin"] = False   # reset : les cas suivants sont des workers ordinaires

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

# (5-bis) MEMBRE, ET LE CONVERGEUR A REFUSE SON LOGIN. Etat DIFFERENT du precedent, et c'est tout
# l'objet de ce cas : Gitea accepte des logins qui ne peuvent PAS devenir un compte Unix (33
# caracteres, par exemple), donc une personne peut etre enrolee et ne converger JAMAIS. Dire
# « ca converge tout seul » a celle-la est un mensonge que personne ne revient verifier.
# Meme raison que `cfg_path` plus haut : hors du depot. Ce fichier-ci etait efface juste apres son
# usage, donc il ne trainait que sur un run mort — c'est-a-dire exactement les runs d'une
# contre-epreuve, ceux qu'on enchaine sans regarder l'arbre entre deux.
refused_path = os.path.join(_cfg_dir, "refused")
with open(refused_path, "w") as fh:
    fh.write("zoe\tce login ne peut pas devenir un compte Unix : il faut 1 a 32 caracteres\n")
deck.REFUSED_FILE = refused_path
code, body, _ = fetch(dport, "/", cookie)
check(code == 200 and "CE LOGIN NE PEUT PAS ABOUTIR" in body,
      "refus publie par le convergeur -> une page qui le DIT (vu: %d)" % code)
check("1 a 32 caracteres" in body,
      "et elle porte la RAISON du convergeur, pas un refus generique")
check("converge tout seul" not in body,
      "elle ne promet SURTOUT pas que ca se debloquera seul")
check(fetch(dport, "/api/state", cookie)[0] == 422,
      "et l'API distingue 422 (n'aboutira jamais) de 409 (pas encore converge)")
deck.REFUSED_FILE = refused_path + ".absent"
check(fetch(dport, "/api/state", cookie)[0] == 409,
      "sans fichier de refus, on retombe sur « pas encore converge » — l'absence n'accuse rien")
os.unlink(refused_path)   # il vit dans `_cfg_dir` : `atexit` ramasserait le reste de toute facon

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

# (6-bis) P5 — CE QUE L'ENROLLMENT NE PEUT PAS FABRIQUER. Un humain converge n'a AUCUNE capacite a
# spawner tant qu'il n'a pas fait son `claude /login`, et rien dans la chaine ne le lui disait : il
# le rencontrait sous forme de pod mort. Trois etats, et « absent » est une AFFIRMATION qu'on ne
# prononce que si on a pu regarder.
import tempfile
hbase = tempfile.mkdtemp(prefix="deck-homes-")
h_ok = os.path.join(hbase, "avec"); h_no = os.path.join(hbase, "sans"); h_blind = os.path.join(hbase, "aveugle")
os.makedirs(os.path.join(h_ok, ".claude")); os.makedirs(h_no); os.makedirs(h_blind)
open(os.path.join(h_ok, ".claude", ".credentials.json"), "w").write("{}")
check(deck.claude_credentials(h_ok) == "present",
      "credentials posees -> 'present' (vu: %s)" % deck.claude_credentials(h_ok))
check(deck.claude_credentials(h_no) == "absent",
      "home traversable et rien dedans -> 'absent' : on a REGARDE (vu: %s)" % deck.claude_credentials(h_no))
os.chmod(h_blind, 0o000)
# root TRAVERSE tout : sous uid 0 ce cas n'est pas mesurable, et le cocher quand meme serait un
# vert creux. On le DIT plutot que de le faire passer.
if os.geteuid() == 0:
    print("SKIP: home non traversable — non mesurable sous root (root ignore les permissions)")
else:
    check(deck.claude_credentials(h_blind) == "unknown",
          "home non traversable -> 'unknown', JAMAIS 'absent' (vu: %s)" % deck.claude_credentials(h_blind))
os.chmod(h_blind, 0o755)
check(deck.claude_credentials(None) == "unknown", "pas de home -> 'unknown'")
check(deck.claude_credentials(os.path.join(hbase, "inexistant")) == "unknown",
      "home inexistant -> 'unknown' : une absence de home n'est pas une absence de credentials")
# Le contenu n'est JAMAIS lu — la validite se tranche au spawn, pas ici.
open(os.path.join(h_ok, ".claude", ".credentials.json"), "w").write("")
check(deck.claude_credentials(h_ok) == "present",
      "un fichier VIDE reste 'present' : cette sonde ne juge pas la validite, elle constate")
deck.humans = lambda: [{"human": "zoe", "uid": 1001, "home": h_no, "ports": deck.block(1001)}]
code, body, _ = fetch(dport, "/api/state", cookie)
check(code == 200 and json.loads(body)["humans"][0]["claude"] == "absent",
      "l'etat claude voyage dans /api/state (vu: %s)" % body[:80])

# (7) SORTIR. La session meurt cote serveur, pas seulement dans le navigateur.
code, _, hdrs = fetch(dport, "/auth/logout", cookie)
check(code == 302, "/auth/logout redirige (vu: %d)" % code)
check(fetch(dport, "/api/state", cookie)[0] == 401,
      "et le MEME cookie ne vaut plus rien — la session est tuee au serveur")
_, _, lo = fetch(dport, "/auth/logout", cookie)
check(lo.get("Location", "").endswith("/user/logout"),
      "et la deconnexion PROPAGE a la forge (vu: %s)" % lo.get("Location"))

# (8) L'EXPIRATION EST LUE, PAS PLANIFIEE. Une session perimee ne survit pas a sa relecture.
deck._sessions["perime"] = {"login": "zoe", "groups": [], "exp": time.time() - 1}
check(deck.session_of(deck.SESSION_COOKIE + "=perime") is None,
      "une session expiree est refusee A LA LECTURE (aucun timer a rater)")

# ════════════════════════════════════════════════════════════════════════════════════════════════
# (9) LE RELAIS — 6-072 / 6-098
#
# CE QUI EST PROUVE ICI : les DECISIONS du relais (qui atteint quoi, ce qui est transmis en amont)
# et le fait qu'il transporte bien des octets apres le `101`.
#
# CE QUI NE PEUT PAS L'ETRE ICI, ET QUI EST MESURE AILLEURS : que le noyau refuse un `connect(2)` a
# un repertoire qu'on ne peut pas traverser, et que ttyd rende 407 sans l'en-tete. Les deux ont ete
# mesures DANS L'IMAGE le 2026-08-14 (C-09 : le lieu fait partie de la mesure). L'amont simule
# ci-dessous n'a aucune autorite sur ces deux points — il n'en a pas besoin : ce qu'on lui demande,
# c'est de RAPPORTER ce que le relais lui a envoye.
sock_root = tempfile.mkdtemp(dir="/tmp", prefix="lcd.")
deck.CONSOLE_SOCK_ROOT = sock_root
seen_headers = {}


def fake_ttyd(login, name="console.sock"):
    """Un faux amont sur AF_UNIX : il enregistre les en-tetes recus, bascule en 101, puis renvoie."""
    d = os.path.join(sock_root, login)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, name)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(4)

    def serve():
        while True:
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            head = b""
            while b"\r\n\r\n" not in head:
                c = conn.recv(4096)
                if not c:
                    conn.close()
                    break
                head += c
            else:
                lines = head.decode("latin-1").split("\r\n")
                # ⚠ UNE LISTE, PAS UN DICT, ET LA PREMIERE VERSION DE CETTE DOUBLURE ETAIT UN DICT.
                # Avec un dict, un en-tete envoye DEUX fois s'ecrase et seule la derniere valeur
                # subsiste : le test lisait alors la semantique de la doublure au lieu de la garantie
                # du relais. Prouve par mutation — en laissant `x-lcars-human` passer depuis le
                # client, l'amont recevait DEUX lignes, le dict n'en gardait qu'une (la notre), et
                # toutes les assertions restaient vertes. Un vrai serveur peut retenir la PREMIERE.
                pairs = []
                for ln in lines[1:]:
                    if ": " in ln:
                        k, v = ln.split(": ", 1)
                        pairs.append((k.lower(), v))
                seen_headers[(login, name)] = (lines[0], pairs)
                conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\n"
                             b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
                             b"Sec-WebSocket-Accept: probe\r\n\r\n")
                # Echo : c'est ce qui prouve que les octets circulent DANS LES DEUX SENS apres le
                # basculement. Un relais qui n'aurait branche qu'un seul sens passerait tout test
                # qui se contente de lire la ligne de statut.
                while True:
                    b = conn.recv(4096)
                    if not b:
                        break
                    conn.sendall(b"<" + b)
                conn.close()

    threading.Thread(target=serve, daemon=True).start()
    return srv


def ws_get(port, path, cookie=None, extra=None):
    """Un GET d'upgrade a la main : urllib ne sait pas basculer. Rend (ligne de statut, socket)."""
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    req = ["GET %s HTTP/1.1" % path, "Host: 127.0.0.1", "Upgrade: websocket",
           "Connection: Upgrade", "Sec-WebSocket-Key: cHJvYmVwcm9iZXByb2JlMTI=",
           "Sec-WebSocket-Version: 13"]
    if cookie:
        req.append("Cookie: " + cookie)
    for k, v in (extra or {}).items():
        req.append("%s: %s" % (k, v))
    s.sendall(("\r\n".join(req) + "\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        c = s.recv(4096)
        if not c:
            break
        head += c
    return head.split(b"\r\n")[0].decode("latin-1", "replace"), s


t_zoe = fake_ttyd("zoe")
t_zoe_pod = fake_ttyd("zoe", "pod.sock")
t_max = fake_ttyd("max")

deck._sessions["s-zoe"] = {"login": "zoe", "groups": ["fleet", "fleet:humans"],
                           "exp": time.time() + 600}
deck._sessions["s-max"] = {"login": "max", "groups": ["fleet", "fleet:humans"],
                           "exp": time.time() + 600}
# L'ADMINITE EST UN CHAMP DE SESSION, pose au callback depuis `is_admin` de la forge — plus une
# equipe lue dans `groups`. Les groupes de cette session sont donc ceux de n'importe quel humain :
# si un jour ce test repassait au vert en remettant `fleet:admins` ici, c'est que la seconde source
# de verite serait revenue.
deck._sessions["s-adm"] = {"login": "adm", "groups": ["fleet", "fleet:humans"], "admin": True,
                           "exp": time.time() + 600}
c_zoe = deck.SESSION_COOKIE + "=s-zoe"
c_max = deck.SESSION_COOKIE + "=s-max"
c_adm = deck.SESSION_COOKIE + "=s-adm"

# Le relais vit DERRIERE la porte : il faut aussi que le bloc local existe, sinon on mesure le
# refus du convergeur au lieu de mesurer l'autorisation.
_humans_real = deck.humans
deck.humans = lambda: [{"human": "zoe"}, {"human": "max"}, {"human": "adm"}]

# (9a) SANS SESSION, RIEN NE PART EN AMONT. Le code seul ne suffirait pas comme preuve : la page de
# login rend 200. Ce qui tranche, c'est que l'amont n'a VU personne.
seen_headers.clear()
status, s = ws_get(dport, "/console/zoe/ws")
s.close()
check(("zoe", "console.sock") not in seen_headers,
      "sans session, le relais ne touche meme pas la socket amont (vu: %s)" % status)

# (9b) LE CHEMIN NOMINAL — sans lui, un relais qui refuserait TOUT passerait tous les refus.
seen_headers.clear()
status, s = ws_get(dport, "/console/zoe/ws", c_zoe)
check("101" in status, "zoe atteint SA console et le relais bascule (vu: %s)" % status)
s.sendall(b"ping")
echoed = s.recv(64)
s.close()
check(echoed == b"<ping",
      "et les octets circulent dans les DEUX sens apres le 101 (vu: %r)" % echoed)

# (9c) L'IDENTITE EST POSEE PAR LE RELAIS, ET UNE VERSION CLIENTE EST ECRASEE. ttyd ne verifie que
# la PRESENCE de l'en-tete (mesure dans l'image) : s'il suffisait de l'envoyer soi-meme, la garde ne
# vaudrait rien. C'est le test le plus important du fichier.
seen_headers.clear()
_, s = ws_get(dport, "/console/zoe/ws", c_zoe, {"X-LCARS-Human": "max"})
s.close()
line, pairs = seen_headers[("zoe", "console.sock")]
ident = [v for k, v in pairs if k == "x-lcars-human"]
# LA PROPRIETE N'EST PAS « LA VALEUR EST BONNE », C'EST « L'EN-TETE EST LA UNE SEULE FOIS ». Deux
# occurrences laissent le choix au serveur d'amont, et ce choix n'est pas le notre : rien ne dit
# qu'il retient la derniere. Compter est la seule assertion qui ne depende d'aucun amont.
check(ident == ["zoe"],
      "l'en-tete d'identite est present UNE SEULE FOIS et vient de la session, "
      "l'en-tete forge par le client est JETE (vu: %r)" % ident)
check(line.startswith("GET /ws "),
      "et le prefixe de montage est retire avant l'amont (vu: %s)" % line)
check(not [k for k, _ in pairs if k == "cookie"],
      "le cookie de session ne part PAS en amont — il n'a rien a y faire")

# (9d) 6-098 : LA CONSOLE D'UN AUTRE HUMAIN N'EST PAS ATTEIGNABLE.
seen_headers.clear()
status, s = ws_get(dport, "/console/max/ws", c_zoe)
s.close()
check("404" in status, "zoe n'atteint pas la console de max (vu: %s)" % status)
check(("max", "console.sock") not in seen_headers,
      "et le refus a lieu AVANT toute connexion a la socket de max")

# (9e) 6-098 : idem pour la console de POD, qui est la cible que la fiche nomme.
seen_headers.clear()
status, s = ws_get(dport, "/pod/max/ws", c_zoe)
s.close()
check("404" in status, "zoe n'atteint pas les pods de max (vu: %s)" % status)
check(("max", "pod.sock") not in seen_headers, "et rien n'a touche la socket de pod de max")
status, s = ws_get(dport, "/pod/zoe/ws", c_zoe)
s.close()
check("101" in status, "TEMOIN : zoe atteint SES pods (vu: %s)" % status)

# LA QUERY DOIT SURVIVRE AU RELAIS, et son absence serait une panne MUETTE. `do_GET` coupe sur `?`
# des sa premiere ligne ; sans recollage, `?arg=<pod_id>` n'atteint jamais ttyd, dont `--url-arg`
# est justement ce qui laisse le client nommer le pod. L'onglet se serait ouvert sur un terminal
# sans cible, sans une seule erreur nulle part. Trouve en relisant le code, pas en le voyant casser.
seen_headers.clear()
_, s = ws_get(dport, "/pod/zoe/ws?arg=pod_architect-x", c_zoe)
s.close()
line, _pairs = seen_headers[("zoe", "pod.sock")]
check(line.startswith("GET /ws?arg=pod_architect-x "),
      "la query traverse le relais jusqu'a ttyd (vu: %s)" % line)

# (9f) ⚠ L'ARBITRAGE LE PLUS FACILE A TRAHIR — L'ADMIN N'ATTEINT PAS LES CONSOLES DES AUTRES.
# *Ce serait un geste de panoptique, pas un geste d'admin.* La regle est ECRITE dans `authorize`,
# elle n'est pas une clause oubliee — et ce test porte la phrase pour que personne ne la « repare ».
seen_headers.clear()
status, s = ws_get(dport, "/console/zoe/ws", c_adm)
s.close()
check("404" in status,
      "un ADMIN n'atteint PAS la console d'un autre humain — panoptique, pas admin (vu: %s)" % status)
check(("zoe", "console.sock") not in seen_headers, "et rien n'a touche la socket de zoe")
# ⚠ TEMOIN INDISPENSABLE, ET LA PREMIERE VERSION DE CE TEST ETAIT FAUSSE. Sans lui, le 404 ci-dessus
# passerait aussi sur une regle qui bloquerait les admins PARTOUT — ce qui serait un autre bug, et
# l'arbitrage dit exactement le contraire. Un admin est un humain comme les autres : il atteint SA
# console. Ce qui lui est refuse, c'est celle d'AUTRUI, et rien de plus.
t_adm = fake_ttyd("adm")
status, s = ws_get(dport, "/console/adm/ws", c_adm)
s.close()
check("101" in status,
      "TEMOIN : l'admin atteint SA PROPRE console — le refus porte sur autrui, pas sur son role "
      "(vu: %s)" % status)

# (9g) LE TIER ADMIN EXISTE POURTANT, et il s'exerce sur les cibles SYSTEME. La table est vide en
# livraison — le mecanisme est ecrit et teste, aucun backend systeme n'existe encore. On en publie
# un le temps du test : c'est exactement le geste que demandera la page de configuration.
sys_srv = fake_ttyd("admin-backend")
deck.SYSTEM_TARGETS["admin"] = os.path.join(sock_root, "admin-backend", "console.sock")
try:
    status, s = ws_get(dport, "/admin/ws", c_adm)
    s.close()
    check("101" in status, "un admin atteint une cible SYSTEME (vu: %s)" % status)
    status, s = ws_get(dport, "/admin/ws", c_zoe)
    s.close()
    check("404" in status, "un humain non-admin ne l'atteint pas (vu: %s)" % status)

    # ⚠ ET L'ADMINITE NE SE DEDUIT PLUS D'UN GROUPE. Le tier a ete une equipe (`fleet:admins`) avant
    # d'etre `is_admin` : une session qui porte le groupe SANS le champ doit etre refusee, sinon les
    # deux sources de verite coexistent encore et personne ne s'en apercoit.
    #
    # ⚠ ET IL LUI FAUT SON BLOC LOCAL, comme au relais plus haut : la porte du convergeur est AVANT
    # l'autorisation. Sans cette ligne le refus arrive quand meme, mais c'est celui du bloc absent
    # (200, page « pas de bloc ») — un vert qui aurait repondu a une autre question que la sienne.
    deck._sessions["s-grp"] = {"login": "grp", "groups": ["fleet:humans", "fleet:admins"],
                               "exp": time.time() + 600}
    deck.humans = lambda: [{"human": "zoe"}, {"human": "max"}, {"human": "adm"}, {"human": "grp"}]
    status, s = ws_get(dport, "/admin/ws", deck.SESSION_COOKIE + "=s-grp")
    s.close()
    check("404" in status,
          "le GROUPE fleet:admins n'ouvre plus rien — seule la forge dit qui est admin (vu: %s)"
          % status)
    check(deck.authorize({"login": "grp", "groups": ["fleet:admins"]}, ("admin", "", "/ws")) is False,
          "une session SANS le champ admin vaut « pas admin » — l'absence de reponse est un refus")
finally:
    deck._sessions.pop("s-grp", None)
    deck.humans = lambda: [{"human": "zoe"}, {"human": "max"}, {"human": "adm"}]
    deck.SYSTEM_TARGETS.pop("admin", None)
    sys_srv.close()

# (9g-bis) D'OU VIENT LE CHAMP : `is_admin`, rendu par la forge, lu au callback avec le jeton deja en
# main. Les trois cas qui comptent sont la forge qui dit oui, la forge qui dit non, et la forge qui ne
# repond pas — ce dernier est le seul ou un defaut permissif se serait vu trop tard.
_cfg = {"internal_url": "http://forge:3000/"}
_get_json_real = deck._get_json
try:
    deck._get_json = lambda url, tok: {"login": "adm", "is_admin": True}
    check(deck.forge_is_admin(_cfg, "tok") is True, "la forge dit is_admin -> la session est admin")
    deck._get_json = lambda url, tok: {"login": "zoe", "is_admin": False}
    check(deck.forge_is_admin(_cfg, "tok") is False, "la forge dit non -> session ordinaire")
    deck._get_json = lambda url, tok: {"login": "zoe"}
    check(deck.forge_is_admin(_cfg, "tok") is False,
          "un champ ABSENT n'est pas un oui — on ne promeut pas sur un silence")

    # ⚠ FAIL-CLOSED. Une panne de cet appel ne doit pas ouvrir le tier : sinon il se prend en faisant
    # tomber l'endpoint, ce qui est plus facile que de devenir admin sur la forge.
    def _boom(url, tok):
        raise TimeoutError("forge muette")
    deck._get_json = _boom
    check(deck.forge_is_admin(_cfg, "tok") is False,
          "forge muette -> PAS admin : une panne ne promeut personne")

    # L'URL tapee est l'INTERNE, celle que le conteneur peut joindre. La publique est une adresse de
    # navigateur ; la confondre ici rend un appel qui echoue, donc — fail-closed oblige — un admin
    # silencieusement degrade en humain ordinaire.
    _seen = []
    deck._get_json = lambda url, tok: (_seen.append((url, tok)), {"is_admin": True})[1]
    deck.forge_is_admin(_cfg, "jeton")
    check(_seen == [("http://forge:3000/api/v1/user", "jeton")],
          "l'appel part sur l'URL INTERNE, avec le jeton du callback (vu: %s)" % _seen)
finally:
    deck._get_json = _get_json_real

# (9g-ter) L'ADMINITE DESCEND JUSQU'A LA PAGE, et par la session — pas par une seconde lecture de la
# forge a chaque tick. Sans ce champ dans `/api/state`, l'onglet ne peut pas se dessiner.
_humans_saved = deck.humans
deck.humans = lambda: []
try:
    check(deck.state(only="adm", admin=True)["admin"] is True,
          "/api/state porte l'adminite de la session")
    check(deck.state(only="zoe")["admin"] is False,
          "et son defaut est FAUX — un appelant qui ne la passe pas ne promeut pas son lecteur")
finally:
    deck.humans = _humans_saved

# (9h) UN LOGIN QUI N'EST PAS UN NOM SIMPLE NE FABRIQUE PAS DE CHEMIN. La session est deja la source
# du chemin apres `authorize` — donc la forme du login est la derniere chose entre nous et un `..`.
deck._sessions["s-bad"] = {"login": "../../etc", "groups": ["fleet:humans"],
                           "exp": time.time() + 600}
check(deck.socket_for(("console", "../../etc", "/ws")) is None,
      "un login non canonique ne produit AUCUN chemin de socket")
check(deck.authorize({"login": "zoe"}, ("console", "zoe", "/ws")) is True,
      "TEMOIN : authorize dit OUI quand les deux logins sont le meme")

# (9h-bis) LE RELAIS REFUSE CE QU'IL NE SAIT PAS TRANSPORTER, au lieu de le tronquer. Un GET
# ordinaire recopierait les en-tetes d'amont puis s'arreterait : le corps, delimite par
# `Content-Length` ou decoupe en morceaux, serait perdu SANS ERREUR. Le refus est ce qui obligera la
# premiere cible systeme en HTTP ordinaire a ecrire son transport.
code, body, _ = fetch(dport, "/console/zoe/ws", c_zoe)
check(code == 400 and "upgrade websocket" in body,
      "un GET ordinaire sur une cible de relais est REFUSE, pas tronque (vu: %d)" % code)
seen_headers.clear()
fetch(dport, "/console/zoe/ws", c_zoe)
check(("zoe", "console.sock") not in seen_headers,
      "et le refus a lieu AVANT de connecter l'amont")

# (9i) LE JS DE LA PAGE N'EST PARSE PAR RIEN, ET C'EST UN ANGLE MORT ENTIER. Il vit dans une chaine
# brute Python : `py_compile` la voit comme du texte, aucun test ne l'execute, et une parenthese
# manquante donne une page qui s'affiche et ne FAIT rien — sans une erreur cote serveur. Le client
# de terminal a fait passer ce bloc de ~230 a ~320 lignes ; l'angle mort a cesse d'etre acceptable.
#
# ⚠ MODE DEGRADE ASSUME ET DIT : node n'est pas garanti dans l'image (c'est meme un geste d'admin de
# l'y installer). Absent, on ne peut pas verifier — on l'ECRIT plutot que de compter un test vert
# qui n'a rien mesure.
import re as _re
import shutil as _shutil
import subprocess as _subprocess

_src = open(os.path.join(HERE, "..", "deploy", "docker", "console-deck.py")).read()
_page = _re.search(r'PAGE = r"""(.*?)"""', _src, _re.S)
check(_page is not None, "la page du deck est trouvable dans le source")
_js = "\n".join(_re.findall(r"<script>(.*?)</script>", _page.group(1), _re.S)).replace("%%", "%")
check(len(_js.splitlines()) > 100,
      "le bloc JS extrait est bien le vrai (vu: %d lignes)" % len(_js.splitlines()))
check("termPane" in _js and "new Terminal(" in _js,
      "et il porte le client de terminal — sinon on validerait la syntaxe d'autre chose")

if _shutil.which("node"):
    _dir = tempfile.mkdtemp()
    _p = os.path.join(_dir, "page.js")
    with open(_p, "w") as fh:
        fh.write(_js)
    _r = _subprocess.run(["node", "--check", _p], capture_output=True, text=True)
    check(_r.returncode == 0,
          "le JS de la page PARSE (node --check) : %s" % (_r.stderr.strip().splitlines() or [""])[0])

    # ─── (9j) LE CLIENT DE TERMINAL EST EXECUTE, PAS SEULEMENT PARSE ────────────────────────────
    # ⚠ CE BLOC EXISTE PARCE QUE `node --check` A LAISSE PASSER UN BUG FATAL. `stage` etait declare
    # en `const` DANS `show()`, et `termPane()` — defini au meme niveau — l'utilisait. JavaScript
    # resout les noms LEXICALEMENT, pas depuis l'appelant : `ReferenceError: stage is not defined`
    # au premier clic sur un terminal, c'est-a-dire sur la fonctionnalite entiere du lot. Une erreur
    # d'EXECUTION ne se voit pas a la syntaxe ; le seul remede est de faire tourner le code.
    #
    # Le harnais est volontairement pauvre : des doublures minces pour le DOM, xterm, le WebSocket
    # et l'observateur de taille. Il ne teste PAS le rendu (aucun navigateur ici) — il teste ce qui
    # se casse en silence : la resolution des noms, et les OCTETS qui partent sur le fil.
    _harness = r"""
const sent = []; let wsUrl = null, wsProto = null, onmsg = null, onopen = null;
const mkEl = () => ({ dataset: {}, style: {}, hidden: false, textContent: '', innerHTML: '',
  classList: { toggle() {}, add() {}, remove() {} },
  appendChild() {}, removeChild() {}, remove() {}, querySelectorAll: () => [],
  addEventListener() {}, focus() {} });
// `createTextNode` MANQUAIT, et son absence est un constat : `build()` n'avait jamais tourne ici —
// c'est la premiere chose qu'il appelle pour poser le libelle d'un onglet.
globalThis.document = { getElementById: () => mkEl(), createElement: () => mkEl(),
  createTextNode: (t) => ({ nodeValue: String(t) }),
  querySelectorAll: () => [], title: '' };
globalThis.location = { protocol: 'http:', host: 'box:20999' };
globalThis.CSS = { escape: (s) => s };
globalThis.ResizeObserver = class { observe() {} disconnect() {} };
globalThis.addEventListener = () => {};
globalThis.setInterval = () => 0;
globalThis.fetch = () => new Promise(() => {});   // `tick()` ne doit rien resoudre ici
globalThis.WebSocket = class {
  constructor(url, proto) { wsUrl = url; wsProto = proto; this.readyState = 1;
    WebSocket.OPEN = 1; setTimeout(() => {}, 0); }
  send(b) { sent.push(b); }
  close() {}
  set onopen(f) { onopen = f; } set onmessage(f) { onmsg = f; }
  set onclose(f) {} set onerror(f) {}
};
globalThis.WebSocket.OPEN = 1;
let dataCb = null, resizeCb = null; const written = [];
// `onSelectionChange` + `getSelection` : le rail du copier-auto. Le stub les porte parce que le
// client les APPELLE — un stub qui ignore une methode fait passer un client qui ne l'appelle plus.
let selCb = null, selText = '';
const copies = [];
globalThis.document.execCommand = (cmd) => { copies.push(cmd); return true; };
globalThis.Terminal = class {
  constructor() { this.cols = 80; this.rows = 24; }
  loadAddon() {} open() {} focus() {} dispose() {}
  write(b) { written.push(b); }
  onData(f) { dataCb = f; } onResize(f) { resizeCb = f; }
  onSelectionChange(f) { selCb = f; } getSelection() { return selText; }
};
globalThis.FitAddon = { FitAddon: class { activate() {} fit() {} dispose() {} } };

__PAGE__

// LE GESTE MESURE : ouvrir un onglet terminal, exactement comme un clic.
show({ key: 'console-zoe', crumb: 'X', term: '/console/zoe/ws' });
onopen();
const dec = new TextDecoder();
const out = { url: wsUrl, proto: wsProto, init: dec.decode(sent[0]) };
dataCb('ls');
out.input = dec.decode(sent[1]);
resizeCb();
out.resize = dec.decode(sent[2]);
onmsg({ data: new TextEncoder().encode('0bonjour').buffer });
out.written = dec.decode(written[0]);

// LE COPIER AUTOMATIQUE SUR SELECTION — regression du lot console, retrouvee le 2026-08-15.
// Le comportement venait du frontend applicatif de ttyd, pas de xterm.js : en remplacant l'iframe
// par ce client on a porte le protocole et pas le comportement. Les deux sens sont pris — une
// selection VIDE ne doit rien copier, sinon chaque clic ecraserait le presse-papier.
out.copy = {};
selText = ''; if (selCb) selCb(); out.copy.onEmpty = copies.length;
selText = 'du texte selectionne'; if (selCb) selCb(); out.copy.onText = copies.slice();
out.copy.wired = Boolean(selCb);

// LES DEUX AUTRES NATURES D'ONGLET, parce que le bug de portee trouve dans `termPane` etait du
// code de la MEME facture, ecrit dans la meme heure — et rien ne les avait executees non plus.
// Un onglet `render:` construit son panneau dans le DOM local : c'est le chemin de l'observation.
out.obs = {};
try {
  const h = { human: 'zoe', pods: [{ pod_id: 'p1' }],
              projection_status: 'deaf',
              projection: { total: 3, counts: { 'pod.failed': 2 }, stream: ['e1'],
                            workflow_runs: [], gatekeeper: [], coordination: [], diagnostics: [] } };
  show({ key: 'deck-zoe', crumb: 'D', render: () => observationPanel(h) });
  out.obs.ok = true;
  // La cicatrice qui doit survivre au demenagement : un flux FIGE ne se dit pas « calme ».
  out.obs.banner = projectionBanner(h);
  out.obs.live = projectionBanner({ projection_status: 'live' });
  out.obs.denied = projectionBanner({ projection_status: 'denied' });
  out.obs.label = fleetLabel({ fleet_status: 'denied', pods: [] });
} catch (e) { out.obs.ok = false; out.obs.err = String(e); }

// L'ONGLET ADMIN, ET ON LE CLIQUE. `build()` decide s'il existe, `adminPanel()` le remplit —
// et RIEN dans cette suite n'executait ni l'une ni l'autre. C'est exactement la facture du
// `ReferenceError` ci-dessus : du code neuf, parse, gate, jamais lance. Le rail enregistre donc ce
// qu'on lui pose, et on declenche le `onclick` que build a cable, au lieu d'appeler `adminPanel`
// en direct — appeler la fonction a la main sauterait la moitie qui la relie a la page.
out.adm = {};
try {
  const railKids = [];
  const rail = mkEl(); rail.appendChild = (c) => { railKids.push(c); };
  document.getElementById = (id) => (id === 'rail' ? rail : mkEl());

  build({ hostname: 'box', admin: true, humans: [] });
  const tab = railKids.find((k) => k.dataset && k.dataset.key === 'admin');
  out.adm.present = Boolean(tab);
  if (tab) { tab.onclick(); out.adm.clicked = true; }

  railKids.length = 0;
  build({ hostname: 'box', admin: false, humans: [] });
  out.adm.absent = !railKids.some((k) => k.dataset && k.dataset.key === 'admin');
  out.adm.ok = true;
} catch (e) { out.adm.ok = false; out.adm.err = String(e); }

// LA FERMETURE : trois gestes, et en oublier un fuit en silence (une socket ouverte cote serveur
// pour un onglet qui n'existe plus). On rouvre un terminal puis on le laisse tomber.
show({ key: 'console-zoe', crumb: 'X', term: '/console/zoe/ws' });
out.closed = { before: terms.size };
dropPanes(new Set(['autre-chose']));
out.closed.after = terms.size;

console.log(JSON.stringify(out));
"""
    _drive = os.path.join(_dir, "drive.js")
    with open(_drive, "w") as fh:
        fh.write(_harness.replace("__PAGE__", _js))
    _r = _subprocess.run(["node", _drive], capture_output=True, text=True)
    check(_r.returncode == 0,
          "le client de terminal S'EXECUTE (ouverture d'un onglet) : %s"
          % (_r.stderr.strip().splitlines() or [""])[-1:] or "")
    if _r.returncode == 0:
        _o = json.loads(_r.stdout.strip().splitlines()[-1])
        check(_o["url"] == "ws://box:20999/console/zoe/ws",
              "le WS vise la MEME origine, chemin relatif (vu: %s)" % _o["url"])
        check(_o["proto"] == ["tty"],
              "et annonce le sous-protocole que ttyd attend (vu: %s)" % _o["proto"])
        # La 1re trame est le JSON NON prefixe, encode en binaire — mesure sur le binaire pinne.
        check(json.loads(_o["init"]).get("columns") == 80,
              "la 1re trame est le JSON d'init de ttyd (vu: %s)" % _o["init"])
        check(_o["input"] == "0ls",
              "une saisie part prefixee '0' (vu: %r)" % _o["input"])
        check(_o["resize"].startswith("1{") and '"columns"' in _o["resize"],
              "un redimensionnement part prefixe '1' + JSON (vu: %r)" % _o["resize"])
        check(_o["written"] == "bonjour",
              "une sortie serveur '0' est ecrite SANS son prefixe (vu: %r)" % _o["written"])

        # ── LE COPIER AUTOMATIQUE SUR SELECTION (regression 2026-08-15) ─────────────────────────
        # Perdu en remplacant l'iframe ttyd par ce client : le handler etait du code APPLICATIF de
        # ttyd, pas de xterm.js. Le terminal selectionnait toujours, donc rien n'avait l'air casse —
        # sauf que la selection n'arrivait plus dans le presse-papier. Aucun temoin ne l'a vu partir.
        check(_o["copy"].get("wired") is True,
              "le client CABLE onSelectionChange (sans lui, shift+glisser selectionne sans copier)")
        check(_o["copy"].get("onText") == ["copy"],
              "une selection NON VIDE declenche la copie (vu: %r)" % (_o["copy"].get("onText"),))
        check(_o["copy"].get("onEmpty") == 0,
              "une selection VIDE ne copie RIEN — sinon un simple clic ecrase le presse-papier "
              "(vu: %r)" % (_o["copy"].get("onEmpty"),))

        # ── L'ONGLET ADMIN S'EXECUTE, ET SA BRANCHE SE PREND DANS LES DEUX SENS ─────────────────
        check(_o["adm"].get("ok") is True,
              "l'onglet admin S'EXECUTE (build + clic) : %s" % _o["adm"].get("err", ""))
        check(_o["adm"].get("present") is True,
              "un admin voit l'onglet — build a bien pose la branche (vu: %r)"
              % _o["adm"].get("present"))
        check(_o["adm"].get("clicked") is True,
              "et le CLIC rend le panneau : c'est le seul geste qui execute adminPanel()")
        # ⚠ LE TEMOIN NEGATIF, SANS LEQUEL LE PRECEDENT PASSERAIT SUR UN ONGLET TOUJOURS LA. Ce
        # qu'on mesure n'est pas « l'onglet existe » mais « il depend de `s.admin` ».
        check(_o["adm"].get("absent") is True,
              "et un NON-admin ne l'a pas — l'onglet suit s.admin, il n'est pas decoratif")

        # ── L'ONGLET D'OBSERVATION S'EXECUTE LUI AUSSI ──────────────────────────────────────────
        check(_o["obs"].get("ok") is True,
              "le panneau d'observation S'EXECUTE : %s" % _o["obs"].get("err", ""))
        check(_o["obs"].get("live") is None,
              "une projection saine n'affiche AUCUN bandeau (vu: %r)" % _o["obs"].get("live"))
        check("FIG" in (_o["obs"].get("banner") or ""),
              "une projection SOURDE dit « flux FIGE », pas un tableau vide (vu: %r)"
              % _o["obs"].get("banner"))
        # Insensible a la casse ET distincte des autres : ce qui compte n'est pas un mot precis
        # mais qu'un refus d'acces ne se dise pas comme une fleet eteinte. La 1re version de cette
        # assertion cherchait « REFUS » en capitales et accusait le code pour une casse.
        check("refus" in (_o["obs"].get("denied") or "").lower()
              and _o["obs"].get("denied") != _o["obs"].get("banner"),
              "et l'acces refuse a sa propre phrase, distincte du flux fige (vu: %r)"
              % _o["obs"].get("denied"))
        check("REFUS" in (_o["obs"].get("label") or ""),
              "le libelle de fleet connait 'denied' — sinon il tombe dans « NON MESUREE » (vu: %r)"
              % _o["obs"].get("label"))

        # ── LA FERMETURE LIBERE VRAIMENT ────────────────────────────────────────────────────────
        check(_o["closed"]["before"] == 1 and _o["closed"]["after"] == 0,
              "dropPanes ferme le terminal et le retire du registre (avant %s, apres %s)"
              % (_o["closed"]["before"], _o["closed"]["after"]))
else:
    print("SKIP: node absent — le JS de la page N'A ete ni verifie ni EXECUTE")

deck.humans = _humans_real
for _s in (t_zoe, t_zoe_pod, t_max, t_adm):
    _s.close()

dsrv.shutdown()
forge_srv.shutdown()
# Le repertoire des configs OIDC part par `atexit` — y compris si ce script meurt avant d'arriver
# ici, ce qui etait tout le probleme de la version precedente.

# ── L'EQUIPE DES HUMAINS SUIT L'ORG, ELLE N'EST PLUS UN LITTERAL ────────────────────────────────
# Ce que ce temoin tient : le deck et `human-converger.sh` nomment la MEME equipe a partir des
# MEMES variables. Il y en avait deux jeux (`LCARS_DECK_TEAM` ici, une paire `LCARS_*` la-bas), personne n'en posait aucun, et les defauts portaient seuls l'accord.
# Le renommage de l'org le rompait dans un seul sens : la forge emet `<org>:humans`, le deck
# comparait a `fleet:humans` et refusait tout humain non-admin pendant que le convergeur creait
# leurs comptes.
#
# La forme negative est la moitie qui compte : sans elle, un `HUMANS_TEAM` reste fige a
# `fleet:humans` passerait le premier check par pure coincidence de defaut.
_env_saved = {k: os.environ.get(k) for k in ("PROV_FORGE_ORG", "PROV_HUMANS_TEAM")}
try:
    for _k in _env_saved:
        os.environ.pop(_k, None)
    check(load_deck().HUMANS_TEAM == "fleet:humans",
          "equipe: sans variable, le defaut vaut celui du convergeur (fleet + humans)")

    os.environ["PROV_FORGE_ORG"] = "starfleet"
    check(load_deck().HUMANS_TEAM == "starfleet:humans",
          "equipe: renommer l'org DEPLACE l'equipe du deck — le litteral est mort")

    os.environ["PROV_HUMANS_TEAM"] = "crew"
    check(load_deck().HUMANS_TEAM == "starfleet:crew",
          "equipe: les deux moities viennent des memes variables que le convergeur")
finally:
    for _k, _v in _env_saved.items():
        if _v is None:
            os.environ.pop(_k, None)
        else:
            os.environ[_k] = _v

# ─── LA DOC SERVIE PAR LE DECK ───────────────────────────────────────────────────────────────────
#
# La plaquette part dans l'image (Dockerfile, stage `site`) et le deck la sert sous `/doc/`. Deux
# choses seulement sont a tenir, et ce sont les deux qui coutent si elles lachent :
#
#   1. `..` NE SORT PAS DE LA RACINE. Le prefixe voisin porte les jetons de la boite ; une
#      traversee servirait un fichier que ce serveur n'a aucun droit de lire a un navigateur.
#   2. LES TYPES SERVIS SONT UNE LISTE, pas une deduction : ce qui n'y est pas ne sort pas.
_deck = load_deck()
_doc_root = tempfile.mkdtemp(prefix="lcars-doc-")
os.makedirs(os.path.join(_doc_root, "manuel"), exist_ok=True)
with open(os.path.join(_doc_root, "index.html"), "w") as _fh:
    _fh.write("<!doctype html><title>doc</title>")
with open(os.path.join(_doc_root, "manuel", "index.html"), "w") as _fh:
    _fh.write("<!doctype html><title>manuel</title>")

_secret = os.path.join(os.path.dirname(_doc_root), "hors-doc.html")
with open(_secret, "w") as _fh:
    _fh.write("SECRET")

check(_deck.DOC_TYPES.get(".html") == "text/html; charset=utf-8",
      "doc: les types servis sont ENUMERES — ce qui n'est pas dans la table ne sort pas")
check(_deck.DOC_TYPES.get(".gitea_token") is None and _deck.DOC_TYPES.get("") is None,
      "doc: une extension inconnue n'a pas de type, donc pas de reponse")

# La resolution, telle que la route la fait : join + realpath + prefixe.
def _resolve(rel):
    full = os.path.realpath(os.path.join(_doc_root, rel))
    root = os.path.realpath(_doc_root)
    return full if (full == root or full.startswith(root + os.sep)) else None

check(_resolve("index.html") is not None and _resolve("manuel/index.html") is not None,
      "doc: une page de la doc se resout dans sa racine")
check(_resolve("../hors-doc.html") is None,
      "doc: `..` sort de la racine et est REFUSE — le prefixe voisin porte les jetons de la boite")
check(_resolve("manuel/../../hors-doc.html") is None,
      "doc: une traversee cachee au milieu du chemin est refusee comme les autres")


sys.exit(0 if ok else 1)
