#!/usr/bin/env bats
# SOURCE: runtime/test/services/container/init_layout.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for container/init.sh store — le magasin de l'instance est celui que l'hote monte, et l'init le DIT
#
# ⚖ user 2026-09-04 (Q1, lot 7) : `26-store` (le module de l'installeur qui posait les modes du
# magasin en substrat docker) est mort — l'init de l'instance pose les quatre arbres. Ce mur
# etait le sien : la liste des arbres que l'init pose est EXACTEMENT celle que l'hote monte
# (`deploy/lib/store.sh`, `LCARS_STORE_TREES`, la source des volumes externes du compose). Un
# arbre monte et jamais pose n'aurait pas de mode ; un arbre pose et jamais monte serait un
# repertoire du conteneur qui se prend pour un volume.
#
# ⚠ RELECTURE HOSTILE 2026-09-04 (S3) : `store_modes.bats` (9 temoins qui JOUAIENT `26-store`)
# avait ete remplace par trois greps de texte — aucun temoin du depot n'executait le magasin de
# l'init. Les cas ci-dessous jouent le verbe `store` contre un decor : racine non posee, racine
# absente, arbre non monte, nominal, arbre remplace par un lien. Chacun a rougi sur une mutation
# (message du commit).

load ../../support/refute

setup() {
  SUT="$BATS_TEST_DIRNAME/../../../services/container/init.sh"
  STORE_LIB="$BATS_TEST_DIRNAME/../../../../deploy/lib/store.sh"
  [ -f "$SUT" ] && [ -f "$STORE_LIB" ]
  export LCARS_MODULE_PROTOCOL="$BATS_TEST_DIRNAME/../../../services/lib/module-protocol.sh"
  export LCARS_MODULE_TAG=container-init
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/tokens"
  # hors root, le groupe demande doit etre le notre pour que le setgid se pose
  LCARS_FLEET_GROUP="$(id -gn)"; export LCARS_FLEET_GROUP
  unset LCARS_STORE_ROOT
  STORE="$BATS_TEST_TMPDIR/store"
  # ⚠ LE PROPRIETAIRE `root:` NE SE POSE PAS SANS PRIVILEGE. Les arbres du magasin sont a root par
  # contrat ; sans root, `chown` refuse et `ensure_mode` compte un FAIL qui n'est pas celui qu'on
  # mesure. Une doublure de `chown` qui rend 0 laisse le reste du protocole intact : la presence,
  # le mode et le setgid sont mesures pour de vrai (`stat`), seule la propriete est jouee.
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/chown"; chmod 0755 "$BIN/chown"
  export PATH="$BIN:$PATH"
}

@test "les arbres du magasin que l'init pose sont ceux que l'hote monte — ni plus, ni moins" {
  local montes poses
  montes="$(bash -c 'source "$1" 2>/dev/null; printf "%s\n" "${LCARS_STORE_TREES[@]}"' _ "$STORE_LIB" | sort)"
  [ -n "$montes" ]
  poses="$(sed -n '/^store()/,/^}/p' "$SUT" | grep -oE '^\s*store_tree [a-z]+' | awk '{ print $2 }' | sort)"
  [ -n "$poses" ]
  [ "$montes" = "$poses" ] || { echo "montes: $montes"; echo "poses: $poses"; false; }
}

@test "cache est au groupe fleet en setgid (les pods y ecrivent), les autres a root" {
  grep -qE '^\s*store_tree cache +2775 "root:\$LCARS_FLEET_GROUP"' "$SUT"
  grep -qE '^\s*store_tree toolchains +0755 root:root' "$SUT"
  grep -qE '^\s*store_tree sysroots +0755 root:root' "$SUT"
}

