#!/usr/bin/env python3
# SOURCE: fleet/deploy/docker/console-deck.py
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
import secrets
import select
import socket
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

PORT = int(os.environ.get("LCARS_LANDING_PORT", "20999"))
HUMANS_SH = os.environ.get("LCARS_CONSOLE_HUMANS", "/opt/lcars/console-humans.sh")

# ── THE DOOR ────────────────────────────────────────────────────────────────────────────────────
# WHAT THE AUTH IS FOR, AND IT IS NOT MAINLY SECURITY: this page is the box's front door and it
# used to hand EVERY human's port block to whoever opened it. The fleet was already per-human --
# one port block per uid, one observation deck each -- so authenticating does not create the
# partition, it makes the INDEX personal: you arrive, you are recognised, you land on yours.
#
# GITEA IS THE MASTER OF HUMANS, so it answers "who are you" too. `preferred_username` falls
# straight onto /etc/passwd (the login is the SAME on both sides by contract), which yields the uid
# and therefore the port block. Routing and authorisation come out of one round trip.
#
# WE READ THE CLAIMS FROM `userinfo`, NOT FROM THE id_token. Both carry the same `groups` (measured
# 2026-08-12), but validating an RS256 signature needs a crypto library this image does not carry,
# and an UNVERIFIED id_token is an attacker-supplied blob. The userinfo endpoint is a direct
# server-to-forge call authenticated by the access token we just obtained: nothing to verify,
# because nothing untrusted carried it.
OIDC_CONFIG = os.environ.get("LCARS_DECK_OIDC", "/etc/lcars/deck-oidc.json")
# Membership of THIS team is what separates a human of the fleet from a mere forge account. Free
# registration is deliberate (an account is inert on its own); the single admin gesture that
# enrolls somebody is adding them here. Measured: a member gets `["fleet", "fleet:humans"]`, a
# self-registered guest gets NO `groups` claim at all.
HUMANS_TEAM = os.environ.get("LCARS_DECK_TEAM", "fleet:humans")
SESSION_COOKIE = "lcars_deck"
SESSION_TTL = 12 * 3600
PENDING_TTL = 600
# WHERE THE CONVERGER PUBLISHES ITS REFUSALS, and reading it is what stops this page from lying.
# Gitea accepts logins that can never become a Unix account (a 33-character name, for one), so a
# person CAN be enrolled into the team and never converge. This page used to tell them "it
# converges on its own, nothing to do on your side" -- for a convergence that will never happen.
# The converger is the only component that knows why; it writes the reason here, we read it.
REFUSED_FILE = os.environ.get("LCARS_CONVERGER_REFUSED", "/run/lcars-converger.refused")

# ─── LA TABLE DE MONTAGE ────────────────────────────────────────────────────────────────────────
# LE RELAIS EST GENERIQUE, ET C'EST CE QUI REND LA SUITE TRIVIALE. Il n'y a pas de route « console »
# ni de route « pod » : il y a des CIBLES, de deux natures.
#
#   par-humain : /console/<login>/…  /pod/<login>/…   -> la socket de CET humain
#   systeme    : /admin/…                             -> un backend unique, sans <login>
#
# La page de configuration des cartes sera UNE LIGNE ici, pas un chantier. C'est la meme raison qui
# fait que ce relais ne parle jamais de terminal : apres le `101`, il ne comprend plus rien de ce
# qu'il transporte, et c'est deliberé.
CONSOLE_SOCK_ROOT = os.environ.get("LCARS_CONSOLE_SOCK_ROOT", "/run/lcars/console")
# Le client de terminal, pose par le Dockerfile et epingle par sha256 au meme rang que le binaire
# ttyd. LA LISTE EST BLANCHE ET FERMEE : ce repertoire n'est pas « servi », ce sont TROIS fichiers
# nommes qui le sont. Un serveur de statique generique dans un processus qui relaie des shells est
# une surface qu'on n'a aucune raison d'ouvrir — et un `..` dans un nom de fichier n'est meme pas
# une question qui se pose.
DECK_STATIC = os.environ.get("LCARS_DECK_STATIC", "/opt/lcars/deck-static")
STATIC_FILES = {
    "xterm.js": "application/javascript; charset=utf-8",
    "xterm.css": "text/css; charset=utf-8",
    "addon-fit.js": "application/javascript; charset=utf-8",
}
# Le second nom dans une liste DEJA en main : la session porte `groups` depuis le callback OIDC, donc
# le tier admin ne coute ni un appel ni un credential stocke. ⚠ Ce qui est gratuit est le MECANISME
# (l'acheminement de l'identite, la route) — pas les POUVOIRS de l'admin, qui demandent chacun un
# endpoint systeme qui n'existe pas encore.
ADMINS_TEAM = os.environ.get("LCARS_DECK_ADMIN_TEAM", "fleet:admins")

