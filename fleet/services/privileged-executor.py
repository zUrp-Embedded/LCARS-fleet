#!/usr/bin/env python3
# SOURCE: fleet/services/privileged-executor.py
# AUTHOR: bob
# STARDATE: 2026-08-25
# STATUS: PROTO-V2 — l'UNIQUE process root de cette machine, et il ne detient RIEN
#
# ─── POURQUOI CE SERVICE EXISTE ─────────────────────────────────────────────────────────────────
#
# Il remplace une ligne :
#
#     %fleet ALL=(root) NOPASSWD: /usr/local/bin/lcars-toolchain-converge
#
# C'etait le lien le plus fin du systeme — un chemin `groupe -> root` direct. Et le groupe `fleet`
# n'etait pas une liste d'ayants droit : `human-converger` le remplissait depuis l'equipe `humans`
# de la forge, toutes les trente secondes. Le droit d'executer du code en root avait donc la
# peremption d'un cache, et se retirer demandait un `pkill`.
#
# ─── LA REGLE QUI DONNE LA FORME ────────────────────────────────────────────────────────────────
#
#   celui qui DETIENT des secrets n'a aucun privilege noyau  -> `lcars-authority`
#   celui qui a le PRIVILEGE ne detient aucun secret          -> ce fichier
#
# Les deux ne se melangent pas : celui qui detient ne peut pas escalader, celui qui escalade n'a
# rien a voler. Ce service ouvre ZERO fichier de `/home/private`, et le mur `MUR P1` le tient.
#
# ⚠ COMMENT UN PROCESS SANS SECRET LIT-IL LA FORGE ? EN ANONYME, ET C'EST MESURE, PAS SUPPOSE.
# Mesure du 2026-08-25 sur forge vivante : `fleet/lcars` est `private=false, internal=false`, et
# `/repos/fleet/lcars/branches/tool_request` comme `/repos/fleet/lcars/contents/ops` repondent 200
# SANS aucun en-tete d'autorisation. Le depot d'ops est public par construction — c'est le depot que
# tout le monde doit pouvoir lire pour savoir ce que la boite declare.
#
# Une boite dont la forge exige une session pour lire configure `FORGE_TOKEN` sur l'unite. C'est une
# entree EXPLICITE, pas un repli silencieux : sans elle, la lecture part en anonyme et echoue
# bruyamment si la forge refuse.
#
# ─── L'APPELANT N'ECRIT RIEN, ET C'EST TOUT LE GARDE ────────────────────────────────────────────
#
# ⚠ LE VERBE NE PREND AUCUN ARGUMENT. L'ancien rail passait un SHA : le sudoers ouvrait le binaire a
# tout `%fleet`, et le controle ne portait que la FORME hexadecimale — donc n'importe quel membre
# pouvait faire appliquer en root le manifeste de N'IMPORTE QUEL commit du depot d'ops, y compris
# ceux qu'un pod venait d'y pousser sans revue. Une borne a ete posee en aval depuis (`toolchain-
# converger.sh` refuse tout SHA qui n'est pas la tete de la branche protegee).
#
# Ici il n'y a plus rien a borner : LE SERVICE RESOUT LA TETE LUI-MEME. L'appelant ne dit pas QUOI
# appliquer, il dit « converge ». Rien de ce qu'il ecrit ne decide de ce qui s'execute — ni quel
# geste (c'est la socket qui le dit), ni sur quoi (c'est la forge qui le dit).
#
# La borne en aval RESTE, et ce n'est pas une redondance : un process privilegie ne s'appuie pas sur
# un controle voisin pour une frontiere de privilege. Elle vit dans le convergeur, qui EST le geste
# privilegie ; la retirer parce que « l'appelant ne passe plus rien » rendrait le rail dependant
# d'une propriete de son appelant.
#
# ─── CE QUE `SO_PEERCRED` ACHETE ICI, ET CE QU'IL N'ACHETE PAS ──────────────────────────────────
#
# Il achete l'ATTRIBUTION : le journal dit QUI a demande, et le noyau l'atteste — rien n'est lu sur
# le fil. Il n'achete PAS une autorisation : le verbe est le meme pour tout le monde et son contenu
# est decide par la forge. Confondre les deux serait refaire le defaut que ce chantier retire.

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

