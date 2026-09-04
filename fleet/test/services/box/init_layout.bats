#!/usr/bin/env bats
# SOURCE: fleet/test/services/box/init_layout.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for box/init.sh layout — le magasin de l'instance est celui que l'hote monte
#
# ⚖ user 2026-09-04 (Q1, lot 7) : `26-store` (le module de l'installeur qui posait les modes du
# magasin en substrat docker) est mort — l'init de l'instance pose les quatre arbres. Ce mur
# etait le sien : la liste des arbres que l'init pose est EXACTEMENT celle que l'hote monte
# (`deploy/lib/store.sh`, `LCARS_STORE_TREES`, la source des volumes externes du compose). Un
# arbre monte et jamais pose n'aurait pas de mode ; un arbre pose et jamais monte serait un
# repertoire du conteneur qui se prend pour un volume.

load ../../support/refute

setup() {
  SUT="$BATS_TEST_DIRNAME/../../../services/box/init.sh"
  STORE_LIB="$BATS_TEST_DIRNAME/../../../../deploy/lib/store.sh"
  [ -f "$SUT" ] && [ -f "$STORE_LIB" ]
}

@test "les arbres du magasin que l'init pose sont ceux que l'hote monte — ni plus, ni moins" {
  local montes poses
  montes="$(bash -c 'source "$1" 2>/dev/null; printf "%s\n" "${LCARS_STORE_TREES[@]}"' _ "$STORE_LIB" | sort)"
  [ -n "$montes" ]
  poses="$(grep -oE 'ensure_dir "\$STORE_ROOT/[a-z]+"' "$SUT" | sed 's#.*/##; s/"$//' | sort)"
  [ -n "$poses" ]
  [ "$montes" = "$poses" ] || { echo "montes: $montes"; echo "poses: $poses"; false; }
}

@test "cache est au groupe fleet en setgid (les pods y ecrivent), les autres a root" {
  grep -qE 'ensure_dir "\$STORE_ROOT/cache" +2775 "root:\$LCARS_FLEET_GROUP"' "$SUT"
  grep -qE 'ensure_dir "\$STORE_ROOT/toolchains" +0755 root:root' "$SUT"
  grep -qE 'ensure_dir "\$STORE_ROOT/sysroots" +0755 root:root' "$SUT"
}

@test "un magasin non monte se DIT (drift), il ne se fabrique pas dans le conteneur" {
  grep -qE 'p_drift "magasin \$STORE_ROOT absent' "$SUT"
}
