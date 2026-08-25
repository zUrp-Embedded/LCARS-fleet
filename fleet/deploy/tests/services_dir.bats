#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/services_dir.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for fleet/services — un repertoire par ROLE, et il doit le rester
#
# ⚠ CE QUE CES DEUX TEMOINS TIENNENT, ET POURQUOI AUCUN AUTRE NE LE FAIT.
#
# `runtime_helpers.bats` porte deja le miroir `HELPERS <-> COPY du Dockerfile` — dans les deux sens,
# et derive du module, donc il suit un demenagement tout seul. Il croise une LISTE avec une AUTRE
# LISTE. Ce qu'il ne voit pas, c'est le REPERTOIRE : un fichier present et declare NULLE PART lui est
# invisible, parce qu'il n'est dans aucune des deux listes qu'il compare.
#
# C'etait l'etat exact de `console-agents.py` — 1211 lignes, ni copiees, ni posees, ni appelees, dans
# l'arbre pendant trois semaines sans qu'aucun temoin ne s'en apercoive. Ces deux-la ferment ca.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # fleet/
  MOD="$REPO/deploy/modules.d/62-runtime-helpers.sh"
  DOCKERFILE="$REPO/deploy/docker/Dockerfile"
  SERVICES="$REPO/services"
  [ -f "$MOD" ] && [ -f "$DOCKERFILE" ] && [ -d "$SERVICES" ]
}

# La liste des auxiliaires, EXTRAITE du module — jamais recopiee : un instrument qui mesure une copie
# de la source ne mesure pas la source, il est vert au moment precis ou ca derive.
helpers() {
  sed -n '/^HELPERS=(/,/^)/p' "$MOD" | sed '1d;$d;s/#.*//' | tr -d ' \t' | grep -v '^$'
}

# Ce que le Dockerfile pose a plat dans /opt/lcars depuis `services/`, plus le convergeur qui va
# ailleurs (`/usr/local/bin`) — il est pose, donc il compte.
copied() {
  sed -n 's|^COPY fleet/services/\([^ ]*\) .*|\1|p' "$DOCKERFILE"
}

@test "GARDE D'INSTRUMENT : les trois listes sont NON VIDES" {
  # Sans ce garde, une extraction cassee (tableau renomme, COPY reecrit, repertoire deplace) rendrait
  # les deux temoins ci-dessous verts en n'ayant RIEN compare. C'est la forme d'echec la plus chere :
  # elle certifie. Ce chantier meme a fait rougir cinq temoins pour cette raison — chacun a refuse
  # plutot que de passer au vert sur du vide.
  [ "$(helpers | wc -l)" -ge 8 ]
  [ "$(copied | wc -l)" -ge 10 ]
  [ "$(ls -1 "$SERVICES" | wc -l)" -ge 10 ]
}

@test "PROPRIETE 1 : deploy/docker ne porte plus AUCUN auxiliaire pose" {
  # Le repertoire `docker/` redevient ce que son nom dit : du packaging conteneur. Un auxiliaire qui
  # y reapparaitrait remettrait du runtime privilegie sous un nom d'outil — le defaut que ce chantier
  # repare, et il se referait par simple habitude d'un `git mv` de confort.
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
  # ⚠ C'EST LE TEMOIN QUI ATTRAPE LE FICHIER QUE PERSONNE N'A DECLARE, et aucun autre ne le fait :
  # le miroir de `runtime_helpers` croise deux LISTES, celui-ci croise le REPERTOIRE avec elles. Un
  # fichier present et declare nulle part n'est pas un service, c'est une exploration garee — et un
  # fichier range est un fichier dont plus personne ne se demande s'il sert.
  local base bad=()
  # ⚠ ON MESURE CE QUE GIT SUIT, PAS CE QUE LE DISQUE PORTE. Un `__pycache__` regenere par le
  # premier `python3` venu n'est pas un service non declare : c'est un artefact, deja ignore
  # (`.gitignore:28`). Un temoin qui le compte crie a chaque execution de test, et un mur qui
  # crie sans raison apprend a etre ignore.
  while read -r base; do
    [[ "$base" == */* ]] && continue
    helpers | grep -qx "$base" && continue
    copied  | grep -qx "$base" && continue
    bad+=("$base")
  done < <(cd "$SERVICES" && git ls-files)
  [ "${#bad[@]}" -eq 0 ] || {
    echo "dans services/ mais pose NULLE PART (ni HELPERS, ni COPY) : ${bad[*]}" >&2
    echo "  soit c'est un service — declare-le ; soit ce n'en est pas un — il n'a rien a faire ici." >&2
    false
  }
}
