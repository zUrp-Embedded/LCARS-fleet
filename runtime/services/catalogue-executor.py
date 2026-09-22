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
import urllib.error
import urllib.parse
import urllib.request

# ⚠ LE MODULE VOISIN, PAS UN PAQUET : `lcars_socket.py` est POSE a cote de ce fichier par les deux
# rails, et c'est ce qui rend l'import valide sans installation.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lcars_facts  # noqa: E402 -- meme condition : le module voisin, pose par les deux rails
import lcars_socket  # noqa: E402 -- apres le sys.path, c'est la condition de l'import

# ⚠ SOUS `/run/lcars/authority/`, PAS `/run/lcars/` : ce service n'est pas root et ne peut rien
# creer dans un `0755 root:root`. Le repertoire est declare au manifeste ET au `tmpfiles.d` — `/run`
# est un tmpfs, ce qui n'y est pas declare ne se refait pas au reboot.
SOCKET_PATH = os.environ.get("LCARS_CATALOGUE_SOCKET", "/run/lcars/authority/catalogue.sock")
# THE SOCKET'S ACL CARRIES NO AUTHORIZATION -- it only bounds who may KNOCK. Opening it to the world
# would grant nobody anything, but it would offer this process to every account on the container for no gain.
SOCKET_GROUP = lcars_facts.get("LCARS_FLEET_GROUP")
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
FORGE_ORG = lcars_facts.get("LCARS_FORGE_ORG")
HUMANS_TEAM = lcars_facts.get("LCARS_HUMANS_TEAM")

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
# ⚠ ET CE SERVICE NE REJUGE PAS L'IDENTITE, C'EST UN ARBITRAGE (user, 2026-09-18). Le deck REFUSE
# d'ouvrir une session sans la forge : l'appartenance a l'equipe est deja etablie quand la requete
# arrive ici. La redemander ne fermerait aucun scenario reel — la liste des projets proposes vient
# des pods de la fleet de cette personne, donc d'un projet sur lequel elle travaille — et un deck
# compromis affirmerait de toute facon un login legitime. La fraicheur d'une session et un poste
# non verrouille sont la securite du DECK ; ce service en est le client, il reste a sa place.
#
# CE QUE CE SERVICE GARDE, parce que c'est SA responsabilite et pas celle du voisin :
#   · le pair DOIT etre le compte du deck, pas n'importe quel membre du groupe ;
#   · le nom DOIT etre un nom de fichier, jamais un chemin — il devient un chemin dans le depot ;
#   · la taille DOIT tenir dans la borne, mesuree sur le fichier et pas sur ce qu'on annonce ;
#   · le contenu DOIT correspondre a l'empreinte annoncee — deux recits qui se contredisent valent
#     mieux qu'un seul qu'on croit ;
#   · le depot du projet DOIT exister : on ne cree pas un depot de projet.
#
# Et le depot est ecrit AU NOM de cet humain (auteur du commit) par le compte systeme (committer).
DEPOSIT_SOCKET_PATH = lcars_facts.get("LCARS_DEPOSIT_SOCKET")
# ⚠ LE GROUPE DE CE SERVICE, ET LE DECK LE RECOIT A L'EXEC. Trois groupes etaient possibles et deux
# sont refuses : `fleet` donnerait au deck les jetons de role, et `lcars-console` ne s'accorde par
# ADHESION a personne (MUR 5 ter : il se donne par `setpriv --groups`, jamais par `usermod -aG`).
# Reste le groupe de ce service : il ne porte que ses propres portes — ses secrets sont fermes au
# proprietaire (`/opt/lcars/var/tofu` en 0700) ou ouverts a `fleet` (`var/tokens` en 0710) — et
# `console-landing.sh` le passe au deck au lancement, comme il lui passe deja `lcars-console`.
# D'ou le repertoire A PART : `lcars_socket.bind` donne au PARENT le groupe qu'on lui passe, donc
# poser cette socket dans `/run/lcars/authority` retirerait `fleet` des deux autres portes.
# LE GROUPE SE DERIVE DU COMPTE, il ne se declare pas une seconde fois (MUR 13).
DEPOSIT_SOCKET_GROUP = lcars_facts.get("LCARS_AUTHORITY_USER")
DEPOSIT_PEER = lcars_facts.get("LCARS_SYSTEM_USER")
# LA DESTINATION EST LE DEPOT DU PROJET, ET SA FACE WORKSHOP. Un projet a UN depot sur la forge et
# trois faces qui sont trois BRANCHES de ce depot (`lib/fleet/layout.ex`) ; la ready room est un
# repertoire de la face workshop. Le chemin ne porte ni login ni horodatage : le commit porte deja
# l'auteur et la date, les repeter dans le chemin serait une seconde verite qui derive.
# ⚠ LE NOM DE LA BRANCHE EST FIGE, ET IL NE SE LIT PAS DANS L'ENVIRONNEMENT. L'autorite est
# `Fleet.Layout.workshop_branch/0` ; cette copie est un miroir, tenu par le mur
# `layout.workshop_branch_single_source` — meme regle que la branche d'outillage, pour la meme
# raison : un nom que la moitie du rail peut retuner est un rail qui se fend en silence.
WORKSHOP_BRANCH = "workshop"
# La ready room est un repertoire de cette face, et ce service en est le seul ecrivain : le nom vit
# ICI, une fois. Le deck ne le recopie pas — il lit le chemin que ce service lui rend.
READY_ROOM_DIR = "ready-room"
# ⚠ L'ORG D'UN PROJET EST LE NOM DU CATALOGUE QUI LE DECLARE, et elle est fixee a vie. Le pod ne
# rend que le slug : c'est ici qu'on retrouve l'org, en demandant a la forge lequel des catalogues
# INSTALLES porte ce depot. Deviner l'org serait une table de correspondance, donc une seconde
# verite ; demander a la forge ne peut pas deriver.
CATALOGUES_DIR = lcars_facts.get("LCARS_CATALOGUES_DIR")
# LA ZONE DE TRANSIT : le deck y ecrit le fichier, ce service l'y lit, et RIEN d'autre n'en sort.
# Sur disque et jamais sous `/run` — c'est un tmpfs, donc 50 Mo de transit y seraient 50 Mo de RAM.
DEPOSIT_SPOOL = lcars_facts.get("LCARS_DEPOSIT_SPOOL")
# Le temps d'un depot n'est pas le temps d'une question : 50 Mo ne traversent pas en 15 secondes.
DEPOSIT_HTTP_TIMEOUT = int(os.environ.get("LCARS_DEPOSIT_HTTP_TIMEOUT", "300"))
# Le compte qui POUSSE. L'humain est l'auteur, ce compte est le committer : c'est exactement la
# distinction que git porte depuis toujours — quelqu'un a fait le travail, quelqu'un d'autre l'a
# applique — et elle dit la verite des deux cotes sans inventer de jeton personnel.
SYSTEM_ACCOUNT = lcars_facts.get("LCARS_SYSTEM_ACCOUNT")
SYSTEM_TOKEN_FILE = os.environ.get(
    "LCARS_SYSTEM_TOKEN_FILE", os.path.join(ROLE_TOKENS_DIR, f"{SYSTEM_ACCOUNT}.gitea_token"))
