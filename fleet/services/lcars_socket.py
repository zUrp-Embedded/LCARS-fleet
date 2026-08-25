#!/usr/bin/env python3
# SOURCE: fleet/services/lcars_socket.py
# AUTHOR: bob
# STARDATE: 2026-08-25
# STATUS: PROTO-V2 — le cycle de vie d'une socket unix de service, ecrit UNE fois
#
# ─── POURQUOI UN MODULE, ET PAS UN PROCESS ──────────────────────────────────────────────────────
#
# Un service peut ecouter plusieurs sockets ; c'est vrai, et ca n'est pas la question. Un process
# UNIQUE qui ecouterait tout retomberait sur un seul uid, donc une seule CLASSE DE CONFIANCE — et
# s'il portait `apt`, il serait root, donc les detenteurs de secrets redeviendraient root.
#
# Ce qui se partage n'est donc pas le process, c'est le CYCLE DE VIE : delier une socket morte,
# creer le repertoire, poser le groupe, poser le mode, ecouter. Cinq gestes, un piege deja paye,
# et rien qui merite d'etre reecrit deux fois.
#
# ⚠ LE PIEGE, ET IL EST MUET. Une socket residuelle laissee par un process tue fait echouer `bind`
# en EADDRINUSE — et la boite se retrouve sans porte, sans qu'une ligne dise pourquoi. On delie
# donc AVANT. `/run` etant un tmpfs, ca ne vaut que dans une meme duree de vie de machine.

import grp
import os
import socket
import sys


def log(prefix, msg):
    """Le rail operateur d'un service : un prefixe qu'on greppe, sur stderr."""
    print(f"[{prefix}] {msg}", file=sys.stderr, flush=True)


def bind(path, group, mode=0o660, backlog=8, prefix="lcars"):
    """
    Une socket unix qui ecoute, prete a `accept()`.

    ⚠ L'ACL DE LA SOCKET NE PORTE AUCUNE AUTORISATION. Elle borne qui peut FRAPPER ; qui a le droit
    se decide par `SO_PEERCRED` puis par une question a la forge. Confondre les deux serait refaire
    exactement le defaut que ce chantier retire — une decision prise en lisant une projection.

    Le `chown` n'est PAS conditionne sur root : le service POSSEDE la socket qu'il vient de creer,
    et POSIX laisse un proprietaire donner son fichier a un groupe DONT IL EST MEMBRE. Un temoin,
    lui, n'est dans aucun de ces groupes — d'ou le `except`, qui RESSERRE au lieu d'ouvrir. Un
    secret trop ferme se diagnostique ; trop ouvert, non.
    """
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    os.makedirs(os.path.dirname(path), mode=0o750, exist_ok=True)

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    try:
        os.chown(path, os.geteuid(), grp.getgrnam(group).gr_gid)
    except (KeyError, PermissionError, OSError) as exc:
        log(prefix, f"groupe {group} non pose sur {path} ({exc}) — elle reste au proprietaire seul")
    os.chmod(path, mode)
    srv.listen(backlog)
    return srv
