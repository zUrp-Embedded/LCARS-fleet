#!/usr/bin/env python3
# SOURCE: runtime/services/console-deck.py
# AUTHOR: consultant
# STARDATE: 2026-08-02
# STATUS: PROTO-V2 — le deck du conteneur : UNE page, des onglets verticaux, l'etat sonde en continu
#
# La coquille RESTE et le contenu change dans un cadre : une page generee une fois au demarrage
# affiche l'etat du boot, et chaque lien qui quitte la page fait perdre la vue d'ensemble.
#
# STDLIB SEULE (http.server) : l'image n'embarque pas de framework web et n'a pas a en embarquer un
# pour une page.
#
# CE QUE LE SERVEUR NE FAIT PAS : il ne PILOTE rien — aucun POST, aucune action. Il lit et il
# montre ; toute la conduite passe par les consoles ou par l'API de la fleet.
#
# ⚠ LA VUE AGENTS EST ICI, ET NULLE PART AILLEURS : ne la reimplemente pas dans une page a cote.

import html
import http.client
import hashlib
import json
import os
import re
import secrets
import select
import socket
import subprocess
import tempfile
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

PORT = int(os.environ.get("LCARS_LANDING_PORT", "20999"))
# ⚠ `console-humans.sh` EST la regle, ce fichier la LIT — il ne refait pas le filtre a cote, avec des
# bornes qui divergeraient.
HUMANS_SH = os.environ.get("LCARS_CONSOLE_HUMANS", "/opt/lcars/console-humans.sh")

# ── THE DOOR ────────────────────────────────────────────────────────────────────────────────────
# WHAT THE AUTH IS FOR, AND IT IS NOT MAINLY SECURITY: the fleet is already partitioned per-human,
# so authenticating does not create the partition — it makes the INDEX personal. And since the forge
# is the master of humans, `preferred_username` falls straight onto /etc/passwd (same login on both
# sides by contract): routing and authorisation come out of ONE round trip.
#
# ⚠ WE READ THE CLAIMS FROM `userinfo`, NOT FROM THE id_token. Both carry the same `groups`, but
# validating an RS256 signature needs a crypto library this image does not carry, and an UNVERIFIED
# id_token is an attacker-supplied blob. `userinfo` is a direct server-to-forge call authenticated
# by the access token we just obtained: nothing to verify, because nothing untrusted carried it.
# ONE name for the file, the one the gesture that writes it uses (forge.d/deck-oidc.sh):
# the container points it under its state volume, the workstation keeps the protocol default.
OIDC_CONFIG = os.environ.get("LCARS_DECK_OIDC_FILE", "/etc/lcars/deck-oidc.json")
# Membership of THIS team is what separates a human of the fleet from a mere forge account. Free
# registration is deliberate — an account is inert on its own, and the single admin gesture that
# enrolls somebody is adding them here. A member gets `["<org>", "<org>:humans"]`; a self-registered
# guest gets NO `groups` claim at all.
#
# ⚠ UNE SEULE PAIRE DE VARIABLES NOMME CETTE EQUIPE, ET LES DEUX PORTES EN DERIVENT. Un literal ici
# et une paire chez le convergeur, c'est un renommage d'org qui casse en SILENCE et dans UN SEUL
# sens : la forge emet `<org>:humans`, cette page compare a `fleet:humans` et REFUSE tout humain non
# admin, pendant que le convergeur continue de creer leurs comptes.
FORGE_ORG = os.environ.get("LCARS_FORGE_ORG", "fleet")
HUMANS_TEAM = "%s:%s" % (FORGE_ORG, os.environ.get("LCARS_HUMANS_TEAM", "humans"))
SESSION_COOKIE = "lcars_deck"
SESSION_TTL = 12 * 3600
PENDING_TTL = 600
# ⚠ LE LIRE EST CE QUI EMPECHE CETTE PAGE DE MENTIR : la forge accepte des logins qui ne peuvent PAS
# devenir un compte Unix, donc une personne peut etre enrolee dans l'equipe et ne jamais converger.
# Sans ce fichier, la page lui dirait « ca converge tout seul » pour une convergence qui n'arrivera
# jamais.
REFUSED_FILE = os.environ.get("LCARS_CONVERGER_REFUSED", "/run/lcars-converger.refused")

# ─── LA TABLE DE MONTAGE ────────────────────────────────────────────────────────────────────────
# LE RELAIS EST GENERIQUE : pas de route « console » ni de route « pod », des CIBLES de deux natures.
#
#   par-humain : /console/<login>/…  /pod/<login>/…   -> la socket de CET humain
#   systeme    : /admin/…                             -> un backend unique, sans <login>
#
# ⚠ Ce relais ne parle JAMAIS de terminal : apres le `101` il ne comprend plus rien de ce qu'il
# transporte, et c'est delibere.
CONSOLE_SOCK_ROOT = os.environ.get("LCARS_CONSOLE_SOCK_ROOT", "/run/lcars/console")
# ⚠ LA LISTE EST BLANCHE ET FERMEE : ce repertoire n'est pas « servi », ce sont des fichiers NOMMES
# qui le sont. Un serveur de statique generique dans un processus qui relaie des shells est une
# surface sans raison d'etre ouverte — et un `..` dans un nom n'est meme pas une question qui se pose.
DECK_STATIC = os.environ.get("LCARS_DECK_STATIC", "/opt/lcars/deck-static")
# LA DOC DE CETTE VERSION, BATIE PAR LE MEME COMMIT : le conteneur sert SA propre doc, pas la derniere
# en ligne ni une copie a resynchroniser.
#
# ⚠ HORS DU PREFIXE DE RELEASE, ET CE PROCESS EST LA RAISON : il largue ses privileges vers son
# compte de service, qui ne peut ni traverser ni ouvrir le prefixe RO. Sous le prefixe, chaque
# `open()` leverait et `/doc/` rendrait 404 sur des fichiers parfaitement presents.
DECK_DOC = os.environ.get("LCARS_DECK_DOC", "/opt/lcars/share/doc")
# ⚠ L'onglet du navigateur prend l'icone du document du HAUT, jamais celle de l'iframe : sans cette
# declaration, onglet muet meme quand la doc, elle, en a un.
DECK_FAVICON = os.environ.get("LCARS_DECK_FAVICON", "/opt/lcars/share/favicon")
# Les types servis, ENUMERES. Un dossier statique servi par extension inconnue rend `text/plain` ou
# pire ; et surtout, la liste EST la surface : ce qui n'est pas ici ne sort pas.
DOC_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".webp": "image/webp",
    ".woff2": "font/woff2",
    ".ico": "image/x-icon",
    ".json": "application/json; charset=utf-8",
    ".txt": "text/plain; charset=utf-8",
}
STATIC_FILES = {
    "xterm.js": "application/javascript; charset=utf-8",
    "xterm.css": "text/css; charset=utf-8",
    "addon-fit.js": "application/javascript; charset=utf-8",
}

# ── LA BOITE DE DEPOT ───────────────────────────────────────────────────────────────────────────
#
# CE SERVEUR N'ECRIT QUE DANS SA ZONE DE TRANSIT, ET C'EST LE POINT. Il tourne sous `lcars-system`,
# avec deux groupes accordes A L'EXEC (console-landing.sh) et aucun par adhesion : `lcars-console`
# pour joindre les consoles, et celui du service d'autorite pour joindre la porte de depot. Il ne
# peut ecrire ni dans `/home`, ni la ou vivent les jetons.
#
# LE FICHIER NE TRAVERSE PAS LA MEMOIRE. Le corps de la requete est ECRIT AU FIL DE L'EAU dans la
# zone de transit, l'empreinte se calcule pendant l'ecriture, et ce qui part sur la socket est le
# CHEMIN. Un base64 dans un corps JSON aurait coute un tiers de plus sur le fil et trois copies du
# fichier en memoire — tenable a 8 Mio, absurde a 50 Mo.
#
# ⚠ L'ATTRIBUTION EST DECLARATIVE, ET ELLE EST DITE TELLE QUELLE DANS L'ONGLET. Le commit porte
# l'humain comme AUTEUR ; la poussee reste celle du compte systeme, parce qu'aucun jeton personnel
# n'existe dans ce conteneur. C'est une trace pour savoir qui a depose quoi, pas une preuve
# opposable a celui qui la conteste.
DEPOSIT_SOCKET = os.environ.get("LCARS_DEPOSIT_SOCKET", "/run/lcars/deposit/deposit.sock")
# Sur DISQUE, jamais sous `/run` : c'est un tmpfs, donc 50 Mo de transit y seraient 50 Mo de RAM.
DEPOSIT_SPOOL = os.environ.get("LCARS_DEPOSIT_SPOOL", "/var/tmp/lcars/deposit")
# La meme borne que la porte d'en face, et les deux se lisent : celle-ci refuse au fil de la
# lecture, celle d'en face mesure le fichier qu'elle trouve.
DEPOSIT_MAX_BYTES = int(os.environ.get("LCARS_DEPOSIT_MAX_BYTES", str(50 * 1000 * 1000)))
# Le temps d'un depot, pas celui d'une question : la porte pousse le fichier vers la forge pendant
# que ce delai court.
DEPOSIT_TIMEOUT = int(os.environ.get("LCARS_DEPOSIT_TIMEOUT", "600"))
# Affiche, jamais decide : la porte lit les memes valeurs et tranche sur ce qu'elle lit, elle.
WORKSHOP_BRANCH = os.environ.get("LCARS_WORKSHOP_BRANCH", "workshop")
READY_ROOM_DIR = os.environ.get("LCARS_READY_ROOM_DIR", "ready-room")
# Les causes que la porte rend sont des JETONS ; les phrases sont ici, parce que c'est cette page
# que l'operateur regarde. Une cause inconnue se montre telle quelle plutot que d'etre lissee en
# « erreur » : un jeton qu'on n'a pas prevu se cherche dans les logs, une phrase vague ne se cherche
# nulle part.
DEPOSIT_CAUSES = {
    "not_the_deck": "ce conteneur refuse le relais du deck — le service de depot ne le reconnait pas",
    "bad_request": "le deck a mal formule la demande",
    "bad_login": "le deck a relaye un login que la porte refuse",
    "bad_project": "nom de projet refuse",
    "bad_name": "nom de fichier refuse : lettres, chiffres, point, tiret et souligne, 128 au plus",
    "bad_digest": "empreinte du fichier illisible",
    "bad_spool": "le fichier de transit n'est pas la ou la porte l'attend",
    "size_mismatch": "la taille annoncee et le fichier ne concordent pas — rien n'est depose",
    "hash_mismatch": "le contenu recu ne correspond pas a son empreinte — rien n'est depose",
    "too_big": "fichier trop gros pour la boite de depot",
    "empty": "fichier vide",
    "unknown_project": "aucun catalogue installe ne porte ce projet sur la forge",
    "ambiguous_project": "ce nom de projet existe dans plusieurs catalogues — la porte ne choisit pas",
    "no_authority": "ce conteneur n'a pas de jeton utilisable pour deposer",
    "forge_unreachable": "la forge n'a pas repondu — rien n'est depose",
    "unknown_peer": "la porte de depot ne sait pas qui frappe",
    # Les trois dernieres ne viennent pas de la porte : c'est CE serveur qui les nomme, quand la
    # porte ne repond pas. Un depot refuse et un depot non tente appellent des gestes opposes.
    "porte_fermee": "le service de depot de ce conteneur est eteint — rien n'est depose",
    "porte_muette": "le service de depot accepte et se tait — rien n'est confirme",
    "verdict_illisible": "la porte de depot a repondu quelque chose d'inattendu",
}

# Nature d'une cible par-humain -> nom de la socket dans son repertoire.
PER_HUMAN_TARGETS = {"console": "console.sock", "pod": "pod.sock"}
# Nature d'une cible systeme -> chemin de socket absolu. VIDE, ET C'EST HONNETE : le mecanisme
# d'autorisation admin existe et est teste ; aucun backend systeme n'est encore ecrit. Une entree
# ici suffira a en publier un, sans toucher a `authorize`.
SYSTEM_TARGETS = {}

_lock = threading.Lock()
_sessions = {}
_pending = {}


def deck_socket_for(login):
    """Ou ecoute le deck d'observation de cet humain. Meme derivation que le runtime, pas une table."""
    return os.path.join(CONSOLE_SOCK_ROOT, login, "deck.sock")


class _UnixHTTPConnection(http.client.HTTPConnection):
    """
    `http.client` sur une socket AF_UNIX. LA STDLIB NE SAIT PAS LE FAIRE, et c'est le seul motif de
    cette classe : `urlopen` ne connait que des URLs, or il n'y a plus d'URL — le deck n'a pas
    d'adresse. Tout le reste (requete, en-tetes, decoupage de la reponse) reste celui de la stdlib ;
    on ne remplace QUE l'etablissement de la connexion.
    """

    def __init__(self, sock_path, timeout):
        super().__init__("localhost", timeout=timeout)
        self._sock_path = sock_path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        # ⚠ LES ERREURS DE `connect` REMONTENT TELLES QUELLES, ET C'EST DELIBERE. `PermissionError`,
        # `FileNotFoundError` et `ConnectionRefusedError` sont TROIS diagnostics differents que
        # l'appelant traduit en trois etats differents. Les envelopper dans une exception maison
        # ferait perdre exactement l'information qui distingue « la fleet est eteinte » de « je n'ai
        # pas le droit de lui parler ».
        s.connect(self._sock_path)
        self.sock = s


