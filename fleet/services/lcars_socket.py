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

    # ⚠ LE REPERTOIRE PORTE LE MEME GROUPE QUE LA SOCKET, ET L'OUBLIER RENDAIT LA PORTE
    # INATTEIGNABLE. `makedirs` cree avec l'uid:gid DU SERVICE. Pour un service root, c'est
    # `root:root` en 0750 — donc un membre du groupe ne TRAVERSE pas, quelle que soit la finesse du
    # mode de la socket qui est dedans.
    #
    # MESURE DU 2026-08-25, install reelle : `toolchain.sock` en `srw-rw---- root:fleet`, parfaite,
    # dans un `drwxr-x--- root:root`. Le sudoers `%fleet ALL=(root)` venait d'etre retire et la
    # socket qui le remplace etait injoignable. Le chantier etait NON FONCTIONNEL, et rien ne le
    # disait : la socket existe, ses droits sont justes, elle repond a personne.
    #
    # C'est la meme moitie d'axe que ce depot a deja payee deux fois — le fichier traite, le
    # contenant oublie. Ici c'est un `chown` qui portait sur la socket et pas sur ce qui la porte.
    #
    # ⚠ AU GROUPE PASSE, JAMAIS AU GROUPE PRIMAIRE DU SERVICE. `lcars-authority` a desormais un
    # groupe a lui : chowner au primaire rendrait `/run/lcars/authority` en
    # `lcars-authority:lcars-authority`, alors que `system.manifest` le declare
    # `0750 lcars-authority:fleet` — la table dirait le contraire du disque, et `roles.sock`
    # deviendrait injoignable exactement comme `toolchain.sock` l'etait. Avec le groupe passe, les
    # deux portes collent a la table : `privileged` -> `root:fleet`, `authority` ->
    # `lcars-authority:fleet`.
    parent = os.path.dirname(path)
    os.makedirs(parent, mode=0o750, exist_ok=True)

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    # UN SEUL `try` POUR LES DEUX, et c'est voulu : ils ont la meme condition de possibilite (le
    # groupe existe, et on possede l'objet) et le meme repli — un temoin n'est dans aucun de ces
    # groupes, et ce qui RESSERRE est sans danger. Un secret trop ferme se diagnostique ; trop
    # ouvert, non.
    # ⚠ `chmod` EXPLICITE SUR LE REPERTOIRE, PARCE QUE `makedirs` NE SUFFIT PAS DEUX FOIS.
    # Son `mode=` est soumis a l'UMASK du service (un umask 027 rendrait 0750 en 0750, un 077 en
    # 0700), et surtout `exist_ok=True` ne touche RIEN si le repertoire est deja la. Une porte posee
    # une fois avec un mauvais mode le garderait a chaque redemarrage suivant, et le service
    # convergerait tout sauf ca.
    os.chmod(parent, 0o750)
    try:
        gid = grp.getgrnam(group).gr_gid
        os.chown(parent, os.geteuid(), gid)
        os.chown(path, os.geteuid(), gid)
    except (KeyError, PermissionError, OSError) as exc:
        log(prefix, f"groupe {group} non pose sur {path} ni sur {parent} ({exc}) — "
                    f"la porte reste au proprietaire seul, et le groupe ne la traversera pas")
    os.chmod(path, mode)
    srv.listen(backlog)
    return srv
