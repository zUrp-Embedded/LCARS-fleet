#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/modules.d/thin_callers.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for the thin callers 45/63/65/66 — ce que l'installeur transmet au produit est GARDE
#
# DI-09 (lot 11). Un appelant mince ne fait qu'une chose : `exec env LCARS_X="…" bash <geste>`. Sous
# `set -u`, une valeur `"$PROV_X"` transmise depuis un PROV_ que la lib n'a pas pose tue l'appelant
# avant le geste, avec « unbound variable » pour tout verdict — vu au lot 6 (a2). La forme est donc
# `"${PROV_X:-}"` (vide → le protocole du produit pose SON defaut par `:=`), ou un defaut explicite.

load ../refute

setup() {
  MODS="$BATS_TEST_DIRNAME/../../modules.d"
  CALLERS=(50-catalogues 63-forge-tokens 65-ops-branch 66-deck-oidc)
}

@test "les quatre appelants sont MINCES : un exec env vers services/forge.d, et rien d'autre a executer" {
  local m code
  for m in "${CALLERS[@]}"; do
    code="$(grep -vE '^\s*#|^\s*$' "$MODS/$m.sh")"
    grep -qE '^exec env' <<<"$code" || { echo "$m : pas d'exec env" >&2; return 1; }
    grep -qE 'services/forge\.d/[a-z-]+\.sh" "\$\{?1' <<<"$code" || { echo "$m : n'appelle pas un geste de forge.d" >&2; return 1; }
    # aucune sonde, aucun verdict, aucun p_* : le geste rend le verdict, l'appelant relaie
    refute grep -qE '\bp_(ok|drift|fail|chg|warn)\b|verdict_(apply|check)' <<<"$code"
  done
}

@test "toute valeur transmise depuis un PROV_ est GARDEE — jamais un « unbound » a la place du verdict" {
  local m line bad=0
  for m in "${CALLERS[@]}"; do
    while IFS= read -r line; do
      # une valeur brute sans `:-` est la forme qui tue — et elle a DEUX ecritures, `"$PROV_X"` et
      # `"${PROV_X}"` ; la premiere version de ce cas ne voyait que la premiere (relecture hostile
      # 2026-09-04, M4 : mutation `"${PROV_CATALOGUES_DIR}"` verte ici, rouge au cas 3 seulement)
      if [[ "$line" =~ ^[[:space:]]+(LCARS|FORGE)_[A-Z_]+=\"\$\{?PROV_[A-Z_]+\}?\" ]]; then
        echo "$m : transmis sans garde → $line" >&2; bad=1
      fi
    done < <(grep -E '^\s+(LCARS|FORGE)_[A-Z_]+=' "$MODS/$m.sh")
  done
  [ "$bad" -eq 0 ]
}

@test "la garde est MESUREE, pas supposee : un appelant joue sans AUCUN PROV_ pose et meurt sur le geste, pas sur lui-meme" {
  # decor : une lib minimale (repo_root) et un geste doublure qui dit ce qu'il a recu
  local lib="$BATS_TEST_TMPDIR/lib.sh" root="$BATS_TEST_TMPDIR/root" m
  mkdir -p "$root/runtime/services/forge.d" "$root/runtime/services/lib"
  printf '%s\n' "repo_root() { printf '%s' '$root'; }" "product_tree() { printf '%s' '$root/runtime'; }" "advertise_addr() { :; }" > "$lib"
  : > "$root/runtime/services/lib/module-protocol.sh"
  for g in catalogues tokens ops-branch deck-oidc; do
    printf '%s\n' '#!/usr/bin/env bash' 'echo "geste:$(basename "$0") verbe:${1:-} login:${LCARS_LOGIN-<absent>}"' > "$root/runtime/services/forge.d/$g.sh"
  done
  for m in "${CALLERS[@]}"; do
    # AUCUN PROV_ pose, PROV_MODULE_TAG compris : sa garde `${PROV_MODULE_TAG:-}` est mesuree aussi
    run env -i PATH="$PATH" PROVISION_LIB="$lib" bash "$MODS/$m.sh" check
    [ "$status" -eq 0 ] || { echo "$m : rc=$status — $output" >&2; return 1; }
    [[ "$output" == *"geste:"*"verbe:check"* ]] || { echo "$m : $output" >&2; return 1; }
    [[ "$output" != *"unbound"* ]]
  done
}