def unix_get(sock_path, path, timeout=2):
    """Un GET sur une socket AF_UNIX. Rend `(code, corps)`; les erreurs de connexion remontent."""
    conn = _UnixHTTPConnection(sock_path, timeout)
    try:
        conn.request("GET", path, headers={"Host": "lcars"})
        r = conn.getresponse()
        return r.status, r.read()
    finally:
        conn.close()


def deposit(login, projet, name, spool, taille, digest):
    """
    Un depot relaye a la porte qui detient le jeton. Rend `(ok, detail_ou_cause)`.

    LE FIL EST VOLONTAIREMENT BETE, comme celui des deux autres portes : une ligne de requete, une
    ligne qui donne le CHEMIN du fichier de transit, une ligne de verdict. Le fichier lui-meme ne
    passe pas par la socket — il est deja sur le disque, ecrit au fil de l'eau par la route qui l'a
    recu.

    ⚠ L'EMPREINTE EST CALCULEE ICI ET VERIFIEE LA-BAS. Ce n'est pas une ceinture de plus : c'est ce
    qui rend les deux journaux independants. Celui-ci ecrit ce qu'il a lu du navigateur, celui d'en
    face ce qu'il trouve sur le disque ; un transit altere se denonce.
    """
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(DEPOSIT_TIMEOUT)
            sock.connect(DEPOSIT_SOCKET)
            wire = sock.makefile("rw", encoding="utf-8", newline="\n")
            wire.write(f"deposit {login} {projet} {digest} {taille} {name}\n{spool}\n")
            wire.flush()
            verdict = (wire.readline() or "").rstrip("\r\n")
    except (ConnectionRefusedError, FileNotFoundError):
        # PERSONNE N'ECOUTE = LE SERVICE EST ETEINT, et c'est une mesure, pas une supposition. La
        # meme distinction que pour les decks des humains : un refus de connexion se nomme, un
        # silence se nomme autrement.
        print(f"[lcars-deck] depot impossible : rien n'ecoute sur {DEPOSIT_SOCKET}",
              file=sys.stderr, flush=True)
        return False, "porte_fermee"
    except (socket.timeout, TimeoutError):
        print(f"[lcars-deck] depot: {DEPOSIT_SOCKET} accepte et se tait", file=sys.stderr, flush=True)
        return False, "porte_muette"
    except OSError as exc:
        print(f"[lcars-deck] depot: {DEPOSIT_SOCKET} ({exc})", file=sys.stderr, flush=True)
        return False, "porte_fermee"

    if verdict.startswith("OK:"):
        sha, _, reste = verdict[3:].partition(" ")
        repo, _, chemin = reste.partition(" ")
        print(f"[lcars-deck] depot de {login} : « {name} » ({taille} o, sha256 {digest[:12]}…) "
              f"-> {repo} {chemin} (commit {sha[:12]})", file=sys.stderr, flush=True)
        return True, {"sha": sha, "repo": repo, "path": chemin, "sha256": digest}
    cause = verdict[5:] if verdict.startswith("FAIL:") else "verdict_illisible"
    print(f"[lcars-deck] depot de {login} REFUSE : {cause}", file=sys.stderr, flush=True)
    return False, cause


def spool_write(source, annonce):
    """
    Ecrit le corps de la requete dans la zone de transit, par tranches. Rend `(chemin, taille, sha)`.

    ⚠ LA BORNE S'APPLIQUE AU FIL DE LA LECTURE, pas seulement sur la taille annoncee : un client qui
    ment sur `Content-Length` ne doit pas pouvoir remplir le disque parce qu'on l'a cru. On lit ce
    qui est annonce, on s'arrete a la borne, et le fichier part avec.

    Le fichier nait dans un repertoire `setgid` : il herite du groupe de la porte, qui doit le LIRE.
    Le mode est resserre a `0640` — le deck l'ecrit, la porte le lit, personne d'autre.
    """
    os.makedirs(DEPOSIT_SPOOL, exist_ok=True)
    fd, chemin = tempfile.mkstemp(prefix="depot-", dir=DEPOSIT_SPOOL)
    h = hashlib.sha256()
    taille = 0
    try:
        os.fchmod(fd, 0o640)
        with os.fdopen(fd, "wb") as sortie:
            reste = annonce
            while reste > 0:
                morceau = source.read(min(1024 * 1024, reste))
                if not morceau:
                    break
                taille += len(morceau)
                if taille > DEPOSIT_MAX_BYTES:
                    raise ValueError("depasse la borne")
                h.update(morceau)
                sortie.write(morceau)
                reste -= len(morceau)
    except BaseException:
        spool_remove(chemin)
        raise
    return chemin, taille, h.hexdigest()


def spool_remove(chemin):
    """Le transit ne survit pas au depot, reussi ou non — sinon le disque se remplit en silence."""
    try:
        os.unlink(chemin)
    except OSError as exc:
        print(f"[lcars-deck] transit non nettoye : {chemin} ({exc})", file=sys.stderr, flush=True)


def parse_target(path):
    """
    `/console/alice/ws` -> ("console", "alice", "/ws") · `/admin/x` -> ("admin", None, "/x").

    Rend `None` pour tout le reste. LE DECOUPAGE EST STRICT PAR CONSTRUCTION : le segment de login
    est pris tel quel et compare ENSUITE a la session — il ne sert jamais a fabriquer un chemin
    avant d'avoir ete autorise (cf. `socket_for`, qui refuse tout login non canonique).
    """
    parts = path.split("/")
    if len(parts) < 3 or parts[0] != "":
        return None
    kind = parts[1]
    if kind in PER_HUMAN_TARGETS:
        if len(parts) < 4:
            return None
        return (kind, parts[2], "/" + "/".join(parts[3:]))
    if kind in SYSTEM_TARGETS:
        return (kind, None, "/" + "/".join(parts[2:]))
    return None


def authorize(sess, target):
    """
    LA REGLE S'ECRIT EN POSITIF, ET C'EST UN ARBITRAGE, PAS UN OUBLI.

        cible par-humain -> cible.login == sess.login, et RIEN D'AUTRE
        cible systeme    -> sess est admin

    ⚠ L'ADMIN N'ATTEINT PAS LA CONSOLE D'UN AUTRE HUMAIN — choix tranche : *ce serait un geste de
    panoptique, pas un geste d'admin*. Son perimetre est le SYSTEME (faire tourner le conteneur, ajouter
    des catalogues, purger des depots morts), jamais les cibles par-humain d'autrui.

    C'est pour ca que la premiere branche ne consulte PAS `groups` : une clause absente se relit
    comme un oubli et se fait combler par le premier qui trouve ca pratique. Ici il n'y a rien a
    combler — il faudrait retirer une egalite ecrite noir sur blanc, et le test qui la tient porte
    la phrase.
    """
    kind, login, _rest = target
    if kind in PER_HUMAN_TARGETS:
        return login == sess.get("login")
    if kind in SYSTEM_TARGETS:
        # `.get`, PAS un index : une session ecrite avant ce champ (ou par un test qui n'en parle
        # pas) doit valoir « pas admin », jamais une KeyError qui rendrait 500 sur une question
        # d'autorisation. L'absence de reponse est un refus.
        return bool(sess.get("admin"))
    return False


def socket_for(target):
    """Chemin de socket d'une cible AUTORISEE, ou `None` si la forme du login l'interdit."""
    kind, login, _rest = target
    if kind in SYSTEM_TARGETS:
        return SYSTEM_TARGETS[kind]

    # DEUXIEME GARDE, APRES L'AUTORISATION, ET ELLE N'EST PAS REDONDANTE. `authorize` a deja exige
    # `login == sess.login` — mais c'est la session qui devient alors la source du chemin, et une
    # session ne vaut que ce que vaut le login que la forge a rendu. Gitea accepte des logins que ce
    # decoupage n'attend pas ; on refuse tout ce qui n'est pas un nom simple plutot que de laisser un
    # `..` ou un `/` fabriquer un chemin hors de la racine.
    if not login or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", login):
        return None
    return os.path.join(CONSOLE_SOCK_ROOT, login, PER_HUMAN_TARGETS[kind])


def oidc_config():
    """
    The registered OAuth2 client, or `(None, why)` -- never a silent degraded mode.

    TWO FORGE URLS, AND CONFLATING THEM IS THE CLASSIC FIRST-TRY FAILURE. The browser is sent to
    `public_url` (an address a person's machine can reach); the code-for-token exchange goes to
    `internal_url` (which inside a container is the compose service name). One value cannot be
    both: `http://gitea:3000` resolves nowhere outside the network, and the host's address may not
    resolve inside it.
    """
    try:
        with open(OIDC_CONFIG) as fh:
            cfg = json.load(fh)
    except FileNotFoundError:
        return None, f"{OIDC_CONFIG} absent"
    except PermissionError:
        return None, f"{OIDC_CONFIG} illisible par uid {os.geteuid()} (le deck tourne sous « lcars-system » ; le fichier se pose 0640 root:lcars-system)"
    except (OSError, ValueError) as e:
        return None, f"{OIDC_CONFIG} illisible: {e}"
    missing = [k for k in ("client_id", "client_secret", "public_url") if not cfg.get(k)]
    if missing:
        return None, f"{OIDC_CONFIG}: champ(s) manquant(s) {', '.join(missing)}"
    cfg.setdefault("internal_url", cfg["public_url"])
    return cfg, None


def _post_form(url, fields):
    body = urllib.parse.urlencode(fields).encode()
    req = Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urlopen(req, timeout=10) as r:
        return json.load(r)


def _get_json(url, token):
    req = Request(url)
    req.add_header("Authorization", "Bearer " + token)
    with urlopen(req, timeout=10) as r:
        return json.load(r)


def forge_is_admin(cfg, token):
    """
    Is the freshly authenticated user a forge admin? False when the forge does not say so.

    FAIL-CLOSED, AND THE FAILURE IS LOGGED. `userinfo` has already answered by the time this runs,
    so a failure here is not "the forge is down" -- it is this one endpoint refusing, and the only
    safe reading of "no answer" on an authority question is "no". A degraded mode that granted admin
    on a timeout would hand the tier to whoever can make the call time out.
    """
    try:
        return bool(_get_json(
            f"{cfg['internal_url'].rstrip('/')}/api/v1/user", token
        ).get("is_admin"))
    except (HTTPError, URLError, TimeoutError, socket.timeout, ValueError) as e:
        print(f"[lcars-deck] adminite non lue, session ordinaire : {e}", file=sys.stderr, flush=True)
        return False


def _sweep(now):
    for store, key in ((_sessions, "exp"), (_pending, "exp")):
        for k in [k for k, v in store.items() if v[key] <= now]:
            store.pop(k, None)


def refusal_for(login):
    """The converger's stated reason for refusing `login`, or None if it never refused it."""
    try:
        with open(REFUSED_FILE) as fh:
            for line in fh:
                name, _, reason = line.rstrip("\n").partition("\t")
                if name == login:
                    return reason or "raison non precisee par le convergeur"
    except OSError:
        pass
    return None


def session_of(cookie_header):
    """The live session a request carries, or None. Expiry is checked on READ, never on a timer."""
    if not cookie_header:
        return None
    sid = None
    for part in cookie_header.split(";"):
        k, _, v = part.strip().partition("=")
        if k == SESSION_COOKIE:
            sid = v
    if not sid:
        return None
    now = time.time()
    with _lock:
        _sweep(now)
        s = _sessions.get(sid)
        return dict(s, sid=sid) if s else None

# ⚠ AUCUNE FORMULE DE BLOC DE PORTS ICI, MEME EN COMMENTAIRE : une constante gardee « au cas ou »
# est une invitation a la reutiliser, et le prochain qui voudrait un port republierait une origine.

POD_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def block(uid):
    """
    ⚠ NE REND AUCUN PORT, ET C'EST UNE REPONSE, PAS UN MANQUE : plus une cible du conteneur n'a
    d'adresse (API, deck, console, pod — toutes sur socket). Publier un numero ici enverrait un
    consommateur frapper a une porte qui n'existe pas.

    ELLE RESTE parce que `humans()` pose la cle `ports` dans `/api/state`, et qu'un champ qui
    DISPARAIT d'une reponse est un changement de contrat plus brutal qu'un champ qui devient vide.
    Mesure du 2026-08-14 : `h.ports` a ZERO occurrence dans le JS de cette page — plus personne ne
    le lit. Le jour ou plus rien ne le lit non plus cote client, la cle part avec la fonction.
    """
    return {}


