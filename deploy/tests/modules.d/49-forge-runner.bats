#!/usr/bin/env bats
# SOURCE: deploy/tests/modules.d/49-forge-runner.bats
# AUTHOR: alice
# STARDATE: (posee par /push-github)
# STATUS: bats tests for 49-forge-runner — l'APPLY, que rien ne tenait
#
# POURQUOI CE FICHIER. Le decoupage `48 -> 49` a sorti l'enrolement du runner CI dans un module neuf,
# et ce module est arrive SANS SUITE. `forge_ci_runner.bats` tient la SONDE de `63-forge-tokens` — « zero
# runner » contre « je ne peux pas savoir » — pas le geste qui enrole.
#
# CE QUE L'APPLY DOIT TENIR, et chacun est un chemin distinct :
#   · la forge est eteinte      -> on REPORTE, ce n'est pas un echec (48 la monte)
#   · un runner existe deja     -> on ne le rejoue pas
#   · le jeton master manque    -> on le DIT, et ce n'est pas un echec non plus
#   · le delegue refuse         -> DRIFT, et sa sortie remonte a l'operateur
#   · le delegue reussit        -> POSE, et le compteur de changements bouge
#   · dans TOUS les cas         -> le fichier temporaire est retire
#
# ⚠ LE DERNIER POINT EST CELUI QUI SE PERD. `converge_ci_runner` ecrit la sortie du delegue dans un
# `mktemp` et le retire sur DEUX chemins distincts — succes et echec. Un troisieme chemin ajoute plus
# tard laisserait un fichier par passe dans `/tmp`, et personne ne le verrait avant que le disque ne
# soit plein. MESURE DU 2026-08-28 sur banc : le delegue a refuse (trois images introuvables et non
# tirables), donc c'est le chemin d'echec qui a servi — celui qu'aucun temoin ne gardait.
#
# ON EXECUTE LE MODULE, on ne le source pas : patron des autres temoins de `deploy/`.

# ⚠ SC2016 : ce temoin LIT DU CODE. Ses motifs `grep` portent des `$…` qui doivent atteindre l'outil
# tels quels — les developper chercherait la valeur dans CE shell au lieu du texte audite.
# ⚠ SC2030/SC2031 : chaque `@test` de bats est un sous-shell, et c'est l'isolation qu'on veut.
# shellcheck disable=SC2016,SC2030,SC2031

load ../refute

setup() {
  MODULE="$BATS_TEST_DIRNAME/../../modules.d/49-forge-runner.sh"
  [ -f "$MODULE" ]
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN" "$BATS_TEST_TMPDIR/tokens"
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROV_FORGE_URL="http://forge.test"
  export PROV_HUMAN="zoe"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/tokens"
  export PROV_MASTER_TOKEN_FILE="$BATS_TEST_TMPDIR/tokens/master"
  printf 'MASTERTOK' > "$PROV_MASTER_TOKEN_FILE"
  # ⚠ UN TMPDIR A NOUS, ET C'EST TOUT L'INSTRUMENT DU DERNIER TEMOIN : `converge_ci_runner` fait son
  # `mktemp` sous `$TMPDIR`. Le pointer ici rend le fichier temporaire OBSERVABLE ; sans ca il se
  # perd dans le `/tmp` de la machine qui joue la suite, avec ceux de tout le monde.
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  export PATH="$BIN:$PATH"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/docker"; chmod +x "$BIN/docker"
  export PROV_DOCKER_BIN="$BIN/docker"
}

# La forge repond, et `admin/actions/runners` rend ce qu'on lui dit. ETEINTE = /version refuse.
stub_curl() { # stub_curl <corps runners | MUET> [ETEINTE]
  cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
case "\$url" in
  */api/v1/version)               [ '${2:-}' = ETEINTE ] && exit 22; printf '{"version":"1.26.1"}' ;;
  */api/v1/admin/actions/runners) [ '$1' = MUET ] && exit 22; printf '%s' '$1' ;;
  *)                              exit 22 ;;
esac
exit 0
EOF
  chmod +x "$BIN/curl"
}

