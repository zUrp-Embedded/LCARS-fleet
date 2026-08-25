#!/usr/bin/env python3
# SOURCE: fleet/test/test_catalogue_executor.py
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

import importlib.util
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

ok = True


def check(cond, label):
    global ok
    print(("PASS: " if cond else "FAIL: ") + label)
    if not cond:
        ok = False


HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "services", "catalogue-executor.py")

if not os.path.isfile(SRC):
    # Sujet absent = perimetre manquant, pas un vert. Sans cette ligne `FAIL:`, un exit 1 sec
    # donnerait un gate rouge dont le decompte ne dit rien.
    print("FAIL: catalogue-executor.py introuvable (%s) — sujet manquant" % SRC)
    sys.exit(1)

WORK = tempfile.mkdtemp(prefix="lcars-catexec-")
SOCK = os.path.join(WORK, "catalogue.sock")
TOKEN = os.path.join(WORK, "master.token")
GESTURES = os.path.join(WORK, "gestures.sh")

with open(TOKEN, "w") as fh:
    fh.write("banc-master-token\n")

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
ASKED = []


class Forge(BaseHTTPRequestHandler):
    """La forge de banc : elle repond `is_admin` selon le login DEMANDE, et note qui a demande."""

    def do_GET(self):
        login = self.path.rsplit("/", 1)[-1]
        ASKED.append((login, self.headers.get("Authorization")))
        body = json.dumps({"login": login, "is_admin": login in ADMINS}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
    PROV_FLEET_GROUP="lcars-banc-groupe-absent",
)

spec = importlib.util.spec_from_file_location("catexec", SRC)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

srv = mod.bind()
threading.Thread(target=mod.serve_forever, args=(srv,), daemon=True).start()
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
check(mod.main() == 1,
      "garde root: ce service tient le jeton master, il refuse de tourner sans etre root")

shutil.rmtree(WORK, ignore_errors=True)
sys.exit(0 if ok else 1)