def humans():
    """
    Les humains servis par ce conteneur, DEMANDES a `console-humans.sh`.

    ⚠ PAS DE REGLE PROPRE ICI — CE SERAIT UNE SECONDE AUTORITE. Un filtre local sur `/etc/passwd`
    (`uid >= 1000 and uid < 65000`, un shell en `bash|sh|zsh`) divergerait de `console-humans.sh`
    sur ses bornes, et l'ecart qui mord est le home : le script REFUSE un compte sans home (« une
    console sans home s'ouvre sur / et ment ») ; une copie qui l'accepterait ferait lister un siege
    dont `console.sh --all` n'a jamais demarre la console, et la page rendrait « cette console ne
    fonctionne pas » a quelqu'un dont le compte va tres bien.

    La liste des humains est portee par la FORGE et derivee par le convergeur ; `console-humans.sh`
    derive a son tour qui peut recevoir une console ici. Ce fichier est un LECTEUR : il ne refait
    pas la derivation, il la demande.

    Leve `OSError` si le script ne peut pas repondre — voir `door_humans/1` pour pourquoi cette
    panne ne doit pas se dire « tu n'as pas de siege ».
    """
    out = []

    proc = subprocess.run(
        [HUMANS_SH], capture_output=True, text=True, timeout=10, check=False
    )

    if proc.returncode != 0:
        raise OSError(
            "%s exited %d: %s" % (HUMANS_SH, proc.returncode, (proc.stderr or "").strip()[:200])
        )

    for line in proc.stdout.splitlines():
        f = line.split()
        if len(f) != 3:
            continue
        name, uid, home = f[0], f[1], f[2]
        if not uid.isdigit():
            continue
        out.append({"human": name, "uid": int(uid), "home": home, "ports": block(int(uid))})

    return sorted(out, key=lambda h: h["uid"])


def fleet_pods(human):
    """
    Pods vivants d'un humain, vus par SA fleet (le deck d'observation, sur sa socket).

    Source unique volontaire : le runtime sait ce qu'il a spawne (role, phase), la ou une
    enumeration de sockets ne rend que des noms.

    TROIS ETATS, PAS DEUX. Une fleet eteinte est un etat NOMINAL ; un deck qu'on n'a pas pu
    joindre est une mesure RATEE, et les deux ne se disent pas de la meme facon. Rendre `None` sur
    n'importe quelle exception, traduit `fleet=False` par l'appelant, afficherait un timeout de 2 s
    en « fleet eteinte » — une assertion d'extinction tiree d'une absence de reponse. C'est le piege
    que le read-model du runtime ferme par `:live | :deaf | :unavailable`.

    Le discriminant est la CAUSE, pas l'echec : connexion refusee = personne n'ecoute = eteinte
    (on a mesure) ; timeout, reset, DNS = on n'a pas mesure.
    """
    sock = deck_socket_for(human["human"])
    try:
        code, body = unix_get(sock, "/api/pods", timeout=2)
    except PermissionError:
        # ⚠ CAUSE NOUVELLE, SANS EQUIVALENT TCP, ET C'EST TOUT L'INTERET DE LA NOMMER. Le deck
        # ECOUTE, on n'a simplement pas le droit d'ouvrir sa socket : le groupe supplementaire
        # manque au landing, ou le repertoire de l'humain n'a pas le bon mode. Ranger ca dans
        # « eteinte » serait exactement le mensonge que cette fonction a passe vingt lignes a
        # fermer — une assertion d'extinction tiree d'un refus de permission. Et c'est le seul etat
        # d'ici qui se repare par un geste PRECIS, donc le seul qu'il serait couteux de taire.
        return "denied", []
    except FileNotFoundError:
        # Pas de socket = personne n'ecoute. C'est une MESURE, pas une absence de mesure : le
        # listener retire son fichier en s'arretant, precisement pour que cet etat soit lisible.
        return "off", []
    except ConnectionRefusedError:
        # Socket residuelle d'un BEAM tue : le fichier survit, plus personne n'accepte. Meme
        # verdict qu'au-dessus, autre chemin.
        return "off", []
    except (TimeoutError, socket.timeout, OSError):
        return "unknown", []

    if code != 200:
        # Quelqu'un ecoute et repond autre chose que ce qu'on attend : mesure faite, etat anormal.
        return "deaf", []
    try:
        return "live", (json.loads(body).get("pods") or [])
    except ValueError:
        return "deaf", []


def fleet_projection(human):
    """
    La projection du read-model de cet humain : `(status, projection)`.

    ⚠ SECONDE SOURCE, ET ELLE EST NECESSAIRE. Le deck d'observation alimente SIX de ses sept
    panneaux avec `/api/projection` ; un landing qui n'appellerait que `/api/pods` perdrait ces six
    panneaux en silence, tout en ayant l'air d'avoir embarque le deck.

    ⚠ ET LA CICATRICE DE LA PAGE DU DECK SE GARDE : une projection `deaf`/`unavailable` est un FLUX
    FIGE, pas une flotte calme. La rendre comme un tableau vide serait exactement le mensonge que
    `fleet_pods` a passe vingt lignes a fermer, un etage plus haut. Le `_status` que le runtime pose
    dans la charge est donc REMONTE tel quel, jamais aplati.
    """
    sock = deck_socket_for(human["human"])
    try:
        code, body = unix_get(sock, "/api/projection", timeout=2)
    except PermissionError:
        return "denied", {}
    except (FileNotFoundError, ConnectionRefusedError):
        return "off", {}
    except (TimeoutError, socket.timeout, OSError):
        return "unknown", {}

    if code != 200:
        return "deaf", {}
    try:
        proj = json.loads(body)
    except ValueError:
        return "deaf", {}

    # Le runtime a son propre verdict sur la fraicheur de son flux, et il le publie. Le nôtre ne
    # porte que sur le transport : quand les deux existent, c'est le sien qui tranche.
    return (proj.get("_status") or "live"), proj


def claude_credentials(home):
    """
    Whether this human has done their `claude /login` yet: "present" | "absent" | "unknown".

    P5, SAID IN THE ENROLLMENT GESTURE RATHER THAN DISCOVERED AT THE FIRST FAILED SPAWN. A freshly
    converged human has a system account, a forge account, and ZERO ability to spawn a pod: what
    they lack is `~/.claude/.credentials.json`, obtained by an interactive `claude /login` nobody
    can perform for them. Nothing in the chain could tell them, so they met it as a spawn failure.

    PRESENT, NEVER "VALID", and the distinction is not caution. Measured on 2026-08-09: a file
    complete in shape -- scopes, subscriptionType, a future refreshTokenExpiresAt -- whose two
    tokens were both zero bytes. Announcing "wizard done" on that made every spawn die in
    `credentials_invalid`. The authority is the runtime's credentials gate, at spawn; this only
    reports that the file is there.

    We can see this as the deck's service account because the home and `.claude` are traversable while the file
    itself stays 0600 -- presence is observable, content is not, which is exactly the right amount.
    A human who tightens their home gets "unknown", and an unknown is never rendered as an absence.
    """
    if not home:
        return "unknown"
    try:
        if os.path.exists(os.path.join(home, ".claude", ".credentials.json")):
            return "present"
        # Distinguish "looked and found nothing" from "could not look": a home we cannot traverse
        # tells us nothing, and saying "absent" there would invent a verdict.
        if os.path.isdir(home) and os.access(home, os.X_OK):
            return "absent"
    except OSError:
        pass
    return "unknown"


def state(only=None, admin=False, people=None):
    """
    The container's state, RESTRICTED to `only` when a session names a human.

    The filter is applied at the SOURCE, not in the page: an index that renders one human while
    `/api/state` still serves everybody has not made anything personal, it has hidden a list that
    is still one fetch away.

    `admin` travels with the payload for ONE reason: to let the page draw a tab. It is a
    projection of the session, never an authorization -- what the tier actually opens is decided
    by `authorize`, server-side, on the session and not on anything the browser sends back.
    """
    # `people` EVITE UN SECOND APPEL, il n'ouvre pas une seconde source. La porte vient d'appeler
    # `humans()` pour decider si ce visiteur a un siege ; relancer le script ici le ferait tourner
    # deux fois par requete, donc deux fois toutes les 10 s et par session. Quand personne ne
    # transmet la liste (les tests, un appel direct), on la redemande — jamais on ne la reconstruit.
    hs = []
    for h in people if people is not None else humans():
        if only is not None and h["human"] != only:
            continue
        status, pods = fleet_pods(h)

        # LA PROJECTION N'EST TIREE QUE SI LE DECK REPOND. Sur une fleet eteinte, une seconde sonde
        # ne rendrait qu'un second « off » — au prix d'un timeout de 2 s de plus par humain sur
        # CHAQUE `/api/state`, c'est-a-dire toutes les 10 s. Le cout d'une sonde inutile se paie a
        # la periode, pas une fois.
        if status == "live":
            proj_status, proj = fleet_projection(h)
        else:
            proj_status, proj = status, {}

        # `fleet` reste le booleen « vivante », pour les consommateurs qui ne posent que cette
        # question ; `fleet_status` porte la distinction que le booleen ne peut pas porter.
        h = dict(h, fleet=(status == "live"), fleet_status=status,
                 projection_status=proj_status, projection=proj,
                 claude=claude_credentials(h.get("home")), pods=[])
        for p in pods or []:
            pid = p.get("pod_id", "")
            if not POD_ID_RE.match(pid):
                continue
            h["pods"].append({
                "pod_id": pid,
                "role": p.get("role") or "?",
                "phase": p.get("phase") or "?",
                # LE RATTACHEMENT VIENT DU RUNTIME, plus d'une inspection de /proc.
                #
                # Le deck derivait le projet des montages du pod, et `pod_mounts_env` a retire
                # l'arbre ops de tous les pods de projet — deliberement. Le scan ne repondait donc
                # plus que pour les architectes, et son repli AFFIRMAIT « fleet-level » la ou il
                # voulait dire « je ne sais pas ». Trois couches d'accord sur une reponse fausse.
                #
                # `project_slug` absent = le pod n'appartient a aucun projet, et c'est le RUNTIME
                # qui le dit. La meme absence deduite d'un montage manquant ne disait rien.
                "project": p.get("project_slug"),
            })
        hs.append(h)
    # `deposit` voyage pour que la page sache QUOI DIRE — la borne et la destination — jamais pour
    # decider : la porte d'en face lit les memes variables et retranche sur ce qu'elle lit, elle.
    # LE PROJET, LUI, NE VOYAGE PAS ICI : la page le tire des pods qu'elle recoit deja, comme elle
    # en tire les groupes de sa barre laterale. Une seconde liste serait une seconde verite.
    return {"hostname": socket.gethostname(), "humans": hs, "admin": bool(admin),
            "deposit": {"max_bytes": DEPOSIT_MAX_BYTES, "branch": WORKSHOP_BRANCH,
                        "dir": READY_ROOM_DIR}}


# ── THE THREE PAGES THAT ARE NOT THE DECK ───────────────────────────────────────────────────────
# Each says ONE thing and offers exactly the gesture that unblocks it. A door that refuses without
# naming what it wants sends the person to ask an admin what the deck already knows.
SHELL = r"""<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LCARS &mdash; %(title)s</title>
<style>
  :root { --or:#FF9900; --am:#FFCC66; --bg:#000; --pan:#141414; --dim:#7a7a7a; --line:#262626 }
  * { box-sizing:border-box }
  body { margin:0; min-height:100vh; background:var(--bg); color:var(--am);
         font:15px/1.6 ui-monospace,"DejaVu Sans Mono",Menlo,monospace;
         display:flex; align-items:center; justify-content:center; padding:24px }
  .card { max-width:620px; width:100%%; background:var(--pan); border-left:4px solid var(--or); padding:26px 30px }
  h1 { color:var(--or); font-size:15px; letter-spacing:.22em; margin:0 0 18px; font-weight:700 }
  p { margin:0 0 14px }
  .dim { color:var(--dim) }
  code { color:var(--or); word-break:break-all }
  a.go { display:inline-block; margin-top:10px; padding:9px 20px; background:var(--or); color:#000;
         text-decoration:none; font-weight:700; letter-spacing:.08em }
  a.go:hover { background:var(--am) }
</style>
<div class="card">%(body)s</div>
"""


def page_login(forge=None):
    return SHELL % {
        "title": "identification",
        "body": (
            "<h1>LCARS</h1>"
            "<p>Ce conteneur est desservi par la forge : elle sait qui tu es, on ne redemande pas.</p>"
            '<p><a class="go" href="/auth/login">S\'identifier sur la forge</a></p>'
            '<p class="dim">Pas encore de compte ? La forge accepte les inscriptions. Un compte '
            "seul ne donne acces a rien ici : c'est l'ajout a l'equipe <code>" + html.escape(HUMANS_TEAM) +
            "</code> qui fait de toi un humain de la fleet.</p>"
            # LE LIEN VERS LA FORGE FERME UNE BOUCLE. Sans lui, quelqu'un qui veut changer de compte
            # n'a nulle part ou aller : notre porte le renvoie a la forge sans jamais en donner
            # l'adresse, et la forge le reconnait en silence. Une porte doit montrer ou elle mene.
            '<p class="dim">La forge : <a href="' + html.escape(forge or "#") + '">' +
            html.escape(forge or "(adresse non configuree)") + "</a></p>"
        ),
    }


