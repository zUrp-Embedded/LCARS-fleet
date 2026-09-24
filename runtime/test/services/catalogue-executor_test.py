#!/usr/bin/env python3
# SOURCE: runtime/test/services/catalogue-executor_test.py
# AUTHOR: bob
# STARDATE: 2026-08-23
# STATUS: actif — le banc de l'executeur de catalogue : l'identite vient du noyau, l'autorite de la forge
#
# POURQUOI CE FICHIER. `catalogue-executor.py` est le seul endroit du produit ou un process root
# accepte une demande venue d'un humain et agit avec l'autorite totale de la forge. Tout ce qui s'y
# passe est une frontiere de privilege : l'identite du pair, la forme du nom, la question posee, et
# ce qu'on fait quand la reponse manque.
#
# CE QUI EST EPINGLE, ET LA FORME COMPTE. Les cinq causes de refus sont exercees SEPAREMENT, contre
# une VRAIE socket unix et une VRAIE forge de banc — pas contre des stubs d'exception. Un stub
# prouverait que le `except` est bien ecrit ; il ne prouverait pas que la bibliotheque leve ce qu'on
# croit, ni que `SO_PEERCRED` porte ce que le noyau y met.
#
# ⚠ DEUX TEMOINS EXISTENT PARCE QUE LE DEFAUT ETAIT REEL, PAS PAR PRINCIPE :
#   - « le nom porte une tabulation » : une premiere ecriture faisait `.strip()` sur la ligne du
#     fil, donc `install web-demo\t` devenait `web-demo` et passait. Le format du fil etait alors en
#     desaccord SILENCIEUX avec la forme qu'il pretend imposer. A une frontiere de privilege, la
#     lecture tolerante est la mauvaise.
#   - « la forge muette ne dit jamais "tu n'es pas admin" » : les deux causes ont des gestes de
#     sortie opposes (reessayer / se faire promouvoir). Les confondre envoie l'operateur reparer ce
#     qui n'est pas casse.

import grp
import hashlib
import importlib.util
import json
import os
import re
import shutil
import socket
import sys
import tempfile
import threading
import urllib.parse
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

ok = True


def check(cond, label):
    global ok
    print(("PASS: " if cond else "FAIL: ") + label)
    if not cond:
        ok = False


HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "..", "services", "catalogue-executor.py")

if not os.path.isfile(SRC):
    # Sujet absent = perimetre manquant, pas un vert. Sans cette ligne `FAIL:`, un exit 1 sec
    # donnerait un gate rouge dont le decompte ne dit rien.
    print("FAIL: catalogue-executor.py introuvable (%s) — sujet manquant" % SRC)
    sys.exit(1)

WORK = tempfile.mkdtemp(prefix="lcars-catexec-")
SOCK = os.path.join(WORK, "catalogue.sock")
TOKEN = os.path.join(WORK, "master.token")
GESTURES = os.path.join(WORK, "gestures.sh")

TOKEN_VALUE = "banc-master-token"
# Le jeton du compte SYSTEME est distinct du master : le service les lit dans deux fichiers, et un
# depot ecrit avec le master passerait inapercu si le banc n'en avait qu'un.
SYSTEM_VALUE = "banc-system-token"
with open(TOKEN, "w") as fh:
    fh.write(TOKEN_VALUE + "\n")
SYSTEM_TOKEN = os.path.join(WORK, "system.token")
with open(SYSTEM_TOKEN, "w") as fh:
    fh.write(SYSTEM_VALUE + "\n")

# ── LA BOITE DE DEPOT : l'etat de la forge de banc ──────────────────────────────────────────────
# `REPOS` dit quels depots existent (la resolution de l'org les interroge un par un), `FICHIERS`
# ce que chaque depot porte deja (pour le remplacement), `ECRITS` ce que la forge a recu.
REPOS = set()
FICHIERS = {}
ECRITS = []
# Les GET recus (pour epingler que le service NE TELECHARGE PAS le fichier qu'il remplace)
# et les depots dont la face workshop n'a jamais ete poussee.
LUS = []
SANS_WORKSHOP = set()
# La taille d'une page du banc : petite, pour que la pagination se joue pour de vrai.
PAGE = 50

# Le faux geste PARLE, et son code de sortie est pilotable : le relais de sa sortie et la remontee
# de son code sont deux promesses distinctes de l'executeur.
with open(GESTURES, "w") as fh:
    fh.write(
        "#!/usr/bin/env bash\n"
        'echo "forge-gestures: $2 <- fleet/$2 (main@deadbeef)"\n'
        'echo "forge-gestures: recette appliquee"\n'
        'sleep "${BANC_SLEEP:-0}"\n'
        '[[ -n "${BANC_SIGNAL:-}" ]] && kill -TERM $$\n'
        'exit "${BANC_RC:-0}"\n'
    )
os.chmod(GESTURES, 0o755)

ADMINS = set()
WORKERS = set()
ASKED = []
# La boite de depot : ce que la forge a recu, et un interrupteur pour jouer « depot absent ».


