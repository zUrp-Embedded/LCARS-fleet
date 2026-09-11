#!/usr/bin/env bash
# SOURCE: deploy/modules.d/61-forge-structure.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: PROTO-V2 — la STRUCTURE de la forge : roster du catalogue depuis la release POSEE, puis la recette
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# AFTER: 44-media 46-tofu 48-forge-host 60-deploy

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# ─── POURQUOI CE MODULE EXISTE, ET POURQUOI IL EST APRES 60 ──────────────────────────────────────
#
# `48-forge-host` posait la structure de la forge (orgs, comptes de rôle, teams, dépôt modèle) dans
# le même geste que son amorçage. Or la structure demande le ROSTER du catalogue, qui se dérive de
# la release — celle que `60-deploy` pose douze rangs plus loin. `provision` refuse un `AFTER` vers
# un rang supérieur : la dépendance était nommée dans un commentaire, pas tenue, et le module la
# contournait en COMPILANT l'arbre lui-même en livraison source (hex, rebar, `deps.get`, un
# `mix run` pour le catalogue de référence), puis en devinant quelle release lire
# (`prov_release_bin` : celle du paquet, ou celle déjà posée).
#
# ⚖ user 2026-09-04, chantier deploy-independance (point 1) : couper `48` en deux. Ici, au rang
# 61, la release est POSÉE par construction — un seul chemin, aucun `mix`, aucune devinette. Ce
# module lit `$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet` et rien d'autre ; s'il n'y est pas,
# c'est `60-deploy` qui n'a pas abouti, et le verdict le nomme.
#
# ⚠ CE MODULE NE NOMME AUCUN HUMAIN. Le seul déclarant du nom de l'humain intégré est
# `forge-gestures.sh` (`LCARS_BUILTIN_HUMAN`, posé par le BANC et par lui seul — `bench-forge-bootstrap.sh`
# pour le conteneur, `install.sh --bench` pour le poste, ⚖ user 2026-09-11 : les deux installs sont
# ISO) ; ce module le laisse traverser vers le geste sans le lire. Un déploiement de travail ne sème
# personne.

: "${PROV_FORGE_HOST_PORT:=21000}"

# La même adresse que `48-forge-host` la dérive — forge montée par nous, ou fournie. Recomposée ici
# à l'identique plutôt que lue dans `forge.url` : ce fichier est un EFFET de 48, et un module qui
# lirait l'effet d'un autre pour retrouver son entrée mesurerait la machine, pas le rail.
if [[ "${PROV_FORGE_MONTEE:-}" == "1" ]]; then
  FORGE_URL="http://127.0.0.1:${PROV_FORGE_HOST_PORT}"
elif [[ -n "${FORGE_BASE_URL:-}" ]]; then
  FORGE_URL="${FORGE_BASE_URL%/}"
else
  FORGE_URL="http://127.0.0.1:${PROV_FORGE_HOST_PORT}"
fi
RELEASE_BIN="$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"
TOFU_BIN="${LCARS_TOFU_BIN:-/usr/local/bin/tofu}"

forge_up() { curl -fsS -m 5 -o /dev/null "$FORGE_URL/api/v1/version" 2>/dev/null; }

