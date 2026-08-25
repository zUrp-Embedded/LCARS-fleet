#!/usr/bin/env python3
# SOURCE: fleet/services/catalogue-executor.py
# AUTHOR: bob
# STARDATE: 2026-08-23
# STATUS: PROTO-V2 — the root side of `lcars catalogue install`: it holds the authority, the caller proves nothing
#
# ─── WHY THIS PROCESS EXISTS ────────────────────────────────────────────────────────────────────
#
# TWO RESPONSIBILITIES USED TO RIDE IN ONE PROCESS, and every mechanism this file replaces grew out
# of that. Proving who you are held no power; executing held the token. When the caller's shell held
# the token, HOLDING IT WAS THE PROOF -- so the token's mode became the gate, so a unix group had to
# carry `is_admin`, so a converger had to project it, so a poll had to refresh it, so a drift repair
# had to fix consoles born before the projection.
#
# Split the two and the whole chain is unnecessary. The caller proves nothing and holds nothing: it
# opens a socket. The kernel states who it is. This process asks the forge, and this process acts.
#
# THE IDENTITY IS THE CHANNEL. `SO_PEERCRED` is set by the kernel on the connected socket -- the uid
# is not sent, not declared, and not forgeable by the caller. Same doctrine this repo already applies
# to pods: the identity is the acceptor's own state, NEVER read from the wire.
#
# NO SEAT IS PRIVILEGED. Not a name, not a uid, not a group. The only authority is the forge's
# `is_admin` flag, asked at the moment of the gesture. A path that skipped the question "because it
# is the seat" would be a second gate, therefore a second truth, therefore the drift again.
#
# WHY PYTHON, AND IT IS A DECISION. Bash can neither listen on a unix socket nor call
# `getsockopt(SO_PEERCRED)`; `socat` does not propagate the peer's credentials. Python can, and it is
# already a runtime of this product (`console-deck.py`) -- so this costs no new
# dependency. Stdlib only, for the same reason the deck is stdlib only.

import grp
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

SOCKET_PATH = os.environ.get("LCARS_CATALOGUE_SOCKET", "/run/lcars/catalogue.sock")
# THE SOCKET'S ACL CARRIES NO AUTHORIZATION -- `SO_PEERCRED` does that. It only bounds who may
# KNOCK: a member of the fleet group. Opening it to the world would not grant anyone anything, but
# it would offer this root process to every account on the box for no gain.
SOCKET_GROUP = os.environ.get("PROV_FLEET_GROUP", "fleet")
SOCKET_MODE = 0o660
MASTER_TOKEN_FILE = os.environ.get("LCARS_MASTER_TOKEN_FILE", "/home/private/forge-master.token")
GESTURES = os.environ.get("LCARS_FORGE_GESTURES", "/opt/lcars/forge-gestures.sh")
FORGE_BASE_URL = os.environ.get("FORGE_BASE_URL", "")
HTTP_TIMEOUT = int(os.environ.get("LCARS_CATALOGUE_HTTP_TIMEOUT", "15"))
# Le temps accorde a un pair pour FORMULER sa demande, pas pour que le geste s'accomplisse.
REQUEST_TIMEOUT = int(os.environ.get("LCARS_CATALOGUE_REQUEST_TIMEOUT", "30"))

# THE FORM OF A CATALOGUE NAME IS AUTHORITATIVE IN ELIXIR -- `@name_rx` in `lib/fleet/catalogue.ex`.
# This is a CITED COPY, not a second authority: the executor is Python and cannot share the literal.
#
# ⚠ AND THE TRANSCRIPTION IS NOT MECHANICAL. In Python `^...$` is NOT `\A...\z`: `$` also matches
# before a trailing newline, so `web-demo\n` -- exactly what arrives from a line-oriented socket --
# would pass. `fullmatch` on an already-stripped value is the form that means what it says.
NAME_RX = re.compile(r"[a-z0-9][a-z0-9-]*")

# ⚠ THE VALIDATION IS THIS PROCESS'S OWN RESPONSIBILITY, and it is not defence in depth.
# `cmd_install` turns the name into a PATH (`$CATALOGUE_WORK/$name`), then runs `mkdir -p`, `cp -r`
# and `tofu apply` under it -- as root. Today the form is also refused upstream by `entrypoint
# verify`, but that defence is INCIDENTAL: verify's job is a catalogue's coherence, not a path's
# safety, and it may legitimately change without anyone thinking about this process. A root process
# does not lean on a neighbour's check for a privilege boundary.

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


