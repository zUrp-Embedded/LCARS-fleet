#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/media_tree.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: bats tests for 44-media — les medias partages, jumeau FICHIER du trou ISO des paquets
#
# `assets/` est la source ; le Dockerfile la pose en `/usr/share/lcars/{avatars,favicon}`. Aucun
# module de provision ne le faisait. Le trou etait COSMETIQUE tant que la recette de charte tournait
# DANS l'image ; en sortant tofu du conteneur, il est devenu un echec dur :
#
#   provision-forge-charte: dossier avatars introuvable: /usr/share/lcars/avatars
#
# ⚠ LE CHEMIN REEL SE NOMME, SINON LE TEMOIN MESURE LA MACHINE. `/usr/share/lcars` peut exister sur
# un poste de dev. Cinquieme occurrence de ce piege apres `/etc/lcars/host-consent`, `ttyd`, `tofu`
# et le reseau de `deck_origins`.

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  MOD="$BATS_TEST_DIRNAME/../modules.d/44-media.sh"
  DOCKERFILE="$BATS_TEST_DIRNAME/../docker/Dockerfile"
  ASSETS="$BATS_TEST_DIRNAME/../../../assets"
  [ -f "$MOD" ] && [ -f "$DOCKERFILE" ] && [ -d "$ASSETS" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export PROVISION_MODULE=44-media
  export PROV_SUBSTRATE=linux
  export PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP="$(id -gn)"
  export PROV_ADMIN_GROUP="$(id -gn)"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  export LCARS_MEDIA_ROOT="$BATS_TEST_TMPDIR/share/lcars"
  export LCARS_MEDIA_OWNER="$(id -un):$(id -gn)"
}

mod() { run bash "$MOD" "$1"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS + les trois en-tetes de module" {
  run head -9 "$MOD"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
  [[ "$output" == *"APPLY-ON: wsl linux"* ]]
  [[ "$output" == *"CHECK-ON: any"* ]]
  [[ "$output" == *"NEEDS: root"* ]]
}

@test "l'ORDRE porte le sens : ce module vient AVANT 48-forge-host, qui joue la recette" {
  local d="$BATS_TEST_DIRNAME/../modules.d"
  [ -f "$d/44-media.sh" ]
  [ -f "$d/48-forge-host.sh" ]
  [[ "44-media" < "48-forge-host" ]]
}

@test "les arbres poses sont EXACTEMENT ceux que le Dockerfile pose — deux rails, un contenu" {
  # C'est la definition du trou : ce que l'image livre et que le rail natif ne livrait pas.
  local t
  for t in avatars favicon; do
    grep -qE "^COPY assets/$t +/usr/share/lcars/$t" "$DOCKERFILE"
    grep -vE '^\s*#' "$MOD" | grep -q "MEDIA_TREES=(.*$t"
  done
}

@test "\`doc\` n'est PAS pose, et son absence est MOTIVEE" {
  # Le Dockerfile le remplit depuis un etage de build du site que ce rail ne batit pas. L'omettre
  # est une decision ; l'omettre en silence serait un oubli.
  grep -vE '^\s*#' "$MOD" | grep -q 'MEDIA_TREES=(avatars favicon)'
  grep -q 'COPY --from=site' "$DOCKERFILE"
  grep -q 'doc/` N.EST PAS POSÉ ICI' "$MOD"
}

@test "le seam est celui du PRODUIT, pas un second defaut" {
  # `runtime.exs` et `deck.ex` lisent `/usr/share/lcars`. Un module qui inventerait son propre chemin
  # servirait des avatars que personne ne regarde.
  local rt="$BATS_TEST_DIRNAME/../../config/runtime.exs" deck="$BATS_TEST_DIRNAME/../../lib/fleet/observation/deck.ex"
  grep -q 'LCARS_MEDIA_ROOT", "/usr/share/lcars"' "$rt"
  grep -q ':media_root, "/usr/share/lcars"' "$deck"
  grep -vE '^\s*#' "$MOD" | grep -q 'LCARS_MEDIA_ROOT:-/usr/share/lcars'
}

@test "absent : DRIFT qui nomme les DEUX consequences" {
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"avatars absent"* ]]
  [[ "$output" == *"charte"* ]]
  [[ "$output" == *"génériques"* ]]
}

@test "apply pose les deux arbres, et le CONTENU (jamais avatars/avatars)" {
  mod apply
  [ -f "$LCARS_MEDIA_ROOT/avatars/admiral.png" ]
  [ ! -d "$LCARS_MEDIA_ROOT/avatars/avatars" ]
  [ -d "$LCARS_MEDIA_ROOT/favicon" ]
}

@test "IDEMPOTENT : un second apply ne niche pas les arbres" {
  mod apply
  mod apply
  [ "$status" -eq 0 ]
  [ ! -d "$LCARS_MEDIA_ROOT/avatars/avatars" ]
  [ -f "$LCARS_MEDIA_ROOT/avatars/admiral.png" ]
}

@test "un repertoire VIDE est un DRIFT — l'existence n'est pas la question posee" {
  # Un dossier vide passe un `-d` et fait echouer la recette exactement pareil. C'est la meme classe
  # que « la version se sonde, pas la presence » dans 46-tofu.
  mkdir -p "$LCARS_MEDIA_ROOT/avatars" "$LCARS_MEDIA_ROOT/favicon"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"incomplet"* ]]
}

@test "apres apply, le check est VERT — les deux verbes lisent la meme regle" {
  mod apply
  mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"avatars posé"* ]]
}

@test "une source disparue est un ECHEC NOMME, jamais un arbre vide pose en silence" {
  # ⚠ LA SOURCE A UNE COUTURE, ET SANS ELLE CE CHEMIN EST INJOUABLE. `repo_root` vient de la lib, qui
  # la redefinit au source : la surcharger depuis le decor ne tient pas. Un chemin qu'aucun temoin ne
  # peut atteindre est un chemin non ecrit.
  export LCARS_MEDIA_SRC_ROOT="$BATS_TEST_TMPDIR/vide"
  mkdir -p "$LCARS_MEDIA_SRC_ROOT"
  mod apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"source absente"* ]]
  [ ! -d "$LCARS_MEDIA_ROOT/avatars" ]
}
