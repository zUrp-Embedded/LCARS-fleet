#!/usr/bin/env python3
# SOURCE: runtime/services/catalogue-executor.py
# AUTHOR: bob
# STARDATE: 2026-08-23
# STATUS: PROTO-V2 — the root side of `lcars catalogue install`: it holds the authority, the caller proves nothing
#
# ─── WHY THIS PROCESS EXISTS ────────────────────────────────────────────────────────────────────
#
# WHEN THE CALLER'S SHELL HELD THE TOKEN, HOLDING IT WAS THE PROOF -- so the token's mode became the
# gate, so a unix group had to carry `is_admin`, so a converger had to project it, so a poll had to
# refresh it, so a drift repair had to fix consoles born before the projection. Split proving from
# executing and the whole chain is unnecessary: the caller holds nothing and proves nothing.
#
# NO SEAT IS PRIVILEGED -- not a name, not a uid, not a group. A path that skipped the question
# "because it is the seat" would be a second gate, therefore a second truth, therefore the drift
# again.
#
# WHY PYTHON, AND IT IS A DECISION: bash can neither listen on a unix socket nor call
# `getsockopt(SO_PEERCRED)`, and `socat` does not propagate the peer's credentials. Stdlib only, so
# this costs no new dependency.

import json
import os
import pwd
import re
import socket
import struct
import subprocess
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request

# ⚠ LE MODULE VOISIN, PAS UN PAQUET : `lcars_socket.py` est POSE a cote de ce fichier par les deux
# rails, et c'est ce qui rend l'import valide sans installation.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lcars_socket  # noqa: E402 -- apres le sys.path, c'est la condition de l'import

# ⚠ SOUS `/run/lcars/authority/`, PAS `/run/lcars/` : ce service n'est pas root et ne peut rien
# creer dans un `0755 root:root`. Le repertoire est declare au manifeste ET au `tmpfiles.d` — `/run`
# est un tmpfs, ce qui n'y est pas declare ne se refait pas au reboot.
SOCKET_PATH = os.environ.get("LCARS_CATALOGUE_SOCKET", "/run/lcars/authority/catalogue.sock")
# THE SOCKET'S ACL CARRIES NO AUTHORIZATION -- it only bounds who may KNOCK. Opening it to the world
# would grant nobody anything, but it would offer this process to every account on the box for no gain.
SOCKET_GROUP = os.environ.get("PROV_FLEET_GROUP", "fleet")
SOCKET_MODE = 0o660
# ⚠ UNE SOCKET PAR VERBE, ET LE VERBE EST LE CANAL : le service sait quel code lancer par la socket
# d'ARRIVEE, jamais par un mot lu sur le fil.
ROLES_SOCKET_PATH = os.environ.get(
    "LCARS_ROLES_SOCKET", os.path.join(os.path.dirname(SOCKET_PATH), "roles.sock"))
# ⚠ `FORGE_ROLE_TOKENS_DIR`, LE NOM DU CONTRAT COTE CONSOMMATEURS, ET PAS UN NOM A NOUS : en
# multi-forge, un operateur qui le pose pour un profil secondaire alignerait le runtime tout en
# laissant CE service lire le repertoire de la forge primaire — des gestes vises sur la seconde
# forge presentant les jetons de la premiere.
ROLE_TOKENS_DIR = os.environ.get("FORGE_ROLE_TOKENS_DIR", "/opt/lcars/var/tokens")
FORGE_ORG = os.environ.get("PROV_FORGE_ORG", "fleet")
HUMANS_TEAM = os.environ.get("PROV_HUMANS_TEAM", "humans")