# Le courriel decide de ce que la forge AFFICHE : un commit dont l'adresse d'auteur est celle du
# compte est rattache a la personne, avec son profil. Une adresse inventee rendrait un auteur
# orphelin, et la trace visible — celle qu'un humain lit sans requete — serait perdue.
HUMAN_EMAIL_DOMAIN = os.environ.get("LCARS_HUMAN_EMAIL_DOMAIN", "lcars.local")
# 50 Mo, la meme borne des deux cotes. Elle vit dans le code des deux processus et se surcharge par
# l'environnement : une borne que le deck croit plus haute que la porte ne fait que deplacer le
# refus, elle ne laisse rien passer.
# ⚠ LE PLAFOND EST UN REGLAGE, PAS UNE RECOMPILATION : le fait porte le defaut, l'installeur le
# transporte quand l'operateur le change, et l'environnement gagne sur le fait.
DEPOSIT_MAX_BYTES = int(lcars_facts.get("LCARS_DEPOSIT_MAX_BYTES"))
# UN NOM DE FICHIER, JAMAIS UN CHEMIN : le nom devient un segment d'URL et un chemin dans le depot.
# Ni `/`, ni `..`, ni nom cache, et une longueur bornee.
# Une ready room que personne ne purge finit par etre longue : on la parcourt page par page, mais
# pas indefiniment — au-dela, le remplacement se dit impossible plutot que de boucler.
DEPOSIT_LISTING_MAX = int(os.environ.get("LCARS_DEPOSIT_LISTING_MAX", "5000"))
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


