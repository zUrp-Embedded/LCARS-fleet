#!/usr/bin/env bash
# SOURCE: deploy/modules.d/61-forge-structure.sh
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: la structure de la forge (orgs, comptes de rôle, teams, dépôt modèle) — le roster dérivé de la release posée, la recette jouée sur une copie
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# AFTER: 46-tofu 48-forge-host 60-deploy

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

RELEASE_BIN="$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"

# la structure se sonde compte par compte dans 63-forge-tokens ; release et tofu, dans 60 et 46
check() {
  if ! forge_up; then
    p_drift "forge muette ($PROV_FORGE_URL) — rien à structurer tant que 48-forge-host ne l'a pas relevée"
  elif [[ -s "$PROV_MASTER_TOKEN_FILE" ]]; then
    p_ok "forge vivante ($PROV_FORGE_URL), autorité de création présente ($PROV_MASTER_TOKEN_FILE)"
  else
    p_drift "aucune autorité de création ($PROV_MASTER_TOKEN_FILE) — 48-forge-host la minte"
  fi
  verdict_check
}

apply() {
  forge_up || { p_fail "forge muette ($PROV_FORGE_URL) — 48-forge-host la monte ou la relève, ce module la structure"; verdict_apply; }
  [[ -s "$PROV_MASTER_TOKEN_FILE" ]] || { p_fail "aucune autorité de création ($PROV_MASTER_TOKEN_FILE) — 48-forge-host la minte"; verdict_apply; }
  [[ -x "$PROV_TOFU_BIN" ]] || { p_fail "tofu absent ($PROV_TOFU_BIN) — 46-tofu le pose"; verdict_apply; }
  [[ -x "$RELEASE_BIN" ]] || { p_fail "aucune release exécutable posée ($RELEASE_BIN) — 60-deploy n'a pas abouti, et le roster s'en dérive"; verdict_apply; }

  # la release refuse de s'évaluer sous le siège (GUARD B) : le roster se dérive sous l'humain, en mode outil
  local enroll; enroll="$(mktemp -d "${TMPDIR:-/tmp}/prov-enroll.XXXXXX")"
  chown "$PROV_HUMAN" "$enroll" \
    || { p_fail "dossier de roster non cédé à $PROV_HUMAN ($enroll)"; rm -rf "$enroll"; verdict_apply; }
  run_step "roster du catalogue, dérivé de la release ($RELEASE_BIN)" -- as_human "$(dirname "$PROVISION_LIB")/enroll-catalogue.sh" --tofu-dir "$enroll" --release "$RELEASE_BIN" \
    || { rm -rf "$enroll"; verdict_apply; }
  [[ -s "$enroll/roles.auto.tfvars.json" ]] \
    || { p_fail "roster vide — la recette serait appliquée sans comptes"; rm -rf "$enroll"; verdict_apply; }

  p_step "forge : pose de la structure (orgs, comptes de rôle, teams, dépôt modèle)"
  local recipe; recipe="$(mktemp -d "${TMPDIR:-/tmp}/prov-recipe.XXXXXX")"
  cp -a "$(product_tree)/services/forge-recipe/." "$recipe/" \
    || { p_fail "recette non copiable ($(product_tree)/services/forge-recipe)"; rm -rf "$recipe" "$enroll"; verdict_apply; }
  cp "$enroll/roles.auto.tfvars.json" "$recipe/roles.auto.tfvars.json" \
    || { p_fail "roster non déposé dans la recette"; rm -rf "$recipe" "$enroll"; verdict_apply; }
  rm -rf "$recipe/.terraform" "$recipe/instance/.terraform"

  local rc=0 tf_out
  tf_out="$(mktemp "${TMPDIR:-/tmp}/prov-tofu.XXXXXX")"
  p_step "structure de la forge"
  prov_product_env
  # le geste initialise la recette avec le tofu de son PATH, et lit un jeton sur son entrée
  env "${PROV_PRODUCT_ENV[@]}" \
    PATH="$(dirname "$PROV_TOFU_BIN"):$PATH" \
    LCARS_RECIPE_DIR="$recipe" \
    LCARS_DEMO_CATALOGUE="$(repo_root)/catalogues/web-demo" \
    TF_CLI_CONFIG_FILE="$PROV_TOFU_DIR/tofurc" \
    bash "$(product_tree)/services/forge-gestures.sh" apply >"$tf_out" 2>&1 </dev/null || rc=$?
  rm -rf "$recipe" "$enroll"
  if [[ "$rc" -ne 0 ]]; then
    p_fail "structure non posée (rc=$rc) — la sortie ci-dessous dit pourquoi"
    PROV_LAST_OUT="$tf_out"; prov_dump_last
    verdict_apply
  fi
  # la recette est idempotente et rend 0 dans les deux cas : seule la sortie de tofu dit ce qui a bougé
  local moved
  moved="$(grep -c -E 'Apply complete!.*Resources: [1-9][0-9]* (added|changed|destroyed)|, [1-9][0-9]* (changed|destroyed)' "$tf_out" || true)"
  rm -f "$tf_out"
  if [[ "$moved" -gt 0 ]]; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "structure de la forge posée — 63-forge-tokens peut minter les jetons de rôle"
  else
    p_ok "structure de la forge déjà conforme — rien à poser"
  fi
  verdict_apply
}

case "${1:?usage: 61-forge-structure.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