# Nature d'une cible par-humain -> nom de la socket dans son repertoire.
PER_HUMAN_TARGETS = {"console": "console.sock", "pod": "pod.sock"}
# Nature d'une cible systeme -> chemin de socket absolu. VIDE, ET C'EST HONNETE : le mecanisme
# d'autorisation admin existe et est teste ; aucun backend systeme n'est encore ecrit. Une entree
# ici suffira a en publier un, sans toucher a `authorize`.
SYSTEM_TARGETS = {}

_lock = threading.Lock()
_sessions = {}
_pending = {}


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
    panoptique, pas un geste d'admin*. Son perimetre est le SYSTEME (faire tourner la boite, ajouter
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
        return ADMINS_TEAM in (sess.get("groups") or [])
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
    both: `http://forge:3000` resolves nowhere outside the network, and the host's address may not
    resolve inside it.
    """
    try:
        with open(OIDC_CONFIG) as fh:
            cfg = json.load(fh)
    except FileNotFoundError:
        return None, f"{OIDC_CONFIG} absent"
    except PermissionError:
        return None, f"{OIDC_CONFIG} illisible par {os.geteuid()} (le deck tourne en nobody)"
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


def fleet_pods(human):
    """
    Pods vivants d'un humain, vus par SA fleet (le deck d'observation, base+1).

    Source unique volontaire : le runtime sait ce qu'il a spawne (role, phase), la ou une
    enumeration de sockets ne rend que des noms.

    TROIS ETATS, PAS DEUX. Une fleet eteinte est un etat NOMINAL ; un deck qu'on n'a pas pu
    joindre est une mesure RATEE, et les deux ne se disent pas de la meme facon. Le code rendait
    `None` sur n'importe quelle exception et l'appelant en faisait `fleet=False` : un timeout de
    2 s s'affichait « fleet eteinte », c'est-a-dire une assertion d'extinction tiree d'une absence
    de reponse. C'est le piege exact que le read-model du runtime a ferme par
    `:live | :deaf | :unavailable`, refait ici a deux cents lignes de la.

    Le discriminant est la CAUSE, pas l'echec : connexion refusee = personne n'ecoute = eteinte
    (on a mesure) ; timeout, reset, DNS = on n'a pas mesure.
    """
    url = f"http://127.0.0.1:{human['ports']['deck']}/api/pods"
    try:
        with urlopen(url, timeout=2) as r:
            return "live", (json.load(r).get("pods") or [])
    except HTTPError:
        # Quelqu'un ecoute et repond autre chose que ce qu'on attend : mesure faite, etat anormal.
        return "deaf", []
    except URLError as e:
        if isinstance(e.reason, ConnectionRefusedError):
            return "off", []
        return "unknown", []
    except (TimeoutError, socket.timeout):
        return "unknown", []
    except Exception:
        return "unknown", []


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

    We can see this as `nobody` because the home and `.claude` are traversable while the file
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


def state(only=None):
    """
    The box's state, RESTRICTED to `only` when a session names a human.

    The filter is applied at the SOURCE, not in the page: an index that renders one human while
    `/api/state` still serves everybody has not made anything personal, it has hidden a list that
    is still one fetch away.
    """
    hs = []
    for h in humans():
        if only is not None and h["human"] != only:
            continue
        status, pods = fleet_pods(h)
        # `fleet` reste le booleen « vivante », pour les consommateurs qui ne posent que cette
        # question ; `fleet_status` porte la distinction que le booleen ne peut pas porter.
        h = dict(h, fleet=(status == "live"), fleet_status=status,
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
    return {"hostname": socket.gethostname(), "humans": hs}


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
            "<p>Cette boite est desservie par la forge : elle sait qui tu es, on ne redemande pas.</p>"
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
            "qu'il ne l'est pas, tu n'as pas de fleet sur cette boite &mdash; rien n'est casse, il "
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
            "encore sur cette boite, donc tu n'as ni bloc de ports ni fleet a montrer. C'est le "
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
            "<p>Ce n'est pas une attente : cette boite a REFUSE de creer ton utilisateur systeme, "
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
            "public_url, internal_url), lisible par l'utilisateur <code>nobody</code>.</p>"
        ),
    }


PAGE = r"""<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LCARS &mdash; %(host)s</title>
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
  /* LA SCENE : position:relative + panneaux en inset:0 absolu. Un iframe dimensionne par flex
     herite d'une hauteur ambigue (les navigateurs lui donnent 150px par defaut si la chaine de
     hauteurs casse) et la page embarquee, qui se dimensionne en 100vh/grille, se replie sur
     quelques pixels. En absolu dans une scene qui a une taille, la question ne se pose plus. */
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
  <header><b id="crumb">STATUT</b><span id="hint"></span><span id="size"></span><a id="pop" href="#" target="_blank" rel="noopener" hidden>ouvrir dans une fenetre &#8599;</a><span id="who">%(who)s</span><a href="/auth/logout">sortir</a></header>
  <div id="stage"><div id="panel"></div></div>
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

  const stage = document.getElementById('stage'), panel = document.getElementById('panel');
  const pop = document.getElementById('pop');

  // UN CADRE PAR ONGLET, CREE UNE FOIS ET JAMAIS RECHARGE. Reutiliser un seul cadre en
  // reecrivant son `src` DECHARGE la page en place : ttyd pose un `beforeunload` (il protege un
  // terminal connecte), donc changer d'onglet faisait surgir un « voulez-vous quitter ? ». Et le
  // terminal se reconnectait a chaque retour, perdant son ecran. Montrer/cacher ne decharge rien :
  // la question ne se pose plus, et les sessions gardent leur etat.
  // On ne masque JAMAIS le cadre qu'on s'apprete a montrer. `hidden` vaut `display:none` : un
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
    // Rien a « ouvrir dans un onglet » : il n'y a plus d'URL a laquelle aller. C'est le point.
    pop.hidden = true;
  } else if (tab.url) {
    panel.style.display = 'none';
    let pane = stage.querySelector(`.pane[data-key="${CSS.escape(tab.key)}"]`);
    if (!pane) {
      pane = document.createElement('iframe');
      pane.className = 'pane';
      pane.dataset.key = tab.key;
      pane.title = tab.crumb;
      pane.src = tab.url;
      stage.appendChild(pane);
    }
    pane.hidden = false;
    pop.hidden = false; pop.href = tab.url;
  } else {
    panel.style.display = '';
    panel.innerHTML = ''; panel.appendChild(tab.render());
    pop.hidden = true;
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
    default:        return 'fleet NON MESUREE (deck injoignable)';
  }
}

