#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/human_git_identity.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for 70-human — l'identite git de l'humain vient de son COMPTE FORGE
#
# CE QUE CES TEMOINS TIENNENT. Sans `user.email`, git signe `<login>@<hostname>` (`lcars@bridge` sur
# cette image) et la forge ne mappe cette adresse sur aucun compte : commit sans lien, sans avatar,
# attribue a un fantome. L'adresse qui mappe est celle du compte forge, et c'est la SEULE.
#
# CE QU'ILS ONT COUTE. Le bloc vivait dans l'entrypoint et posait l'identite de `LCARS_HUMAN` —
# l'unique humain de la boite a l'epoque. `identity-v2` (b99d035f2) a fait de l'entree du conteneur
# le SYSADMIN : la substitution `LCARS_HUMAN` -> `LCARS_ADMIRAL` a suivi mecaniquement, et l'identite
# a atterri sur le seul compte qui ne commite jamais. Le commentaire au-dessus continuait de dire
# « l'email du compte forge de l'humain » — vrai, a cote d'un code qui ne le faisait plus, et le boot
# annoncait « identite git seedee » a chaque demarrage. Mesure du 2026-08-18, banc lcars-l8 :
# admiral <admiral@lcars.local>, `lcars` et `lordzurp` VIDES.
#
# Aucune socket : `curl` est une doublure en tete de PATH. Le module est charge SANS son dispatch
# final, pour appeler les deux fonctions directement — `check()`/`apply()` complets ecriraient dans
# le home reel de celui qui joue les tests.

setup() {
  SRC="$BATS_TEST_DIRNAME/../modules.d/70-human.sh"
  [ -f "$SRC" ]
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
  export FORGE_PAYLOAD="$BATS_TEST_TMPDIR/payload.json"
  echo '{}' > "$FORGE_PAYLOAD"
  cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
cat "$FORGE_PAYLOAD"
SH
  chmod +x "$BIN/curl"

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export PROVISION_MODULE=70-human
  export PROV_HUMAN="$(id -un)"
  export PROV_FORGE_URL="http://forge.test"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/tokens"; mkdir -p "$PROV_TOKENS_DIR"
  echo "tok" > "$PROV_TOKENS_DIR/system_starfleet.gitea_token"

  # HOME jetable : `as_human` s'execute DIRECTEMENT quand PROV_HUMAN est deja l'utilisateur courant,
  # donc `git config --global` ecrit dans CE home et nulle part ailleurs.
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"

  # Le module sans son `case` final : on veut ses fonctions, pas son cycle complet.
  MOD="$BATS_TEST_TMPDIR/mod.sh"
  sed '/^case "${1:?usage/,$d' "$SRC" > "$MOD"
}

run_fn() { run bash -c "set -euo pipefail; source \"$MOD\"; $1"; }

account() { # account <full_name> <email>
  printf '{"login":"x","full_name":"%s","email":"%s"}\n' "$1" "$2" > "$FORGE_PAYLOAD"
}

@test "identite absente + compte forge connu : DRIFT qui nomme la consequence" {
  account "Lord Zurp" "lord@zurp.xyz"
  run_fn 'check_git_identity'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT"* ]]
  [[ "$output" == *"aucun compte"* ]]
  [[ "$output" == *"avatar"* ]]
}

@test "apply pose le nom ET l'email du COMPTE FORGE" {
  account "Lord Zurp" "lord@zurp.xyz"
  run_fn 'apply_git_identity'
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSÉ"* ]]
  run git config --global --get user.email
  [ "$output" = "lord@zurp.xyz" ]
  run git config --global --get user.name
  [ "$output" = "Lord Zurp" ]
}

@test "un compte forge SANS full_name retombe sur le login, jamais sur du vide" {
  account "" "lord@zurp.xyz"
  run_fn 'apply_git_identity'
  run git config --global --get user.name
  [ "$output" = "$(id -un)" ]
}

@test "SEED-ONCE : une identite deja posee n'est jamais reecrite" {
  git config --global user.name "Le Choix De L Humain"
  git config --global user.email "moi@ailleurs.net"
  account "Lord Zurp" "lord@zurp.xyz"
  run_fn 'apply_git_identity'
  [ "$status" -eq 0 ]
  [[ "$output" != *"POSÉ"* ]]
  run git config --global --get user.email
  [ "$output" = "moi@ailleurs.net" ]
}

@test "identite posee : la sonde la NOMME au lieu de se taire" {
  git config --global user.email "moi@ailleurs.net"
  run_fn 'check_git_identity'
  [[ "$output" == *"OK"* ]]
  [[ "$output" == *"moi@ailleurs.net"* ]]
}

@test "PAS de compte forge : MUET des deux cotes — ce fait appartient a 50-forge" {
  # Le cas de `root` sur une vraie boite. Deux voix sur un meme fait divergent le jour ou l'une
  # des deux change ; `50-forge` rapporte deja « compte forge absent pour l'humain X ».
  echo '{"errors":["user does not exist"]}' > "$FORGE_PAYLOAD"
  run_fn 'check_git_identity'
  [ -z "$output" ]
  run_fn 'apply_git_identity'
  [ -z "$output" ]
  run git config --global --get user.email
  [ "$status" -ne 0 ]
}

@test "forge injoignable : rien n'est invente, le passage suivant la trouvera" {
  account "Lord Zurp" "lord@zurp.xyz"
  run_fn 'PROV_FORGE_URL=""; apply_git_identity'
  [ "$status" -eq 0 ]
  run git config --global --get user.email
  [ "$status" -ne 0 ]
}

@test "TEMOIN STRUCTUREL : l'entrypoint ne pose plus d'identite git" {
  # La regression exacte : un bloc d'identite dans l'entrypoint vise UN compte — celui de l'entree
  # du conteneur — et rate par construction tout humain enrole apres le boot.
  EP="$BATS_TEST_DIRNAME/../docker/entrypoint.sh"
  ! grep -qE '^\s*su - "\$LCARS_[A-Z]+" -c "git config' "$EP"
  ! grep -q 'LCARS_ADMIRAL_EMAIL' <(grep -v '^#' "$EP")
}