@test "store : LCARS_STORE_ROOT non pose = DRIFT nomme (rc 2), pas un avertissement sans verdict" {
  run bash "$SUT" store
  [ "$status" -eq 2 ] || { echo "rc=$status : $output"; return 1; }
  [[ "$output" == *"DRIFT"*"LCARS_STORE_ROOT absent"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "store : une racine ABSENTE se DIT (drift, rc 2) — le magasin ne se fabrique pas dans le conteneur" {
  export LCARS_STORE_ROOT="$STORE"
  run bash "$SUT" store
  [ "$status" -eq 2 ] || { echo "rc=$status : $output"; return 1; }
  [[ "$output" == *"DRIFT"*"magasin $STORE absent"* ]]
  [ ! -e "$STORE" ]
}

@test "store : racine posee, un arbre NON MONTE — le drift le NOMME et ne le fabrique pas" {
  export LCARS_STORE_ROOT="$STORE"
  mkdir -p "$STORE/cache" "$STORE/toolchains" "$STORE/sysroots"
  run bash "$SUT" store
  [ "$status" -eq 2 ] || { echo "rc=$status : $output"; return 1; }
  [[ "$output" == *"DRIFT"*"« state » absent"* ]] || { echo "$output"; return 1; }
  [ ! -e "$STORE/state" ]
  # les trois arbres presents ont ete converges quand meme
  [ "$(stat -c %a "$STORE/cache")" = 2775 ]
  [ "$(stat -c %a "$STORE/toolchains")" = 755 ]
}

@test "store : les quatre arbres montes = converge (rc 0), modes et setgid poses, rien d'autre touche" {
  export LCARS_STORE_ROOT="$STORE"
  mkdir -p "$STORE/cache" "$STORE/toolchains" "$STORE/sysroots" "$STORE/state"
  chmod 0700 "$STORE/cache" "$STORE/state"
  run bash "$SUT" store
  [ "$status" -eq 0 ] || { echo "rc=$status : $output"; return 1; }
  [[ "$output" != *"DRIFT"* && "$output" != *"FAIL"* ]]
  [[ "$output" == *"POSÉ"*"$STORE/cache"* ]]
  [ "$(stat -c %a "$STORE/cache")" = 2775 ]
  [ "$(stat -c %a "$STORE/state")" = 2775 ]
  [ "$(stat -c %a "$STORE/toolchains")" = 755 ]
  [ "$(stat -c %a "$STORE/sysroots")" = 755 ]
  [ "$(ls -A "$STORE" | sort | tr '\n' ' ')" = "cache state sysroots toolchains " ]
}

@test "store : un arbre remplace par un LIEN est un ECHEC (rc 1) nomme — et les autres arbres sont converges quand meme" {
  # ⚠ CE TEMOIN TIENT LE VERDICT DU BLOC. `store_tree` continue apres un echec (`|| return 0`) :
  # si le FAIL n'etait pas compte par le protocole, un magasin a moitie pose rendrait 0.
  export LCARS_STORE_ROOT="$STORE"
  mkdir -p "$STORE/cache" "$STORE/toolchains" "$STORE/sysroots" "$BATS_TEST_TMPDIR/ailleurs"
  ln -s "$BATS_TEST_TMPDIR/ailleurs" "$STORE/state"
  run bash "$SUT" store
  [ "$status" -eq 1 ] || { echo "rc=$status : $output"; return 1; }
  [[ "$output" == *"FAIL"*"$STORE/state"* ]] || { echo "$output"; return 1; }
  [ "$(stat -c %a "$STORE/cache")" = 2775 ]
  [ "$(stat -c %a "$STORE/sysroots")" = 755 ]
}

# ⚠ LE COMPTEUR DECIDE, PAS ERREXIT. Le protocole compte les echecs (`p_fail`) et le module tourne
# sous `set -e` : sans garde, le premier dossier refuse emporte le module, et l'init s'arrete avant
# d'avoir seulement essaye les suivants. La regle vivait recopiee a chaque ligne de `layout` —
# treize fois ; ce temoin la tient une fois, sur la table entiere.
@test "layout : toute la table est jouee, et un dossier refuse est COMPTE sans emporter la suite" {
  local BLOC="$BATS_TEST_TMPDIR/layout.sh" LOG="$BATS_TEST_TMPDIR/poses"
  { sed -n '/^layout_table() {/,/^}/p' "$SUT"; sed -n '/^layout() {/,/^}/p' "$SUT"; } > "$BLOC"
  [ -s "$BLOC" ]
  run bash -c "
    set -euo pipefail
    . '$LCARS_MODULE_PROTOCOL' >/dev/null
    store() { :; }
    ensure_dir() { printf '%s\n' \"\$1\" >> '$LOG'; [[ \"\$1\" != /etc/lcars ]] || { p_fail 'refus de decor'; return 1; }; return 0; }
    source '$BLOC'
    layout
    printf 'FAILED=%s\n' \"\$LCARS_FAILED\""
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAILED=1"* ]]
  [ "$(wc -l < "$LOG")" -eq 13 ]
  grep -qx '/run/lock/lcars' "$LOG"   # la derniere ligne de la table est atteinte malgre le refus
  grep -qx "$LCARS_PRIVATE_DIR" "$LOG"
}

# ⚠ LA TABLE EST LE CONTRAT AVEC `deploy/system.manifest`, et une table qu'on ne mesure que par le
# NOMBRE de ses lignes laisse passer un mode ou un propriétaire faux — c'est-à-dire exactement ce que
# ces lignes servent à dire. Chaque ligne se compare donc à la déclaration du manifeste.
@test "layout : le mode et le proprietaire de chaque ligne sont ceux que le manifeste declare" {
  local MAN="$BATS_TEST_DIRNAME/../../../../deploy/system.manifest"
  [ -f "$MAN" ]
  local table
  # les DEFAUTS du protocole, pas le décor des autres cas : le contrat se lit sur la machine réelle
  table="$(env -u LCARS_PRIVATE_DIR -u LCARS_FLEET_GROUP -u LCARS_CATALOGUES_DIR -u LCARS_CATALOGUES_WORK \
    -u LCARS_AUTHORITY_USER bash -c ". '$LCARS_MODULE_PROTOCOL' >/dev/null 2>&1
      $(sed -n '/^layout_table() {/,/^}/p' "$SUT")
      layout_table")"
  [ -n "$table" ]
  local path mode owner decl compares=0 bad=""
  while read -r path mode owner; do
    # `dir` sur disque, `runtime` sous /run : les deux types déclarent un mode et un propriétaire
    decl="$(awk -v p="$path" '($1 == "dir" || $1 == "runtime") && $2 == p { print $3, $4; exit }' "$MAN")"
    [ -n "$decl" ] || continue          # un chemin que le manifeste ne déclare pas : hors contrat
    compares=$((compares + 1))
    [ "$decl" = "$mode $owner" ] || bad="$bad\n  $path : table « $mode $owner », manifeste « $decl »"
  done <<< "$table"
  [ -z "$bad" ] || { printf 'la table et le manifeste divergent :%b\n' "$bad" >&2; return 1; }
  # GARDE D'INSTRUMENT : sans comparaison, ce témoin serait vert sur une table vide
  [ "$compares" -ge 12 ] || { echo "instrument casse : $compares ligne(s) comparee(s), 8 au moins attendues" >&2; return 1; }
}