# ─── CE QUE LE CHECK MESURE, ET CE QU'IL NE MESURE PAS ───────────────────────────────────────────
#
# La conformité de la STRUCTURE (comptes, teams, dépôts) se sonde compte par compte dans
# `63-forge-tokens` — c'est lui qui minte pour chacun, et un compte absent y est un drift nommé.
# Ce check tient les PRÉCONDITIONS du geste : la forge répond, l'autorité de création est là, la
# release est posée, tofu est là. Un check qui rejouerait la recette pour la comparer ferait un
# `tofu plan` à chaque doctor — c'est un geste, pas une mesure.
check() {
  if ! forge_up; then
    p_drift "forge muette ($FORGE_URL) — rien à structurer tant que 48-forge-host ne l'a pas relevée"
    verdict_check
  fi
  p_ok "forge vivante ($FORGE_URL)"
  if [[ -s "$PROV_MASTER_TOKEN_FILE" ]]; then
    p_ok "autorité de création présente ($PROV_MASTER_TOKEN_FILE)"
  else
    p_drift "aucune autorité de création ($PROV_MASTER_TOKEN_FILE) — 48-forge-host la minte"
  fi
  if [[ -x "$RELEASE_BIN" ]]; then
    p_ok "release posée ($RELEASE_BIN) — le roster s'en dérive"
  else
    p_drift "release absente ($RELEASE_BIN) — 60-deploy ne l'a pas posée, le roster ne peut pas se dériver"
  fi
  if [[ -x "$TOFU_BIN" ]]; then
    p_ok "tofu présent ($TOFU_BIN)"
  else
    p_drift "tofu absent — la structure de la forge est son territoire : joue « 46-tofu » d'abord"
  fi
  p_ok "la structure elle-même est sondée compte par compte par 63-forge-tokens"
  verdict_check
}