# Un nom de compte de role est un nom de compte forge, et il devient un CHEMIN juste en dessous.
ROLE_RX = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
MASTER_TOKEN_FILE = os.environ.get("LCARS_MASTER_TOKEN_FILE", "/opt/lcars/var/tokens/forge-master.token")
GESTURES = os.environ.get("LCARS_FORGE_GESTURES", "/opt/lcars/forge-gestures.sh")
FORGE_BASE_URL = os.environ.get("FORGE_BASE_URL", "")
HTTP_TIMEOUT = int(os.environ.get("LCARS_CATALOGUE_HTTP_TIMEOUT", "15"))
# Le temps accorde a un pair pour FORMULER sa demande, pas pour que le geste s'accomplisse.
REQUEST_TIMEOUT = int(os.environ.get("LCARS_CATALOGUE_REQUEST_TIMEOUT", "30"))

# A CITED COPY of the Elixir authority, not a second one: this executor cannot share the literal.
#
# ⚠ AND THE TRANSCRIPTION IS NOT MECHANICAL. In Python `^...$` is NOT `\A...\z`: `$` also matches
# before a trailing newline, so `web-demo\n` -- exactly what arrives from a line-oriented socket --
# would pass. `fullmatch` on an already-stripped value is the form that means what it says.
NAME_RX = re.compile(r"[a-z0-9][a-z0-9-]*")

# ⚠ THE VALIDATION IS THIS PROCESS'S OWN RESPONSIBILITY, and it is not defence in depth: the name
# becomes a PATH under which this process runs `mkdir -p`, `cp -r` and `tofu apply`. The upstream
# check that also refuses the form is INCIDENTAL -- its job is a catalogue's coherence, not a path's
# safety, and it may legitimately change without anyone thinking about this process.

# ONE GESTURE AT A TIME, AND WE REFUSE RATHER THAN QUEUE. Same choice as `with_apply_lock`'s
# `flock -n` below us: a caller made to wait would get its verdict when the other one finished, on a
# forge that moved under it. Refusing gives it a sentence it can act on.
_gesture_lock = threading.Lock()


def log(msg):
    print(f"[lcars-catalogue] {msg}", file=sys.stderr, flush=True)


def peer_of(conn):
    """
    The connected peer's (pid, uid, gid), as stated by the kernel.

    This is the whole identity story. Nothing here parses anything the caller sent.
    """
    raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    return struct.unpack("3i", raw)


def login_of(uid):
    """
    The unix login for a uid, or None.

    THE UNIX NAME **IS** THE FORGE LOGIN. The converger creates accounts with
    `useradd -- "$login"`, verbatim from the forge -- so no mapping table exists, and none is wanted:
    a table is a second truth that drifts from the first.
    """
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return None


class NoAuthority(Exception):
    """
    This box has no usable site-admin credential.

    ⚠ IT IS A CAUSE OF ITS OWN, AND MERGING IT WAS A MEASURED DEFECT. `master_token()` used a bare
    `open()`, and its caller caught `OSError` -- which `FileNotFoundError` and `PermissionError`
    both inherit from. An absent, unreadable, empty or REVOKED token therefore came out as
    `forge_unreachable`, and the operator was told "the forge is perhaps restarting, retry" about a
    forge in perfect health. Measured 2026-08-24, all four cases.

    The two remedies are OPPOSITE, which is what makes the merge expensive: a mute forge is retried,
    a missing authority is RE-POSED by an admin. Nothing the operator can do fixes the first, and
    retrying forever fixes neither.
    """


def master_token():
    """
    The site-admin credential, read fresh at each request.

    Read at each request and not cached at startup, so a rotated token is picked up without a
    restart. Raises NoAuthority when this box cannot produce one -- never a bare OSError, which the
    caller would read as "the forge did not answer".
    """
    try:
        with open(MASTER_TOKEN_FILE, "r", encoding="utf-8") as fh:
            token = fh.read().strip()
    except OSError as exc:
        raise NoAuthority(f"{MASTER_TOKEN_FILE} illisible ({exc.strerror})") from exc
    # ⚠ VIDE N'EST PAS ABSENT, ET C'EST LE MEME MANQUE. Un fichier vide part sur le fil comme un
    # en-tete sans jeton, la forge rend 401, et sans ce garde la cause devient « forge muette ».
    # `forge-gestures.sh cmd_install` fait ce controle depuis toujours ; ce process l'avait perdu.
    if not token:
        raise NoAuthority(f"{MASTER_TOKEN_FILE} est VIDE")
    return token