class Forge(BaseHTTPRequestHandler):
    """La forge de banc : elle repond `is_admin` selon le login DEMANDE, et note qui a demande."""

    def do_GET(self):
        login = self.path.rsplit("/", 1)[-1]
        ASKED.append((login, self.headers.get("Authorization")))
        chemin = self.path.split("?")[0]
        LUS.append(self.path)
        # LE LISTAGE D'UN REPERTOIRE : des noms et des sha, jamais de contenu. La forge rend une
        # LISTE pour un repertoire et un OBJET pour un fichier — le banc rend les deux formes, sinon
        # le service pourrait confondre les deux sans que rien ne rougisse.
        if "/contents/" in chemin:
            bouts = chemin.strip("/").split("/")
            repo = "/".join(bouts[3:5])
            demande = chemin.split("/contents/", 1)[1]
            if repo in SANS_WORKSHOP:
                self.send_response(404); self.send_header("Content-Length", "0")
                self.end_headers(); return
            dedans = sorted(
                [{"name": c.split("/")[-1], "type": "file", "sha": v}
                 for (r, c), v in FICHIERS.items()
                 if r == repo and c.startswith(demande.rstrip("/") + "/")],
                key=lambda e: e["name"])
            if not dedans and (repo, demande) not in FICHIERS:
                self.send_response(404); self.send_header("Content-Length", "0")
                self.end_headers(); return
            # ⚠ ELLE PAGINE, COMME LA VRAIE. Un banc qui rend tout d'un coup ne peut pas voir une
            # troncature lue comme une absence — c'est exactement le defaut qu'on a corrige.
            page = int(dict(urllib.parse.parse_qsl(self.path.partition("?")[2])).get("page", "1"))
            tranche = dedans[(page - 1) * PAGE:page * PAGE]
            b = json.dumps(tranche).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(b)))
            if page * PAGE < len(dedans):
                suivante = "%s&page=%d" % (self.path.split("&page=")[0], page + 1)
                self.send_header("Link", '<http://127.0.0.1:%d%s>; rel="next"'
                                 % (self.server.server_port, suivante))
            self.end_headers(); self.wfile.write(b); return
        # « CE DEPOT EXISTE-T-IL ? » — la resolution de l'org pose cette question a chaque catalogue.
        if chemin.startswith("/api/v1/repos/") and "/contents/" not in chemin:
            bouts = chemin.strip("/").split("/")
            if len(bouts) == 5:
                self.send_response(200 if "/".join(bouts[3:5]) in REPOS else 404)
                self.send_header("Content-Length", "0"); self.end_headers(); return
        # ⚠ ELLE REFUSE UN JETON QUI N'EST PAS LE SIEN, comme la vraie. Une forge de banc qui dit
        # « oui » a n'importe quel en-tete ne peut pas voir le cas du jeton vide ou revoque — et
        # c'est exactement le cas qui etait confondu avec « forge muette ».
        # L'equipe `humans` et ses membres — la question que `roles.sock` pose a la place du groupe.
        if "/teams" in self.path or "/orgs/" in self.path:
            if "/orgs/" in self.path and self.path.endswith("/teams"):
                b = json.dumps([{"id": 6, "name": "humans"}]).encode()
                self.send_response(200); self.send_header("Content-Length", str(len(b)))
                self.end_headers(); self.wfile.write(b); return
            membre = self.path.rsplit("/", 1)[-1]
            self.send_response(200 if membre in WORKERS else 404)
            self.send_header("Content-Length", "0"); self.end_headers(); return
        if (self.headers.get("Authorization") or "").removeprefix("token ").strip() != TOKEN_VALUE:
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = json.dumps({"login": login, "is_admin": login in ADMINS}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # ── LES TROIS ROUTES DU DEPOT ──────────────────────────────────────────────────────────────
    #   GET  /repos/<org>/<slug>                      « ce depot existe-t-il ? » (resolution de l'org)
    #   GET  /repos/<o>/<r>/git/trees/<branche>       le sha du blob en place, SANS son contenu
    #   POST /repos/<o>/<r>/contents/<chemin>         creation ; 422 si le chemin est pris
    #   PUT  /repos/<o>/<r>/contents/<chemin>         remplacement, avec le sha du blob
    def _depot(self):
        """Rend (owner, name) pour une route de depot, ou None."""
        bouts = self.path.split("?")[0].strip("/").split("/")
        if len(bouts) >= 5 and bouts[2] == "repos":
            return bouts[3], bouts[4]
        return None

    def _rendre(self, code, charge=None):
        corps = json.dumps(charge).encode() if charge is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        if corps:
            self.wfile.write(corps)

    def _ecriture(self, methode):
        length = int(self.headers.get("Content-Length", "0"))
        brut = self.rfile.read(length) if length else b""
        depot = self._depot()
        if not depot:
            return self._rendre(404)
        repo = "/".join(depot)
        chemin = self.path.split("/contents/", 1)[1] if "/contents/" in self.path else ""
        corps = json.loads(brut.decode("utf-8"))
        ECRITS.append({"methode": methode, "repo": repo, "chemin": chemin, "corps": corps,
                       "auth": self.headers.get("Authorization"),
                       "longueur_annoncee": length, "longueur_recue": len(brut)})
        if (self.headers.get("Authorization") or "").removeprefix("token ").strip() != SYSTEM_VALUE:
            return self._rendre(401)
        if repo not in REPOS or repo in SANS_WORKSHOP:
            return self._rendre(404)
        deja = FICHIERS.get((repo, chemin))
        if methode == "POST" and deja:
            return self._rendre(422, {"message": "path already exists"})
        if methode == "PUT" and corps.get("sha") != deja:
            return self._rendre(409, {"message": "sha mismatch"})
        FICHIERS[(repo, chemin)] = "blob-" + hashlib.sha256(brut).hexdigest()[:8]
        return self._rendre(201, {"commit": {"sha": "cafe1234cafe1234cafe1234cafe1234cafe1234"}})

    def do_POST(self):
        self._ecriture("POST")

    def do_PUT(self):
        self._ecriture("PUT")

    def log_message(self, *a):
        pass


forge = HTTPServer(("127.0.0.1", 0), Forge)
threading.Thread(target=forge.serve_forever, daemon=True).start()

os.environ.update(
    LCARS_CATALOGUE_SOCKET=SOCK,
    LCARS_MASTER_TOKEN_FILE=TOKEN,
    LCARS_FORGE_GESTURES=GESTURES,
    FORGE_BASE_URL="http://127.0.0.1:%d" % forge.server_port,
    # Un groupe qui n'existe pas : le banc n'est pas root, et l'executeur doit RESSERRER plutot que
    # d'ouvrir a un groupe qu'il n'a pas pu nommer.
    LCARS_FLEET_GROUP="lcars-banc-groupe-absent",
    # LA BOITE DE DEPOT : son jeton est celui du compte SYSTEME, distinct du master — le banc les
    # separe parce que le service les separe, et un depot ecrit avec le master passerait inapercu.
    LCARS_SYSTEM_TOKEN_FILE=SYSTEM_TOKEN,
    LCARS_READY_ROOM_REPO="fleet/ready-room",
    LCARS_DEPOSIT_SOCKET=os.path.join(WORK, "deposit.sock"),
    LCARS_CONSOLE_GROUP="lcars-banc-groupe-absent",
)

spec = importlib.util.spec_from_file_location("catexec", SRC)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

srv = mod.bind()
threading.Thread(target=mod.serve_forever, args=(srv,), daemon=True).start()
ROLES = os.path.join(WORK, "roles.sock")
mod.ROLES_SOCKET_PATH = ROLES
mod.ROLE_TOKENS_DIR = WORK
_srv_roles = mod.bind(ROLES)
threading.Thread(target=mod.serve_forever, args=(_srv_roles, mod.serve_role_token),
                 daemon=True).start()
MOI = mod.login_of(os.getuid())


def ask(line, timeout=30):
    """Une demande, une reponse. Rend les lignes du fil, verdict inclus."""
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(timeout)
    c.connect(SOCK)
    f = c.makefile("rw", encoding="utf-8", newline="\n")
    f.write(line + "\n")
    f.flush()
    lines = [l.rstrip("\n") for l in f]
    c.close()
    return lines


def verdict(lines):
    return lines[-1] if lines else ""


# ─── 1. LE CHEMIN NOMINAL ───────────────────────────────────────────────────────────────────────
ADMINS.add(MOI)
r = ask("install web-demo")
check(verdict(r) == "OK", "nominal: la forge dit admin -> OK")
check(any(l.startswith("> ") and "recette appliquee" in l for l in r),
      "nominal: la sortie du geste est RELAYEE, pas avalee")
check(ASKED and ASKED[-1][0] == MOI,
      "nominal: la forge est interrogee sur le login du PAIR, jamais sur un nom du fil")
check(ASKED and ASKED[-1][1] == "token banc-master-token",
      "nominal: interrogee avec le jeton master — un jeton systeme rendrait false sur un vrai admin")

# ─── 2. LA FORGE DIT NON ────────────────────────────────────────────────────────────────────────
ADMINS.clear()
r = ask("install web-demo")
check(verdict(r) == "FAIL:not_admin", "non-admin: la forge dit non -> FAIL:not_admin")
check(not any(l.startswith("> ") for l in r),
      "non-admin: le geste n'a PAS tourne — le refus precede l'action")

# ─── 3. LA FORME DU NOM, ET ELLE EST JUGEE AVANT LA QUESTION ────────────────────────────────────
ADMINS.add(MOI)
avant = len(ASKED)
for mauvais, pourquoi in [
    ("../../etc", "une traversee de chemin"),
    ("/etc/passwd", "un chemin absolu"),
    ("Web-Demo", "une majuscule"),
    ("-demo", "un tiret en tete"),
    ("web demo", "une espace"),
    ("", "un nom vide"),
    ("web-demo\t", "une tabulation en queue"),
    ("web-demo ", "une espace en queue"),
]:
    r = ask("install " + mauvais)
    check(verdict(r) == "FAIL:bad_name", "nom refuse: %s -> FAIL:bad_name" % pourquoi)
check(len(ASKED) == avant,
      "nom refuse: AUCUNE question posee a la forge — la validation precede tout usage")

r = ask("rm -rf /")
check(verdict(r) == "FAIL:bad_name", "verbe inconnu: un seul verbe existe -> FAIL:bad_name")

# ─── 4. LA FORGE MUETTE — FAIL-CLOSED, ET LA CAUSE RESTE DISTINCTE ──────────────────────────────
garde = mod.FORGE_BASE_URL
mod.FORGE_BASE_URL = "http://127.0.0.1:1"
r = ask("install web-demo")
check(verdict(r) == "FAIL:forge_unreachable",
      "forge muette: pas de reponse -> refus (fail-closed)")
check("not_admin" not in verdict(r),
      "forge muette: JAMAIS confondu avec « tu n'es pas admin » — gestes de sortie opposes")
mod.FORGE_BASE_URL = garde

# ─── 5. LE GESTE ECHOUE — DISTINCT D'UN REFUS ───────────────────────────────────────────────────
os.environ["BANC_RC"] = "3"
r = ask("install web-demo")
check(verdict(r) == "FAIL:gesture_failed:3",
      "geste en echec: le code de sortie remonte, distinct d'un refus d'autorite")
del os.environ["BANC_RC"]

# ─── 6. DEUX DEMANDES — ON REFUSE, ON N'ATTEND PAS ──────────────────────────────────────────────
# Meme choix que le `flock -n` de `with_apply_lock` sous nous : un appelant mis en attente recevrait
# son verdict quand l'autre a fini, sur une forge qui a bouge sous lui.
os.environ["BANC_SLEEP"] = "3"
res = {}
t = threading.Thread(target=lambda: res.update(premier=ask("install web-demo")))
t.start()
time.sleep(1.0)
t0 = time.time()
second = ask("install autre-demo")
ecoule = time.time() - t0
t.join()
del os.environ["BANC_SLEEP"]
check(verdict(second) == "FAIL:busy", "concurrence: le second est REFUSE -> FAIL:busy")
check(ecoule < 1.0, "concurrence: refuse SANS attendre la fin du premier (%.2fs)" % ecoule)
check(verdict(res.get("premier", [])) == "OK", "concurrence: le premier aboutit quand meme")

# ─── 7. L'IDENTITE EST LE CANAL ─────────────────────────────────────────────────────────────────
# Rien de ce que l'appelant ECRIT ne porte son identite. Le seul nom qui compte est celui que le
# noyau a pose sur la socket, donc un non-admin ne peut pas se declarer admin.
ADMINS.clear()
ADMINS.add("quelqun-dautre")
r = ask("install web-demo")
check(verdict(r) == "FAIL:not_admin",
      "identite: un non-admin ne peut pas se declarer admin — SO_PEERCRED, pas le fil")

check(mod.login_of(999321) is None,
      "pair inconnu: un uid sans compte unix ne rend aucun login")

# ─── 7 ter. « CE CONTENEUR N'A PAS D'AUTORITE » N'EST PAS « LA FORGE N'A PAS REPONDU » ────────────
#
# ⚠ QUATRE ETATS TOMBAIENT DANS `forge_unreachable`, par DEUX chemins distincts : `OSError` (absent,
# illisible) et `HTTPError`, qui derive de `URLError` (vide -> 401, revoque -> 401). L'operateur
# lisait « la forge redemarre peut-etre, reessaie » sur une forge en parfaite sante, et aucun
# reessai n'y pouvait rien : le geste qui repare est de REPOSER le jeton, une fois.
ADMINS.clear()
ADMINS.add(MOI)
_garde_token = open(TOKEN, encoding="utf-8").read()

os.rename(TOKEN, TOKEN + ".parti")
check(verdict(ask("install web-demo")) == "FAIL:no_authority",
      "autorite: jeton ABSENT -> no_authority, jamais « la forge n'a pas repondu »")
os.rename(TOKEN + ".parti", TOKEN)

open(TOKEN, "w").close()
_avant = len(ASKED)
check(verdict(ask("install web-demo")) == "FAIL:no_authority",
      "autorite: jeton VIDE -> no_authority")
# ⚠ ET LE VERDICT NE SUFFIT PAS A PROUVER LE GARDE. Retirer le controle du vide laisse ce verdict
# INCHANGE : le jeton part vide, la forge rend 401, et le 401 retombe sur la meme cause. Mesure du
# 2026-08-24, mutation muette. Ce que le garde achete vraiment est en amont — on n'envoie PAS un
# credential vide sur le fil — et c'est donc ca qu'il faut mesurer.
check(len(ASKED) == _avant,
      "autorite: jeton VIDE -> la forge n'est meme pas CONTACTEE (le garde est en amont du fil)")

open(TOKEN, "w", encoding="utf-8").write("jeton-revoque-par-la-forge\n")
check(verdict(ask("install web-demo")) == "FAIL:no_authority",
      "autorite: jeton REFUSE par la forge (401) -> no_authority, pas « muette »")

os.chmod(TOKEN, 0o000)
_illisible = verdict(ask("install web-demo"))
os.chmod(TOKEN, 0o600)
check(_illisible == "FAIL:no_authority" or os.geteuid() == 0,
      "autorite: jeton ILLISIBLE -> no_authority (root lit tout, le cas ne se joue pas sous root)")

open(TOKEN, "w", encoding="utf-8").write(_garde_token)
check(verdict(ask("install web-demo")) == "OK",
      "autorite: le jeton rendu, le geste repasse — les quatre cas etaient bien la CAUSE")

# Et la forge VRAIMENT muette garde sa cause a elle.
_garde_url = mod.FORGE_BASE_URL
mod.FORGE_BASE_URL = "http://127.0.0.1:1"
check(verdict(ask("install web-demo")) == "FAIL:forge_unreachable",
      "autorite: une forge injoignable reste forge_unreachable — les deux causes ne fusionnent pas")
mod.FORGE_BASE_URL = _garde_url

# ─── 7 bis. LA FORME DU NOM EST UN CONTRAT A DEUX MOTEURS ───────────────────────────────────────
#
# `@name_rx` fait autorite en Elixir (`lib/fleet/catalogue.ex`) ; l'executeur est en Python et ne
# peut pas partager le litteral. Il en porte une copie citee — et une copie que rien ne compare est
# une regle tenue par la DISCIPLINE, c'est-a-dire une regle que le prochain site rate.
#
# ⚠ ON NE COMPARE PAS LES DEUX TEXTES, ET C'EST DELIBERE. Ils sont legitimement differents : le
# litteral Elixir porte ses ancres (`\A…\z`), la version Python les recoit de `fullmatch`. Un mur
# qui comparerait les sources serait ROUGE aujourd'hui, sur du code juste — et un mur rouge sur du
# code juste finit desactive.
#
# On compare donc ce qui compte : le VERDICT des deux moteurs sur un corpus partage. Le moteur
# « Elixir » est reconstruit ici depuis SA source, ancres comprises, et confronte a celui que
# l'executeur utilise vraiment.
_cat_ex = os.path.join(HERE, "..", "..", "lib", "fleet", "catalogue.ex")
_src = open(_cat_ex, encoding="utf-8").read() if os.path.isfile(_cat_ex) else ""
_m = re.search(r"@name_rx\s+~r/(.+?)/", _src)
check(_m is not None, "forme du nom: le litteral @name_rx est TROUVE dans catalogue.ex")
if _m:
    # `\A`/`\z` de PCRE-Elixir -> `\A`/`\Z` de Python : memes ancres absolues, autre orthographe.
    _elixir = re.compile(_m.group(1).replace(r"\z", r"\Z"))
    _corpus = [
        "web-demo", "a", "a1", "x-y-z", "0-abc", "demo-",
        "Web-demo", "-demo", "", " web", "web ", "web demo", "web_demo", "web.demo",
        "../../etc", "/etc/passwd", "web-demo\n", "web-demo\t", "wéb", "web\ndemo",
    ]
    _ecarts = [n for n in _corpus
               if bool(_elixir.match(n)) != bool(mod.NAME_RX.fullmatch(n))]
    check(not _ecarts,
          "forme du nom: les DEUX moteurs rendent le meme verdict sur %d noms%s"
          % (len(_corpus), "" if not _ecarts else " — ecarts: %r" % _ecarts))
    # Le garde d'instrument : un corpus qui n'accepterait rien, ou tout, ne comparerait rien.
    _oui = sum(1 for n in _corpus if mod.NAME_RX.fullmatch(n))
    check(0 < _oui < len(_corpus),
          "forme du nom: le corpus DISCRIMINE (%d acceptes sur %d)" % (_oui, len(_corpus)))

# ─── 7 quater. `roles.sock` — LE GROUPE REMPLACE PAR UNE QUESTION ───────────────────────────────
#
# Le jeton d'un role etait lisible par TOUT humain du conteneur (`0640 root:fleet`), et le groupe
# etait peuple par le convergeur depuis l'equipe `humans` de la forge — donc une projection, avec sa
# peremption. La question se pose maintenant a l'instant du geste.
#
# ⚠ CE QUE CE VERBE REND EST UN CREDENTIAL, ET C'EST UN RECUL ASSUME sur `catalogue.sock`, ou le
# service AGIT et ou rien ne sort. Ce qui le rend defendable est le point de depart, pas une
# propriete absolue. Les temoins mesurent ce qui est vraiment achete : plus de lecture muette, une
# identite attestee par le noyau, et une revocation qui mord.
def demande_role(role, timeout=20):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(timeout)
    c.connect(ROLES)
    f = c.makefile("rw", encoding="utf-8", newline="\n")
    f.write(role + "\n"); f.flush()
    lignes = [l.rstrip("\n") for l in f]
    c.close()
    return lignes[-1] if lignes else ""

open(os.path.join(WORK, "fleet_engineer.gitea_token"), "w").write("jeton-du-role\n")
WORKERS.clear(); WORKERS.add(MOI)

check(demande_role("fleet_engineer") == "jeton-du-role",
      "roles: un worker de l'equipe obtient le jeton du role demande")

WORKERS.clear()
check(demande_role("fleet_engineer") == "FAIL:not_a_worker",
      "roles: retire de l'equipe sur la forge -> refus AU GESTE SUIVANT, pas au prochain tour")
WORKERS.add(MOI)

check(demande_role("../../home/private/forge-master") == "FAIL:bad_role",
      "roles: un nom qui traverse est refuse AVANT de devenir un chemin")
_avant = len(ASKED)
check(demande_role("") == "FAIL:bad_role", "roles: un nom vide est refuse")
check(len(ASKED) == _avant, "roles: un nom refuse ne fait poser AUCUNE question a la forge")

check(demande_role("role_qui_nexiste_pas") == "FAIL:no_role_token",
      "roles: un role sans jeton -> cause a lui, jamais « la forge n'a pas repondu »")

# ⚠ VIDE N'EST PAS ABSENT, ET C'EST LE MEME MANQUE — trou trouve par mutation, pas par relecture :
# retirer le garde du vide ne faisait rougir AUCUN temoin. Un fichier vide part sur le fil comme un
# jeton, la forge rend 401 au premier usage, et la cause devient « la forge refuse » sur un conteneur
# dont le provisionnement est incomplet.
open(os.path.join(WORK, "role_vide.gitea_token"), "w").close()
check(demande_role("role_vide") == "FAIL:no_role_token",
      "roles: un jeton VIDE est un jeton absent — on ne le sert pas")

_garde = mod.FORGE_BASE_URL
mod.FORGE_BASE_URL = "http://127.0.0.1:1"
check(demande_role("fleet_engineer") == "FAIL:forge_unreachable",
      "roles: forge muette -> fail-closed, et distinct de « tu n'es pas un worker »")
mod.FORGE_BASE_URL = _garde

_tok = open(TOKEN).read()
open(TOKEN, "w").close()
check(demande_role("fleet_engineer") == "FAIL:no_authority",
      "roles: sans autorite, la cause est celle du CONTENEUR, pas celle de l'appelant")
open(TOKEN, "w").write(_tok)

# ─── 8. UN GESTE INTERROMPU N'EST PAS UN GESTE QUI ECHOUE ───────────────────────────────────────
# `Popen.wait()` rend `-N` quand l'enfant a ete TUE par le signal N. Relaye tel quel, ca donnait
# `exit -15` cote bash, qui rend 241 — un nombre qui ne designe rien. Les deux natures sont nommees
# separement parce que les gestes different : un echec se diagnostique, une interruption se rejoue.
# ⚠ L'ETAT EXIGE EST REPOSE ICI, il ne s'herite pas de la section precedente : celle-ci vide
# `ADMINS` pour prouver qu'un non-admin ne peut pas se declarer admin. Un temoin qui depend de
# l'ordre de ses voisins ment le jour ou l'un d'eux bouge.
ADMINS.clear()
ADMINS.add(MOI)
os.environ["BANC_SIGNAL"] = "1"
r = ask("install web-demo")
check(verdict(r) == "FAIL:gesture_signalled:15",
      "interrompu: un geste tue par SIGTERM est nomme comme tel, pas comme un echec")
check("gesture_failed" not in verdict(r),
      "interrompu: JAMAIS confondu avec un echec du geste — les sorties different")
del os.environ["BANC_SIGNAL"]

# ─── 8 bis. UN CLIENT PARTI N'INTERROMPT PAS LE GESTE ───────────────────────────────────────────
# Si la coupure du client tuait le geste, le `finally` rendrait le verrou pendant que
# `forge-gestures.sh` continue en orphelin : un second appelant prendrait le verrou, tomberait sur
# le `flock -n` en dessous, et lirait « le geste a echoue » sur une machine parfaitement saine.
ADMINS.clear()
ADMINS.add(MOI)
os.environ["BANC_SLEEP"] = "2"
_c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
_c.connect(SOCK)
_f = _c.makefile("rw", encoding="utf-8", newline="\n")
_f.write("install web-demo\n")
_f.flush()
time.sleep(0.4)
_c.close()                      # l'operateur coupe, le geste tourne encore
time.sleep(3.0)                 # on laisse le geste finir
del os.environ["BANC_SLEEP"]
_t0 = time.time()
r = ask("install autre-demo")
check(verdict(r) == "OK",
      "client parti: le verrou a bien ete rendu — le suivant passe, il ne lit pas « busy »")
check(time.time() - _t0 < 2.0,
      "client parti: et il passe TOUT DE SUITE, donc le geste orphelin s'est bien termine")

# ─── 8. UN PAIR QUI SE TAIT NE RETIENT PAS LE SERVICE ───────────────────────────────────────────
# Sans delai de lecture, une connexion ouverte et muette bloque un thread pour toujours : un membre
# du groupe pourrait en ouvrir autant qu'il veut sans jamais formuler une demande.
mod.REQUEST_TIMEOUT = 1
_muet = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
_muet.connect(SOCK)
_t0 = time.time()
_muet.settimeout(10)
try:
    _reste = _muet.recv(4096)
except (socket.timeout, TimeoutError):
    _reste = b"(rien, la socket est restee ouverte)"
_muet.close()
check(time.time() - _t0 < 8,
      "pair muet: le service LACHE la connexion au lieu de retenir un thread (%.1fs)"
      % (time.time() - _t0))

# ─── 9. LE GARDE DE ROOT ────────────────────────────────────────────────────────────────────────
# ⚠ CE TEMOIN A PENDU, ET C'EST LA PREUVE QU'IL MESURAIT LE MAUVAIS OBJET. Il appelait `main()` en
# comptant sur le refus `geteuid() != 0` pour rendre la main. Le garde nomme desormais l'EXIGENCE —
# « je peux ouvrir le jeton » — donc dans un banc ou le jeton EXISTE, `main()` passe le garde et part
# en `serve_forever()` : le banc ne rendait plus rien, pas meme les tests deja verts, et sa sortie
# bufferisee disparaissait avec lui.
#
# Un temoin qui PEND est pire qu'un temoin rouge : il n'echoue pas, il s'efface.
#
# On mesure donc le garde DANS L'ETAT QU'IL GARDE : le jeton inouvrable.
_tok_garde = mod.MASTER_TOKEN_FILE
mod.MASTER_TOKEN_FILE = os.path.join(WORK, "jeton-qui-n-existe-pas")
_t0 = time.time()
_rc = mod.main()
_ecoule = time.time() - _t0
mod.MASTER_TOKEN_FILE = _tok_garde
check(_rc == 1,
      "garde: sans pouvoir OUVRIR le jeton, le service refuse de demarrer (rc=%r)" % _rc)
check(_ecoule < 5,
      "garde: il refuse TOT — un garde franchi part en boucle de service et n'est plus un garde (%.1fs)"
      % _ecoule)

# ─── 6d — LE JETON MASTER EST LU A CHAQUE REQUETE, ET JAMAIS GARDE ──────────────────────────────
#
# ⚠ CE N'EST PAS UNE PROPRIETE DE CONFORT : C'EST CE QUI TIENT UN ARBITRAGE.
#
# `02` a tranche « pas de troisieme process » — le jeton master (autorite TOTALE de la forge) et les
# jetons de role (identites de travail) vivent dans le MEME espace d'adressage. La faiblesse est
# assumee, et elle n'est defendable QUE parce que ce process ne garde rien : `master_token()` relit
# le fichier a chaque requete, donc entre deux installs il n'y a RIEN a voler en memoire — seulement
# un uid qui peut ouvrir un fichier.
#
# Le jour ou quelqu'un met ce jeton en cache pour « eviter une lecture disque », l'arbitrage tombe —
# et il tombe SANS QUE PERSONNE S'EN APERCOIVE, parce que tout continue de fonctionner. Sans ce
# temoin, la decision de ne pas separer les deux credentials n'est plus defendable.
#
# ⚠ ET C'EST UN TEMOIN FONCTIONNEL, PAS UN MUR TEXTUEL, POUR UNE RAISON MESUREE. Un balayage de
# texte ne voit pas une memoisation : elle s'ecrit en variable globale, en attribut, en
# `functools.cache`, ou simplement en gardant la valeur dans le handler. La phase 3 a paye
# exactement ca — un mur qui cherchait un `chmod` et un nom de fichier sur la MEME ligne ne pouvait
# pas voir une ecriture atomique, et il passait vert. Ici on CHANGE le fichier entre deux appels et
# on regarde ce qui sort.
_cache_tok = os.path.join(WORK, "jeton-rotatif")
_garde_mt = mod.MASTER_TOKEN_FILE
mod.MASTER_TOKEN_FILE = _cache_tok

with open(_cache_tok, "w", encoding="utf-8") as _fh:
    _fh.write("premier-jeton\n")
_lu1 = mod.master_token()

with open(_cache_tok, "w", encoding="utf-8") as _fh:
    _fh.write("jeton-tourne\n")
_lu2 = mod.master_token()

# La ROTATION est l'autre face de la meme propriete : un jeton tourne est pris en compte sans
# redemarrer le service. Une seule phrase, lue par les deux bouts.
check(_lu1 == "premier-jeton", "6d: le jeton master est lu depuis le fichier (%r)" % _lu1)
check(_lu2 == "jeton-tourne",
      "6d: RELU a chaque appel — un jeton tourne est vu sans redemarrage, et rien ne reste en "
      "memoire entre deux requetes (%r)" % _lu2)

# ⚠ LA MOITIE QUI MANQUERAIT SANS CA : que le fichier redevienne ILLISIBLE doit se voir aussi. Un
# cache rendrait l'ancienne valeur ici, et le service continuerait d'agir avec une autorite que le
# conteneur n'a plus — le pire des deux mondes, puisque rien ne rougirait nulle part.
os.unlink(_cache_tok)
try:
    mod.master_token()
    check(False, "6d: un jeton master RETIRE doit lever NoAuthority, pas rendre l'ancienne valeur")
except mod.NoAuthority:
    check(True, "6d: le jeton retire leve NoAuthority — aucune valeur ne survit a son fichier")

mod.MASTER_TOKEN_FILE = _garde_mt

# ─── bind() : LE REPERTOIRE D'UNE PORTE PORTE LE GROUPE DE LA PORTE ─────────────────────────────
#
# ⚠ LE DEFAUT QUE CE TEMOIN GARDE A RENDU LE CHANTIER NON FONCTIONNEL, ET AUCUN MUR NE POUVAIT LE
# VOIR. `bind()` chownait la SOCKET au groupe passe et laissait son REPERTOIRE a l'uid:gid du
# process. Pour un service root : `drwxr-x--- root:root`. Mesure du 2026-08-25, install reelle —
# `toolchain.sock` en `srw-rw---- root:fleet`, parfaite, dans ce repertoire-la : un membre de `fleet`
# ne le TRAVERSE pas. Le sudoers `%fleet ALL=(root)` venait d'etre retire et la socket qui le
# remplace ne repondait a personne.
#
# ⚠ ET C'EST FONCTIONNEL, PAS TEXTUEL, POUR UNE RAISON MESUREE. Un mur qui cherche le chemin sur la
# ligne de l'appel ne voit rien : le code passe une VARIABLE. J'en ai ecrit un, son garde de
# population a rendu « 0 chemin trouve ». La seule mesure qui tienne est d'APPELER `bind()` et de
# regarder le disque.
# ⚠ LE GROUPE CHOISI N'EST PAS LE GROUPE PRIMAIRE, ET C'EST TOUTE LA VALIDITE DE CE TEMOIN.
#
# Premiere ecriture : je passais le groupe primaire du process. `makedirs` cree DEJA le repertoire
# avec ce gid — le `chown` etait donc un no-op, et retirer le correctif ne faisait rougir personne.
# Mesure : la mutation « bind() cesse de chowner son repertoire » passait VERTE.
#
# C'est exactement l'accident qui a masque le defaut sur le vrai conteneur : `/run/lcars/authority` y
# echappait parce que `lcars-authority` avait `fleet` en primaire, pendant que `/run/lcars/privileged`
# — service root, primaire `root` — tombait. Un temoin qui reproduit l'accident ne mesure rien.
#
# On prend donc un groupe SECONDAIRE : le chown doit deplacer le gid pour que l'assertion tienne.
_gid_primaire = os.getgid()
_gid_secondaire = next((g for g in os.getgroups() if g != _gid_primaire), None)
if _gid_secondaire is None:
    check(False, "bind: ce runner n'a qu'UN groupe — le temoin ne peut pas distinguer un chown "
                 "d'un no-op, et il ne doit pas passer vert en n'ayant rien mesure")
    _gid_secondaire = _gid_primaire

_sock_dir = os.path.join(WORK, "porte")
_sock_path = os.path.join(_sock_dir, "t.sock")
_mon_groupe = grp.getgrgid(_gid_secondaire).gr_name

# `catalogue-executor.py` fait `import lcars_socket` apres avoir insere son propre repertoire dans
# `sys.path` : le module voisin est donc un attribut de celui qu'on vient de charger. On l'atteint
# par la, plutot qu'en recopiant le `sys.path.insert` — deux facons de trouver un module divergent.
_srv = mod.lcars_socket.bind(_sock_path, _mon_groupe, 0o660, prefix="banc")
try:
    _st_dir = os.stat(_sock_dir)
    _st_sock = os.stat(_sock_path)
    _gid_attendu = grp.getgrnam(_mon_groupe).gr_gid

    check(_st_sock.st_gid == _gid_attendu,
          "bind: la SOCKET porte le groupe passe (%s)" % grp.getgrgid(_st_sock.st_gid).gr_name)
    check(_st_dir.st_gid == _gid_attendu,
          "bind: son REPERTOIRE porte le MEME groupe — sinon la porte est parfaite et "
          "inatteignable (%s)" % grp.getgrgid(_st_dir.st_gid).gr_name)
    # Et le repertoire donne bien la TRAVERSEE au groupe : 0750, pas 0700. Sans le bit `x`, le
    # groupe ne peut pas atteindre la socket meme en la possedant.
    check(_st_dir.st_mode & 0o010,
          "bind: le repertoire accorde le bit x au groupe (mode 0%o)" % (_st_dir.st_mode & 0o777))
    # ⚠ LE MODE EXACT, ET PAS SEULEMENT UN BIT. `makedirs(mode=…)` est soumis a l'UMASK et
    # `exist_ok=True` ne touche pas un repertoire deja la : sans le `chmod` explicite, la porte
    # pouvait naitre a un mode que la table ne declare pas, ou garder le sien indefiniment. La table
    # dit `0750` pour les deux portes.
    check((_st_dir.st_mode & 0o777) == 0o750,
          "bind: le repertoire porte EXACTEMENT le mode de la table (0%o)" % (_st_dir.st_mode & 0o777))
finally:
    _srv.close()

# ─── 10. LA BOITE DE DEPOT — LA DESTINATION EST LE DEPOT DU PROJET ──────────────────────────────
#
# CE QUI EST EPINGLE ICI :
#   · le fichier ne passe pas par le fil : la porte lit la ZONE DE TRANSIT, et rien d'autre ;
#   · un chemin hors de cette zone est refuse — sans cette garde, la porte commiterait un jeton ;
#   · l'org du projet se resout parmi le catalogue LIVRE et les catalogues INSTALLES, et
#     l'ambiguite est un refus ;
#   · un nom que le harnais d'un agent charge seul (`CLAUDE.md`, `AGENTS.md`) entre renomme ;
#   · l'humain est l'AUTEUR du commit, le compte systeme le COMMITTER, la branche est `workshop` ;
#   · le chemin ne porte ni login ni horodatage — le commit les porte deja ;
#   · un nom deja pris est REMPLACE : second commit, sha du blob en place, historique conserve ;
#   · le contenu n'est jamais charge en memoire : la longueur annoncee vaut celle d'un base64.
DEPOT = os.path.join(WORK, "deposit.sock")
SPOOL = os.path.join(WORK, "spool")
CATS = os.path.join(WORK, "catalogues")
os.makedirs(SPOOL, exist_ok=True)
# ⚠ `fleet` N'EST PAS ICI, ET C'EST LE POINT. Le catalogue livre vit dans la release, pas dans le
# repertoire des installes. Le banc le posait autrefois a cote de `reverse` : il masquait le defaut
# qu'un banc reel a montre le 2026-09-23 — tout projet du catalogue livre etait `unknown_project`.
for _cat in ("reverse",):
    os.makedirs(os.path.join(CATS, _cat), exist_ok=True)
    with open(os.path.join(CATS, _cat, "catalogue.yaml"), "w") as fh:
        fh.write("api: 1\nname: %s\n" % _cat)

mod.DEPOSIT_SOCKET_PATH = DEPOT
mod.DEPOSIT_SPOOL = SPOOL
mod.CATALOGUES_DIR = CATS
mod.SYSTEM_TOKEN_FILE = SYSTEM_TOKEN
# Le pair de cette porte est le DECK, et le banc n'a qu'un uid : le sien. On nomme donc le compte du
# banc comme etant celui du deck — ce qui EPINGLE la regle « un seul compte relaie ».
mod.DEPOSIT_PEER = MOI
_srv_depot = mod.bind(DEPOT, "lcars-banc-groupe-absent")
threading.Thread(target=mod.serve_forever, args=(_srv_depot, mod.serve_deposit),
                 daemon=True).start()


def transit(contenu):
    """Un fichier dans la zone de transit, comme le deck l'y pose. Rend (chemin, taille, sha)."""
    import hashlib as _h
    brut = contenu if isinstance(contenu, bytes) else contenu.encode("utf-8")
    fd, chemin = tempfile.mkstemp(prefix="depot-", dir=SPOOL)
    with os.fdopen(fd, "wb") as fh:
        fh.write(brut)
    return chemin, len(brut), _h.sha256(brut).hexdigest()


def depose(login, slug, contenu=b"firmware", nom="firmware.bin",
           empreinte=None, taille=None, chemin=None, timeout=20):
    """Un depot sur la porte, et son verdict."""
    spool, reelle, digest = transit(contenu)
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(timeout)
    c.connect(DEPOT)
    f = c.makefile("rw", encoding="utf-8", newline="\n")
    f.write("deposit %s %s %s %s %s\n%s\n" % (
        login, slug, empreinte or digest, reelle if taille is None else taille, nom,
        chemin or spool))
    f.flush()
    rep = (f.readline() or "").rstrip("\n")
    c.close()
    return rep


REPOS.add("reverse/samyang-reverse")
ECRITS.clear()
_v = depose("alice", "samyang-reverse")
check(_v.startswith("OK:"), "depot: le fichier part dans le depot du projet — %s" % _v[:70])
check(len(ECRITS) == 1, "depot: une seule ecriture sur la forge (%d)" % len(ECRITS))
if ECRITS:
    _e = ECRITS[0]
    check(_e["repo"] == "reverse/samyang-reverse",
          "depot: l'org vient du catalogue qui porte le projet (%s)" % _e["repo"])
    check(_e["corps"].get("branch") == "workshop",
          "depot: la branche est celle de la face workshop (%s)" % _e["corps"].get("branch"))
    check(_e["chemin"] == "ready-room/firmware.bin",
          "depot: le chemin ne porte ni login ni horodatage (%s)" % _e["chemin"])
    check(_e["corps"].get("author", {}).get("name") == "alice",
          "depot: l'AUTEUR du commit est l'humain (%s)" % _e["corps"].get("author"))
    check(_e["corps"].get("committer", {}).get("name") == "system_starfleet",
          "depot: le COMMITTER est le compte systeme, celui qui pousse")
    check(_e["auth"] == "token " + SYSTEM_VALUE,
          "depot: la poussee presente le jeton SYSTEME, pas le master")
    check("Deposited-by: alice" in _e["corps"].get("message", ""),
          "depot: la remorque nomme le deposant — seconde trace, lisible sans la forge")
    # ⚠ LA LONGUEUR ANNONCEE EST CELLE DU CORPS RECU : c'est ce qui prouve que le contenu a ete
    # STREAME sans etre charge — un calcul faux se verrait ici, pas en production.
    check(_e["longueur_annoncee"] == _e["longueur_recue"],
          "depot: la longueur annoncee vaut celle du corps recu (%s vs %s)"
          % (_e["longueur_annoncee"], _e["longueur_recue"]))

# ─── 10 bis. LE MEME NOM EST REMPLACE, PAS REFUSE ───────────────────────────────────────────────
# git garde l'historique : le second depot est un commit de plus, et le sha du blob en place est ce
# que l'API exige pour distinguer un remplacement d'un ecrasement aveugle.
ECRITS.clear()
_v = depose("alice", "samyang-reverse", contenu=b"firmware v2")
check(_v.startswith("OK:"), "depot: un nom deja pris est remplace — %s" % _v[:40])
check([e["methode"] for e in ECRITS] == ["POST", "PUT"],
      "depot: creation tentee, puis remplacement (%s)" % [e["methode"] for e in ECRITS])
check(ECRITS[-1]["corps"].get("sha"), "depot: le remplacement porte le sha du blob en place")

# ─── 10 bis (suite). LE REMPLACEMENT TIENT SUR UNE READY ROOM BIEN REMPLIE ──────────────────────
#
# ⚠ LE PIEGE QUE CE CAS FERME : chercher le sha du blob dans `git/trees/<branche>?recursive` compte
# TOUTE la face et se tronque au-dela d'une page. Au-dela, le sha revenait « absent », le 422 du
# depart etait relance, et l'operateur lisait `forge_refused:422` pour un fichier bien la. Le
# listage du REPERTOIRE ne parle que de la ready room, et ne se tronque pas sur la taille de la face.
for _i in range(1200):
    FICHIERS[("reverse/samyang-reverse", "docs/note-%04d.md" % _i)] = "blob-%04d" % _i
ECRITS.clear()
LUS.clear()
_v = depose("alice", "samyang-reverse", contenu=b"firmware v3")
check(_v.startswith("OK:"),
      "depot: le remplacement tient quand la face porte 1200 fichiers de plus — %s" % _v[:40])
check([e["methode"] for e in ECRITS] == ["POST", "PUT"],
      "depot: et c'est bien un remplacement (%s)" % [e["methode"] for e in ECRITS])
# ⚠ ET LE FICHIER N'EST JAMAIS TELECHARGE POUR SAVOIR S'IL EXISTE : on liste le repertoire, on ne
# demande pas le blob. Un `GET /contents/ready-room/firmware.bin` ici rendrait 50 Mo en base64.
check(not [u for u in LUS if "/contents/ready-room/firmware.bin" in u],
      "depot: le sha vient du LISTAGE, jamais du contenu du fichier (%s)"
      % [u for u in LUS if "/contents/" in u][:2])

# ─── 10 bis (pagination). UNE READY ROOM QUI DEPASSE UNE PAGE ───────────────────────────────────
#
# ⚠ LE DEFAUT QUE CE CAS FERME : une reponse tronquee lue comme complete rend « absent » pour un
# fichier bien la, et le remplacement devient un refus de la forge. La porte suit `Link: rel="next"`
# jusqu'au bout. Le banc pagine par 50 ; on en met 120 pour que la cible soit hors premiere page.
for _i in range(120):
    FICHIERS[("reverse/samyang-reverse", "ready-room/piece-%03d.bin" % _i)] = "blob-p%03d" % _i
ECRITS.clear()
_v = depose("alice", "samyang-reverse", contenu=b"firmware v4")
check(_v.startswith("OK:"),
      "depot: le remplacement traverse les pages du listage — %s" % _v[:40])
check([e["methode"] for e in ECRITS] == ["POST", "PUT"],
      "depot: et c'est bien un remplacement, pas un refus (%s)" % [e["methode"] for e in ECRITS])

# ⚠ ET LA TRAVERSEE EST BORNEE : une ready room sans fin ne doit pas faire boucler ce service.
# La cible trie APRES les pieces : sans ca elle tombe en premiere page et la borne n'est jamais
# atteinte — le cas passerait au vert sans rien mesurer.
FICHIERS[("reverse/samyang-reverse", "ready-room/zz-cible.bin")] = "blob-zz"
_max_listing = mod.DEPOSIT_LISTING_MAX
mod.DEPOSIT_LISTING_MAX = 60
ECRITS.clear()
_v = depose("alice", "samyang-reverse", contenu=b"cible v2", nom="zz-cible.bin")
check(_v == "FAIL:listing_too_long",
      "depot: au-dela de la borne du listage, la porte le DIT au lieu de boucler — %s" % _v)
mod.DEPOSIT_LISTING_MAX = _max_listing
# Et avec la vraie borne, la meme cible hors premiere page se remplace.
ECRITS.clear()
_v = depose("alice", "samyang-reverse", contenu=b"cible v3", nom="zz-cible.bin")
check(_v.startswith("OK:") and [e["methode"] for e in ECRITS] == ["POST", "PUT"],
      "depot: la meme cible, hors premiere page, se remplace — %s" % _v[:40])
FICHIERS.pop(("reverse/samyang-reverse", "ready-room/zz-cible.bin"), None)
for _i in range(120):
    FICHIERS.pop(("reverse/samyang-reverse", "ready-room/piece-%03d.bin" % _i), None)

# ─── 10 bis (fin). UNE FACE WORKSHOP JAMAIS POUSSEE SE NOMME ────────────────────────────────────
# Le depot existe — la resolution vient de le prouver. Un 404 a l'ecriture parle donc de la BRANCHE,
# et le dire evite d'envoyer l'operateur chercher du cote du fichier.
REPOS.add("reverse/sans-face")
SANS_WORKSHOP.add("reverse/sans-face")
_v = depose("alice", "sans-face")
check(_v == "FAIL:no_workshop_branch",
      "depot: un projet sans face workshop se nomme, au lieu de « la forge refuse » — %s" % _v)
SANS_WORKSHOP.discard("reverse/sans-face")
REPOS.discard("reverse/sans-face")

# ─── 10 ter. LA ZONE DE TRANSIT EST UNE FRONTIERE ───────────────────────────────────────────────
# ⚠ SANS CETTE GARDE, LA PORTE COMMITERAIT CE QU'ON LUI DESIGNE : elle tourne avec l'autorite du
# conteneur, et un chemin non borne pourrait nommer le fichier de jetons.
ECRITS.clear()
_v = depose("alice", "samyang-reverse", chemin=TOKEN)
check(_v == "FAIL:bad_spool", "depot: un chemin hors de la zone de transit est refuse — %s" % _v)
check(not ECRITS, "depot: et rien ne part vers la forge")
_lien = os.path.join(SPOOL, "lien-vers-jeton")
os.path.islink(_lien) or os.symlink(TOKEN, _lien)
_v = depose("alice", "samyang-reverse", chemin=_lien)
check(_v == "FAIL:bad_spool", "depot: un lien symbolique DANS la zone est refuse aussi — %s" % _v)

# ─── 10 quater. L'ORG SE RESOUT, ET L'AMBIGUITE EST UN REFUS ────────────────────────────────────
_v = depose("alice", "projet-inconnu")
check(_v == "FAIL:unknown_project", "depot: un projet qu'aucun catalogue ne porte est refuse — %s" % _v)
REPOS.add("fleet/samyang-reverse")
ECRITS.clear()
_v = depose("alice", "samyang-reverse")
check(_v == "FAIL:ambiguous_project",
      "depot: le meme slug dans deux catalogues — la porte ne choisit pas — %s" % _v)
check(not ECRITS, "depot: et rien n'est ecrit tant que l'org est ambigue")
REPOS.discard("fleet/samyang-reverse")

# ─── 10 quater (livre). LE CATALOGUE LIVRE PORTE DES PROJETS ────────────────────────────────────
# Aucun repertoire d'installation ne le nomme : la porte le connait quand meme, comme le produit.
REPOS.add("fleet/basilisk")
ECRITS.clear()
_v = depose("captain", "basilisk")
check(_v.startswith("OK:") and ECRITS and ECRITS[0]["repo"] == "fleet/basilisk",
      "depot: un projet du catalogue LIVRE se resout, sans repertoire installe — %s" % _v[:70])
_vide = os.path.join(WORK, "catalogues-vides")
os.makedirs(_vide, exist_ok=True)
mod.CATALOGUES_DIR = _vide
ECRITS.clear()
_v = depose("captain", "basilisk")
check(_v.startswith("OK:"),
      "depot: et sur une machine SANS aucun catalogue installe — %s" % _v[:70])
mod.CATALOGUES_DIR = CATS
REPOS.discard("fleet/basilisk")

# ─── 10 quater (harnais). UN NOM QUE L'AGENT CHARGE SEUL ENTRE RENOMME ──────────────────────────
# Deposer un `CLAUDE.md` dans la ready room, c'est donner des consignes a l'architect sans qu'il les
# ait demandees. Le fichier n'est pas refuse : il entre sous un nom que le harnais ne charge pas, et
# le verdict rend CE nom — le deck l'affiche tel quel.
for _nom in ("CLAUDE.md", "claude.md", "AGENTS.md", "CLAUDE.local.md"):
    ECRITS.clear()
    _v = depose("alice", "samyang-reverse", nom=_nom)
    check(_v.startswith("OK:") and _v.endswith(" ready-room/%s.safety" % _nom)
          and ECRITS and ECRITS[-1]["chemin"] == "ready-room/%s.safety" % _nom,
          "depot: « %s » entre sous « %s.safety » — %s" % (_nom, _nom, _v[-50:]))
ECRITS.clear()
_v = depose("alice", "samyang-reverse", nom="README.md")
check(_v.endswith(" ready-room/README.md"), "depot: un nom ordinaire entre tel quel — %s" % _v[-40:])

# ─── 10 quinquies. CE QUE LA PORTE GARDE POUR ELLE ──────────────────────────────────────────────
mod.DEPOSIT_PEER = "un-autre-service"
_v = depose("alice", "samyang-reverse")
check(_v == "FAIL:not_the_deck", "depot: un pair qui n'est pas le deck est refuse — %s" % _v)
mod.DEPOSIT_PEER = MOI

for _nom, _label in ((".." , "deux points"), ("a/b", "une barre"), (".cache", "un nom cache")):
    _v = depose("alice", "samyang-reverse", nom=_nom)
    check(_v == "FAIL:bad_name", "depot: « %s » refuse (%s) — %s" % (_nom, _label, _v))
_v = depose("alice", "samyang-reverse", empreinte="0" * 64)
check(_v == "FAIL:hash_mismatch", "depot: une empreinte qui ne correspond pas refuse le depot — %s" % _v)
_v = depose("alice", "samyang-reverse", taille=3)
check(_v == "FAIL:size_mismatch", "depot: une taille qui ne correspond pas au fichier — %s" % _v)
_v = depose("alice", "samyang-reverse", contenu=b"")
check(_v == "FAIL:empty", "depot: un fichier vide est refuse — %s" % _v)
_max = mod.DEPOSIT_MAX_BYTES
mod.DEPOSIT_MAX_BYTES = 8
_v = depose("alice", "samyang-reverse", contenu=b"beaucoup trop long")
check(_v == "FAIL:too_big", "depot: au-dela de la borne, refus — %s" % _v)
mod.DEPOSIT_MAX_BYTES = _max

# ─── 10 sexies. SANS JETON SYSTEME, LA CAUSE EST L'AUTORITE ─────────────────────────────────────
# Et surtout pas « la forge n'a pas repondu » : l'une se repare en reposant un jeton, l'autre en
# attendant. Le service demarre quand meme — deux portes sur trois n'en ont aucun usage.
mod.SYSTEM_TOKEN_FILE = os.path.join(WORK, "system-absent.token")
_v = depose("alice", "samyang-reverse")
check(_v == "FAIL:no_authority", "depot: sans jeton systeme, la cause est l'autorite — %s" % _v)
mod.SYSTEM_TOKEN_FILE = SYSTEM_TOKEN

shutil.rmtree(WORK, ignore_errors=True)
sys.exit(0 if ok else 1)
