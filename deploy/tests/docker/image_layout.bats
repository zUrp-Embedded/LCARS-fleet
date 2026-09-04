#!/usr/bin/env bats
# SOURCE: deploy/tests/docker/image_layout.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for le Dockerfile — ce que l'image POSE sort de l'image avec son mode, pas repare par l'instance
#
# Relecture hostile 2026-09-04 (S5). Journal du banc bob_2 au boot : « POSÉ perms 0755 root:root
# /etc/lcars » — l'init de l'instance reparait le mode d'un repertoire que l'IMAGE venait de livrer.
# Cause : `COPY --chmod=0644 … /etc/lcars/lcars.bashrc` cree le parent manquant avec le `--chmod`
# du fichier. Un `/etc/lcars` non traversable rend `seat.uid` (GUARD B) et le bashrc invisibles a
# tout non-root ; l'init le reparait AVANT que quiconque n'entre, donc ca marchait — mais la doctrine
# du lot 5 (« l'image ne derive pas, sa conformite est le build ») etait fausse ici, et le stage
# `verify` ne pouvait pas le voir : root traverse un repertoire sans bit x.
#
# ⚠ CES TEMOINS NE BATISSENT AUCUNE IMAGE. Ils lisent le Dockerfile : le repertoire est pose par un
# `install -d` AVANT le premier `COPY` qui y ecrit, et son mode est celui que l'init de l'instance
# et la table de l'installeur declarent — trois ecritures, une valeur.

load ../refute

setup() {
  DF="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  INIT="$BATS_TEST_DIRNAME/../../../runtime/services/box/init.sh"
  MANIFEST="$BATS_TEST_DIRNAME/../../system.manifest"
  [ -f "$DF" ] && [ -f "$INIT" ] && [ -f "$MANIFEST" ]
  # Le stage runtime seul : c'est lui que `final` livre.
  RUNTIME="$(sed -n '/^FROM .* AS runtime$/,/^FROM runtime AS verify$/p' "$DF" | grep -vE '^\s*#')"
  [ -n "$RUNTIME" ]
}

@test "/etc/lcars est POSE par l'image (install -d 0755 root:root) AVANT le premier COPY qui y ecrit" {
  local l_dir l_copy
  l_dir="$(grep -nE '^RUN install -d -m 0755 -o root -g root /etc/lcars$' <<<"$RUNTIME" | head -1 | cut -d: -f1)"
  l_copy="$(grep -nE '^COPY .* /etc/lcars/' <<<"$RUNTIME" | head -1 | cut -d: -f1)"
  [ -n "$l_copy" ] || { echo "aucun COPY vers /etc/lcars/ dans le stage runtime — le temoin ne mesure plus rien" >&2; return 1; }
  [ -n "$l_dir" ] || { echo "/etc/lcars n'est pas pose par un install -d 0755 root:root : le COPY --chmod cree le parent avec le mode du FICHIER" >&2; return 1; }
  [ "$l_dir" -lt "$l_copy" ] || { echo "install -d /etc/lcars (l.$l_dir) vient APRES le COPY (l.$l_copy) — trop tard, le parent existe deja avec le mauvais mode" >&2; return 1; }
}

@test "le mode de /etc/lcars est le MEME dans l'image, dans l'init de l'instance et dans la table de l'installeur" {
  # Trois poseurs, une valeur. L'init reste poseur (une instance sur un vieux volume, un /etc
  # monte) ; il ne doit plus jamais avoir a REPARER ce que l'image livre.
  grep -qE '^RUN install -d -m 0755 -o root -g root /etc/lcars$' <<<"$RUNTIME"
  grep -qE '^\s*ensure_dir /etc/lcars\s+0755 root:root' "$INIT"
  grep -qE '^dir\s+/etc/lcars\s+0755\s+root:root' "$MANIFEST"
}

@test "aucun COPY --chmod du stage runtime ne cree /etc/lcars en passant — le seul createur est l'install -d" {
  # Garde de forme : un second fichier copie sous /etc/lcars demain doit tomber APRES l'install -d,
  # sinon c'est lui qui cree le parent.
  local l_dir l
  l_dir="$(grep -nE '^RUN install -d -m 0755 -o root -g root /etc/lcars$' <<<"$RUNTIME" | head -1 | cut -d: -f1)"
  [ -n "$l_dir" ]
  while read -r l; do
    [ -n "$l" ] || continue
    [ "$l" -gt "$l_dir" ] || { echo "COPY vers /etc/lcars/ a la ligne $l du stage, avant l'install -d ($l_dir)" >&2; return 1; }
  done < <(grep -nE '^COPY .* /etc/lcars/' <<<"$RUNTIME" | cut -d: -f1)
}
