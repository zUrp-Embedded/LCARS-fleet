#!/usr/bin/env bats
# SOURCE: runtime/test/services/box/boot_launch.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for box/boot.sh — `launch` : l'echec d'un lancement se MESURE, et chaque site d'appel porte sa branche
#
# Relecture hostile 2026-09-04 (M7). `launch` finissait sur `say` dans ses deux branches, donc
# rendait toujours 0 : le `|| say "home NON lancée … AUCUNE console n'est joignable"` du deck etait
# une branche inatteignable, et le message qu'elle portait — le plus important du bloc — n'etait
# jamais dit. `setsid … &` rend la main sans savoir si la commande a pu s'executer ; ce qui SE
# mesure avant de lancer est que la commande existe et soit executable. Ce qui meurt APRES est
# l'affaire du superviseur (supervise.bats).
#
# ⚠ ET LA BRANCHE DOIT EXISTER A CHAQUE SITE. Le boot est sous `set -e` : un `launch` qui rend 1
# sur une ligne nue TUE le boot — l'inverse de la doctrine du fichier (la boite reste joignable
# pour etre reparee). Rendre l'echec mesurable sans garder chaque site serait pire qu'avant.
#
# ⚠ CES TEMOINS EXECUTENT LA FONCTION REELLE, extraite du fichier, avec un `setsid` double qui ne
# detache rien (sinon un daemon survit au temoin) et qui note ce qu'on a voulu lancer.

load ../../support/refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../../services/box/boot.sh"
  [ -f "$SRC" ]
  FN="$BATS_TEST_TMPDIR/launch.sh"
  sed -n '/^SUPERVISE=/p; /^launch() {/,/^}/p' "$SRC" > "$FN"
  JOURNAL="$BATS_TEST_TMPDIR/journal"
  SPAWNED="$BATS_TEST_TMPDIR/spawned"
  LOG="$BATS_TEST_TMPDIR/svc.log"
  # Pas de superviseur : la branche `setsid "$@"` est celle qu'on exerce, la plus courte.
  export LCARS_SUPERVISE_BIN="$BATS_TEST_TMPDIR/absent/supervise.sh"
}

lancer() { # lancer <cmd...> — joue `launch "svc" "$LOG" -- <cmd...>` avec le decor
  run bash -c "
    set -euo pipefail
    say() { printf '%s\n' \"\$*\" >> '$JOURNAL'; }
    setsid() { printf '%s\n' \"\$*\" >> '$SPAWNED'; }
    source '$FN'
    launch 'svc' '$LOG' -- \"\$@\"
    " _ "$@"
}

@test "la fonction s'extrait, et elle n'est pas vide" {
  [ -s "$FN" ]
  grep -q '^SUPERVISE=' "$FN"
  grep -q 'setsid' "$FN"
}

@test "commande INTROUVABLE : launch rend 1, le dit, nomme la commande — et ne lance rien" {
  lancer /nulle/part/console-landing.sh --foreground
  [ "$status" -eq 1 ]
  grep -q 'svc NON lancé' "$JOURNAL"
  grep -q '/nulle/part/console-landing.sh' "$JOURNAL"
  [ ! -e "$SPAWNED" ]
}

@test "commande PRESENTE mais NON EXECUTABLE : meme verdict — un cp sans -p, un montage noexec" {
  local f="$BATS_TEST_TMPDIR/svc.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$f"; chmod 0644 "$f"
  lancer "$f"
  [ "$status" -eq 1 ]
  grep -q 'NON lancé' "$JOURNAL"
  [ ! -e "$SPAWNED" ]
}

@test "commande LANCABLE : launch rend 0, dit ACTIF, et la commande part avec ses arguments" {
  local f="$BATS_TEST_TMPDIR/svc.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$f"; chmod 0755 "$f"
  lancer "$f" --foreground
  [ "$status" -eq 0 ]
  grep -q 'svc ACTIF' "$JOURNAL"
  grep -q -- "$f --foreground" "$SPAWNED"
  refute grep -q 'NON lancé' "$JOURNAL"
}

@test "CHAQUE site d'appel de launch dans le boot porte sa branche d'echec (|| say) — sous set -e, une ligne nue tuerait le boot" {
  # Les appels sont continues par des `\` : on recolle les lignes logiques avant de lire.
  local sites n
  sites="$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$SRC" | grep -vE '^\s*#' | grep 'launch "')"
  n="$(grep -c . <<<"$sites")"
  [ "$n" -ge 4 ] || { echo "moins de 4 sites d'appel lus — l'instrument ne lit plus le boot" >&2; return 1; }
  local nu; nu="$(grep -v '|| say' <<<"$sites" || true)"
  [ -z "$nu" ] || { echo "site(s) sans branche d'echec :"; echo "$nu"; return 1; } >&2
}