def forge_is_admin(login):
    """
    Does the forge say this login is a site admin?

    Raises on any non-answer -- the caller turns that into a refusal that says "I could not ask",
    never "you are not admin". FAIL-CLOSED, and the two causes stay distinct: a refusal naming the
    wrong cause sends the operator to fix something that is not broken.

    ⚠ THIS READ REQUIRES A SITE-ADMIN READER, and that is the constraint the whole design turns on.
    Measured on Gitea 1.26.1: for an anonymous reader and for the system token, `is_admin` on
    `/api/v1/users/<login>` is PRESENT and FALSE for an account that really is admin. The field is
    not masked -- it is lied about. Only a site-admin reader gets the truth, which is why the token
    lives in this process and cannot live in the caller's.
    """
    url = f"{FORGE_BASE_URL.rstrip('/')}/api/v1/users/{urllib.parse.quote(login, safe='')}"
    req = urllib.request.Request(url, headers={"Authorization": f"token {master_token()}"})
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return bool(json.load(resp).get("is_admin"))
    except urllib.error.HTTPError as exc:
        # ⚠ 401/403 EST UNE REPONSE, ET ELLE PARLE DE NOUS. La forge a repondu, clairement : le
        # jeton qu'on lui presente ne vaut rien -- revoque, expire, ou jamais valide. Le ranger dans
        # « pas de reponse » ferait reessayer l'operateur sur une forge qui vient de refuser, et
        # `HTTPError` DERIVE de `URLError`, donc c'est exactement ce qui se passait.
        if exc.code in (401, 403):
            raise NoAuthority(f"la forge REFUSE le jeton de cette boite (HTTP {exc.code})") from exc
        raise


def is_fleet_human(login):
    """
    Does the forge say this login is a member of the org's `humans` team?

    ⚠ THIS IS THE QUESTION THE UNIX GROUP WAS ANSWERING, and answering STALE. `fleet` was populated
    from this very team by the converger, every 30s, and a role token was readable by anyone the
    projection had reached — including someone the forge had since removed, until the next tick and
    until every one of their live processes died.

    Asked here, at the instant of the gesture, it has no staleness to carry: a removal bites on the
    next request. Raises on any non-answer -- fail-closed, like every other authority question in
    this process.

    Measured on Gitea 1.26.1: `GET /teams/{id}/members/{login}` answers 200 for a member and 404 for
    everyone else, INCLUDING a site admin who is not in the team. Membership is not adminity, and
    the endpoint does not confuse them.
    """
    teams = _forge_json(f"/api/v1/orgs/{urllib.parse.quote(FORGE_ORG, safe='')}/teams")
    tid = next((t["id"] for t in teams if t.get("name") == HUMANS_TEAM), None)
    if tid is None:
        raise NoAuthority(f"l'org {FORGE_ORG} n'a pas d'equipe « {HUMANS_TEAM} »")
    url = (f"{FORGE_BASE_URL.rstrip('/')}/api/v1/teams/{tid}"
           f"/members/{urllib.parse.quote(login, safe='')}")
    req = urllib.request.Request(url, headers={"Authorization": f"token {master_token()}"})
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT):
            return True
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return False
        if exc.code in (401, 403):
            raise NoAuthority(f"la forge REFUSE le jeton de cette boite (HTTP {exc.code})") from exc
        raise


def _forge_json(path):
    url = f"{FORGE_BASE_URL.rstrip('/')}{path}"
    req = urllib.request.Request(url, headers={"Authorization": f"token {master_token()}"})
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise NoAuthority(f"la forge REFUSE le jeton de cette boite (HTTP {exc.code})") from exc
        raise


