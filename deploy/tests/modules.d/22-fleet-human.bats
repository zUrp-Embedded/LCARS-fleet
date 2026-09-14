#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/22-fleet-human.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: bats tests for 22-fleet-human — la sonde des humains de fleet du poste et leur groupe

load ../refute
load ../support/decor

setup() {
  # le décor possède l'environnement : ces témoins jugent ce que le module fait d'un environnement
  # donné (bornes d'uid, siège, groupe), jamais la machine qui les joue
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)

  SRC="$BATS_TEST_DIRNAME/../../modules.d/22-fleet-human.sh"
  [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=22-fleet-human PROV_SUBSTRATE=wsl
  PROV_HUMAN="$(id -un)"; export PROV_HUMAN

  decor_pose
  decor_comptes
  printf 'UID_MIN 1000\nUID_MAX 60000\n' > "$LCARS_DECOR_ROOT/etc/login.defs"
  printf '1000\n' > "$LCARS_DECOR_ROOT/etc/lcars/seat.uid"
  passwd_with
  groupes 'fleet:x:2000:'
}

passwd_with() { # passwd_with <ligne>...  → pose le passwd du décor
  local f="$LCARS_DECOR_ROOT/etc/passwd"
  printf 'root:x:0:0:root:/root:/bin/bash\n' > "$f"
  printf 'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n' >> "$f"
  printf 'siege:x:1000:1000::/home/siege:/bin/bash\n' >> "$f"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}
groupes() { printf '%s\n' "$@" > "$LCARS_DECOR_ROOT/etc/group"; }   # groupes <ligne>... → pose le group du décor

mod() { run bash -c "set -euo pipefail; source <(sed '\$d' '$SRC') >/dev/null 2>&1; $1"; }
nu() { run bash "$SRC" "$1"; }

@test "ce module ne crée pas de compte unix : le convergeur est le seul créateur, et le verdict y renvoie" {
  passwd_with 'zoe:x:1001:1001::/home/zoe:/bin/bash'
  groupes 'fleet:x:2000:' 'zoe:x:1001:'
  DECOR_USERMOD_REFUS=1 nu apply
  refute grep -q '^useradd' "$DECOR_COMPTES"
  mod 'observe'
  refute grep -q 'useradd' <<<"$output"
}

@test "aucun humain : l'état nominal d'une machine neuve est conforme, dit en une ligne qui nomme qui s'en occupera" {
  nu check
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<<"$output")" -eq 1 ]
  [[ "$output" == "OK    22-fleet-human: aucun humain de fleet — "*"s'inscrit sur la forge"*"lcars-converger"* ]]
}

@test "aucun humain : l'apply ne dérive pas non plus" {
  nu apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"DRIFT"* ]]
}

@test "un humain dans les bornes qui porte le groupe est conforme" {
  passwd_with 'zoe:x:1234:1234::/home/zoe:/bin/bash'
  groupes 'fleet:x:2000:zoe' 'zoe:x:1234:'
  nu check
  [ "$status" -eq 0 ]
  [[ "$output" == *"« zoe » (uid 1234) ∈ fleet — il peut lancer la fleet"* ]]
}

@test "l'adhésion au groupe est mesurée ici, et le drift nomme la racine des jetons du décor" {
  passwd_with 'zoe:x:1234:1234::/home/zoe:/bin/bash'
  groupes 'fleet:x:2000:' 'zoe:x:1234:'
  nu check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 22-fleet-human: « zoe » hors du groupe fleet — il ne lira ni $LCARS_DECOR_ROOT/opt/lcars/var/tokens"* ]]
}

@test "la population ne regarde aucun groupe" {
  passwd_with 'zoe:x:1001:1004::/home/zoe:/bin/bash'
  mod 'fleet_humans'
  [ "$status" -eq 0 ]
  [ "$output" = "zoe" ]
}

@test "nobody n'est jamais un humain de fleet — énumérer exige la borne haute" {
  # uid 65534 sur toute machine : supérieur à UID_MIN et différent du siège
  mod 'fleet_humans'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "bornes illisibles : le check dérive sur une seule ligne qui porte le remède, sans « aucun humain »" {
  passwd_with 'zoe:x:1001:1001::/home/zoe:/bin/bash'
  rm "$LCARS_DECOR_ROOT/etc/login.defs"
  nu check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxE "DRIFT 22-fleet-human: la frontiere systeme/humain n'est pas etablie \(UID_MIN illisible dans .*\) — .*repare $LCARS_DECOR_ROOT/etc/login.defs — cette machine ne peut reconnaître aucun humain de fleet"
  [ "$(grep -c "n'est pas etablie" <<<"$output")" -eq 1 ]
  refute grep -q 'WARN' <<<"$output"
  refute grep -q 'zoe' <<<"$output"
}

@test "bornes illisibles : l'apply dérive de même, et ne touche à aucun groupe" {
  passwd_with 'zoe:x:1001:1001::/home/zoe:/bin/bash'
  rm "$LCARS_DECOR_ROOT/etc/login.defs"
  nu apply
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qE "^DRIFT 22-fleet-human: la frontiere systeme/humain n'est pas etablie"
  [ ! -s "$DECOR_COMPTES" ]
}

@test "un humain hors du groupe : l'apply l'y ajoute, et check le voit" {
  passwd_with 'horsgroupe:x:1001:1001::/home/horsgroupe:/bin/bash'
  groupes 'fleet:x:2000:' 'horsgroupe:x:1001:'
  nu apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'usermod -aG fleet horsgroupe' "$DECOR_COMPTES"
  nu check
  [ "$status" -eq 0 ]
}

@test "un usermod en échec est un échec nommé avec sa cause, pas un drift muet" {
  passwd_with 'horsgroupe:x:1001:1001::/home/horsgroupe:/bin/bash'
  groupes 'fleet:x:2000:' 'horsgroupe:x:1001:'
  DECOR_USERMOD_REFUS=1 nu apply
  [ "$status" -eq 1 ]
  grep -qx 'usermod -aG fleet horsgroupe' "$DECOR_COMPTES"
  [[ "$output" == *"FAIL  22-fleet-human: commande en échec (rc=10) : usermod -aG fleet horsgroupe"* ]]
  [[ "$output" == *"/etc/group verrouillé"* ]]
}

@test "un apply ne délègue jamais à check — le verdict porte le dialecte du verbe" {
  local m bad=0
  for m in "$BATS_TEST_DIRNAME"/../../modules.d/*.sh; do
    if awk '/^apply\(\) \{/,/^\}/' "$m" | grep -vE '^\s*#' | grep -qE '(^|[^_[:alnum:]])check;'; then
      echo "apply() delegue a check() : $(basename "$m")"; bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}