apply() {
  forge_up || { p_fail "forge muette ($FORGE_URL) — 48-forge-host la monte ou la relève, ce module la structure"; verdict_apply; }
  [[ -s "$PROV_MASTER_TOKEN_FILE" ]] \
    || { p_fail "aucune autorité de création ($PROV_MASTER_TOKEN_FILE) — 48-forge-host la minte"; verdict_apply; }
  [[ -x "$TOFU_BIN" ]] \
    || { p_fail "tofu absent ($TOFU_BIN) — la structure de la forge est son territoire : joue « 46-tofu » d'abord, puis relance"; verdict_apply; }
  # ⚠ UN SEUL CHEMIN, ET C'EST LE POINT. Ni `_build/prod/rel` d'un paquet, ni un arbre source à
  # compiler : la release POSÉE par 60, ou rien. Un module qui accepterait deux chemins aurait à
  # deviner lequel est le bon, et c'est exactement la gymnastique qu'on retire.
  [[ -x "$RELEASE_BIN" ]] || {
    p_fail "aucune release exécutable posée ($RELEASE_BIN) — 60-deploy n'a pas abouti"
    p_fail "  le roster du catalogue s'en dérive — sans elle, la structure serait posée sans comptes"
    verdict_apply
  }

  # ─── LE ROSTER, DEPUIS LA RELEASE ────────────────────────────────────────────────────────────
  # `enroll-catalogue.sh --release` joue `Fleet.Roster.eval_tfvars` par la porte de la release —
  # la même fonction que l'image expose par `roles-tfvars`. La release porte son catalogue : rien à
  # nommer, rien à monter. Sous l'humain, parce que la release refuse de s'évaluer sous le siège
  # (GUARD B) et que `LCARS_TOOL_EVAL=1` est le seam prévu pour un outil, pas pour une fleet.
  local enroll; enroll="$(mktemp -d "${TMPDIR:-/tmp}/prov-enroll.XXXXXX")"
  chown "$PROV_HUMAN" "$enroll" \
    || { p_fail "dossier de roster non cédé à $PROV_HUMAN ($enroll)"; rm -rf "$enroll"; verdict_apply; }
  run_step "roster du catalogue" -- as_human env LCARS_TOOL_EVAL=1 "$(dirname "$PROVISION_LIB")/enroll-catalogue.sh" --tofu-dir "$enroll" --release "$RELEASE_BIN" \
    || { p_fail "roster non dérivable de la release ($RELEASE_BIN) — relis la sortie, elle nomme l'étape"; rm -rf "$enroll"; verdict_apply; }
  [[ -s "$enroll/roles.auto.tfvars.json" ]] \
    || { p_fail "roster vide — la recette serait appliquée sans comptes"; rm -rf "$enroll"; verdict_apply; }

  # ─── LA RECETTE, DANS UNE COPIE ──────────────────────────────────────────────────────────────
  # Le checkout de l'opérateur ne reçoit ni le roster généré ni un état tofu : la recette se copie,
  # s'initialise hors-ligne (le miroir de providers de 46-tofu), se joue, s'efface.
  p_step "forge : pose de la structure (orgs, comptes de rôle, teams, dépôt modèle)"
  local recipe; recipe="$(mktemp -d "${TMPDIR:-/tmp}/prov-recipe.XXXXXX")"
  cp -a "$(product_tree)/services/forge-recipe/." "$recipe/" \
    || { p_fail "recette non copiable ($(product_tree)/services/forge-recipe)"; rm -rf "$recipe" "$enroll"; verdict_apply; }
  cp "$enroll/roles.auto.tfvars.json" "$recipe/roles.auto.tfvars.json" \
    || { p_fail "roster non déposé dans la recette"; rm -rf "$recipe" "$enroll"; verdict_apply; }
  # Le `.terraform` de l'arbre NE VOYAGE PAS : un état décrit un chemin, pas une recette.
  rm -rf "$recipe/.terraform" "$recipe/instance/.terraform"
  local m
  for m in instance .; do
    TF_CLI_CONFIG_FILE="${LCARS_TOFU_DIR:-/opt/lcars/tofu}/tofurc" \
      run_quiet env -C "$recipe/$m" "$TOFU_BIN" init -input=false -no-color \
      || { p_fail "recette non initialisable ($m) — le miroir de providers couvre-t-il cette recette ? (46-tofu)"; rm -rf "$recipe" "$enroll"; verdict_apply; }
  done

  # ─── LE GESTE ────────────────────────────────────────────────────────────────────────────────
  # `forge-gestures.sh apply` : l'autorité est LUE là où 48 l'a écrite (`LCARS_PRIVATE_DIR`), le
  # catalogue de référence, le geste le dérive lui-même de la release ; ce module ne nomme rien.
  local rc=0 tf_out
  tf_out="$(mktemp "${TMPDIR:-/tmp}/prov-tofu.XXXXXX")"
  p_step "structure de la forge"
  env \
    LCARS_PRIVATE_DIR="$PROV_TOKENS_DIR" \
    LCARS_AUTHORITY_USER="$PROV_AUTHORITY_USER" \
    FORGE_BASE_URL="$FORGE_URL" \
    LCARS_RECIPE_DIR="$recipe" \
    LCARS_DEMO_CATALOGUE="$(repo_root)/catalogues/web-demo" \
    TF_CLI_CONFIG_FILE="${LCARS_TOFU_DIR:-/opt/lcars/tofu}/tofurc" \
    bash "$(product_tree)/services/forge-gestures.sh" apply >"$tf_out" 2>&1 || rc=$?
  rm -rf "$recipe" "$enroll"
  if [[ "$rc" -ne 0 ]]; then
    p_fail "structure NON posée (rc=$rc) — relis la sortie, rien n'est supposé"
    { printf '───── sortie : %s dernières lignes ─────\n' "$PROV_DUMP_LINES"; tail -n "$PROV_DUMP_LINES" "$tf_out"; printf '───── sortie COMPLÈTE conservée : %s ─────\n' "$tf_out"; } >&2
    verdict_apply
  fi

  # ⚠ « APPLIQUÉ » N'EST PAS « CHANGÉ », ET LE CODE DE SORTIE NE LES DISTINGUE PAS. La recette est
  # idempotente : elle rend 0 aussi bien après avoir tout posé qu'après n'avoir rien eu à faire.
  # `tofu` le DIT, et c'est la seule source qui le sache : « Apply complete! Resources: N added,
  # M changed, K destroyed », une ligne par module de la recette. Illisible (format changé, sortie
  # tronquée) → on n'invente pas : on ne compte rien et on le nomme.
  local moved
  moved="$(grep -c -E 'Apply complete!.*Resources: [1-9][0-9]* (added|changed|destroyed)|, [1-9][0-9]* (changed|destroyed)' "$tf_out" 2>/dev/null || true)"
  rm -f "$tf_out"
  if [[ "${moved:-0}" -gt 0 ]]; then
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