def installed_orgs():
    """
    Les catalogues installes sur cette machine, donc les orgs possibles d'un projet.

    ⚠ LE NOM SE LIT DANS LE MANIFESTE, ET LE REPERTOIRE EST UN REPLI. Le produit lit la meme
    arborescence (`Fleet.Catalogue.installed_catalogues/0`) : un repertoire par catalogue, un
    `catalogue.yaml` dedans, le nom a l'interieur. Pas de YAML ici — une seule scalaire est lue par
    motif, et le nom du repertoire sert quand la ligne manque.
    """
    noms = []
    try:
        entrees = sorted(os.listdir(CATALOGUES_DIR))
    except OSError as exc:
        log(f"catalogues illisibles ({CATALOGUES_DIR}: {exc.strerror})")
        return noms
    for entree in entrees:
        manifeste = os.path.join(CATALOGUES_DIR, entree, "catalogue.yaml")
        nom = entree
        try:
            with open(manifeste, "r", encoding="utf-8") as fh:
                for ligne in fh:
                    trouve = re.match(r"name:\s*\"?([A-Za-z0-9][A-Za-z0-9-]*)\"?\s*$", ligne)
                    if trouve:
                        nom = trouve.group(1)
                        break
        except OSError:
            continue
        if nom not in noms:
            noms.append(nom)
    return noms


def resolve_project(slug):
    """
    `<org>/<slug>` — l'org est celle du catalogue qui porte ce depot sur la forge.

    Rend le nom complet, ou leve `LookupError` avec une cause : `unknown_project` quand aucun
    catalogue installe ne porte ce depot, `ambiguous_project` quand plusieurs le portent. On ne
    CHOISIT pas a la place de l'humain : l'org d'un projet est fixee a vie, en deviner une reviendrait
    a deposer dans un autre projet que celui qu'il a nomme.
    """
    trouves = []
    for org in installed_orgs():
        url = (f"{FORGE_BASE_URL.rstrip('/')}/api/v1/repos/"
               f"{urllib.parse.quote(org, safe='')}/{urllib.parse.quote(slug, safe='')}")
        req = urllib.request.Request(url, headers={"Authorization": f"token {system_token()}"})
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT):
                trouves.append(f"{org}/{slug}")
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                raise NoAuthority(f"la forge REFUSE le jeton systeme (HTTP {exc.code})") from exc
            if exc.code != 404:
                raise
    if not trouves:
        raise LookupError("unknown_project")
    if len(trouves) > 1:
        log(f"depot: « {slug} » existe dans {len(trouves)} catalogues : {', '.join(trouves)}")
        raise LookupError("ambiguous_project")
    return trouves[0]


def blob_sha(repo, branch, dossier, nom):
    """
    Le sha du blob DEJA en place dans `dossier`, ou None.

    ⚠ LE LISTAGE DU REPERTOIRE, NI L'ARBRE NI LE CONTENU. Trois formes existaient, deux sont des
    pieges : `GET /contents/<fichier>` rendrait le fichier ENCODE — demander si un fichier de 50 Mo
    existe en le telechargeant ne se voit qu'en production ; `git/trees/<branche>?recursive` compte
    TOUTE la face et se tronque au-dela d'une page, donc rendrait « absent » pour un fichier bien la.
    Le listage d'un repertoire ne parle que de la ready room.

    ⚠ ET IL SE PAGINE QUAND MEME. Une ready room que personne ne purge finit par depasser une page ;
    une reponse tronquee lue comme complete rendrait « absent », et le remplacement deviendrait un
    refus de la forge. On suit donc `Link: rel="next"` jusqu'au bout, comme le client de forge du
    produit le fait de son cote.

    Un dossier absent (404) rend None : c'est un premier depot, pas une panne.
    """
    owner, _, name = repo.partition("/")
    url = (f"{FORGE_BASE_URL.rstrip('/')}/api/v1/repos/"
           f"{urllib.parse.quote(owner, safe='')}/{urllib.parse.quote(name, safe='')}/contents/"
           f"{urllib.parse.quote(dossier)}?ref={urllib.parse.quote(branch, safe='')}")
    vues = 0
    while url:
        req = urllib.request.Request(url, headers={"Authorization": f"token {system_token()}"})
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
                entrees = json.load(resp)
                suivante = _lien_suivant(resp.headers.get("Link"))
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise
        # ⚠ UNE LISTE, PAS UN OBJET : la meme route rend un OBJET quand le chemin est un FICHIER. Si
        # la ready room etait un fichier, on ne saurait pas quoi remplacer — et on ne le devine pas.
        if not isinstance(entrees, list):
            return None
        for entree in entrees:
            if entree.get("name") == nom and entree.get("type") == "file":
                return entree.get("sha")
        vues += len(entrees)
        # Une pagination qui ne s'arrete pas est une boucle : on la borne et on le dit.
        if vues > DEPOSIT_LISTING_MAX:
            log(f"depot: {repo} {dossier} depasse {DEPOSIT_LISTING_MAX} entrees — listage abandonne")
            raise LookupError("listing_too_long")
        url = suivante
    return None