# ⚠ LE MODULE VOISIN, PAS UN PAQUET. `lcars_socket.py` est POSE a cote de ce fichier par
# `62-runtime-helpers` (rail poste) et par un `COPY` du Dockerfile (rail conteneur) : les deux
# atterrissent dans le meme repertoire, et c'est ce qui rend l'import valide sans installation.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lcars_socket  # noqa: E402 -- apres le sys.path, c'est la condition de l'import

SOCKET_PATH = os.environ.get(
    "LCARS_TOOLCHAIN_SOCKET", "/run/lcars/privileged/toolchain.sock"
)
# ⚠ L'ACL DE LA SOCKET NE PORTE AUCUNE AUTORISATION. Elle borne qui peut FRAPPER, et le verbe
# derriere est le meme pour tous : « applique ce que la forge declare ». Un membre de `fleet` ne
# gagne rien a frapper qu'il n'obtiendrait en attendant le tick suivant du reconciliateur.
SOCKET_GROUP = os.environ.get("PROV_FLEET_GROUP", "fleet")
SOCKET_MODE = 0o660

CONVERGE_BIN = os.environ.get(
    "LCARS_TOOLCHAIN_CONVERGE_BIN", "/usr/local/bin/lcars-toolchain-converge"
)
OPS_REPO = os.environ.get("LCARS_OPS_REPO", "fleet/lcars")
# Nom GELE, autorite `Fleet.Toolchain.branch/0`, recopie tenue par le contrat
# `toolchain.branch_single_source`. Reglable a moitie, il ferait converger une boite sur une branche
# pendant que les demandes atterrissent dans une autre.
BRANCH = "tool_request"
FORGE_BASE_URL = os.environ.get("FORGE_BASE_URL", "")
# ⚠ EXPLICITE, ET VIDE PAR DEFAUT. Ce service ne va chercher AUCUN jeton nulle part : s'il en faut
# un, l'unite le nomme. Un service qui saurait ou trouver un secret aurait le droit de le lire, et
# c'est exactement le droit qu'on lui retire.
FORGE_TOKEN = os.environ.get("FORGE_TOKEN", "")
HTTP_TIMEOUT = int(os.environ.get("LCARS_TOOLCHAIN_HTTP_TIMEOUT", "15"))
REQUEST_TIMEOUT = int(os.environ.get("LCARS_TOOLCHAIN_REQUEST_TIMEOUT", "30"))

# ⚠ LA SERIALISATION VIT ICI ET DANS LE CONVERGEUR, ET LES DEUX SERVENT. Celle-ci evite qu'un
# second appelant lance un `apt` concurrent ; celle du convergeur (`flock`) tient aussi contre une
# invocation qui ne passerait pas par cette porte. Deux verrous pour deux populations d'appelants.
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
        <- "FAIL:<cause>"

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
        log("aucun FORGE_BASE_URL — impossible de savoir ce que la boite declare")
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
    # ⚠ LE GARDE NOMME L'EXIGENCE, PAS LE MECANISME. Ce service EXISTE pour faire un geste root ;
    # sans root, il n'a rien a offrir et sa socket serait un decor qui refuse tout. Contrairement au
    # service d'autorite — dont l'exigence est « je peux ouvrir un fichier » — ici l'exigence EST le
    # privilege, et l'enoncer comme tel reste vrai.
    if os.geteuid() != 0:
        log("je ne tourne pas en root — ce service EXISTE pour porter le seul geste privilegie "
            "de cette machine, il n'a rien a offrir sans lui")
        return 1
    if not FORGE_BASE_URL:
        log("aucun FORGE_BASE_URL — ce service ne saurait pas ce que la boite declare")
        return 2

    srv = lcars_socket.bind(SOCKET_PATH, SOCKET_GROUP, SOCKET_MODE, prefix="lcars-privileged")
    log(f"a l'ecoute sur {SOCKET_PATH} (0{SOCKET_MODE:o} root:{SOCKET_GROUP})")
    serve_forever(srv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