def serve_role_token(conn):
    """
    One request, one role token — or one named cause.

        -> <role account>
        <- the token, one line
        <- "FAIL:<cause>"

    ⚠ CE QU'ON REND EST UN CREDENTIAL, ET C'EST UN RECUL ASSUME PAR RAPPORT A `catalogue.sock`.
    La, le service AGIT et rien ne sort ; ici il DONNE. Ce qui le rend defendable est le point de
    depart, pas une propriete absolue : aujourd'hui le fichier est lisible par tout humain de la
    boite. Une socket qui demande a la forge et sait QUI a demande est strictement meilleure — mais
    le jeton s'exerce encore hors du chemin audite, et pretendre l'inverse serait une survente.
    """
    wire = conn.makefile("rw", encoding="utf-8", newline="\n")

    def done(status):
        try:
            wire.write(f"{status}\n")
            wire.flush()
        except OSError:
            log(f"reponse non remise, client parti : {status.split(':')[0]}")

    pid, uid, _gid = peer_of(conn)
    login = login_of(uid)
    if login is None:
        log(f"refus roles: uid {uid} (pid {pid}) n'a pas de compte unix")
        return done("FAIL:unknown_peer")

    role = wire.readline().rstrip("\r\n")
    conn.settimeout(None)
    if not ROLE_RX.fullmatch(role):
        log(f"refus roles: {login} a demande « {role} » — pas un nom de compte")
        return done("FAIL:bad_role")

    try:
        if not is_fleet_human(login):
            log(f"refus roles: la forge dit que {login} n'est pas de l'equipe {HUMANS_TEAM}")
            return done("FAIL:not_a_worker")
    except NoAuthority as exc:
        log(f"refus roles: cette boite n'a pas d'autorite utilisable — {exc}")
        return done("FAIL:no_authority")
    except (urllib.error.URLError, TimeoutError, socket.timeout, ValueError, OSError) as exc:
        log(f"refus roles: appartenance de {login} non lue ({exc})")
        return done("FAIL:forge_unreachable")

    # ⚠ LE NOM EST VALIDE AVANT DE DEVENIR UN CHEMIN, et c'est la meme responsabilite qu'au verbe
    # catalogue : ce process ouvre le fichier, personne ne le fait a sa place.
    path = os.path.join(ROLE_TOKENS_DIR, f"{role}.gitea_token")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            token = fh.read().strip()
    except OSError as exc:
        log(f"refus roles: {path} illisible pour {login} ({exc.strerror})")
        return done("FAIL:no_role_token")
    if not token:
        log(f"refus roles: {path} est VIDE")
        return done("FAIL:no_role_token")

    log(f"{login} obtient le jeton du role « {role} »")
    return done(token)


def run_gesture(name, emit):
    """
    Play `forge-gestures install <name>` and relay its output line by line. Returns its exit code.

    ⚠ THE OUTPUT IS RELAYED, NOT SWALLOWED. This gesture clones, verifies, and applies a recipe; it
    talks while it works, and an operator who sees `OK` several minutes after silence has been given
    a worse tool than the one this replaces. The relay is also what carries the gesture's OWN refusal
    sentences, which are more precise than anything this process could restate.
    """
    env = dict(os.environ)
    env["FORGE_BASE_URL"] = FORGE_BASE_URL
    proc = subprocess.Popen(
        [GESTURES, "install", name],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        env=env,
        text=True,
    )
    for line in proc.stdout:
        emit(line.rstrip("\n"))
    return proc.wait()


