#!/usr/bin/env python3
# SOURCE: runtime/services/catalogue-executor.py
# AUTHOR: bob
# STARDATE: 2026-08-23
# STATUS: PROTO-V2 — the root side of `lcars catalogue install`: it holds the authority, the caller proves nothing
#         + `roles.sock` (un jeton de role) et `deposit.sock` (la boite de depot du deck)
#
# ─── WHY THIS PROCESS EXISTS ────────────────────────────────────────────────────────────────────
#
# IF THE CALLER'S SHELL HELD THE TOKEN, HOLDING IT WOULD BE THE PROOF -- so the token's mode would
# become the gate, so a unix group would have to carry `is_admin`, so a converger would have to
# project it, so a poll would have to refresh it, so a drift repair would have to fix consoles born
# before the projection. Split proving from executing and the whole chain is unnecessary: the
# caller holds nothing and proves nothing.
#
# NO SEAT IS PRIVILEGED -- not a name, not a uid, not a group. A path that skipped the question
# "because it is the seat" would be a second gate, therefore a second truth, therefore the drift
# again.
#
# WHY PYTHON, AND IT IS A DECISION: bash can neither listen on a unix socket nor call
# `getsockopt(SO_PEERCRED)`, and `socat` does not propagate the peer's credentials. Stdlib only, so
# this costs no new dependency.

import base64
import hashlib
import json
import os
import pwd
import re
import socket
import struct
import subprocess
import sys
import threading
import time
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
# would grant nobody anything, but it would offer this process to every account on the container for no gain.
SOCKET_GROUP = os.environ.get("LCARS_FLEET_GROUP", "fleet")
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
FORGE_ORG = os.environ.get("LCARS_FORGE_ORG", "fleet")
HUMANS_TEAM = os.environ.get("LCARS_HUMANS_TEAM", "humans")

# Un nom de compte de role est un nom de compte forge, et il devient un CHEMIN juste en dessous.
ROLE_RX = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
MASTER_TOKEN_FILE = os.environ.get("LCARS_MASTER_TOKEN_FILE", "/opt/lcars/var/tokens/forge-master.token")
GESTURES = os.environ.get("LCARS_FORGE_GESTURES", "/opt/lcars/forge-gestures.sh")
FORGE_BASE_URL = os.environ.get("FORGE_BASE_URL", "")
HTTP_TIMEOUT = int(os.environ.get("LCARS_CATALOGUE_HTTP_TIMEOUT", "15"))
# Le temps accorde a un pair pour FORMULER sa demande, pas pour que le geste s'accomplisse.
REQUEST_TIMEOUT = int(os.environ.get("LCARS_CATALOGUE_REQUEST_TIMEOUT", "30"))