def page_denied(login, groups):
    return SHELL % {
        "title": "compte reconnu",
        "body": (
            "<h1>COMPTE RECONNU</h1>"
            "<p>Tu es bien <code>" + html.escape(login or "?") + "</code> sur la forge, et c'est tout "
            "ce qui manquait de verifiable : ton compte existe et il fonctionne.</p>"
            "<p>Il n'est pas encore membre de <code>" + html.escape(HUMANS_TEAM) + "</code>. Tant "
            "qu'il ne l'est pas, tu n'as pas de fleet sur ce conteneur &mdash; rien n'est casse, il "
            "manque <b>un seul geste</b>, cote forge, par un proprietaire de l'organisation.</p>"
            '<p class="dim">Vu de la forge, tu appartiens a : <code>' +
            html.escape(", ".join(groups) if groups else "(aucune equipe)") + "</code></p>"
            '<p><a class="go" href="/auth/logout">Se deconnecter</a></p>'
        ),
    }


def page_no_block(login):
    return SHELL % {
        "title": "bloc absent",
        "body": (
            "<h1>PAS ENCORE DE BLOC</h1>"
            "<p>Tu es <code>" + html.escape(login) + "</code>, membre de <code>" +
            html.escape(HUMANS_TEAM) + "</code> &mdash; l'enrollment est fait cote forge.</p>"
            "<p>Mais aucun utilisateur systeme <code>" + html.escape(login) + "</code> n'existe "
            "encore sur ce conteneur, donc tu n'as ni bloc de ports ni fleet a montrer. C'est le "
            "convergeur qui pose cet utilisateur, et il ne l'a pas encore fait.</p>"
            '<p class="dim">Rien a faire de ton cote : ca converge tout seul. Si ca dure, c\'est '
            "le convergeur qu'il faut regarder, pas ton compte.</p>"
            '<p><a class="go" href="/auth/logout">Se deconnecter</a></p>'
        ),
    }


def page_refused(login, reason):
    return SHELL % {
        "title": "login inutilisable",
        "body": (
            "<h1>CE LOGIN NE PEUT PAS ABOUTIR</h1>"
            "<p>Tu es <code>" + html.escape(login) + "</code>, membre de <code>" +
            html.escape(HUMANS_TEAM) + "</code> : l'enrollment est fait, et il ne suffira pas.</p>"
            "<p><b>" + html.escape(reason) + "</b></p>"
            "<p>Ce n'est pas une attente : ce conteneur a REFUSE de creer ton utilisateur systeme, "
            "et elle le refusera a chaque passage. Rien ne se debloquera tout seul.</p>"
            '<p class="dim">Ce qu\'il faut faire : changer de login sur la forge (ou en creer un '
            "autre), puis se faire ajouter a l'equipe. Tant que ce login reste celui-la, cette page "
            "ne changera pas.</p>"
            '<p><a class="go" href="/auth/logout">Se deconnecter</a></p>'
        ),
    }


def page_unknown_entrance(uri, known):
    return SHELL % {
        "title": "entree non declaree",
        "body": (
            "<h1>CETTE ENTREE N'EST PAS DECLAREE</h1>"
            "<p>Tu es arrive par <code>" + html.escape(uri) + "</code>. La forge n'accepte de te "
            "renvoyer que vers des adresses <b>enregistrees a l'avance</b>, et celle-ci n'y est pas.</p>"
            "<p>Je m'arrete ici volontairement. Si je t'envoyais quand meme, tu t'identifierais "
            "normalement puis tu tomberais sur une erreur 400 de la forge qui ne dit pas pourquoi "
            "&mdash; apres coup, sur une page qui n'est pas la notre.</p>"
            '<p class="dim">Entrees declarees : <code>' +
            html.escape(", ".join(known) if known else "(aucune)") + "</code><br>"
            "Ce qu'il faut faire : passer par l'une d'elles, ou ajouter celle-ci a "
            "<code>LCARS_DECK_ORIGINS</code> et rejouer le provisioning.</p>"
        ),
    }


def page_unconfigured(why):
    return SHELL % {
        "title": "non configure",
        "body": (
            "<h1>DECK NON CONFIGURE</h1>"
            "<p>Ce deck exige l'identification par la forge, et son client OAuth2 n'est pas pose : "
            "<code>" + html.escape(why) + "</code></p>"
            "<p>Il ne sert donc RIEN &mdash; ni annuaire, ni liens. Un deck qui se rabattrait sur "
            "la liste complete des humains rendrait l'absence de configuration invisible, et "
            "personne n'irait la corriger.</p>"
            '<p class="dim">C\'est le provisioning qui pose ce fichier (client_id, client_secret, '
            "public_url, internal_url), lisible par le seul compte du deck, <code>lcars-system</code>.</p>"
        ),
    }