def serve_one(conn):
    """
    One request, one verdict. The wire format is deliberately dumb so that bash can read it.

        -> install <name>
        <- "> <line>"   relayed gesture output, in order
        <- "OK"          the gesture succeeded
        <- "FAIL:<cause>" refused or failed, cause is a stable token

    The cause is a TOKEN and not a sentence: `bin/lcars` owns the operator's wording, because it is
    the thing the operator is talking to. SEVEN causes exist and they are never merged -- a refusal
    that names the wrong one costs more than a mute one.
    """
    wire = conn.makefile("rw", encoding="utf-8", newline="\n")
    gone = []

    # ⚠ ON ABSORBE LA COUPURE ET ON CONTINUE A DRAINER : laisser l'EPIPE remonter relacherait le
    # verrou pendant que le geste continue EN ORPHELIN, et le prochain appelant lirait « le geste a
    # echoue » la ou il fallait lire « un autre geste est en cours ».
    def emit(line):
        if not gone:
            try:
                wire.write(f"> {line}\n")
                wire.flush()
                return
            except OSError:
                gone.append(True)
                log("le client est parti — le geste CONTINUE, sa sortie passe au journal")
        log(f"| {line}")

    def done(status):
        if not gone:
            try:
                wire.write(f"{status}\n")
                wire.flush()
                return
            except OSError:
                gone.append(True)
        log(f"verdict non remis, client parti : {status}")

    pid, uid, gid = peer_of(conn)
    login = login_of(uid)
    if login is None:
        log(f"refus: uid {uid} (pid {pid}) n'a pas de compte unix")
        return done("FAIL:unknown_peer")

    # ⚠ ONLY THE LINE TERMINATOR IS STRIPPED: a `.strip()` here NORMALISES, so `install web-demo\t`
    # would be accepted and the wire format would quietly disagree with the form it claims to
    # enforce. At a privilege boundary, the tolerant reading is the wrong one.
    request = wire.readline().rstrip("\r\n")
    # Le delai de LECTURE a fait son travail : le geste qui suit dure des minutes, et une socket qui
    # expirerait pendant lui laisserait l'appelant sans verdict sur un travail REELLEMENT fait.
    conn.settimeout(None)
    verb, sep, name = request.partition(" ")

    if verb != "install" or not sep or not NAME_RX.fullmatch(name):
        log(f"refus: {login} a demande « {request} » — verbe ou nom invalide")
        return done("FAIL:bad_name")

    try:
        admin = forge_is_admin(login)
    except NoAuthority as exc:
        # ⚠ AVANT le filet large ci-dessous : c'est l'ORDRE des `except` qui rend la distinction
        # reelle, pas l'existence d'une classe a part.
        log(f"refus: cette boite n'a pas d'autorite utilisable — {exc}")
        return done("FAIL:no_authority")
    except (urllib.error.URLError, TimeoutError, socket.timeout, ValueError, OSError) as exc:
        log(f"refus: adminite de {login} non lue ({exc})")
        return done("FAIL:forge_unreachable")

    if not admin:
        log(f"refus: la forge dit que {login} n'est pas admin")
        return done("FAIL:not_admin")

    # ⚠ NON-BLOCKING, so a second caller gets a sentence instead of a hang. The gesture below takes
    # minutes; a queued caller would sit mute through someone else's install.
    if not _gesture_lock.acquire(blocking=False):
        log(f"refus: {login} demande « {name} » pendant un autre geste")
        return done("FAIL:busy")
    try:
        log(f"{login} installe « {name} »")
        rc = run_gesture(name, emit)
    finally:
        _gesture_lock.release()

    # ⚠ UN CODE NEGATIF N'EST PAS UN CODE DE SORTIE : `wait()` rend `-N` quand l'enfant a ete TUE par
    # le signal N, et le relayer tel quel donne un `exit -15` que bash rend en 241 — un nombre qui ne
    # designe rien. Les deux natures se nomment separement parce que les gestes different : un geste
    # qui ECHOUE se diagnostique, un geste INTERROMPU se rejoue.
    if rc < 0:
        log(f"interrompu: « {name} » pour {login} — signal {-rc}")
        return done(f"FAIL:gesture_signalled:{-rc}")
    if rc != 0:
        log(f"echec: « {name} » pour {login} (rc={rc})")
        return done(f"FAIL:gesture_failed:{rc}")
    log(f"fait: « {name} » pour {login}")
    return done("OK")


