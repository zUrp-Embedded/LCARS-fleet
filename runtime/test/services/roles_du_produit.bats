#!/usr/bin/env bats
# SOURCE: runtime/test/services/roles_du_produit.bats
# AUTHOR: bob
# STARDATE: 2026-09-19
# STATUS: bats tests — les comptes de role sont un FAIT DU PRODUIT, demande au release
#
# ⚖ Decision 2 du plan runtime : pas de plancher de roles. La liste vient du catalogue embarque de
# la release et de chaque catalogue installe, lue par « lcars tool roles ». Elle etait ecrite CINQ
# fois dans cet arbre ; le mur `roles.provisioning_locked` en epingle quatre et ne voyait pas la
# cinquieme — celle du convergeur d'humains, dont la liste decide QUI devient un compte Linux.
#
# ⚠ ET L'ECHEC N'EST PAS UNE LISTE VIDE. « Je n'ai pas pu lire » et « cette machine n'a aucun role »
# sont deux etats : les confondre ferait adopter un compte de role comme humain, avec home, shell
# de fleet et console.

setup() {
  RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  PROTOCOLE="$RACINE/services/lib/module-protocol.sh"
  CONVERGEUR="$RACINE/services/human-converger.sh"
  [ -f "$PROTOCOLE" ]
  [ -f "$CONVERGEUR" ]
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export LCARS_MODULE_TAG=temoin
  unset LCARS_CLI LCARS_CATALOGUES_DIR
}

# Une CLI de banc : « tool roles [racine] » imprime un role par ligne.
stub_cli() { # stub_cli <roles du catalogue embarque> [roles d'une racine]
  cat > "$BIN/lcars" <<EOF
#!/usr/bin/env bash
[[ "\$1" == tool && "\$2" == roles ]] || exit 64
if [[ -n "\${3:-}" ]]; then printf '%s\n' ${2:-} ; else printf '%s\n' ${1:-} ; fi
EOF
  chmod +x "$BIN/lcars"
  export LCARS_CLI="$BIN/lcars"
}

appelle() { # appelle <expression bash apres le source du protocole>
  bash -c ". '$PROTOCOLE' >/dev/null 2>&1; $1"
}

@test "les roles viennent du release : un role par ligne, dedoublonnes et tries" {
  stub_cli "fleet_engineer system_chief fleet_engineer"

  run appelle 'lcars_roles'
  [ "$status" -eq 0 ]
  [ "$output" = "fleet_engineer system_chief" ]
}

@test "chaque catalogue INSTALLE ajoute les siens — la machine, pas le seul embarque" {
  stub_cli "system_chief" "web_designer"
  local cats="$BATS_TEST_TMPDIR/catalogues/web-demo"
  mkdir -p "$cats"; : > "$cats/catalogue.yaml"
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/catalogues"

  run appelle 'lcars_roles'
  [ "$status" -eq 0 ]
  [ "$output" = "system_chief web_designer" ]
}

# ⚠ LE POINT DE CE MUR : un echec de lecture n'est pas une liste vide.
@test "CLI absente : ECHEC (rc 1), jamais une liste vide" {
  export LCARS_CLI="$BATS_TEST_TMPDIR/pas-de-cli"

  run appelle 'lcars_roles'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "release muette (aucun role imprime) : ECHEC, pas « zero role »" {
  stub_cli ""

  run appelle 'lcars_roles'
  [ "$status" -eq 1 ]
}

# Le convergeur decide QUI devient un compte Linux. Sans roster, il ne doit adopter personne.
@test "convergeur : roster ILLISIBLE → il le DIT, et ne crée personne" {
  export PATH="$BIN:$PATH"
  export LCARS_CLI="$BATS_TEST_TMPDIR/pas-de-cli"
  export FORGE_BASE_URL="http://127.0.0.1:1"
  export LCARS_SYSADMIN_UID=1000
  export LCARS_HUMAN_PROTOCOL="$RACINE/services/lib/human-protocol.sh"
  export LCARS_MODULE_PROTOCOL="$PROTOCOLE"

  # `useradd` present mais MOUCHARD : s'il est appele, le temoin le verra.
  cat > "$BIN/useradd" <<'EOF'
#!/usr/bin/env bash
echo "USERADD $*" >> "$BATS_TEST_TMPDIR/appels"
EOF
  chmod +x "$BIN/useradd"
  : > "$BATS_TEST_TMPDIR/appels"

  run timeout 60 bash "$CONVERGEUR" --once
  [[ "$output" == *"roster de rôles ILLISIBLE"* || "$output" == *"roster de roles ILLISIBLE"* ]] \
    || { echo "$output" >&2; return 1; }
  [ ! -s "$BATS_TEST_TMPDIR/appels" ] || { echo "un compte a été créé : $(cat "$BATS_TEST_TMPDIR/appels")" >&2; return 1; }
}