# ─── LA BOITE DE DEPOT ──────────────────────────────────────────────────────────────────────────
#
# ⚠ CETTE PORTE N'EST PAS LES DEUX AUTRES, ET LA DIFFERENCE EST L'IDENTITE. `catalogue.sock` et
# `roles.sock` ne croient QUE le noyau : `SO_PEERCRED` nomme l'appelant et rien de ce qui arrive sur
# le fil ne peut le contredire. Ici l'appelant est le DECK — un service, pas une personne — et
# l'humain est celui que la forge a nomme a la porte OIDC. Le login arrive donc SUR LE FIL, affirme
# par un pair que le noyau, lui, nomme.
#
# CE QUE CE SERVICE AJOUTE A CETTE AFFIRMATION, et ce n'est pas rien :
#   · le pair DOIT etre le compte du deck, pas n'importe quel membre du groupe ;
#   · le login affirme DOIT etre de l'equipe humans, la forge interrogee a l'instant du geste ;
#   · le contenu DOIT correspondre a l'empreinte annoncee — deux recits qui se contredisent valent
#     mieux qu'un seul qu'on croit ;
#   · le depot est ecrit AU NOM de cet humain (auteur du commit) par le compte systeme (committer).
#
# CE QUE CE SERVICE NE PEUT PAS FAIRE, ET C'EST DIT PLUTOT QUE SOUS-ENTENDU : prouver que la
# personne etait devant l'ecran. Un deck compromis deposerait au nom d'un autre humain de l'equipe.
# L'attribution vaut ce que vaut la porte OIDC ; elle est traçable, elle n'est pas opposable.
DEPOSIT_SOCKET_PATH = os.environ.get("LCARS_DEPOSIT_SOCKET", "/run/lcars/deposit/deposit.sock")
# ⚠ LE GROUPE DE CE SERVICE, ET LE DECK LE RECOIT A L'EXEC. Trois groupes etaient possibles et deux
# sont refuses : `fleet` donnerait au deck les jetons de role, et `lcars-console` ne s'accorde par
# ADHESION a personne (MUR 5 ter : il se donne par `setpriv --groups`, jamais par `usermod -aG`).
# Reste le groupe de ce service : il ne porte que ses propres portes — ses secrets sont fermes au
# proprietaire (`/opt/lcars/var/tofu` en 0700) ou ouverts a `fleet` (`var/tokens` en 0710) — et
# `console-landing.sh` le passe au deck au lancement, comme il lui passe deja `lcars-console`.
# D'ou le repertoire A PART : `lcars_socket.bind` donne au PARENT le groupe qu'on lui passe, donc
# poser cette socket dans `/run/lcars/authority` retirerait `fleet` des deux autres portes.
DEPOSIT_SOCKET_GROUP = os.environ.get("LCARS_AUTHORITY_GROUP", "lcars-authority")
DEPOSIT_PEER = os.environ.get("LCARS_DECK_USER", "lcars-system")
READY_ROOM_REPO = os.environ.get("LCARS_READY_ROOM_REPO", f"{FORGE_ORG}/ready-room")
READY_ROOM_BRANCH = os.environ.get("LCARS_READY_ROOM_BRANCH", "main")
# Le compte qui POUSSE. L'humain est l'auteur, ce compte est le committer : c'est exactement la
# distinction que git porte depuis toujours — quelqu'un a fait le travail, quelqu'un d'autre l'a
# applique — et elle dit la verite des deux cotes sans inventer de jeton personnel.
SYSTEM_ACCOUNT = os.environ.get("LCARS_SYSTEM_ACCOUNT", "system_starfleet")
SYSTEM_TOKEN_FILE = os.environ.get(
    "LCARS_SYSTEM_TOKEN_FILE", os.path.join(ROLE_TOKENS_DIR, f"{SYSTEM_ACCOUNT}.gitea_token"))