def bind(path=None):
    """
    The listening socket — the lifecycle lives in `lcars_socket`, written once.

    ⚠ CE CORPS PORTAIT CINQ GESTES ET UN PIEGE (une socket residuelle -> EADDRINUSE, muet). Il y en
    a maintenant DEUX dans ce process, et il y en aura un troisieme dans `lcars-privileged` : le
    cycle de vie se partage par un MODULE, jamais en recopiant. Ce qui ne se partage PAS est le
    process — un seul process pour tout retomberait sur une seule classe de confiance.
    """
    return lcars_socket.bind(path or SOCKET_PATH, SOCKET_GROUP, SOCKET_MODE, prefix="lcars-catalogue")


def serve_forever(srv, handler=None):
    handler = handler or serve_one
    while True:
        conn, _ = srv.accept()
        # ⚠ ONE THREAD PER CONNECTION, so that a refusal is instant even while a gesture runs. The
        # SERIALISATION lives on `_gesture_lock`, not on the accept loop: accepting one at a time
        # would make "busy" indistinguishable from "hung".
        threading.Thread(target=_guarded, args=(conn, handler), daemon=True).start()


def main():
    # ⚠ LE GARDE NOMME L'EXIGENCE, PAS LE MECANISME : elle est « je peux OUVRIR le jeton », jamais
    # « je suis root » — root n'etait que le moyen le moins cher d'y arriver. Enonce ainsi, le garde
    # refuse tot et juste sous n'importe quel uid, et ne devient pas faux le jour ou le service
    # descend de root.
    try:
        with open(MASTER_TOKEN_FILE, "r", encoding="utf-8"):
            pass
    except OSError as exc:
        log(f"je ne peux pas ouvrir {MASTER_TOKEN_FILE} ({exc.strerror}) — "
            f"ce service EST le detenteur de l'autorite de cette boite, il ne demarre pas sans elle")
        return 1
    if not FORGE_BASE_URL:
        log("aucun FORGE_BASE_URL — un jeton sans forge ne veut rien dire")
        return 2

    # DEUX SOCKETS, UN THREAD D'ACCEPT CHACUNE. La serialisation des GESTES vit sur
    # `_gesture_lock`, pas sur la boucle d'accept : accepter un a la fois rendrait « occupe »
    # indiscernable de « pendu », et un jeton de role n'a aucune raison d'attendre un `tofu apply`.
    portes = [(bind(SOCKET_PATH), serve_one, SOCKET_PATH),
              (bind(ROLES_SOCKET_PATH), serve_role_token, ROLES_SOCKET_PATH)]
    for _srv, _handler, _path in portes:
        log(f"a l'ecoute sur {_path} (0{SOCKET_MODE:o} {os.geteuid()}:{SOCKET_GROUP})")
    for _srv, _handler, _path in portes[:-1]:
        threading.Thread(target=serve_forever, args=(_srv, _handler), daemon=True).start()
    serve_forever(portes[-1][0], portes[-1][1])


def _guarded(conn, handler=None):
    handler = handler or serve_one
    try:
        # ⚠ UN PAIR QUI SE TAIT NE DOIT PAS RETENIR UN THREAD. Sans delai, une connexion ouverte et
        # muette bloque sur `readline` pour toujours : un membre du groupe pourrait en ouvrir autant
        # qu'il veut et epuiser ce service sans jamais formuler une demande. Le delai porte sur la
        # LECTURE de la requete ; il est retire juste apres, car le geste lui-meme dure des minutes.
        conn.settimeout(REQUEST_TIMEOUT)
        handler(conn)
    except Exception as exc:  # noqa: BLE001 -- one bad request must never take the door down
        log(f"requete abandonnee: {exc}")
    finally:
        try:
            conn.close()
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