def master_token():
    """
    The site-admin credential, read fresh at each request.

    Read at each request and not cached at startup, so a rotated token is picked up without a
    restart and a missing one is diagnosed against the state that actually holds now.
    """
    with open(MASTER_TOKEN_FILE, "r", encoding="utf-8") as fh:
        return fh.read().strip()


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
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return bool(json.load(resp).get("is_admin"))


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
    the thing the operator is talking to. Five causes exist and they are never merged -- a refusal
    that names the wrong one costs more than a mute one.
    """
    wire = conn.makefile("rw", encoding="utf-8", newline="\n")
    gone = []

    # ⚠ UN CLIENT PARTI N'INTERROMPT PAS UN GESTE EN COURS. `tofu apply` dure des minutes ; si
    # l'operateur coupe, `emit` levait EPIPE, l'exception traversait `run_gesture`, le `finally`
    # relachait le verrou -- et `forge-gestures.sh` continuait EN ORPHELIN, hors de tout verrou de ce
    # process. Un second appelant prenait alors le verrou, tombait sur le `flock -n` en dessous, et
    # recevait « le geste a echoue » au lieu de « un autre geste est en cours » : un diagnostic faux
    # sur une machine parfaitement saine.
    #
    # On absorbe la coupure et on CONTINUE A DRAINER. Le geste va jusqu'au bout, le verrou n'est
    # rendu que lorsqu'il l'est vraiment, et le journal recueille ce que l'operateur ne lit plus.
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

    # ⚠ ONLY THE LINE TERMINATOR IS STRIPPED, and the difference is not pedantry. A `.strip()` here
    # NORMALISES: `install web-demo\t` silently became `web-demo` and was accepted, so the wire
    # format quietly disagreed with the form it claims to enforce. At a privilege boundary the
    # tolerant reading is the wrong one -- what is accepted must be exactly what is specified.
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

    # ⚠ UN CODE NEGATIF N'EST PAS UN CODE DE SORTIE. `Popen.wait()` rend `-N` quand l'enfant a ete
    # TUE par le signal N — et le relayer tel quel donnait `exit -15` cote bash, qui rend 241
    # (mesure). L'operateur lisait un nombre qui ne designe rien, pour la cause la plus banale qui
    # soit : `systemctl stop lcars-catalogue` pendant une install. Les deux natures sont donc
    # nommees separement, parce que les gestes different — un geste qui ECHOUE se diagnostique, un
    # geste INTERROMPU se rejoue.
    if rc < 0:
        log(f"interrompu: « {name} » pour {login} — signal {-rc}")
        return done(f"FAIL:gesture_signalled:{-rc}")
    if rc != 0:
        log(f"echec: « {name} » pour {login} (rc={rc})")
        return done(f"FAIL:gesture_failed:{rc}")
    log(f"fait: « {name} » pour {login}")
    return done("OK")


def bind():
    """
    The listening socket, replaced atomically-enough for a boot-time service.

    A stale socket file from a killed process would make `bind` fail with EADDRINUSE and leave the
    box with no door and no reason given, so we unlink first. `/run` is a tmpfs, so this only ever
    matters within one uptime.
    """
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass
    os.makedirs(os.path.dirname(SOCKET_PATH), mode=0o755, exist_ok=True)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCKET_PATH)
    # `chown` is attempted ONLY as root -- same idiom, and same reason, as `put_secret()` in
    # `forge-gestures.sh`: every real caller is root, a witness is not, and conditioning here avoids
    # an `|| true` that would swallow a genuine ownership failure on a box.
    if os.geteuid() == 0:
        try:
            os.chown(SOCKET_PATH, 0, grp.getgrnam(SOCKET_GROUP).gr_gid)
        except KeyError:
            # The group is absent: TIGHTEN rather than open to a group we could not name. A door
            # that is too closed gets diagnosed; too open does not.
            log(f"groupe {SOCKET_GROUP} absent — la socket reste root seul")
    os.chmod(SOCKET_PATH, SOCKET_MODE)
    srv.listen(8)
    return srv


def serve_forever(srv):
    while True:
        conn, _ = srv.accept()
        # ⚠ ONE THREAD PER CONNECTION, so that a refusal is instant even while a gesture runs. The
        # SERIALISATION lives on `_gesture_lock`, not on the accept loop: accepting one at a time
        # would make "busy" indistinguishable from "hung".
        threading.Thread(target=_guarded, args=(conn,), daemon=True).start()


def main():
    if os.geteuid() != 0:
        log("ce service tient le jeton master : il ne tourne qu'en root")
        return 1
    if not FORGE_BASE_URL:
        log("aucun FORGE_BASE_URL — un jeton sans forge ne veut rien dire")
        return 2

    srv = bind()
    log(f"a l'ecoute sur {SOCKET_PATH} (0{SOCKET_MODE:o} root:{SOCKET_GROUP})")
    serve_forever(srv)


def _guarded(conn):
    try:
        # ⚠ UN PAIR QUI SE TAIT NE DOIT PAS RETENIR UN THREAD. Sans delai, une connexion ouverte et
        # muette bloque sur `readline` pour toujours : un membre du groupe pourrait en ouvrir autant
        # qu'il veut et epuiser ce service sans jamais formuler une demande. Le delai porte sur la
        # LECTURE de la requete ; il est retire juste apres, car le geste lui-meme dure des minutes.
        conn.settimeout(REQUEST_TIMEOUT)
        serve_one(conn)
    except Exception as exc:  # noqa: BLE001 -- one bad request must never take the door down
        log(f"requete abandonnee: {exc}")
    finally:
        try:
            conn.close()
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