PAGE = r"""<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LCARS &mdash; %(host)s</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="alternate icon" href="/favicon.ico">
<link rel="stylesheet" href="/static/xterm.css">
<script src="/static/xterm.js"></script>
<script src="/static/addon-fit.js"></script>
<style>
  :root { --or:#FF9900; --am:#FFCC66; --bg:#000; --pan:#141414; --dim:#7a7a7a; --line:#262626 }
  * { box-sizing:border-box }
  html,body { height:100vh; overflow:hidden }
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
  main { flex:1; min-width:0; display:flex; flex-direction:column }
  header { flex:0 0 auto; padding:10px 18px; border-bottom:1px solid var(--line); color:var(--dim);
           font-size:12px; display:flex; gap:14px; align-items:baseline }
  header b { color:var(--or); font-weight:400; letter-spacing:.1em }
  header a { color:var(--dim); text-decoration:none; border-bottom:1px dotted var(--dim) }
  header a:hover { color:var(--or); border-bottom-color:var(--or) }
  header #pop { margin-left:auto }
  header #size { color:var(--dim); font-variant-numeric:tabular-nums }
  header #who { color:var(--or); letter-spacing:.08em }
  /* FENETRE ETROITE : mon rail (236px) + celui de la page embarquee (110px) mangent 346px avant
     le moindre contenu. Sous 900px, le rail se reduit a une colonne d'icones-texte pour rendre
     la place a ce qu'on est venu regarder. */
  @media (max-width: 900px) {
    nav { width:104px; flex:0 0 104px }
    nav h1 { margin-left:10px; font-size:12px; letter-spacing:.12em }
    .grp { margin-left:10px; font-size:10px }
    .tab { padding:6px 10px; font-size:12px }
    .tab .meta { display:none }
  }
  /* LA SCENE : position:relative + panneaux en inset:0 absolu, parce que xterm.js MESURE son
     conteneur pour calculer colonnes et lignes. Un panneau sans taille propre lui ferait proposer
     une geometrie fausse, que le shell croirait. En absolu dans une scene qui a une taille, la
     question ne se pose ni pour l'un ni pour l'autre. */
  #stage { flex:1; min-height:0; position:relative }
  .pane { position:absolute; inset:0; width:100%%; height:100%%; border:0; background:#000 }
  .pane[hidden] { display:none }
  #panel { position:absolute; inset:0; overflow-y:auto; padding:22px 26px }
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
  <!-- PAS DE « ouvrir dans une fenetre » : il n'y a aucune URL a ouvrir. Une cible sur son propre
       port donnerait une adresse a chaque onglet — la seconde origine que cette page refuse. -->
  <header><b id="crumb">STATUT</b><span id="hint"></span><span id="size"></span><span id="who">%(who)s</span><a href="/auth/logout">sortir</a></header>
  <div id="stage"><div id="panel"></div></div>
</main>
<script>
// PAS DE `HOST` : aucune cible n'a d'adresse. Un `http://<hote>:<port>` par onglet serait la
// seconde origine, en une ligne.
let current = null;
// Ecrit par le serveur dans CETTE page, pour CETTE session : le seul moyen d'en obtenir
// un est d'avoir recu la page, donc d'avoir passe la porte.
const CSRF = '%(csrf)s';

// ⚠ `stage` ET `panel` SONT AU SCOPE DU MODULE, JAMAIS DANS `show()`. `termPane()`, defini au meme
// niveau que `show()`, les utilise (`stage.appendChild(host)`) — et JavaScript resout les noms
// LEXICALEMENT, pas depuis l'appelant : declares en `const` dans `show()`, le nom se resoudrait au
// global dans `termPane`, ou il n'existe pas — `ReferenceError: stage is not defined` AU PREMIER
// CLIC sur un terminal, c'est-a-dire sur la fonctionnalite entiere.
//
// Et rien ne l'attraperait : ce n'est pas une erreur de SYNTAXE, donc `node --check` la voit
// passer, et aucun test n'execute ce client. C'est le cout exact de « jamais execute ».
const stage = document.getElementById('stage');
const panel = document.getElementById('panel');

function el(t, cls, txt) { const e = document.createElement(t); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; }

function show(tab) {
  current = tab.key;
  document.querySelectorAll('.tab').forEach(b => b.classList.toggle('here', b.dataset.key === tab.key));
  document.getElementById('crumb').textContent = tab.crumb;
  document.getElementById('hint').textContent = tab.hint || '';

  // UN PANNEAU PAR ONGLET, CREE UNE FOIS ET JAMAIS RECONSTRUIT : le terminal est un objet de CETTE
  // page, le recreer fermerait sa socket et rouvrirait une session. Montrer/cacher ne detruit rien.
  // On ne masque JAMAIS le panneau qu'on s'apprete a montrer. `hidden` vaut `display:none` : un
  // aller-retour, meme d'un seul tick, RETIRE le contenu de la chaine de focus et le demasquage ne
  // le rend pas. Or `build()` rejoue `show()` sur CHAQUE changement de signature (une transition de
  // phase d'un pod qu'on ne regarde meme pas suffit) — donc l'humain qui tapait dans un terminal
  // perdait la main sans que rien de visible n'ait bouge. Un seul passage qui pose l'etat final :
  // la cible n'est pas touchee, les autres sont masquees. Mesure: document.activeElement retombait
  // sur <body> a chaque update de la liste des workers.
  stage.querySelectorAll('.pane').forEach(f => { f.hidden = (f.dataset.key !== tab.key); });
  if (tab.term) {
    panel.style.display = 'none';
    let t = terms.get(tab.key);
    if (!t) { t = termPane(tab); terms.set(tab.key, t); }
    t.host.hidden = false;
    // AJUSTER AU MOMENT OU ON MONTRE, ET PAS AVANT : un panneau cache a une taille CSS nulle, donc
    // tout `fit()` fait pendant qu'il l'etait a mesure du vide. Sans ce rappel, un terminal ouvert
    // en arriere-plan garde la geometrie qu'il avait a sa creation et le shell croit un ecran qui
    // n'existe pas.
    t.fit.fit();
    t.term.focus();
  } else if (tab.frame) {
    // ⚠ UN CADRE, ICI, ET CE N'EST PAS UNE SECONDE ORIGINE : `/doc/` est une route de CE serveur,
    // derriere CETTE session — rien a recoudre, contrairement a un ttyd sur son propre port. Et le contenu est un document, pas un terminal : il n'a ni socket a perdre ni
    // geometrie a ajuster.
    //
    // Cree UNE fois, comme les terminaux : recharger l'iframe a chaque clic reperdrait la page ou
    // le lecteur en etait.
    panel.style.display = 'none';
    let f = stage.querySelector(`.pane[data-key="${tab.key}"]`);
    if (!f) {
      f = el('div', 'pane');
      f.dataset.key = tab.key;
      const fr = document.createElement('iframe');
      fr.src = tab.frame;
      fr.title = tab.crumb;
      // ⚠ LE SIGNE POUR-CENT SE DOUBLE ICI, PARTOUT, Y COMPRIS DANS CE COMMENTAIRE. Ce bloc vit
      // dans PAGE, rendu par un formatage pour-cent de Python : un signe seul y est lu comme le
      // debut d'une conversion, et la page AUTHENTIFIEE meurt en « TypeError: not enough arguments
      // for format string ». La page no-auth marche, elle — donc le defaut n'apparait qu'APRES un
      // login reussi, ce qui est exactement la moitie qu'aucun temoin ne rend. Le reste du gabarit
      // est double depuis toujours ; ces deux-ci sont arrives avec l'onglet doc.
      fr.style.cssText = 'width:100%%;height:100%%;border:0;background:var(--bg)';
      f.appendChild(fr);
      stage.appendChild(f);
    }
    f.hidden = false;
  } else {
    panel.style.display = '';
    panel.innerHTML = ''; panel.appendChild(tab.render());
  }
}

// ─── LE TERMINAL, RENDU ICI, DANS CETTE PAGE ───────────────────────────────────────────────────
// PLUS D'IFRAME, ET CE N'ETAIT PAS UN DEFAUT DE GOUT. Le cadre existait pour recoudre DEUX ORIGINES
// — cette page d'un cote, un ttyd sur son propre port de l'autre — et c'est cette seconde origine
// qui ne demandait rien a personne. Le meme geste supprime le cadre et le trou : il n'y a plus qu'un
// serveur, celui qui a deja verifie la session, et le terminal vit dans SON dom.
//
// LE PROTOCOLE DE ttyd, MESURE DANS L'IMAGE SUR LE BINAIRE PINNE (1.7.7-40e79c7), pas recite :
//   ouverture : WebSocket(url, ["tty"]) sur .../ws
//   1re trame : JSON {AuthToken, columns, rows} ENCODE EN BINAIRE, sans prefixe
//   client -> : '0' saisie · '1' redimensionnement {columns,rows} · '2' pause · '3' reprise
//   -> client : '0' sortie · '1' titre de fenetre · '2' preferences
//   trame     : prefixe = 1er octet, charge = le reste ; binaryType = "arraybuffer"
//
// `AuthToken` part VIDE et c'est correct : l'authentification a eu lieu a la porte, et le relais
// pose l'identite dans un en-tete que le navigateur ne peut pas ecrire. Ce champ est celui d'un
// ttyd qu'on aurait publie ; ici il n'y a rien a authentifier une seconde fois.
const TERM_ENC = new TextEncoder();
const TERM_DEC = new TextDecoder();

function termPane(tab) {
  const host = el('div', 'pane');
  host.dataset.key = tab.key;

  const term = new Terminal({
    fontSize: 15, fontFamily: 'ui-monospace,"DejaVu Sans Mono",Menlo,monospace',
    theme: { background: '#000000', foreground: '#FF9900' },
    // Le scrollback du navigateur ne voit rien : tmux possede l'ecran. C'est xterm.js qui doit le
    // porter, sinon ce qui defile est perdu.
    scrollback: 10000, cursorBlink: true,
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);

  // OUVRIR AVANT DE MESURER. `fit()` lit les dimensions CSS du conteneur : appele avant que le
  // noeud ne soit dans le document, il n'a rien a mesurer et le terminal s'ouvre a une taille
  // arbitraire que le shell croit vraie.
  stage.appendChild(host);
  term.open(host);
  fit.fit();

  // LE COPIER AUTOMATIQUE SUR SELECTION, PORTE PAR CE CLIENT.
  //
  // Ce comportement n'est PAS celui de xterm.js : il vit dans le frontend applicatif de ttyd.
  // Mesure du 2026-08-15 sur le ttyd 1.7.7 pinne de l'image (frontend recupere sur sa socket, il
  // est gzippe dans le binaire et invisible a un `strings`) :
  //   term.onSelectionChange(() => { if (getSelection() !== '') { execCommand('copy'); overlay('✂') } })
  // Un client maison qui reporte le protocole ttyd (trames '0'/'1'/'2', init, sous-protocole) sans
  // ce comportement SELECTIONNE toujours ; c'est la copie qui manque, le geste echoue a la derniere
  // marche et rien ne le dit.
  //
  // POURQUOI SHIFT EST DANS LE GESTE (cf. console.tmux.conf) : `mouse on` donne le drag a tmux, et
  // relacher efface la selection. Shift contourne la capture — xterm.js reprend la souris et fait sa
  // propre selection. C'est CETTE selection que le handler ci-dessous copie.
  //
  // `execCommand('copy')` et pas `navigator.clipboard.writeText(term.getSelection())` : c'est la
  // forme MESUREE comme fonctionnelle dans ce deploiement. xterm.js pose sa selection dans son
  // textarea cache et cable un `copyHandler` sur l'evenement `copy` (verifie present dans le
  // xterm.js servi par le deck) — l'API moderne exige en plus un contexte sur et une activation
  // utilisateur que cet evenement ne garantit pas. Deprecie, mais c'est celle qui marche ici.
  term.onSelectionChange(() => {
    if (!term.getSelection()) return;
    try { document.execCommand('copy'); } catch (e) { /* pas de presse-papier : la selection reste */ }
  });

  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const sock = new WebSocket(`${proto}//${location.host}${tab.term}`, ['tty']);
  sock.binaryType = 'arraybuffer';

  const sendResize = () => {
    if (sock.readyState !== WebSocket.OPEN) return;
    sock.send(TERM_ENC.encode('1' + JSON.stringify({ columns: term.cols, rows: term.rows })));
  };

  sock.onopen = () => {
    sock.send(TERM_ENC.encode(JSON.stringify({
      AuthToken: '', columns: term.cols, rows: term.rows,
    })));
    term.onData(d => {
      if (sock.readyState === WebSocket.OPEN) sock.send(TERM_ENC.encode('0' + d));
    });
    term.onResize(sendResize);
  };

  sock.onmessage = (ev) => {
    const buf = new Uint8Array(ev.data);
    if (!buf.length) return;
    switch (String.fromCharCode(buf[0])) {
      case '0': term.write(buf.subarray(1)); break;
      case '1': document.title = TERM_DEC.decode(buf.subarray(1)); break;
      case '2': break;  // preferences : les notres sont deja posees a la construction
    }
  };

  // UNE FERMETURE SE DIT, ELLE NE SE DEVINE PAS A UN ECRAN QUI NE REPOND PLUS. Un terminal mort et
  // un terminal inactif sont indiscernables sans ca, et l'humain tape dans le vide.
  sock.onclose = () => term.write('\r\n\x1b[33m[connexion fermee]\x1b[0m\r\n');
  sock.onerror = () => term.write('\r\n\x1b[31m[connexion impossible]\x1b[0m\r\n');

  // `ResizeObserver` plutot que l'evenement `resize` de la fenetre : le panneau change aussi de
  // taille quand le rail se replie ou qu'un autre onglet s'ouvre, sans que la fenetre bouge.
  const ro = new ResizeObserver(() => { if (!host.hidden) fit.fit(); });
  ro.observe(host);

  return { host, term, sock, ro, fit };
}

// Les terminaux vivants, par cle d'onglet. Ils SURVIVENT au changement d'onglet — c'est la meme
// raison qu'avec les iframes : recreer le terminal a chaque retour perdrait l'ecran et rouvrirait
// une session. Montrer/cacher ne decharge rien.
const terms = new Map();

// Un onglet dont l'agent est mort n'a plus de cible : son cadre se ferme avec lui, sinon la page
// garderait des terminaux fantomes en memoire pour des pods qui n'existent plus.
//
// ⚠ UN TERMINAL SE FERME EN TROIS GESTES, ET EN OUBLIER UN LAISSE UNE FUITE MUETTE : la socket
// (sinon le relais garde un conduit ouvert vers un ttyd, cote serveur, pour un onglet qui n'existe
// plus), l'observateur de taille, et l'instance xterm. Retirer le seul noeud du DOM n'en fait aucun.
function dropPanes(keys) {
  for (const [key, t] of terms) {
    if (keys.has(key)) continue;
    try { t.sock.close(); } catch (e) {}
    try { t.ro.disconnect(); } catch (e) {}
    try { t.term.dispose(); } catch (e) {}
    terms.delete(key);
  }
  document.querySelectorAll('.pane').forEach(f => {
    if (!keys.has(f.dataset.key)) f.remove();
  });
}

// TROIS ETATS, ET AUCUN NE SE DIT COMME UN AUTRE. « eteinte » est une AFFIRMATION : on ne la
// prononce que quand la connexion a ete refusee, c'est-a-dire qu'on a mesure que personne n'ecoute.
// Un timeout ne dit rien, et une page qui le traduit en « eteinte » ment a son lecteur.
function fleetLabel(h) {
  switch (h.fleet_status) {
    case 'live':    return `fleet vivante — ${h.pods.length} pod(s)`;
    case 'off':     return 'fleet eteinte';
    case 'deaf':    return 'deck present, reponse illisible';
    // Le deck ECOUTE ; c'est nous qui n'avons pas le droit d'ouvrir sa socket. Un etat a part, et
    // le seul de cette liste qui se repare par un geste precis.
    case 'denied':  return 'deck present, ACCES REFUSE a sa socket';
    default:        return 'fleet NON MESUREE (deck injoignable)';
  }
}

function fleetHint(h) {
  switch (h.fleet_status) {
    case 'live':    return '';
    case 'off':     return '(la fleet de cet humain ne tourne pas)';
    case 'deaf':    return '(le deck repond, mais pas ce qu\'on attend)';
    // L'indice DIT LE GESTE, parce que celui-la est reparable : il manque au landing le groupe
    // supplementaire, ou le repertoire de socket de cet humain n'a pas le mode attendu.
    case 'denied':  return '(socket presente, ouverture refusee — groupe du deck ou mode du repertoire)';
    default:        return '(pas de reponse en 2 s — on ne sait PAS si elle tourne)';
  }
}

// CE QUE L'ENROLLMENT NE PEUT PAS FABRIQUER, DIT ICI ET PAS AU PREMIER SPAWN QUI ECHOUE. Un humain
// tout juste convergé a un compte systeme, un compte forge, et AUCUNE capacite a spawner : il lui
// manque son `claude /login`, que personne ne peut faire a sa place. Rien dans la chaine ne le lui
// disait — il le rencontrait sous forme de pod mort.
// « posees », jamais « valides » : la validite se tranche au spawn, dans le runtime.
function claudeLabel(h) {
  switch (h.claude) {
    case 'present': return 'credentials claude posees (leur validite se tranche au spawn)';
    case 'absent':  return 'AUCUNE credential claude — aucun pod ne peut naitre';
    default:        return 'credentials claude NON MESUREES (home non traversable)';
  }
}

// ─── L'OBSERVATION, RENDUE ICI ─────────────────────────────────────────────────────────────────
// PAS DE CADRE, PAS DE SECONDE ORIGINE. Le deck d'observation n'a plus de port : ses deux routes
// sont lues par le serveur sur la socket de l'humain, et cette fonction rend ce qu'elles disent.
//
// ⚠ IL FAUT LES DEUX ROUTES. `/api/pods` alimente UN panneau ; les six autres viennent de
// `/api/projection`. Rendre depuis les seuls pods perdrait six panneaux en silence tout en ayant
// l'air d'avoir embarque le deck.
//
// ⚠ ET LA CICATRICE DU DECK SE GARDE : une projection `deaf`/`unavailable` est un FLUX FIGE, pas
// une flotte calme. Un read-model mort rend `total:0` et des listes vides — exactement ce que rend
// une fleet paisible. Sans le bandeau ci-dessous, la page affirme le calme sur un aveuglement.
function projectionBanner(h) {
  switch (h.projection_status) {
    case 'live':        return null;
    case 'deaf':        return 'projection SOURDE — le read-model vit mais ne recoit plus rien : flux FIGE, PAS une flotte calme';
    case 'unavailable': return 'projection INDISPONIBLE — le read-model est tombe : ce qui suit est vide par panne, pas par calme';
    case 'denied':      return 'projection NON LUE — acces refuse a la socket du deck';
    case 'off':         return 'fleet eteinte — rien a projeter';
    default:            return 'projection NON MESUREE — on ne sait pas si ces panneaux sont a jour';
  }
}

function observationPanel(h) {
  const wrap = el('div');
  const banner = projectionBanner(h);
  if (banner) {
    const b = el('div', 'note');
    b.textContent = '⚠ ' + banner;
    wrap.appendChild(b);
  }

  const proj = h.projection || {};
  const t = el('table');
  const rows = [['pods vivants', String((h.pods || []).length)],
                ['evenements projetes', String(proj.total != null ? proj.total : '—')]];
  for (const [k, v] of Object.entries(proj.counts || {})) rows.push(['  ' + k, String(v)]);
  for (const [k, v] of rows) {
    const tr = el('tr'); tr.appendChild(el('th', null, k)); tr.appendChild(el('td', null, v)); t.appendChild(tr);
  }
  wrap.appendChild(t);

  // Les cinq listes du read-model, dans l'ordre ou le deck les presente. Une liste VIDE se dit
  // « aucun », jamais rien : une section absente et une section vide se lisent pareil, et seule la
  // seconde est une information.
  for (const [key, label] of [['stream', 'flux'], ['workflow_runs', 'runs de workflow'],
                              ['gatekeeper', 'gatekeeper'], ['coordination', 'coordination'],
                              ['diagnostics', 'diagnostics']]) {
    const items = proj[key] || [];
    wrap.appendChild(el('div', 'grp', label));
    if (!items.length) { wrap.appendChild(el('div', 'note', 'aucun')); continue; }
    const ul = el('table');
    for (const it of items.slice(0, 40)) {
      const tr = el('tr');
      tr.appendChild(el('td', null, typeof it === 'string' ? it : JSON.stringify(it)));
      ul.appendChild(tr);
    }
    wrap.appendChild(ul);
    if (items.length > 40) wrap.appendChild(el('div', 'note', `… ${items.length - 40} de plus`));
  }
  return wrap;
}

function statusPanel(s) {
  const wrap = el('div');
  const t = el('table');
  const rows = [['hostname', s.hostname]];
  for (const h of s.humans) {
    rows.push([`humain ${h.human} (uid ${h.uid})`, fleetLabel(h)]);
    rows.push(['  acces claude', claudeLabel(h)]);
  }
  for (const [k, v] of rows) {
    const tr = el('tr'); tr.appendChild(el('th', null, k)); tr.appendChild(el('td', null, v)); t.appendChild(tr);
  }
  wrap.appendChild(t);
  if (s.humans.some(h => h.claude === 'absent')) {
    const g = el('div', 'note');
    g.innerHTML = "Il te reste <b>un geste, et un seul</b>, que personne ne peut faire a ta place : " +
      "ouvre ta console, tape <b>claude</b>, puis <b>/login</b>, dis bonjour, <b>/exit</b>. " +
      "Tant qu'il n'est pas fait, ta fleet demarre mais <b>aucun agent ne peut naitre</b> — " +
      "ce n'est pas une panne, c'est ton identite chez le fournisseur, et elle t'appartient.";
    wrap.appendChild(g);
  }
  const n = el('div', 'note');
  n.innerHTML = "Cette page ne <b>pilote</b> rien : elle lit et elle montre. " +
    "La liste des agents est relue toutes les 10 s — un pod qui nait ou meurt apparait ou disparait ici sans rechargement.";
  wrap.appendChild(n);
  return wrap;
}

// L'ONGLET QUI DIT CE QU'IL N'EST PAS ENCORE. Une page vide sous un onglet nomme se lit comme une
// panne ; celle-ci enonce qu'elle est un emplacement, et ce qui viendra s'y poser. Le jour ou le
// premier pouvoir arrive, c'est ce texte qu'on remplace — pas un onglet qu'on ajoute.
function adminPanel() {
  const wrap = el('div');
  const n = el('div', 'note');
  n.innerHTML = "Cet onglet n'est visible que des <b>administrateurs de la forge</b> — " +
    "la forge repond <b>is_admin</b>, le deck le lit a ta connexion, et il n'existe " +
    "<b>aucune autre liste</b> a tenir a jour ici. Un second administrateur, c'est un compte " +
    "marque admin sur la forge : rien a poser sur le conteneur.<br><br>" +
    "Il est <b>vide, et c'est exact</b> : le chemin d'autorisation existe et il est teste, " +
    "aucun pouvoir ne s'y branche encore. Le premier prevu est l'<b>edition des cartes</b>. " +
    "Ce que la forge affirme ne franchit d'ailleurs pas tout : elle fait autorite sur les " +
    "<b>personnes</b>, pas sur la machine — installer, monter un volume, parler a docker " +
    "reste <b>ssh</b> et <b>root</b>.";
  wrap.appendChild(n);
  return wrap;
}

function depositPanel(s) {
  const wrap = el('div');
  const cfg = s.deposit || {};
  const max = cfg.max_bytes || 0;

  // LES PROJETS OUVERTS SORTENT DES PODS QU'ON A DEJA, comme les groupes de la barre laterale : un
  // projet est ouvert quand un de ses pods vit, et l'ouvrir lance son architecte. Une seconde liste,
  // calculee autrement, divergerait de ce que le rail affiche a gauche.
  const ouverts = [...new Set(
    (s.humans || []).flatMap(h => (h.pods || []).map(p => p.project).filter(Boolean))
  )].sort();

  const n = el('div', 'note');
  if (!ouverts.length) {
    n.innerHTML = "<b>Aucun projet ouvert.</b> Un dépôt vise le dépôt d'un projet dont la fleet " +
      "porte au moins un pod ; ouvre un projet, son architecte se lance, et il apparaîtra ici.";
    wrap.appendChild(n);
    return wrap;
  }
  n.innerHTML = "Le fichier part dans le dépôt du projet, branche <b>" + (cfg.branch || '?') +
    "</b>, sous <b>" + (cfg.dir || '?') + "/</b>, avec <b>toi comme auteur du commit</b>. " +
    "La poussée reste celle du compte système : ce conteneur n'a pas de jeton personnel. " +
    "C'est une <b>trace</b> de qui a déposé quoi, vérifiable dans l'historique.<br><br>" +
    "Taille maximale : <b>" + Math.floor(max / 1000000) + " Mo</b>. " +
    "Un fichier du même nom est <b>remplacé</b> : l'ancien reste dans l'historique du dépôt.";
  wrap.appendChild(n);

  const choix = document.createElement('select');
  choix.style.cssText = 'background:#111;color:var(--or);border:2px solid var(--or);padding:6px 10px;margin-right:12px';
  for (const proj of ouverts) {
    const o = document.createElement('option');
    o.value = proj; o.textContent = proj;
    choix.appendChild(o);
  }
  const pick = document.createElement('input');
  pick.type = 'file';
  const go = el('button', 'tab', 'Deposer');
  go.style.cssText = 'width:auto;padding:8px 18px;border:2px solid var(--or);margin:14px 0';
  const out = el('div', 'note');
  out.style.display = 'none';
  const ligne = el('div');
  ligne.appendChild(choix); ligne.appendChild(pick);
  wrap.appendChild(ligne); wrap.appendChild(go); wrap.appendChild(out);

  const say = (txt, bad) => {
    out.style.display = '';
    out.style.borderLeftColor = bad ? '#c33' : 'var(--or)';
    out.textContent = txt;
  };

  go.onclick = async () => {
    const f = pick.files && pick.files[0];
    if (!f) { say('choisis un fichier', true); return; }
    if (max && f.size > max) { say('ce fichier depasse la borne du depot', true); return; }
    go.disabled = true;
    say('depot en cours…');
    try {
      // LE FICHIER EST LE CORPS, TEL QUEL. `fetch` prend l'objet File : le navigateur le lit depuis
      // le disque en le transmettant, sans le charger en memoire, et le serveur l'ecrit au fil de
      // l'eau. Le nom et le projet voyagent dans la ligne de requete.
      const url = '/deposit?project=' + encodeURIComponent(choix.value) +
                  '&name=' + encodeURIComponent(f.name);
      const rep = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/octet-stream', 'X-Deck-Csrf': CSRF },
        body: f,
      });
      const j = await rep.json().catch(() => ({}));
      if (rep.ok && j.ok) {
        say('depose : ' + j.repo + ' ' + j.path + ' (commit ' + String(j.sha).slice(0, 12) + ')');
        pick.value = '';
      } else {
        say('refuse : ' + (j.why || j.error || rep.status), true);
      }
    } catch (e) {
      say('depot interrompu : ' + e, true);
    } finally {
      go.disabled = false;
    }
  };
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

  add('conteneur', 'Statut', null, { key: 'status', crumb: 'STATUT', render: () => statusPanel(s) });
  // LA DOC DE CETTE VERSION, servie par CE serveur. Pas un lien vers le site en ligne : celui-la
  // decrit la derniere version publiee, celle-ci decrit le conteneur qu'on regarde. Meme origine, meme
  // porte — le cadre charge une route du deck, derriere la session deja verifiee.
  //
  // INCONDITIONNEL. Un `if (s.doc)` au motif qu'une image batie avant le stage `site` n'aurait rien
  // a servir ne garderait rien : cette image N'EXISTE PAS (les bancs se rebatissent entiers, et le
  // Dockerfile pose la doc au meme titre que le runtime) — et il CACHERAIT une image cassee au lieu
  // de la montrer. Doc absente = image ratee : l'onglet s'ouvre, la route rend 404, ca se voit.
  add(null, 'Doc', 'cette version', { key: 'doc', crumb: 'DOC', frame: '/doc/' });
  // BOITE DE DEPOT : un onglet pour tout le monde, parce que tout visiteur d'ici est de l'equipe
  // humans — la porte l'a deja etabli, et la porte d'en face le redemande a la forge.
  add(null, 'Boite de depot', 'vers un projet ouvert',
      { key: 'deposit', crumb: 'BOITE DE DEPOT', render: () => depositPanel(s) });
  // Cache l'ONGLET, pas le pouvoir : le serveur re-tranche sur la session a chaque cible. Retirer ce
  // `if` depuis la console du navigateur ne ferait apparaitre qu'un onglet — et 404 sur ce qu'il
  // ouvre. Un rail qui se dessine sur une reponse du serveur est un confort de lecture ; s'il etait
  // AUSSI la barriere, la barriere vivrait chez le visiteur.
  if (s.admin) {
    add(null, 'Admin', 'forge', { key: 'admin', crumb: 'ADMIN', render: () => adminPanel() });
  }

  for (const h of s.humans) {
    // MEME ORIGINE, CHEMIN RELATIF : plus de `http://HOST:port`. La cible n'est plus une adresse
    // qu'on pourrait taper ailleurs, c'est une route de CE serveur, derriere la session qu'il a
    // deja verifiee. C'est toute la these du lot en une ligne.
    add('humain ' + h.human, 'Console', 'shell ' + h.human,
        { key: 'console-' + h.human, crumb: 'CONSOLE — ' + h.human,
          term: `/console/${encodeURIComponent(h.human)}/ws` });
    // RENDU LOCAL, PLUS UN CADRE : le deck d'observation n'a plus de port, ses deux routes sont
    // lues par le serveur sur la socket de cet humain et arrivent deja dans `/api/state`.
    add(null, 'Deck d\'observation', fleetLabel(h),
        { key: 'deck-' + h.human, crumb: 'DECK — ' + h.human,
          hint: fleetHint(h),
          render: () => observationPanel(h) });

    // Les agents, GROUPES PAR PROJET. Le rattachement est celui que le RUNTIME publie ; un pod
    // sans projet est fleet-level, il a son propre groupe au lieu d'etre range de force.
    //
    // FLEET EN TETE, ET SANS LE MOT « PROJET ». Le groupe fleet-level est FIXE — il existe a
    // chaque boot, avant tout projet, et il n'en est pas un. Le trier alphabetiquement le ferait
    // apparaitre au milieu des projets, a une place qui changerait avec eux ; l'appeler « projet
    // fleet » le rangerait dans une categorie a laquelle il n'appartient pas.
    const FLEET = 'Fleet';
    const byProject = {};
    for (const p of h.pods) (byProject[p.project || FLEET] ||= []).push(p);
    const groups = Object.keys(byProject).filter((k) => k !== FLEET).sort();
    if (byProject[FLEET]) groups.unshift(FLEET);
    for (const proj of groups) {
      let first = true;
      for (const p of byProject[proj].sort((a, b) => a.pod_id.localeCompare(b.pod_id))) {
        add(first ? (proj === FLEET ? FLEET : 'projet ' + proj) : null,
            p.role, p.phase + ' · ' + p.pod_id,
            { key: 'pod-' + p.pod_id, crumb: p.role.toUpperCase() + ' — ' + proj,
              hint: p.pod_id,
              // `?arg=` reste : c'est `--url-arg` de ttyd, et `console-pod.sh` le valide encore
              // (forme, unicite, socket existante), et il ne suffit pas : la socket atteinte est
              // celle de CET humain — l'appelant est etabli AVANT que l'argument n'arrive (6-098).
              term: `/pod/${encodeURIComponent(h.human)}/ws?arg=${encodeURIComponent(p.pod_id)}` });
        first = false;
      }
    }
  }

  dropPanes(new Set(tabs.map(t => t.key)));
  const keep = tabs.find(t => t.key === current) || tabs[0];
  show(keep);
}

async function tick() {
  try {
    const r = await fetch('/api/state', { cache: 'no-store' });
    // UNE SESSION MORTE NE SE GARDE PAS A L'ECRAN. Sans ce test, un 401 tomberait dans le `catch`
    // avec le reste et la page continuerait d'afficher son dernier etat : un deck d'apparence
    // vivante pour quelqu'un qui n'est plus identifie. La porte tranche, pas le cadre — on
    // recharge et c'est le serveur qui dit ce qu'on a le droit de voir.
    if (!r.ok) { location.reload(); return; }
    const s = await r.json();
    // `claude` fait partie de la signature : le jour ou la personne finit son `/login`, la page
    // doit cesser de lui reclamer sans qu'elle ait a recharger — sinon elle croit que ca n'a pas
    // marche et le refait.
    const sig = JSON.stringify(s.humans.map(h => [h.human, h.fleet_status, h.claude, h.pods.map(p => [p.pod_id, p.role, p.phase, p.project])]));
    if (sig !== window.__sig) { window.__sig = sig; build(s); }
  } catch (e) { /* la page survit a une sonde ratee : elle garde son dernier etat vrai */ }
}
// La taille du cadre est AFFICHEE, pas supposee : quand une page embarquee se replie, la premiere
// question est « combien de place lui donne-t-on ? ». Sans cette lecture, on debogue le CSS de la
// page invitee alors que c'est l'hote qui l'etrangle — ou l'inverse.
function showSize() {
  const st = document.getElementById('stage');
  if (st) document.getElementById('size').textContent = Math.round(st.clientWidth) + '×' + Math.round(st.clientHeight) + ' px';
}
addEventListener('resize', showSize);
setInterval(showSize, 1000);
showSize();
tick(); setInterval(tick, 10000);
</script>
"""


