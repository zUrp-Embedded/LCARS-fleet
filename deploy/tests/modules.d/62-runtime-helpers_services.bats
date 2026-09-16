#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/modules.d/62-runtime-helpers_services.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-25
# STATUS: bats tests for runtime/services et 62-runtime-helpers — tout fichier de services est posé, par son nom ou par l'arbre embarqué

# SC2012 : `ls` sur des noms que ce dépôt contrôle
# shellcheck disable=SC2012

load ../refute

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  MOD="$REPO/deploy/modules.d/62-runtime-helpers.sh"
  SERVICES="$REPO/runtime/services"
  [ -f "$MOD" ]
  [ -d "$SERVICES" ]
}

# les listes que 62 pose, lues dans les constantes de l'installeur — jamais recopiees
constante() { sed -n "s/^$1=//p" "$REPO/deploy/installer-constants.env" | tr ' ' '\n'; }
helpers() { constante PROV_HELPERS; }
data() { constante PROV_HELPERS_DATA; constante PROV_SHELL_RC | sed 's|.*/||'; }
bulk_poste() { constante PROV_EMBEDDED | grep -qx 'services'; }
declare_couvre() {
  local p="$1" liste; liste="$(helpers; data)"
  while :; do
    printf '%s\n' "$liste" | grep -qx "$p" && return 0
    [[ "$p" == */* ]] || return 1
    p="${p%/*}"
  done
}

@test "GARDE D'INSTRUMENT : les deux listes sont NON VIDES" {
  [ -n "$(helpers)" ]
  [ -n "$(ls -A "$SERVICES")" ]
}

@test "PROPRIETE 2 : tout fichier de services est POSE quelque part" {
  local base bad=()
  while read -r base; do
    [[ "$(basename "$base")" == "README.md" ]] && continue
    declare_couvre "$base" && continue
    case "$base" in
      # les fichiers que le rail lit par leur racine, chacun avec son lecteur
      forge-recipe/*)             continue ;;  # 61-forge-structure (LCARS_RECIPE_DIR, copie de l'arbre entier)
      admiral/skills/system-issues/SKILL.md) continue ;;  # container/init.sh (le skill du siege)
      admiral/skills/system-issues/list.sh)  continue ;;  # container/init.sh
      agent/claude-automode.json) continue ;;  # human.d/70-human.sh
      container/boot.sh)          continue ;;  # ENTRYPOINT du Dockerfile
      container/init.sh)          continue ;;  # boot.sh
      forge.d/catalogues.sh)      continue ;;  # 50-catalogues
      forge.d/deck-oidc.sh)       continue ;;  # 66-deck-oidc
      forge.d/ops-repo.sh)      continue ;;  # 65-ops-repo
      forge.d/tokens.sh)          continue ;;  # 63-forge-tokens
      human.d/40-claude-bin.sh)   continue ;;  # 60-deploy (convergeur d'humains)
      human.d/70-human.sh)        continue ;;  # 60-deploy, provision-lib
      human.d/75-projects.sh)     continue ;;  # 60-deploy
      lib/human-protocol.sh)      continue ;;  # human-converger.sh, human.d
      lib/module-protocol.sh)     continue ;;  # provision-lib, 63-forge-tokens
    esac
    bad+=("$base")
  done < <(cd "$SERVICES" && find . -type f -not -path '*/__pycache__/*' | sed 's#^\./##' | sort)
  [ "${#bad[@]}" -eq 0 ] || {
    echo "dans services/ mais pose NULLE PART (ni HELPERS, ni la pose en bloc) : ${bad[*]}" >&2
    echo "  soit c'est un service — declare-le ; soit ce n'en est pas un — il n'a rien a faire ici." >&2
    echo "  bloc (EMBEDDED de 62, les deux terrains) : $(bulk_poste && echo present || echo ABSENT)" >&2
    false
  }
}

@test "PROPRIETE 3 : le rail pose l'arbre entier — c'est ce qui tient les fichiers non nommes, sur les deux terrains" {
  bulk_poste  || { echo "62-runtime-helpers n'embarque plus 'services' (EMBEDDED)" >&2
                   echo "  les fichiers non nommes n'atteignent plus les machines — declare-les, ou remets-le dans EMBEDDED" >&2; false; }
}