# Le courriel decide de ce que la forge AFFICHE : un commit dont l'adresse d'auteur est celle du
# compte est rattache a la personne, avec son profil. Une adresse inventee rendrait un auteur
# orphelin, et la trace visible — celle qu'un humain lit sans requete — serait perdue.
HUMAN_EMAIL_DOMAIN = os.environ.get("LCARS_HUMAN_EMAIL_DOMAIN", "lcars.local")
# 8 Mio : de quoi deposer un document ou une capture, pas de quoi faire du depot une archive.
DEPOSIT_MAX_BYTES = int(os.environ.get("LCARS_DEPOSIT_MAX_BYTES", str(8 * 1024 * 1024)))
# UN NOM DE FICHIER, JAMAIS UN CHEMIN : le nom devient un segment d'URL et un chemin dans le depot.
# Ni `/`, ni `..`, ni nom cache, et une longueur bornee.
DEPOSIT_NAME_RX = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
# Le login affirme devient lui aussi un segment de chemin : meme forme que partout ailleurs.
LOGIN_RX = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")

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
    This container has no usable site-admin credential.

    ⚠ IT IS A CAUSE OF ITS OWN, NEVER MERGED INTO `OSError`. A bare `open()` whose caller catches
    `OSError` -- which `FileNotFoundError` and `PermissionError` both inherit from -- turns an
    absent, unreadable, empty or REVOKED token into `forge_unreachable`, and tells the operator
    "the forge is perhaps restarting, retry" about a forge in perfect health (measured 2026-08-24,
    all four cases).

    The two remedies are OPPOSITE, which is what makes the merge expensive: a mute forge is retried,
    a missing authority is RE-POSED by an admin. Nothing the operator can do fixes the first, and
    retrying forever fixes neither.
    """


def master_token():
    """
    The site-admin credential, read fresh at each request.

    Read at each request and not cached at startup, so a rotated token is picked up without a
    restart. Raises NoAuthority when this container cannot produce one -- never a bare OSError, which the
    caller would read as "the forge did not answer".
    """
    try:
        with open(MASTER_TOKEN_FILE, "r", encoding="utf-8") as fh:
            token = fh.read().strip()
    except OSError as exc:
        raise NoAuthority(f"{MASTER_TOKEN_FILE} illisible ({exc.strerror})") from exc
    # ⚠ VIDE N'EST PAS ABSENT, ET C'EST LE MEME MANQUE. Un fichier vide part sur le fil comme un
    # en-tete sans jeton, la forge rend 401, et sans ce garde la cause devient « forge muette ».
    # `forge-gestures.sh cmd_install` fait le meme controle de son cote.
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
        # `HTTPError` DERIVE de `URLError` : un `except URLError` seul l'y rangerait.
        if exc.code in (401, 403):
            raise NoAuthority(f"la forge REFUSE le jeton de ce conteneur (HTTP {exc.code})") from exc
        raise


def is_fleet_human(login):
    """
    Does the forge say this login is a member of the org's `humans` team?

    ⚠ A UNIX GROUP WOULD ANSWER THIS QUESTION STALE: `fleet` is populated from this very team by
    the converger, every 30s, so a role token readable by the group stays readable by someone the
    forge has since removed, until the next tick and until every one of their live processes dies.

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
            raise NoAuthority(f"la forge REFUSE le jeton de ce conteneur (HTTP {exc.code})") from exc
        raise


def _forge_json(path):
    url = f"{FORGE_BASE_URL.rstrip('/')}{path}"
    req = urllib.request.Request(url, headers={"Authorization": f"token {master_token()}"})
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise NoAuthority(f"la forge REFUSE le jeton de ce conteneur (HTTP {exc.code})") from exc
        raise


