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
refused_path = os.path.join(HERE, "..", "tmp-deck-refused-%d" % os.getpid())
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
try:
    os.unlink(refused_path)
except OSError:
    pass

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
deck._sessions["s-adm"] = {"login": "adm", "groups": ["fleet", "fleet:humans", "fleet:admins"],
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
finally:
    deck.SYSTEM_TARGETS.pop("admin", None)
    sys_srv.close()

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
    _p = os.path.join(tempfile.mkdtemp(), "page.js")
    with open(_p, "w") as fh:
        fh.write(_js)
    _r = _subprocess.run(["node", "--check", _p], capture_output=True, text=True)
    check(_r.returncode == 0,
          "le JS de la page PARSE (node --check) : %s" % (_r.stderr.strip().splitlines() or [""])[0])
else:
    print("SKIP: node absent — la syntaxe du JS de la page N'A PAS ete verifiee")

deck.humans = _humans_real
for _s in (t_zoe, t_zoe_pod, t_max, t_adm):
    _s.close()

dsrv.shutdown()
forge_srv.shutdown()
for f in (cfg_path, cfg_path + ".partial"):
    try:
        os.unlink(f)
    except OSError:
        pass

sys.exit(0 if ok else 1)
