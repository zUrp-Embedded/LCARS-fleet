#!/usr/bin/env python3
# SOURCE: runtime/services/privileged-executor.py
# AUTHOR: bob
# STARDATE: 2026-08-25
# STATUS: PROTO-V2 — l'UNIQUE process root de cette machine, et il ne detient RIEN
#
# PAS DE `%fleet ALL=(root) NOPASSWD:` : un chemin `groupe -> root` direct, sur un groupe que
# `human-converger` remplit depuis la forge toutes les trente secondes, donne au droit d'executer du
# code en root la peremption d'un cache, et le retirer demande un `pkill`.
#
# Ce service ouvre ZERO fichier de secret, et `MUR P1` le tient.
#
# ⚠ COMMENT UN PROCESS SANS SECRET LIT-IL LA FORGE ? EN ANONYME, ET C'EST MESURE : le depot d'ops
# est public par construction — c'est celui que tout le monde doit pouvoir lire pour savoir ce que
# le conteneur declare. Une forge qui exigerait une session se configure par `FORGE_TOKEN` sur l'unite,
# entree EXPLICITE et jamais un repli : sans elle la lecture part en anonyme et echoue bruyamment.
#
# ─── L'APPELANT N'ECRIT RIEN, ET C'EST TOUT LE GARDE ────────────────────────────────────────────
#
# ⚠ LE VERBE NE PREND AUCUN ARGUMENT : LE SERVICE RESOUT LA TETE LUI-MEME. L'appelant ne dit pas
# QUOI appliquer, il dit « converge » — ni le geste (c'est la socket qui le dit), ni la cible (c'est
# la forge) ne viennent de lui.
#
# ⚠ LA BORNE EN AVAL RESTE, ET CE N'EST PAS UNE REDONDANCE : un process privilegie ne s'appuie pas
# sur un controle voisin pour une frontiere de privilege. La retirer parce que « l'appelant ne passe
# plus rien » rendrait le rail dependant d'une propriete de son appelant.

import json
import os
import pwd
import socket
import struct
import subprocess
import sys
import threading
import urllib.error
import urllib.request

# ⚠ LE MODULE VOISIN, PAS UN PAQUET : `lcars_socket.py` est POSE a cote de ce fichier par les deux
# rails, et c'est ce qui rend l'import valide sans installation.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lcars_socket  # noqa: E402 -- apres le sys.path, c'est la condition de l'import

SOCKET_PATH = os.environ.get(
    "LCARS_TOOLCHAIN_SOCKET", "/run/lcars/privileged/toolchain.sock"
)
# ⚠ CETTE ACL BORNE QUI PEUT FRAPPER, ELLE N'AUTORISE RIEN : un membre du groupe ne gagne pas a
# frapper ce qu'il n'obtiendrait en attendant le tick suivant du reconciliateur.
SOCKET_GROUP = os.environ.get("LCARS_FLEET_GROUP", "fleet")
SOCKET_MODE = 0o660

CONVERGE_BIN = os.environ.get(
    "LCARS_TOOLCHAIN_CONVERGE_BIN", "/usr/local/bin/lcars-toolchain-converge"
)
OPS_REPO = os.environ.get("LCARS_OPS_REPO", "fleet/lcars")
# ⚠ Nom GELE, autorite `Fleet.Toolchain.branch/0`, recopie tenue par le contrat
# `toolchain.branch_single_source` : reglable ici seulement, il ferait converger le conteneur sur une
# branche pendant que les demandes atterrissent dans une autre.
BRANCH = "tool_request"
FORGE_BASE_URL = os.environ.get("FORGE_BASE_URL", "")
# ⚠ VIDE PAR DEFAUT, ET JAMAIS CHERCHE : un service qui saurait OU trouver un secret aurait le droit
# de le lire, et c'est exactement le droit qu'on lui retire. S'il en faut un, l'unite le nomme.
FORGE_TOKEN = os.environ.get("FORGE_TOKEN", "")
HTTP_TIMEOUT = int(os.environ.get("LCARS_TOOLCHAIN_HTTP_TIMEOUT", "15"))
REQUEST_TIMEOUT = int(os.environ.get("LCARS_TOOLCHAIN_REQUEST_TIMEOUT", "30"))

# ⚠ DEUX VERROUS POUR DEUX POPULATIONS D'APPELANTS, et les deux servent : celui-ci arrete un second
# appelant de cette porte, le `flock` du convergeur tient contre une invocation qui l'evite.
_gesture_lock = threading.Lock()


def log(msg):
    print(f"[lcars-privileged] {msg}", file=sys.stderr, flush=True)


def peer_of(conn):
    """
    The connected peer's (pid, uid, gid), as stated by the kernel.

    This is the whole identity story. Nothing here parses anything the caller sent.
    """
    raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    return struct.unpack("3i", raw)


def login_of(uid):
    """The unix login for a uid, or None. Attribution only — never a decision."""
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return None


