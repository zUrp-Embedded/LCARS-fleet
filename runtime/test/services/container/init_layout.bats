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