def serve_role_token(conn):
    """
    One request, one role token — or one named cause.

        -> <role account>
        <- the token, one line
        <- "FAIL:<cause>"

    ⚠ CE QU'ON REND EST UN CREDENTIAL, ET C'EST UN RECUL ASSUME PAR RAPPORT A `catalogue.sock`.
    La, le service AGIT et rien ne sort ; ici il DONNE. Ce qui le rend defendable est le point de
    depart, pas une propriete absolue : aujourd'hui le fichier est lisible par tout humain du
    conteneur. Une socket qui demande a la forge et sait QUI a demande est strictement meilleure — mais
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
        log(f"refus roles: ce conteneur n'a pas d'autorite utilisable — {exc}")
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


def system_token():
    """
    Le jeton du compte SYSTEME — celui qui pousse, jamais celui qui signe un contenu.

    Lu a chaque requete comme le jeton master, et pour la meme raison : une rotation ne doit pas
    demander un redemarrage. `NoAuthority` et jamais un `OSError` nu — un depot refuse parce que le
    jeton manque et un depot refuse par la forge appellent des gestes opposes.
    """
    try:
        with open(SYSTEM_TOKEN_FILE, "r", encoding="utf-8") as fh:
            token = fh.read().strip()
    except OSError as exc:
        raise NoAuthority(f"{SYSTEM_TOKEN_FILE} illisible ({exc.strerror})") from exc
    if not token:
        raise NoAuthority(f"{SYSTEM_TOKEN_FILE} est VIDE")
    return token


def deposit_message(login, name, digest):
    """
    Le message du commit, et la SECONDE trace.

    L'auteur du commit porte deja l'attribution ; la remorque la reecrit en clair, avec l'empreinte
    du contenu. Elle survit a un rebase, elle se lit sans interroger la forge, et elle se recoupe
    avec le journal de ce service. Deux recits independants : s'ils divergent un jour, on saura
    lequel a menti.
    """
    return (f"depot({login}): {name}\n"
            f"\n"
            f"Deposited-by: {login}\n"
            f"Deposit-Sha256: {digest}\n"
            f"Deposit-Via: deck\n")


def forge_put_file(repo, path, content_b64, message, login):
    """
    Ecrit un fichier dans un depot par l'API de contenu (`POST /contents/<chemin>`), au nom de `login`.

    POST, ET PAS PUT : la creation refuse un chemin deja pris, la mise a jour l'ecrase. Un depot ne
    remplace jamais un depot precedent — l'horodatage du chemin rend la collision improbable, et la
    forge tranche si elle arrive quand meme.

    L'AUTEUR EST L'HUMAIN, LE COMMITTER EST LE COMPTE SYSTEME. C'est la reponse entiere a
    « qui a pousse quoi » : la forge affiche l'humain sur le commit et journalise le compte systeme
    sur la poussee. Aucun jeton personnel n'existe dans ce conteneur, et aucun n'est invente ici.

    Rend le sha du commit. `NoAuthority` si la forge refuse notre jeton, `HTTPError` sinon — la
    distinction est celle des autres portes, et pour la meme raison.
    """
    owner, _, name = repo.partition("/")
    url = (f"{FORGE_BASE_URL.rstrip('/')}/api/v1/repos/"
           f"{urllib.parse.quote(owner, safe='')}/{urllib.parse.quote(name, safe='')}/contents/"
           f"{urllib.parse.quote(path)}")
    body = json.dumps({
        "content": content_b64,
        "message": message,
        "branch": READY_ROOM_BRANCH,
        "author": {"name": login, "email": f"{login}@{HUMAN_EMAIL_DOMAIN}"},
        "committer": {"name": SYSTEM_ACCOUNT, "email": f"{SYSTEM_ACCOUNT}@{HUMAN_EMAIL_DOMAIN}"},
    }).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Authorization": f"token {system_token()}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            answer = json.load(resp)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise NoAuthority(f"la forge REFUSE le jeton systeme (HTTP {exc.code})") from exc
        raise
    # ⚠ UN 2xx N'EST PAS UNE PREUVE DE FORME. On rend le sha que la forge nomme, ou on le dit : un
    # `OK` sans sha laisserait l'appelant annoncer un depot qu'il ne peut pas retrouver.
    sha = (answer.get("commit") or {}).get("sha")
    if not isinstance(sha, str) or not sha:
        raise ValueError("la forge a accepte sans nommer de commit")
    return sha


def forge_ensure_repo(repo):
    """
    Cree le depot de la ready room s'il n'existe pas, et rend True s'il a fallu le creer.

    ⚠ CREER PLUTOT QUE REFUSER, ET C'EST UN ARBITRAGE. Un depot qui refuse « le depot n'existe pas »
    jusqu'a ce qu'un admin joue un geste manuel est une fonctionnalite livree a moitie : personne ne
    la decouvre au bon moment. Le compte systeme a DEJA le droit de creer dans l'org (recette de la
    forge, `can_create_repos = true` pour l'equipe `system`) — la creation ne prend donc aucun
    pouvoir nouveau, elle utilise celui qui existe.
    ⚠ PRIVE ET INITIALISE : prive parce qu'un depot de fichiers deposes n'a aucune raison d'etre
    public, initialise parce que l'API de contenu ecrit SUR UNE BRANCHE — un depot vide n'a pas de
    `main`, et le premier depot echouerait sur une branche absente.
    """
    owner, _, name = repo.partition("/")
    base = f"{FORGE_BASE_URL.rstrip('/')}/api/v1"
    url = f"{base}/repos/{urllib.parse.quote(owner, safe='')}/{urllib.parse.quote(name, safe='')}"
    req = urllib.request.Request(url, headers={"Authorization": f"token {system_token()}"})
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT):
            return False
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise NoAuthority(f"la forge REFUSE le jeton systeme (HTTP {exc.code})") from exc
        if exc.code != 404:
            raise

    body = json.dumps({"name": name, "private": True, "auto_init": True,
                       "default_branch": READY_ROOM_BRANCH,
                       "description": "Ready room : ce que les humains deposent depuis le deck"
                       }).encode("utf-8")
    req = urllib.request.Request(f"{base}/orgs/{urllib.parse.quote(owner, safe='')}/repos",
                                 data=body, method="POST",
                                 headers={"Authorization": f"token {system_token()}",
                                          "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT):
        pass
    log(f"depot: {repo} n'existait pas — cree (prive, initialise sur {READY_ROOM_BRANCH})")
    return True


def serve_deposit(conn):
    """
    Un depot, un verdict.

        -> deposit <login> <sha256> <nom de fichier>
        -> <contenu en base64, UNE ligne>
        <- "OK:<sha du commit> <chemin dans le depot>"
        <- "FAIL:<cause>"

    La cause est un JETON, pas une phrase : le deck possede les mots de l'operateur, parce que c'est
    lui que l'operateur regarde. Meme regle que `catalogue.sock`, et les causes ne se melangent pas.
    """
    wire = conn.makefile("rw", encoding="utf-8", newline="\n")

    def done(status):
        try:
            wire.write(f"{status}\n")
            wire.flush()
        except OSError:
            log(f"verdict de depot non remis, client parti : {status.split(':')[0]}")

    pid, uid, _gid = peer_of(conn)
    peer = login_of(uid)
    if peer is None:
        log(f"refus depot: uid {uid} (pid {pid}) n'a pas de compte unix")
        return done("FAIL:unknown_peer")
    # ⚠ L'ACL DE LA SOCKET BORNE QUI FRAPPE, ELLE N'AUTORISE RIEN. Le groupe `lcars-console` porte
    # aussi les consoles ; seul le compte du deck relaie une identite, et on le nomme.
    if peer != DEPOSIT_PEER:
        log(f"refus depot: le pair est « {peer} », pas le deck ({DEPOSIT_PEER})")
        return done("FAIL:not_the_deck")

    request = wire.readline().rstrip("\r\n")
    verb, _, rest = request.partition(" ")
    login, _, rest = rest.partition(" ")
    digest, _, name = rest.partition(" ")
    if verb != "deposit" or not LOGIN_RX.fullmatch(login or ""):
        log(f"refus depot: requete « {request[:80]} » — verbe ou login invalide")
        return done("FAIL:bad_login")
    if not DEPOSIT_NAME_RX.fullmatch(name or ""):
        log(f"refus depot: {login} a nomme « {name[:80]} » — pas un nom de fichier")
        return done("FAIL:bad_name")
    if not re.fullmatch(r"[0-9a-f]{64}", digest or ""):
        log(f"refus depot: {login} a annonce une empreinte qui n'en est pas une")
        return done("FAIL:bad_digest")

    # ⚠ LA LIGNE EST BORNEE AVANT D'ETRE DECODEE. `readline()` sans borne laisse un pair remplir la
    # memoire de ce service avec une seule ligne ; la borne porte donc sur les octets du FIL, d'ou
    # la marge du base64 (4 octets pour 3) et de la fin de ligne.
    ceiling = (DEPOSIT_MAX_BYTES * 4) // 3 + 1024
    payload = wire.readline(ceiling + 1).rstrip("\r\n")
    conn.settimeout(None)
    if len(payload) > ceiling:
        log(f"refus depot: {login} envoie plus que {DEPOSIT_MAX_BYTES} octets")
        return done("FAIL:too_big")
    try:
        raw = base64.b64decode(payload, validate=True)
    except (ValueError, TypeError):
        log(f"refus depot: le contenu de {login} n'est pas du base64")
        return done("FAIL:bad_base64")
    if len(raw) > DEPOSIT_MAX_BYTES:
        log(f"refus depot: {login} envoie {len(raw)} octets, la borne est {DEPOSIT_MAX_BYTES}")
        return done("FAIL:too_big")
    if not raw:
        log(f"refus depot: {login} envoie un fichier vide")
        return done("FAIL:empty")
    # LE CONTENU EST RECOUPE CONTRE L'EMPREINTE ANNONCEE, et ce n'est pas de la defense en
    # profondeur : c'est ce qui rend les deux traces independantes. Le deck journalise l'empreinte
    # qu'il a calculee, ce service verifie celle qu'il recoit ; un relais qui altere en passant se
    # denonce ici.
    got = hashlib.sha256(raw).hexdigest()
    if got != digest:
        log(f"refus depot: {login} annonce {digest[:12]}… et envoie {got[:12]}…")
        return done("FAIL:hash_mismatch")

    try:
        if not is_fleet_human(login):
            log(f"refus depot: la forge dit que {login} n'est pas de l'equipe {HUMANS_TEAM}")
            return done("FAIL:not_a_worker")
    except NoAuthority as exc:
        log(f"refus depot: ce conteneur n'a pas d'autorite utilisable — {exc}")
        return done("FAIL:no_authority")
    except (urllib.error.URLError, TimeoutError, socket.timeout, ValueError, OSError) as exc:
        log(f"refus depot: appartenance de {login} non lue ({exc})")
        return done("FAIL:forge_unreachable")

    # UN DEPOT, UN CHEMIN, ET L'HORODATAGE EST DEVANT : deux depots du meme nom ne s'ecrasent pas,
    # et le classement d'un repertoire est chronologique sans rien lire.
    path = f"{login}/{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{name}"
    message = deposit_message(login, name, got)
    try:
        try:
            sha = forge_put_file(READY_ROOM_REPO, path, payload, message, login)
        except urllib.error.HTTPError as exc:
            # ⚠ UN SEUL REJEU, ET SEULEMENT SUR 404. Le depot manquant est la seule cause qu'on
            # sache reparer ici ; rejouer sur autre chose ferait deux ecritures pour une demande.
            if exc.code != 404 or not forge_ensure_repo(READY_ROOM_REPO):
                raise
            sha = forge_put_file(READY_ROOM_REPO, path, payload, message, login)
    except NoAuthority as exc:
        log(f"refus depot: {exc}")
        return done("FAIL:no_authority")
    except urllib.error.HTTPError as exc:
        # 404 APRES la tentative de creation = ni le depot ni l'org ne repondent ; le reste est un
        # refus de la forge sur ce contenu ou ce chemin. Les nommer separement evite d'envoyer
        # l'operateur creer un depot qui existe.
        cause = "no_repo" if exc.code == 404 else f"forge_refused:{exc.code}"
        log(f"refus depot: la forge refuse {READY_ROOM_REPO}/{path} (HTTP {exc.code})")
        return done(f"FAIL:{cause}")
    except (urllib.error.URLError, TimeoutError, socket.timeout, ValueError, OSError) as exc:
        log(f"refus depot: depot de {login} non ecrit ({exc})")
        return done("FAIL:forge_unreachable")

    log(f"depot: {login} a depose « {name} » ({len(raw)} o, sha256 {got[:12]}…) "
        f"dans {READY_ROOM_REPO}/{path} — commit {sha[:12]}")
    return done(f"OK:{sha} {path}")


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
        log(f"refus: ce conteneur n'a pas d'autorite utilisable — {exc}")
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


def bind(path=None, group=None):
    """
    The listening socket — the lifecycle lives in `lcars_socket`, written once.

    ⚠ CINQ GESTES ET UN PIEGE (une socket residuelle -> EADDRINUSE, muet), ecrits UNE fois : trois
    sockets dans ce process, une quatrieme dans `lcars-privileged`, et le cycle de vie se partage par
    un MODULE, jamais en recopiant. Ce qui ne se partage PAS est le process — un seul process pour
    tout retomberait sur une seule classe de confiance.
    """
    return lcars_socket.bind(path or SOCKET_PATH, group or SOCKET_GROUP, SOCKET_MODE,
                            prefix="lcars-catalogue")


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
    # « je suis root » — root n'est que le moyen le moins cher d'y arriver. Enonce ainsi, le garde
    # refuse tot et juste sous n'importe quel uid, et ne devient pas faux le jour ou le service
    # descend de root.
    try:
        with open(MASTER_TOKEN_FILE, "r", encoding="utf-8"):
            pass
    except OSError as exc:
        log(f"je ne peux pas ouvrir {MASTER_TOKEN_FILE} ({exc.strerror}) — "
            f"ce service EST le detenteur de l'autorite de ce conteneur, il ne demarre pas sans elle")
        return 1
    if not FORGE_BASE_URL:
        log("aucun FORGE_BASE_URL — un jeton sans forge ne veut rien dire")
        return 2

    # ⚠ LE JETON SYSTEME N'EST PAS UNE CONDITION DE DEMARRAGE, contrairement a l'autorite : deux
    # portes sur trois n'en ont aucun usage. Son absence se dit ici et redevient une cause nommee au
    # moment du depot — refuser de demarrer fermerait le catalogue pour un manque qui ne le concerne
    # pas.
    try:
        with open(SYSTEM_TOKEN_FILE, "r", encoding="utf-8"):
            pass
    except OSError as exc:
        log(f"{SYSTEM_TOKEN_FILE} illisible ({exc.strerror}) — la boite de depot refusera, "
            f"les deux autres portes n'en dependent pas")

    # TROIS SOCKETS, UN THREAD D'ACCEPT CHACUNE. La serialisation des GESTES vit sur
    # `_gesture_lock`, pas sur la boucle d'accept : accepter un a la fois rendrait « occupe »
    # indiscernable de « pendu », et ni un jeton de role ni un depot n'ont a attendre un
    # `tofu apply`.
    # ⚠ LA TROISIEME PORTE A SON GROUPE ET SON REPERTOIRE. Les deux premieres s'ouvrent a `fleet`,
    # donc aux humains du conteneur ; celle-ci s'ouvre au DECK, qui n'est pas de `fleet` et ne doit
    # pas y entrer. Comme `lcars_socket.bind` donne au PARENT le groupe qu'on lui passe, les poser
    # dans un meme repertoire retirerait `fleet` des deux premieres — c'est une mesure du cycle de
    # vie partage, pas une precaution de principe.
    portes = [(bind(SOCKET_PATH), serve_one, SOCKET_PATH, SOCKET_GROUP),
              (bind(ROLES_SOCKET_PATH), serve_role_token, ROLES_SOCKET_PATH, SOCKET_GROUP),
              (bind(DEPOSIT_SOCKET_PATH, DEPOSIT_SOCKET_GROUP), serve_deposit,
               DEPOSIT_SOCKET_PATH, DEPOSIT_SOCKET_GROUP)]
    for _srv, _handler, _path, _group in portes:
        log(f"a l'ecoute sur {_path} (0{SOCKET_MODE:o} {os.geteuid()}:{_group})")
    for _srv, _handler, _path, _group in portes[:-1]:
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
