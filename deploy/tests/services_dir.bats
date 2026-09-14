#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/services_dir.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-25
# STATUS: bats tests for runtime/services — un repertoire par ROLE, et il doit le rester

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2012 — `ls` sur des noms que ce depot controle — pas de nom exotique a manier
# shellcheck disable=SC2012

load refute

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # la RACINE du depot — `deploy/` et `runtime/` y sont FRERES
  MOD="$REPO/deploy/modules.d/62-runtime-helpers.sh"
  DOCKERFILE="$REPO/deploy/docker/Dockerfile"
  SERVICES="$REPO/runtime/services"
  [ -f "$MOD" ]
  [ -f "$DOCKERFILE" ]
  [ -d "$SERVICES" ]
}

# La liste des auxiliaires, EXTRAITE du module — jamais recopiee : un instrument qui mesure une copie
# de la source ne mesure pas la source, il est vert au moment precis ou ca derive.
helpers() {
  sed -n '/^HELPERS=(/,/^)/p' "$MOD" | sed '1d;$d;s/#.*//' | tr -d ' \t' | grep -v '^$'
}
# Les DONNEES de 62 (`DATA`, « nom destination mode ») declarent leur fichier par leur premier champ —
# `console.tmux.conf` en vient, et il n'est plus nomme par un COPY de l'image depuis le 2026-09-11.
data() {
  sed -n '/^DATA=(/,/^)/p' "$MOD" | sed '1d;$d;s/#.*//' | tr -d '"' | awk 'NF { print $1 }'
}

bulk_poste() { # `services` est-il dans le TABLEAU EMBEDDED, et pas dans un commentaire voisin ?
  grep -E '^EMBEDDED=\(' "$MOD" | sed 's/#.*//' | tr ' ()"' '\n\n\n\n' | grep -qx 'services'
}
declare_couvre() {
  local p="$1" liste; liste="$(helpers; data)"
  while :; do
    printf '%s\n' "$liste" | grep -qx "$p" && return 0
    [[ "$p" == */* ]] || return 1
    p="${p%/*}"
  done
}

@test "GARDE D'INSTRUMENT : les deux listes sont NON VIDES" {
  [ "$(helpers | wc -l)" -ge 8 ]
  [ "$(ls -1 "$SERVICES" | wc -l)" -ge 10 ]
}

@test "PROPRIETE 1 : deploy/docker ne porte plus AUCUN auxiliaire pose" {
  local n bad=()
  while read -r n; do
    [[ -e "$REPO/deploy/docker/$n" ]] && bad+=("$n")
  done < <(helpers)
  [ "${#bad[@]}" -eq 0 ] || {
    echo "auxiliaires revenus dans deploy/docker/ : ${bad[*]}" >&2
    false
  }
}

@test "PROPRIETE 2 : tout fichier de services est POSE quelque part" {
  local base bad=()
  while read -r base; do
    [[ "$(basename "$base")" == "README.md" ]] && continue
    declare_couvre "$base" && continue
    case "$base" in
      # ⚠ DEUX ARBRES QUE LE COPY DE L'IMAGE NOMMAIT, ET QUE LE RAIL LIT PAR LEUR RACINE — le jumeau
      # est parti le 2026-09-11, leur lecteur reel reste : un fichier par ligne, avec lui.
      forge-recipe/*)             continue ;;  # 61-forge-structure (LCARS_RECIPE_DIR, copie de l'arbre entier)
      admiral/skills/system-issues/SKILL.md) continue ;;  # container/init.sh (le skill du siege)
      admiral/skills/system-issues/list.sh)  continue ;;  # container/init.sh
      agent/claude-automode.json) continue ;;  # human.d/70-human.sh
      container/boot.sh)          continue ;;  # ENTRYPOINT du Dockerfile
      container/init.sh)          continue ;;  # boot.sh
      forge.d/catalogues.sh)      continue ;;  # 50-catalogues
      forge.d/deck-oidc.sh)       continue ;;  # 66-deck-oidc
      forge.d/ops-branch.sh)      continue ;;  # 65-ops-branch
      forge.d/tokens.sh)          continue ;;  # 63-forge-tokens
      human.d/40-claude-bin.sh)   continue ;;  # 60-deploy (convergeur d'humains)
      human.d/70-human.sh)        continue ;;  # 60-deploy, provision-lib
      human.d/75-projects.sh)     continue ;;  # 60-deploy
      lib/human-protocol.sh)      continue ;;  # human-converger.sh, human.d
      lib/module-protocol.sh)     continue ;;  # provision-lib, 63-forge-tokens
    esac
    bad+=("$base")
  done < <(cd "$SERVICES" && git ls-files)
  [ "${#bad[@]}" -eq 0 ] || {
    echo "dans services/ mais pose NULLE PART (ni HELPERS, ni la pose en bloc) : ${bad[*]}" >&2
    echo "  soit c'est un service — declare-le ; soit ce n'en est pas un — il n'a rien a faire ici." >&2
    echo "  bloc (EMBEDDED de 62, les deux terrains) : $(bulk_poste && echo present || echo ABSENT)" >&2
    false
  }
}

@test "PROPRIETE 3 : le rail pose l'arbre entier — c'est ce qui tient les fichiers non nommes, sur les deux terrains" {
  bulk_poste  || { echo "62-runtime-helpers n'embarque plus 'services' (EMBEDDED)" >&2
                   echo "  12 fichiers non nommes n'atteignent plus les machines — declare-les, ou remets-le dans EMBEDDED" >&2; false; }
  refute grep -qE '^COPY .*runtime/services' "$DOCKERFILE"
}