# Le delegue est un ESPION : il note son argv et rend le code qu'on lui donne.
stub_delegue() { # stub_delegue <rc> [ligne a ecrire sur stdout]
  local d="$BATS_TEST_TMPDIR/repo/deploy/docker"
  mkdir -p "$d"
  CALLS="$BATS_TEST_TMPDIR/runner.calls"; : > "$CALLS"
  cat > "$d/forge-runner.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
[ -n '${2:-}' ] && echo '${2:-}'
exit $1
EOF
  chmod +x "$d/forge-runner.sh"
  # `repo_root()` remonte trois crans depuis `<racine>/deploy/lib`.
  # ⚠ IDEMPOTENT : un temoin appelle ce helper DEUX fois (echec puis succes). Sans cette garde, le
  # second `cp` copie le fichier sur lui-meme et bats meurt — la doublure cassait le temoin qui
  # l'utilisait le plus.
  mkdir -p "$BATS_TEST_TMPDIR/repo/deploy/lib"
  local cible="$BATS_TEST_TMPDIR/repo/deploy/lib/provision-lib.sh"
  [ "$PROVISION_LIB" = "$cible" ] || cp "$PROVISION_LIB" "$cible"
  export PROVISION_LIB="$cible"
}

mod() { run env PROV_SUBSTRATE=wsl bash "$MODULE" "$1"; }

@test "forge ETEINTE : l'enrolement est REPORTE, ce n'est pas un echec" {
  # 48 monte la forge. Un module qui echouerait ici accuserait l'ordre du rail, pas un defaut.
  stub_curl '{"runners":[],"total_count":0}' ETEINTE
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"reporté"* ]]
  refute_out 'NON enrôlé' <<<"$output"
}

@test "un runner EXISTE deja : on ne rejoue pas le delegue" {
  stub_curl '{"runners":[{"name":"r1"}],"total_count":1}'
  stub_delegue 0
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"déjà enregistré"* ]]
  [ ! -s "$CALLS" ]
}

@test "jeton master ABSENT : on le DIT, et ce n'est pas un echec d'apply" {
  # Sans autorite, il n'y a rien a tenter. Un FAIL ici ferait echouer une install dont la forge
  # n'est pas encore amorcee — l'ordre du rail deviendrait une condition de succes.
  stub_curl '{"runners":[],"total_count":0}'
  stub_delegue 0
  rm -f "$PROV_MASTER_TOKEN_FILE"
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"aucun jeton master lisible"* ]]
  [ ! -s "$CALLS" ]
}

@test "le delegue REFUSE : DRIFT, et sa sortie remonte a l'operateur" {
  # MESURE DU 2026-08-28 : le delegue refuse quand ses images sont introuvables et non tirables —
  # un runner qui annoncerait ces labels raterait chaque job qui les demande. Le refus est la BONNE
  # reponse ; ce qui compte est qu'il remonte, et qu'il ne se compte pas comme un echec d'apply.
  stub_curl '{"runners":[],"total_count":0}'
  stub_delegue 1 "REFUS : image(s) introuvable(s)"
  mod apply
  [[ "$output" == *"NON enrôlé"* ]]
  [[ "$output" == *"REFUS : image(s) introuvable(s)"* ]]
  [ -s "$CALLS" ]
}

@test "le delegue REUSSIT : POSE, et il recoit la forge, le reseau et le projet" {
  stub_curl '{"runners":[],"total_count":0}'
  stub_delegue 0
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"runner CI enrôlé"* ]]
  grep -q -- "--forge-api http://forge.test/api/v1" "$CALLS"
  grep -q -- "--admin-token-file" "$CALLS"
  grep -q -- "--project" "$CALLS"
}

@test "API MUETTE : on n'en conclut RIEN, et on tente quand meme l'enrolement" {
  # « zero runner » et « je ne peux pas savoir » sont deux reponses. Muette, la sonde ne doit pas
  # faire croire qu'un runner existe — donc l'apply tente, et le delegue tranchera.
  stub_curl MUET
  stub_delegue 0
  mod apply
  [ "$status" -eq 0 ]
  [ -s "$CALLS" ]
}

@test "LE TEMPORAIRE EST RETIRE — sur le chemin d'ECHEC comme sur celui du succes" {
  # ⚠ C'EST LE POINT QUI SE PERD. La sortie du delegue passe par un `mktemp`, retire sur DEUX
  # chemins distincts. Un troisieme ajoute plus tard laisserait un fichier par passe dans `/tmp`.
  stub_curl '{"runners":[],"total_count":0}'
  stub_delegue 1 "refus"
  mod apply
  refute test -n "$(ls -A "$TMPDIR" 2>/dev/null)"

  stub_delegue 0
  mod apply
  refute test -n "$(ls -A "$TMPDIR" 2>/dev/null)"
}