class Deck(BaseHTTPRequestHandler):
    server_version = "lcars-deck"

    # ⚠ HTTP/1.1 IS A PREREQUISITE, NOT A MODERNISATION: `BaseHTTPRequestHandler` defaults to 1.0,
    # and a 1.0 responder CANNOT perform `101 Switching Protocols` — so the deck could not terminate
    # a WebSocket at all, and every terminal would need its own origin behind its own port.
    #
    # ⚠ SAFE ONLY BECAUSE EVERY RESPONSE PATH IS LENGTH-DELIMITED: 1.1 keeps the connection alive, so
    # a reply with neither `Content-Length` nor chunked encoding leaves the client waiting for an end
    # that never comes. Both paths here set it, and there is no `send_error` call. A THIRD PATH ADDED
    # LATER MUST SET IT TOO.
    protocol_version = "HTTP/1.1"

    # ⚠ `rbufsize = 0` EST UNE CONDITION DU RELAIS, PAS UN REGLAGE DE PERFORMANCE : le
    # `BufferedReader` par defaut peut tirer PLUS d'octets que la requete en lisant les en-tetes, et
    # ces octets resteraient dans un tampon que `_pump` — qui lit la socket brute — ne verra jamais.
    # Perdus silencieusement, et seulement quand le client parle en premier : la panne la plus
    # difficile a attribuer qui soit.
    #
    # LE PRIX EST ASSUME : un appel systeme par caractere d'en-tete, sur une poignee de requetes par
    # session humaine.
    rbufsize = 0

    def _send(self, code, body, ctype, cookie=None):
        raw = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(raw)

    def _redirect(self, where, cookie=None):
        self.send_response(302)
        self.send_header("Location", where)
        self.send_header("Cache-Control", "no-store")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _callback_uri(self):
        """
        Where the forge sends the person back -- DERIVED FROM THE REQUEST, not from config.

        The same deck is reached as `127.0.0.1:20999` from the container's own host and as
        `<lan-addr>:20999` from anyone else's machine, and OAuth2 matches the redirect URI
        EXACTLY against the registered list. Echoing the Host we were actually asked on is the
        only value that can be right for both; the registration must carry every entrance in use,
        and a missing one fails here, on the way back, with the URI printed below.
        """
        host = self.headers.get("Host") or f"127.0.0.1:{PORT}"
        return f"http://{host}/auth/callback"

    # ── the door ────────────────────────────────────────────────────────────────────────────────
    def _auth_login(self, cfg):
        st = secrets.token_urlsafe(24)
        redirect = self._callback_uri()
        # REFUSER ICI PLUTOT QUE DE LAISSER LA FORGE LE FAIRE APRES COUP. OAuth2 compare le
        # `redirect_uri` a une liste enregistree ; une entree absente donne une 400 de Gitea au titre
        # generique, qui ne nomme meme pas `redirect_uri` (mesure) — et elle tombe APRES
        # l'identification, sur une page qui n'est pas la notre. On a la liste, on tranche avant.
        # Absente de la config (fichier d'avant cette version) = on ne sait pas, donc on n'invente
        # aucun refus : la forge reste l'autorite.
        known = cfg.get("redirect_uris")
        if known and redirect not in known:
            self._send(409, page_unknown_entrance(redirect, known), "text/html; charset=utf-8")
            return
        now = time.time()
        with _lock:
            _sweep(now)
            _pending[st] = {"redirect": redirect, "exp": now + PENDING_TTL}
        q = urllib.parse.urlencode({
            "client_id": cfg["client_id"],
            "redirect_uri": redirect,
            "response_type": "code",
            # `groups` is the whole point: it carries the team membership that decides the gate.
            "scope": "openid profile email groups",
            "state": st,
        })
        self._redirect(f"{cfg['public_url'].rstrip('/')}/login/oauth/authorize?{q}")

    def _auth_callback(self, cfg, query):
        args = urllib.parse.parse_qs(query)
        st = (args.get("state") or [""])[0]
        code = (args.get("code") or [""])[0]
        with _lock:
            pending = _pending.pop(st, None)
        # An unknown `state` is a callback we never started: a forged one, or one that outlived its
        # ten minutes. Refusing it is what stops a third party from planting their session here.
        if not pending or not code:
            self._send(400, page_login(cfg.get("public_url")), "text/html; charset=utf-8")
            return
        try:
            tokens = _post_form(f"{cfg['internal_url'].rstrip('/')}/login/oauth/access_token", {
                "grant_type": "authorization_code",
                "client_id": cfg["client_id"],
                "client_secret": cfg["client_secret"],
                "redirect_uri": pending["redirect"],
                "code": code,
            })
            info = _get_json(
                f"{cfg['internal_url'].rstrip('/')}/login/oauth/userinfo", tokens["access_token"]
            )
        except (HTTPError, URLError, TimeoutError, socket.timeout, KeyError, ValueError) as e:
            self._send(502, page_unconfigured(f"echange OAuth2 refuse par la forge: {e}"),
                       "text/html; charset=utf-8")
            return

        login = info.get("preferred_username") or ""
        groups = info.get("groups") or []
        # LU ICI, ET NULLE PART AILLEURS : c'est le seul endroit du deck ou un jeton d'acces existe.
        # Le lire plus tard couterait un credential de service stocke sur le conteneur — exactement ce
        # que ce lot passe son temps a retirer. Lu AVANT la porte : admiral (le master/sysadmin) est
        # site-admin mais PAS dans fleet:humans — il entre par la porte ADMIN (is_admin), distincte
        # de la porte worker. Une fois entre, tout est transparent : sa console tourne sous lui (uid
        # 1000, sudo -> root ; le deck ne fait que relayer un shell), Guard B lui interdit de lancer
        # une fleet, et is_admin lui donne l'onglet admin.
        admin = forge_is_admin(cfg, tokens["access_token"])
        if HUMANS_TEAM not in groups and not admin:
            self._send(403, page_denied(login, groups), "text/html; charset=utf-8")
            return

        sid = secrets.token_urlsafe(32)
        with _lock:
            # ⚠ LE JETON ANTI-REJEU NAIT AVEC LA SESSION, ET IL NE VOYAGE PAS DANS LE COOKIE.
            # `SameSite=Lax` empeche deja un POST venu d'un autre site d'emporter le cookie ; ce
            # jeton ferme ce que Lax laisse — une page de ce meme deck, ouverte ailleurs, et les
            # navigateurs qui n'appliquent pas Lax. Il est lu dans un en-tete, que seule une
            # requete ecrite par cette page peut poser.
            _sessions[sid] = {"login": login, "groups": groups, "admin": admin,
                              "csrf": secrets.token_urlsafe(32),
                              "exp": time.time() + SESSION_TTL}
        # No `Secure`: the deck serves plain HTTP on a LAN port by design (there is no TLS to opt
        # into here). `HttpOnly` + `SameSite=Lax` still hold -- they cost nothing and remove the
        # two ways a page in another tab could reach this cookie.
        self._redirect("/", f"{SESSION_COOKIE}={sid}; HttpOnly; SameSite=Lax; Path=/; Max-Age={SESSION_TTL}")

    def _auth_logout(self, cfg):
        """
        SE DECONNECTER DOIT DECONNECTER — LES DEUX SESSIONS.

        Fermer NOTRE session seule laisse celle de la forge — et comme l'application est deja
        autorisee, le `/auth/login` suivant traverse sans une seule question et remet la personne
        dedans. Vu du dehors ce n'est pas une deconnexion, c'est un aller-retour avec des etapes en
        plus. Et sans lien vers la forge sur la page de login, on ne pourrait meme pas aller s'y
        deconnecter sans connaitre son URL.

        Gitea n'expose PAS d'`end_session_endpoint` (verifie dans sa decouverte OIDC), donc pas de
        deconnexion RP-initiee standard. Mais `GET /user/logout` marche comme un simple lien et tue
        bien la session — mesure : `/user/settings` passe de 200 a 303 apres l'appel. Il ignore
        `redirect_to`, donc la personne atterrit sur l'accueil de la forge : c'est le comportement de
        la forge, pas le notre, et ca la laisse a un endroit ou elle voit qu'elle est deconnectee.

        Ce qu'on ne peut pas promettre : que la deconnexion cote forge ait REUSSI. C'est le
        navigateur qui la fait, pas nous. Notre session, elle, est morte avant la redirection.
        """
        sess = session_of(self.headers.get("Cookie"))
        if sess:
            with _lock:
                _sessions.pop(sess["sid"], None)
        where = f"{cfg['public_url'].rstrip('/')}/user/logout" if cfg else "/"
        self._redirect(where, f"{SESSION_COOKIE}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0")

    # ─── LA SEULE ROUTE QUI ECRIT ───────────────────────────────────────────────────────────────
    #
    # ⚠ ELLE N'ECRIT QUE DANS LA ZONE DE TRANSIT. Le deck pose le fichier sur le disque, en donne le
    # chemin a la porte qui detient le jeton, et le retire ensuite. Ce process reste sans jeton,
    # sans groupe `fleet`, et sans rien a ecrire ailleurs.
    #
    # ⚠ LE CORPS EST LE FICHIER, BRUT. Le nom et le projet voyagent dans la ligne de requete : un
    # corps JSON aurait impose du base64, donc un tiers de plus sur le fil et trois copies en
    # memoire. A 50 Mo, c'est la difference entre un depot et un incident.
    #
    # ⚠ `Content-Length` SUR CHAQUE SORTIE, y compris les refus : la classe est en HTTP/1.1, une
    # reponse sans longueur laisserait le navigateur attendre une fin qui ne vient pas.
    def do_POST(self):
        path, _, query = self.path.partition("?")
        if path != "/deposit":
            self._send(404, "not found\n", "text/plain; charset=utf-8")
            return

        def refuse(code, why):
            self._send(code, json.dumps({"ok": False, "why": why}),
                       "application/json; charset=utf-8")

        sess = session_of(self.headers.get("Cookie"))
        if not sess:
            refuse(401, "session expiree — recharge la page")
            return
        # ⚠ UNE SESSION SANS JETON NE VAUT PAS UN JETON VIDE. `compare_digest("", "")` rend VRAI :
        # une session nee avant ce champ — ou fabriquee par un test qui l'ignore — aurait accepte
        # une requete sans en-tete du tout. L'absence de reponse est un refus, ici comme ailleurs.
        # La comparaison, elle, est a temps constant : elle porte sur un secret de session.
        attendu = sess.get("csrf") or ""
        if not attendu or not secrets.compare_digest(self.headers.get("X-Deck-Csrf", ""), attendu):
            refuse(403, "jeton de page invalide — recharge la page")
            return

        params = urllib.parse.parse_qs(query)
        projet = (params.get("project") or [""])[0].strip()
        # LE NOM EST REDUIT A SA DERNIERE COMPOSANTE : un navigateur rend `photo.png`, mais rien
        # n'oblige un client a le faire. La porte refuse de toute facon ce qui n'est pas un nom
        # simple ; ici on ne veut pas refuser un depot legitime pour un chemin que le systeme de
        # l'humain a colle devant.
        name = os.path.basename((params.get("name") or [""])[0].replace("\\", "/")).strip()
        if not projet or not name:
            refuse(400, "projet ou nom de fichier manquant")
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            refuse(400, "requete illisible")
            return
        if length <= 0:
            refuse(400, "fichier vide ou sans nom")
            return
        if length > DEPOSIT_MAX_BYTES:
            # On ne draine pas un corps qu'on refuse : la connexion ne peut pas resservir.
            self.close_connection = True
            refuse(413, "fichier trop gros pour la boite de depot")
            return

        try:
            spool, taille, digest = spool_write(self.rfile, length)
        except ValueError:
            self.close_connection = True
            refuse(413, "fichier trop gros pour la boite de depot")
            return
        except OSError as exc:
            print(f"[lcars-deck] transit impossible ({DEPOSIT_SPOOL}) : {exc}",
                  file=sys.stderr, flush=True)
            refuse(503, "ce conteneur n'a pas de zone de transit ecrivable")
            return

        try:
            if taille == 0:
                refuse(400, "fichier vide ou sans nom")
                return
            ok, detail = deposit(sess["login"], projet, name, spool, taille, digest)
        finally:
            spool_remove(spool)

        if ok:
            self._send(200, json.dumps({"ok": True, "sha": detail["sha"], "repo": detail["repo"],
                                        "path": detail["path"], "sha256": detail["sha256"]}),
                       "application/json; charset=utf-8")
            return
        # La cause est un jeton ; la phrase vit dans `DEPOSIT_CAUSES`, ici, parce que c'est cette
        # page que l'operateur regarde. Ce qui n'y est pas se montre tel quel.
        code = 502 if detail in ("porte_fermee", "porte_muette", "forge_unreachable") else 422
        refuse(code, DEPOSIT_CAUSES.get(detail, f"refus de la porte de depot : {detail}"))

    def do_GET(self):
        path, _, query = self.path.partition("?")

        # `/health` answers BEFORE the door: it reports that this process is up, which is true
        # whether or not anyone is logged in, and the container's healthcheck has no session.
        if path == "/health":
            self._send(200, "ok\n", "text/plain; charset=utf-8")
            return

        # Le favicon AUSSI avant la porte : le navigateur le demande sur chaque page, login comprise,
        # et il n'a rien de sensible — c'est la marque. Source unique dans l'image (DECK_FAVICON),
        # jamais recopiee ici. Deux noms figes, aucune traversee de chemin depuis l'URL.
        if path in ("/favicon.svg", "/favicon.ico"):
            fav, ctype = (("favicon.svg", "image/svg+xml") if path.endswith(".svg")
                          else ("favicon.ico", "image/x-icon"))
            try:
                with open(os.path.join(DECK_FAVICON, fav), "rb") as fh:
                    raw = fh.read()
            except OSError:
                self._send(404, "not found\n", "text/plain; charset=utf-8")
                return
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(raw)
            return

        cfg, why = oidc_config()
        if not cfg:
            self._send(503, page_unconfigured(why), "text/html; charset=utf-8")
            return

        if path == "/auth/login":
            self._auth_login(cfg)
            return
        if path == "/auth/callback":
            self._auth_callback(cfg, query)
            return
        if path == "/auth/logout":
            self._auth_logout(cfg)
            return

        sess = session_of(self.headers.get("Cookie"))
        if not sess:
            if path == "/api/state":
                self._send(401, json.dumps({"error": "unauthenticated"}),
                           "application/json; charset=utf-8")
            else:
                self._send(200, page_login(cfg.get("public_url")), "text/html; charset=utf-8")
            return

        # Enrolled on the forge, no system user here. TWO STATES, AND THEY MUST NOT BE SAID ALIKE:
        # either the converger has not got to it yet (wait), or the converger REFUSED this login
        # and always will (act). Collapsing them into "it converges on its own" is a lie to the
        # second person, and it is the kind of lie nobody ever comes back to check.
        # ⚠ « JE N'AI PAS PU LIRE LA LISTE » N'EST PAS « TU N'AS PAS DE SIEGE ». Les deux etats
        # ci-dessous accusent le convergeur — l'un dit « pas encore », l'autre « jamais ». Les
        # servir sur une panne de lecture ferait accuser le convergeur d'un tort qui n'est pas le
        # sien, a quelqu'un qui n'a rien a corriger. Un refus qui nomme le mauvais coupable coute
        # plus cher qu'un refus qui dit « je ne sais pas ».
        try:
            people = humans()
        except (OSError, ValueError, subprocess.SubprocessError) as e:
            print(f"[lcars-deck] liste des humains ILLISIBLE : {e}", file=sys.stderr, flush=True)
            if path == "/api/state":
                self._send(503, json.dumps({"error": "humans_unreadable"}),
                           "application/json; charset=utf-8")
            else:
                self._send(503, page_unconfigured(
                    "la liste des humains de ce conteneur est illisible (console-humans.sh) — "
                    "ce n'est PAS un refus te concernant, et rien ne se debloquera en rechargeant"
                ), "text/html; charset=utf-8")
            return

        # ⚠ `and not admin`, MEME TERME QU'A LA PORTE D'ENTREE : un site-admin peut n'avoir aucun
        # compte local — GUARD A ne converge jamais le siege — et son absence est alors NORMALE. Les
        # deux pages ci-dessous accusent le convergeur, elles ne sont justes que pour qui l'attend.
        if not any(h["human"] == sess["login"] for h in people) and not sess.get("admin"):
            refused = refusal_for(sess["login"])
            if refused is not None:
                if path == "/api/state":
                    self._send(422, json.dumps({"error": "login_refused", "login": sess["login"],
                                                "reason": refused}),
                               "application/json; charset=utf-8")
                else:
                    self._send(200, page_refused(sess["login"], refused), "text/html; charset=utf-8")
            elif path == "/api/state":
                self._send(409, json.dumps({"error": "no_local_block", "login": sess["login"]}),
                           "application/json; charset=utf-8")
            else:
                self._send(200, page_no_block(sess["login"]), "text/html; charset=utf-8")
            return

        # LE RELAIS EST DERRIERE LA PORTE, ET SON ORDRE DANS CETTE FONCTION EST LE CONTRAT. Tout ce
        # qui precede a deja etabli trois choses : une session Gitea valide, l'appartenance a
        # `fleet:humans`, et un bloc local converge. Une cible atteinte ici l'est donc par quelqu'un
        # que la forge a nomme — c'est la « seule auth » : on ne redemande rien parce qu'on ne peut
        # plus arriver par ailleurs.
        # Le statique vit DERRIERE la porte, comme la page qui le charge : il n'a aucun usage pour
        # qui n'est pas identifie, et le navigateur porte deja le cookie en le demandant.
        # LA DOC — derriere la porte, meme origine, chemin relatif. Le site est bati avec
        # ⚠ LE CHEMIN EST RESOLU PUIS VERIFIE CONTRE SA RACINE : un `..` sortirait ici du cote d'un
        # prefixe qui porte les jetons du conteneur. `realpath` + prefixe, sinon 404.
        if path == "/doc" or path.startswith("/doc/"):
            rel = path[len("/doc"):].lstrip("/") or "index.html"
            if rel.endswith("/"):
                rel += "index.html"
            full = os.path.realpath(os.path.join(DECK_DOC, rel))
            root = os.path.realpath(DECK_DOC)
            if not (full == root or full.startswith(root + os.sep)):
                self._send(404, "not found\n", "text/plain; charset=utf-8")
                return
            if os.path.isdir(full):
                full = os.path.join(full, "index.html")
            ctype = DOC_TYPES.get(os.path.splitext(full)[1].lower())
            if not ctype:
                self._send(404, "not found\n", "text/plain; charset=utf-8")
                return
            try:
                with open(full, "rb") as fh:
                    raw = fh.read()
            except OSError:
                self._send(404, "not found\n", "text/plain; charset=utf-8")
                return
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(raw)
            return

        if path.startswith("/static/"):
            name = path[len("/static/"):]
            ctype = STATIC_FILES.get(name)
            if not ctype:
                self._send(404, "not found\n", "text/plain; charset=utf-8")
                return
            try:
                with open(os.path.join(DECK_STATIC, name), "rb") as fh:
                    raw = fh.read()
            except OSError as e:
                # LE MOTIF EST POUR L'OPERATEUR : un client de terminal absent donne une page qui
                # s'ouvre sur un cadre noir, et rien a l'ecran ne dit que c'est le BUILD qui a rate.
                print(f"[lcars-deck] statique absent : {name} ({e})", file=sys.stderr, flush=True)
                self._send(503, "client de terminal absent de l'image\n",
                           "text/plain; charset=utf-8")
                return
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(raw)
            return

        target = parse_target(path)
        if target:
            # ⚠ LA QUERY EST RECOLLEE ICI, ET SON ABSENCE EST UNE PANNE MUETTE. `do_GET` a coupe sur
            # `?` des la premiere ligne — donc sans ce recollage, `/pod/<login>/ws?arg=<pod_id>`
            # arriverait a ttyd sans son argument. `--url-arg` est precisement ce qui laisse le client
            # nommer le pod : l'onglet s'ouvrirait sur un terminal sans cible, sans erreur.
            # Elle ne participe PAS a l'autorisation : `authorize` ne regarde que la nature et le
            # login, jamais ce que le client a mis apres le `?`.
            if query:
                target = (target[0], target[1], target[2] + "?" + query)
            if not authorize(sess, target):
                # 404, PAS 403, ET C'EST DELIBERE : repondre « interdit » sur la console d'autrui
                # confirme qu'elle existe et qui est connecte. Un humain n'a aucun usage de cette
                # information, et l'operateur a le motif dans le log ci-dessous.
                print(f"[lcars-deck] refus : {sess['login']} -> {path}", file=sys.stderr, flush=True)
                self._send(404, "not found\n", "text/plain; charset=utf-8")
                return
            self._relay(sess, target)
            return

        if path == "/api/state":
            self._send(200,
                       json.dumps(state(only=sess["login"], admin=sess.get("admin"),
                                        people=people)),
                       "application/json; charset=utf-8")
        elif path in ("/", "/index.html"):
            self._send(200, PAGE % {
                "host": html.escape(socket.gethostname()),
                "who": html.escape(sess["login"]),
                "csrf": html.escape(sess.get("csrf", "")),
            }, "text/html; charset=utf-8")
        else:
            self._send(404, "not found\n", "text/plain; charset=utf-8")

    # ─── LE RELAIS ──────────────────────────────────────────────────────────────────────────────
    # APRES LE `101`, CE RELAIS NE COMPREND PLUS RIEN A CE QU'IL TRANSPORTE, ET C'EST LE POINT. Les
    # deux cotes parlent le meme protocole ; le relais n'est qu'un conduit d'octets. Il n'y a donc
    # aucune trame WebSocket a decoder, aucun masque a appliquer, aucun `Sec-WebSocket-Accept` a
    # calculer — ttyd repond le sien et on le recopie. Une route de plus dans la table de montage ne
    # demandera pas une ligne ici.
    def _relay(self, sess, target):
        # ⚠ CE RELAIS TRANSPORTE UN UPGRADE, ET RIEN D'AUTRE — DIT PLUTOT QUE SOUS-ENTENDU. Apres le
        # `101` il est un conduit d'octets, ce qui marche parce que plus personne ne compte les
        # octets. Une reponse HTTP ORDINAIRE, elle, a un corps delimite par `Content-Length` ou par
        # un decoupage en morceaux : recopier les en-tetes puis s'arreter la tronquerait la reponse
        # EN SILENCE, et recopier jusqu'a la fermeture pendrait sur une connexion persistante.
        #
        # Aujourd'hui aucune cible n'emprunte ce chemin — le deck d'observation est CONSOMME comme
        # une API par le serveur, pas relaye vers le navigateur. Le jour ou une cible systeme voudra
        # de l'HTTP ordinaire, ce refus est ce qui l'obligera a ecrire le transport au lieu de
        # decouvrir une troncature.
        if (self.headers.get("Upgrade") or "").lower() != "websocket":
            self._send(400, "ce relais ne transporte qu'un upgrade websocket\n",
                       "text/plain; charset=utf-8")
            return

        sock_path = socket_for(target)
        if not sock_path:
            self._send(400, "cible invalide\n", "text/plain; charset=utf-8")
            return

        try:
            upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            upstream.settimeout(5)
            upstream.connect(sock_path)
            upstream.settimeout(None)
        except OSError as e:
            # LE MOTIF EST POUR L'OPERATEUR, PAS POUR LE CLIENT : « la console de <login> ne tourne
            # pas » et « le deck n'a pas le droit de traverser son repertoire » sont deux pannes
            # opposees, et celui qui repare a besoin de les distinguer. Le navigateur, lui, n'a
            # besoin que de savoir que ce n'est pas de son fait.
            print(f"[lcars-deck] relais {target[0]} -> {sock_path} : {e}",
                  file=sys.stderr, flush=True)
            self._send(502, "console injoignable\n", "text/plain; charset=utf-8")
            return

        try:
            self._pump(sess, target, upstream)
        finally:
            try:
                upstream.close()
            except OSError:
                pass

    def _pump(self, sess, target, upstream):
        _kind, _login, rest = target

        # ⚠ L'EN-TETE D'IDENTITE EST POSEE PAR NOUS, ET TOUTE VERSION VENANT DU CLIENT EST JETEE.
        # ttyd verifie la PRESENCE de `X-LCARS-Human` (mesure dans l'image : 407 sans, 200 avec) —
        # jamais sa valeur, ni qui l'envoie. Recopier les en-tetes du client en bloc rendrait donc la
        # garde inutile : n'importe qui pourrait la fournir lui-meme. On reconstruit une liste
        # BLANCHE, et l'identite vient de la session, seule chose que la forge a authentifiee.
        forwarded = []
        for name, value in self.headers.items():
            low = name.lower()
            if low in ("host", "connection", "upgrade", "sec-websocket-key",
                       "sec-websocket-version", "sec-websocket-protocol",
                       "sec-websocket-extensions"):
                forwarded.append((name, value))
            # Tout le reste tombe : cookies (la session est deja resolue, ttyd n'en a que faire),
            # `x-lcars-*` (forge), `authorization` (rien a lui transmettre).

        req = [f"GET {rest} HTTP/1.1"]
        req += [f"{n}: {v}" for n, v in forwarded]
        req.append(f"X-LCARS-Human: {sess['login']}")
        raw = ("\r\n".join(req) + "\r\n\r\n").encode("latin-1")

        client = self.connection
        try:
            upstream.sendall(raw)
        except OSError:
            return

        # La reponse d'amont est recopiee TELLE QUELLE, en-tetes compris : c'est ttyd qui calcule le
        # `Sec-WebSocket-Accept`, et un relais qui le recalculerait pourrait diverger de lui.
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = upstream.recv(4096)
            if not chunk:
                return
            head += chunk
            if len(head) > 65536:
                return

        try:
            client.sendall(head)
        except OSError:
            return

        # Un amont qui ne bascule pas (407, 404, 500) a deja ete recopie au client : il n'y a rien a
        # pomper derriere, et rester dans la boucle laisserait la connexion ouverte pour rien.
        if not head.startswith(b"HTTP/1.1 101") and not head.startswith(b"HTTP/1.0 101"):
            self.close_connection = True
            return

        self.close_connection = True
        pair = {client: upstream, upstream: client}
        while True:
            try:
                ready, _, _ = select.select([client, upstream], [], [])
            except (OSError, ValueError):
                return
            for src in ready:
                try:
                    data = src.recv(65536)
                except OSError:
                    return
                if not data:
                    return
                try:
                    pair[src].sendall(data)
                except OSError:
                    return

    def log_message(self, fmt, *args):  # une page consultee n'est pas un evenement
        pass


if __name__ == "__main__":
    # 0.0.0.0 DANS le conteneur : la frontiere reelle est la publication compose, qui n'expose que
    # sur la loopback de l'hote. Meme raison que ttyd (cf. console.sh) — un bind loopback ici
    # rendrait la page injoignable depuis un navigateur, donc inutile.
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Deck)
    print(f"[lcars-deck] deck servi sur :{PORT}", file=sys.stderr, flush=True)
    srv.serve_forever()