def head_of_branch():
    """
    The head commit of the protected branch, read from the forge.

    ⚠ AUCUN REPLI. Une forge muette rend une exception, jamais une valeur par defaut : converger
    sur « la derniere tete connue » ferait appliquer en root un etat que personne ne vient de
    confirmer, et l'operateur lirait un succes.
    """
    url = f"{FORGE_BASE_URL.rstrip('/')}/api/v1/repos/{OPS_REPO}/branches/{BRANCH}"
    req = urllib.request.Request(url)
    if FORGE_TOKEN:
        req.add_header("Authorization", f"token {FORGE_TOKEN}")
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    sha = (body.get("commit") or {}).get("id") or ""
    if not sha:
        raise ValueError(f"la forge ne rend pas de tete pour {BRANCH}")
    return sha


def serve_converge(conn):
    """
    Un geste, aucun argument.

        -> (la connexion suffit ; rien n'est lu sur le fil)
        <- "OK:<sha applique>"
        <- "FAIL:<cause>"                    (refus du service : no_forge, forge_unreachable, busy,
                                              converger_absent)
        <- "FAIL:converger_failed:<code>"   (code de sortie du convergeur ; 2 = manifeste refuse,
                                              que le reconciliateur gele jusqu'au merge suivant)

    ⚠ LA FORME DE LA LIGNE EST UN CONTRAT : `Fleet.Admiral.ToolchainReconciler` lit le code apres
    `converger_failed:`, et son temoin rejoue la ligne ecrite ici.

    ⚠ RIEN N'EST LU SUR LE FIL, ET C'EST DELIBERE. La socket dit le verbe, la forge dit le contenu.
    Un `readline` ici rouvrirait la seule surface par laquelle un appelant pourrait influer sur ce
    que root execute.
    """
    wire = conn.makefile("rw", encoding="utf-8", newline="\n")

    def done(status):
        try:
            wire.write(f"{status}\n")
            wire.flush()
        except OSError:
            log(f"reponse non remise, client parti : {status.split(':')[0]}")

    pid, uid, _gid = peer_of(conn)
    login = login_of(uid) or f"uid:{uid}"

    if not FORGE_BASE_URL:
        log("aucun FORGE_BASE_URL — impossible de savoir ce que le conteneur declare")
        return done("FAIL:no_forge")

    try:
        sha = head_of_branch()
    except (urllib.error.URLError, TimeoutError, socket.timeout, ValueError, OSError) as exc:
        log(f"tete de {BRANCH} illisible pour {login} ({exc})")
        return done("FAIL:forge_unreachable")

    # ⚠ NON BLOQUANT, ET LA DISTINCTION COMPTE. Une convergence deja en vol n'est pas un echec :
    # elle applique le MEME etat declare. Faire attendre l'appelant rendrait « occupe »
    # indiscernable de « pendu » — et le reconciliateur reessaie de toute facon a la passe suivante.
    if not _gesture_lock.acquire(blocking=False):
        log(f"{login} (pid {pid}) demande une convergence — une autre est deja en vol")
        return done("FAIL:busy")

    try:
        log(f"{login} (pid {pid}) demande la convergence d'outillage — tete {BRANCH} = {sha}")
        proc = subprocess.run(  # noqa: S603 -- argv fixe, le seul argument vient de la forge
            [CONVERGE_BIN, sha],
            capture_output=True,
            text=True,
            timeout=None,
            check=False,
        )
    except OSError as exc:
        log(f"{CONVERGE_BIN} injoignable ({exc})")
        return done("FAIL:converger_absent")
    finally:
        _gesture_lock.release()

    if proc.returncode != 0:
        tail = (proc.stdout or proc.stderr or "").strip().splitlines()
        tail = tail[-1] if tail else "(aucune sortie)"
        log(f"convergence REFUSEE pour {login} (code {proc.returncode}) : {tail}")
        return done(f"FAIL:converger_failed:{proc.returncode}")

    log(f"convergence appliquee pour {login} — {sha}")
    return done(f"OK:{sha}")


def serve_forever(srv):
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=_guarded, args=(conn,), daemon=True).start()


def _guarded(conn):
    try:
        conn.settimeout(REQUEST_TIMEOUT)
        serve_converge(conn)
    except Exception as exc:  # noqa: BLE001 -- one bad request must never take the door down
        log(f"requete abandonnee: {exc}")
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main():
    # ⚠ ICI L'EXIGENCE EST LE PRIVILEGE LUI-MEME, pas un acces : sans root ce service n'a rien a
    # offrir, et sa socket serait un decor qui refuse tout.
    if os.geteuid() != 0:
        log("je ne tourne pas en root — ce service EXISTE pour porter le seul geste privilegie "
            "de cette machine, il n'a rien a offrir sans lui")
        return 1
    if not FORGE_BASE_URL:
        log("aucun FORGE_BASE_URL — ce service ne saurait pas ce que le conteneur declare")
        return 2

    srv = lcars_socket.bind(SOCKET_PATH, SOCKET_GROUP, SOCKET_MODE, prefix="lcars-privileged")
    log(f"a l'ecoute sur {SOCKET_PATH} (0{SOCKET_MODE:o} root:{SOCKET_GROUP})")
    serve_forever(srv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