def _lien_suivant(entete):
    """L'URL de la page suivante d'un `Link:` RFC 8288, ou None. Rien d'autre n'est interprete."""
    for morceau in (entete or "").split(","):
        cible, _, params = morceau.partition(">")
        if 'rel="next"' in params and "<" in cible:
            return cible[cible.index("<") + 1:].strip()
    return None


def _b64_body(prefix, spool, suffix, chunk=3 * 65536):
    """Le corps JSON, par morceaux : l'entete, le contenu encode au fil du fichier, la fermeture."""
    yield prefix
    with open(spool, "rb") as fh:
        while True:
            brut = fh.read(chunk)
            if not brut:
                break
            yield base64.b64encode(brut)
    yield suffix


def forge_put_file(repo, path, spool, taille, message, login, sha=None):
    """
    Ecrit un fichier dans un depot par l'API de contenu, au nom de `login`, SANS le charger.

    ⚠ LE CORPS EST STREAME, ET C'EST CE QUI REND 50 Mo TENABLES. L'API veut du base64 dans du JSON ;
    la longueur d'un base64 se calcule (`4×⌈n/3⌉`), donc on annonce la bonne `Content-Length` et on
    encode le fichier par morceaux. Sans ca, un depot de 50 Mo existerait trois fois en memoire.

    POST cree, PUT remplace : un `sha` fourni est celui du blob en place, et le remplacement est un
    NOUVEAU commit — l'ancien contenu reste dans l'historique, c'est le travail de git.

    L'AUTEUR EST L'HUMAIN, LE COMMITTER EST LE COMPTE SYSTEME : la forge affiche l'humain sur le
    commit et journalise le compte systeme sur la poussee.
    """
    owner, _, name = repo.partition("/")
    url = (f"{FORGE_BASE_URL.rstrip('/')}/api/v1/repos/"
           f"{urllib.parse.quote(owner, safe='')}/{urllib.parse.quote(name, safe='')}/contents/"
           f"{urllib.parse.quote(path)}")
    tete = {
        "message": message,
        "branch": WORKSHOP_BRANCH,
        "author": {"name": login, "email": f"{login}@{HUMAN_EMAIL_DOMAIN}"},
        "committer": {"name": SYSTEM_ACCOUNT, "email": f"{SYSTEM_ACCOUNT}@{HUMAN_EMAIL_DOMAIN}"},
    }
    if sha:
        tete["sha"] = sha
    # Le prefixe est le JSON sans le contenu, ouvert sur la chaine ; `content` FERME l'objet.
    prefix = json.dumps(tete)[:-1].encode("utf-8") + b', "content": "'
    suffix = b'"}'
    longueur = len(prefix) + 4 * ((taille + 2) // 3) + len(suffix)
    req = urllib.request.Request(
        url, data=_b64_body(prefix, spool, suffix), method=("PUT" if sha else "POST"),
        headers={"Authorization": f"token {system_token()}",
                 "Content-Type": "application/json",
                 "Content-Length": str(longueur)})
    try:
        with urllib.request.urlopen(req, timeout=DEPOSIT_HTTP_TIMEOUT) as resp:
            answer = json.load(resp)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise NoAuthority(f"la forge REFUSE le jeton systeme (HTTP {exc.code})") from exc
        raise
    # ⚠ UN 2xx N'EST PAS UNE PREUVE DE FORME. On rend le sha que la forge nomme, ou on le dit : un
    # `OK` sans sha laisserait l'appelant annoncer un depot qu'il ne peut pas retrouver.
    commit = (answer.get("commit") or {}).get("sha")
    if not isinstance(commit, str) or not commit:
        raise ValueError("la forge a accepte sans nommer de commit")
    return commit


def spool_bounded(chemin):
    """
    Le fichier de transit, ou None si ce chemin n'est pas dans la zone de transit.

    ⚠ LE CHEMIN VIENT D'UN AUTRE PROCESSUS, ET C'EST LA GARDE LA PLUS IMPORTANTE DE CE VERBE. Ce
    service tourne avec l'autorite du conteneur : un chemin qu'il ouvrirait sans le borner pourrait
    designer `/opt/lcars/var/tokens/...` — et le contenu partirait en commit, dans un depot, pour
    toujours. La zone de transit est declaree a la table ; tout ce qui est ailleurs est refuse, et
    un lien symbolique aussi (`realpath` decide, pas la chaine recue).
    """
    zone = os.path.realpath(DEPOSIT_SPOOL)
    vrai = os.path.realpath(chemin)
    if vrai != zone and not vrai.startswith(zone + os.sep):
        return None
    if not os.path.isfile(vrai) or os.path.islink(chemin):
        return None
    return vrai


def file_sha256(chemin, chunk=1024 * 1024):
    """L'empreinte du fichier, lue par morceaux : on ne charge pas 50 Mo pour les resumer."""
    h = hashlib.sha256()
    with open(chemin, "rb") as fh:
        while True:
            morceau = fh.read(chunk)
            if not morceau:
                break
            h.update(morceau)
    return h.hexdigest()


def serve_deposit(conn):
    """
    Un depot, un verdict.

        -> deposit <login> <slug> <sha256> <taille> <nom de fichier>
        -> <chemin du fichier de transit>
        <- "OK:<sha du commit> <org/slug> <chemin dans le depot>"
        <- "FAIL:<cause>"

    Le fichier ne passe PAS par ce fil : le deck l'a ecrit dans la zone de transit et en donne le
    chemin. La cause d'un refus est un JETON, pas une phrase — le deck possede les mots de
    l'operateur, parce que c'est lui que l'operateur regarde.
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
    # ⚠ L'ACL DE LA SOCKET BORNE QUI FRAPPE, ELLE N'AUTORISE RIEN. Le groupe porte aussi les autres
    # portes de ce service ; seul le compte du deck relaie une identite, et on le nomme.
    if peer != DEPOSIT_PEER:
        log(f"refus depot: le pair est « {peer} », pas le deck ({DEPOSIT_PEER})")
        return done("FAIL:not_the_deck")

    request = wire.readline().rstrip("\r\n")
    champs = request.split(" ", 5)
    if len(champs) != 6 or champs[0] != "deposit":
        log(f"refus depot: requete « {request[:80]} » — forme inattendue")
        return done("FAIL:bad_request")
    _verbe, login, slug, digest, taille_dite, name = champs
    if not LOGIN_RX.fullmatch(login):
        log(f"refus depot: login « {login[:40]} » refuse")
        return done("FAIL:bad_login")
    if not NAME_RX.fullmatch(slug):
        log(f"refus depot: projet « {slug[:40]} » — pas un slug")
        return done("FAIL:bad_project")
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        log(f"refus depot: {login} a annonce une empreinte qui n'en est pas une")
        return done("FAIL:bad_digest")
    if not DEPOSIT_NAME_RX.fullmatch(name):
        log(f"refus depot: {login} a nomme « {name[:80]} » — pas un nom de fichier")
        return done("FAIL:bad_name")
    try:
        taille = int(taille_dite)
    except ValueError:
        log(f"refus depot: taille « {taille_dite[:20]} » illisible")
        return done("FAIL:bad_request")

    spool = spool_bounded(wire.readline().rstrip("\r\n"))
    conn.settimeout(None)
    if spool is None:
        log(f"refus depot: {login} designe un fichier hors de la zone de transit ({DEPOSIT_SPOOL})")
        return done("FAIL:bad_spool")
    # LA TAILLE SE MESURE SUR LE FICHIER, l'annonce ne fait que se recouper avec lui.
    reelle = os.path.getsize(spool)
    if reelle == 0:
        log(f"refus depot: {login} depose un fichier vide")
        return done("FAIL:empty")
    if reelle > DEPOSIT_MAX_BYTES or reelle != taille:
        log(f"refus depot: {login} annonce {taille} octets, le fichier en fait {reelle} "
            f"(borne {DEPOSIT_MAX_BYTES})")
        return done("FAIL:too_big" if reelle > DEPOSIT_MAX_BYTES else "FAIL:size_mismatch")
    # LES DEUX RECITS SE RECOUPENT ICI : le deck a calcule l'empreinte de ce qu'il a lu du
    # navigateur, ce service calcule celle de ce qu'il trouve sur le disque. Un transit altere se
    # denonce, et les deux journaux restent independants.
    got = file_sha256(spool)
    if got != digest:
        log(f"refus depot: {login} annonce {digest[:12]}… et le fichier vaut {got[:12]}…")
        return done("FAIL:hash_mismatch")

    try:
        repo = resolve_project(slug)
    except LookupError as exc:
        log(f"refus depot: projet « {slug} » — {exc.args[0]}")
        return done(f"FAIL:{exc.args[0]}")
    except NoAuthority as exc:
        log(f"refus depot: {exc}")
        return done("FAIL:no_authority")
    except (urllib.error.URLError, TimeoutError, socket.timeout, ValueError, OSError) as exc:
        log(f"refus depot: projet « {slug} » non resolu ({exc})")
        return done("FAIL:forge_unreachable")

    path = f"{READY_ROOM_DIR}/{name}"
    message = deposit_message(login, name, got)
    try:
        try:
            commit = forge_put_file(repo, path, spool, reelle, message, login)
        except urllib.error.HTTPError as exc:
            # DEJA LA = ON REMPLACE, et c'est le contrat : l'ancien contenu reste dans l'historique,
            # le commit dit qui a remplace quoi. Le sha du blob en place est ce que l'API exige pour
            # distinguer un remplacement d'un ecrasement aveugle.
            if exc.code not in (409, 422):
                raise
            try:
                sha = blob_sha(repo, WORKSHOP_BRANCH, READY_ROOM_DIR, name)
            except LookupError as trop:
                # La ready room est trop longue pour qu'on affirme quoi que ce soit : on le DIT, au
                # lieu de rendre « la forge refuse » sur une question qu'on n'a pas pu poser.
                log(f"refus depot: {repo} — {trop.args[0]}")
                return done(f"FAIL:{trop.args[0]}")
            if not sha:
                raise
            log(f"depot: {path} existe deja dans {repo} — {login} le remplace")
            commit = forge_put_file(repo, path, spool, reelle, message, login, sha=sha)
    except NoAuthority as exc:
        log(f"refus depot: {exc}")
        return done("FAIL:no_authority")
    except urllib.error.HTTPError as exc:
        # ⚠ LE DEPOT EXISTE — `resolve_project` vient de le prouver. Un 404 ICI parle donc de la
        # BRANCHE : la face workshop n'a jamais ete poussee. La cause se nomme, sinon l'operateur
        # lit « la forge refuse » et cherche du cote du fichier.
        if exc.code == 404:
            log(f"refus depot: {repo} n'a pas de branche {WORKSHOP_BRANCH}")
            return done("FAIL:no_workshop_branch")
        log(f"refus depot: la forge refuse {repo}/{path} (HTTP {exc.code})")
        return done(f"FAIL:forge_refused:{exc.code}")
    except (urllib.error.URLError, TimeoutError, socket.timeout, ValueError, OSError) as exc:
        log(f"refus depot: depot de {login} non ecrit ({exc})")
        return done("FAIL:forge_unreachable")

    log(f"depot: {login} a depose « {name} » ({reelle} o, sha256 {got[:12]}…) "
        f"dans {repo} ({WORKSHOP_BRANCH}) {path} — commit {commit[:12]}")
    return done(f"OK:{commit} {repo} {path}")


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