function fleetHint(h) {
  switch (h.fleet_status) {
    case 'live':    return '';
    case 'off':     return '(la fleet de cet humain ne tourne pas)';
    case 'deaf':    return '(le deck repond, mais pas ce qu\'on attend)';
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
    // MEME ORIGINE, CHEMIN RELATIF : plus de `http://HOST:port`. La cible n'est plus une adresse
    // qu'on pourrait taper ailleurs, c'est une route de CE serveur, derriere la session qu'il a
    // deja verifiee. C'est toute la these du lot en une ligne.
    add('humain ' + h.human, 'Console', 'shell ' + h.human,
        { key: 'console-' + h.human, crumb: 'CONSOLE — ' + h.human,
          term: `/console/${encodeURIComponent(h.human)}/ws` });
    add(null, 'Deck d\'observation', fleetLabel(h),
        { key: 'deck-' + h.human, crumb: 'DECK — ' + h.human,
          hint: fleetHint(h),
          url: `http://${HOST}:${h.ports.deck}` });

    // Les agents, GROUPES PAR PROJET. Le rattachement est celui que le RUNTIME publie ; un pod
    // sans projet est fleet-level, il a son propre groupe au lieu d'etre range de force.
    //
    // FLEET EN TETE, ET SANS LE MOT « PROJET ». Le groupe fleet-level est FIXE — il existe a
    // chaque boot, avant tout projet, et il n'en est pas un. Le trier alphabetiquement le faisait
    // apparaitre au milieu des projets, a une place qui changeait avec eux ; l'appeler « projet
    // fleet » le rangeait dans une categorie a laquelle il n'appartient pas.
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
              // (forme, unicite, socket existante). Ce qui a change, c'est qu'il ne suffit plus.
              // La socket atteinte est celle de CET humain — l'appelant est etabli AVANT que
              // l'argument n'arrive, ce qui est exactement ce qui manquait a 6-098.
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
    // UNE SESSION MORTE NE SE GARDE PAS A L'ECRAN. Sans ce test, un 401 tombait dans le `catch`
    // avec le reste et la page continuait d'afficher son dernier etat : un deck d'apparence
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

    # HTTP/1.1 IS A PREREQUISITE, NOT A MODERNISATION. `BaseHTTPRequestHandler` defaults to
    # HTTP/1.0, and a 1.0 responder CANNOT perform `101 Switching Protocols` -- so the deck could
    # never terminate a WebSocket, and every terminal had to live on its own origin behind its own
    # port. That second origin is what asks nobody for anything, and the iframe exists only to sew
    # the two back together: one line here is what makes a single origin possible at all.
    #
    # SAFE BECAUSE EVERY RESPONSE PATH IS LENGTH-DELIMITED, and that was checked rather than
    # assumed: 1.1 keeps the connection alive by default, so a reply with neither `Content-Length`
    # nor chunked encoding leaves the client waiting for an end that never comes. This handler has
    # exactly two response paths -- `_send` and `_redirect` -- and both set `Content-Length`; there
    # is no `send_error` call. A third path added later MUST set it too.
    protocol_version = "HTTP/1.1"

    # ⚠ `rbufsize = 0` EST UNE CONDITION DU RELAIS, PAS UN REGLAGE DE PERFORMANCE. Par defaut
    # `StreamRequestHandler` enveloppe la connexion dans un `BufferedReader` : la lecture des
    # en-tetes peut alors tirer PLUS d'octets que la requete, et ces octets restent dans un tampon
    # que `_pump` — qui lit la socket brute — ne verra jamais. Ils seraient perdus, silencieusement,
    # et seulement quand le client parle en premier : la panne la plus difficile a attribuer qui
    # soit. Sans tampon, tout ce qui est arrive est encore dans la socket.
    #
    # LE PRIX EST REEL ET ASSUME : `readline()` sur un flux non tamponne lit octet par octet, donc un
    # appel systeme par caractere d'en-tete. Ce deck sert une poignee de requetes par session humaine
    # — une page, un JSON d'etat, un upgrade — et jamais du trafic de masse.
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

        The same deck is reached as `127.0.0.1:20999` from the box's own host and as
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
        if HUMANS_TEAM not in groups:
            self._send(403, page_denied(login, groups), "text/html; charset=utf-8")
            return

        sid = secrets.token_urlsafe(32)
        with _lock:
            _sessions[sid] = {"login": login, "groups": groups, "exp": time.time() + SESSION_TTL}
        # No `Secure`: the deck serves plain HTTP on a LAN port by design (there is no TLS to opt
        # into here). `HttpOnly` + `SameSite=Lax` still hold -- they cost nothing and remove the
        # two ways a page in another tab could reach this cookie.
        self._redirect("/", f"{SESSION_COOKIE}={sid}; HttpOnly; SameSite=Lax; Path=/; Max-Age={SESSION_TTL}")

    def _auth_logout(self, cfg):
        """
        SE DECONNECTER DOIT DECONNECTER, et ne le faisait pas.

        On ne fermait que NOTRE session. La session de la forge, elle, survivait — et comme
        l'application est deja autorisee, le `/auth/login` suivant traverse sans une seule question
        et remet la personne dedans. Vu du dehors ce n'est pas une deconnexion, c'est un aller-retour
        avec des etapes en plus. Pire, la boucle se referme : le deck ne montrait aucun lien vers la
        forge, donc sans connaitre son URL on ne pouvait meme pas aller s'y deconnecter.

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

    def do_GET(self):
        path, _, query = self.path.partition("?")

        # `/health` answers BEFORE the door: it reports that this process is up, which is true
        # whether or not anyone is logged in, and the container's healthcheck has no session.
        if path == "/health":
            self._send(200, "ok\n", "text/plain; charset=utf-8")
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
        if not any(h["human"] == sess["login"] for h in humans()):
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
            # arrivait a ttyd sans son argument. `--url-arg` est precisement ce qui laisse le client
            # nommer le pod : l'onglet se serait ouvert sur un terminal sans cible, sans erreur.
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
            self._send(200, json.dumps(state(only=sess["login"])),
                       "application/json; charset=utf-8")
        elif path in ("/", "/index.html"):
            self._send(200, PAGE % {
                "host": html.escape(socket.gethostname()),
                "who": html.escape(sess["login"]),
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
