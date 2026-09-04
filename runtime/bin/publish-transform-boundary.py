#!/usr/bin/env python3
# SOURCE: bin/publish-transform-boundary.py
# AUTHOR: DrDree
# STARDATE: 2026-07-07
# STATUS: PROTO-V1 — the boundary scan of publish-transform.sh, run as `python3 <path>`
#
# Reads a `git log --format='%H%x1f%ae%x1f%ce%x1f%B%x1e'` stream on stdin, oldest first, and writes
# the sha of the FIRST commit carrying internal attribution — or nothing. Patterns come from the
# environment: LCARS_IDENT_RE, LCARS_MSG_RE, both built by publish-transform.sh so that the
# boundary and the certification ask the same question.
import os
import re
import sys

ident = re.compile(os.environb[b"LCARS_IDENT_RE"], re.I)
msg = re.compile(os.environb[b"LCARS_MSG_RE"], re.I)

# ⚠ `maxsplit=3` ET PAS UN SPLIT NU : un message de commit peut contenir nimporte quel octet, `\x1f`
# compris, et un split nu laisserait `f[3]` ne porter que la premiere tranche du body.
#
# ANGLE MORT DECLARE : un `\x1e` dans un body coupe le RECORD, pas le champ, et la borne rate ce
# commit. Aucun format de `git log` ne prefixe ses longueurs, donc aucun separateur ne peut etre sur.
# La direction reste SURE : la certification rescanne toute l'histoire et REFUSE. On perd une
# publication, on ne laisse jamais fuir une attribution interne.
for rec in sys.stdin.buffer.read().split(b"\x1e"):
    f = rec.strip(b"\n").split(b"\x1f", 3)
    if len(f) < 4:
        continue
    sha, ae, ce, body = f[0], f[1], f[2], f[3]
    if ident.search(ae) or ident.search(ce) or msg.search(body):
        sys.stdout.write(sha.decode())
        break
