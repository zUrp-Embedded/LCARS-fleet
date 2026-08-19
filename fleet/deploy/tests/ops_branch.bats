#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/ops_branch.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-20
# STATUS: bats tests for 52-ops-branch — la boite aux lettres, et la difference entre « pas encore » et « en panne »
#
# CE QUE CE MODULE POSE. Une branche ORPHELINE sur le depot ops : la boite aux lettres ou un pod
# depose sa demande d'outillage et ou un humain signe. Aucune API Gitea ne sait creer un commit sans
# parent — `POST /branches` exige `old_ref_name`, la ressource tofu n'a meme pas de champ de base —
# donc le geste passe par git, UNE fois, dans un depot jetable. Verifie sur banc neuf le 2026-08-20 :
# `parents: 0`.
#
# ⚠ CE QUE CES TEMOINS TIENNENT VRAIMENT, c'est la difference entre deux silences. Le module tourne
# en 52 ; le jeton systeme est minte par 50 — mais au PREMIER boot la forge n'est pas encore semee,
# donc 50 n'a rien pu frapper et le fichier n'existe pas. Rendre ECHEC faisait publier `rc=1` a une
# boite dont le seul tort etait d'etre neuve, et le vrai etat — « ca se posera a la convergence
# suivante » — n'etait dit nulle part. Un DRIFT dit exactement ca, et un jeton qui ne viendrait
# JAMAIS reste visible a chaque passage au lieu de disparaitre dans un echec de boot que personne
# ne relit.
#
# Le contrat des codes est celui de tous les modules : apply 0 = convergé · 1 = ECHEC · 2 = applique
# avec drift residuel. « Pas encore » vaut 2, jamais 1.

setup() {
  MODULE="$BATS_TEST_DIRNAME/../modules.d/52-ops-branch.sh"
  [ -f "$MODULE" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
  export PROV_FORGE_URL="http://forge.test"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"; mkdir -p "$PROV_TOKENS_DIR"
}

# $1 = code HTTP rendu pour la branche (200 presente · 404 absente)
stub_curl() {
  cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    */api/v1/version) exit 0 ;;
    */branches/*) printf '$1'; exit 0 ;;
  esac
done
exit 0
EOF
  chmod +x "$BIN/curl"
}

@test "jeton PAS ENCORE la : drift (rc 2), jamais un echec — une boite neuve n'est pas en panne" {
  stub_curl 404
  export PROV_SYSTEM_TOKEN_FILE="$PROV_TOKENS_DIR/absent.gitea_token"
  run bash "$MODULE" apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"DRIFT"* ]]
  [[ "$output" == *"pas encore"* ]]
  # Le message dit QUI le posera et QUAND ca se fermera — sans ca, « pas encore » est une excuse.
  [[ "$output" == *"50-forge"* ]]
  [[ "$output" == *"convergence suivante"* ]]
}

@test "branche DEJA presente : rien n'est touche — elle porte des signatures humaines" {
  stub_curl 200
  export PROV_SYSTEM_TOKEN_FILE="$PROV_TOKENS_DIR/x.gitea_token"
  printf 'TOK\n' > "$PROV_SYSTEM_TOKEN_FILE"
  run bash "$MODULE" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"déjà présente"* ]]
}

@test "forge injoignable : ECHEC franc — l'etat de la branche est INCONNU, pas convergé" {
  # Le pendant du premier temoin : tout « pas de reponse » ne vaut pas « pas encore ». Une forge
  # muette ne dit rien de la branche, et un module qui degraderait ca en drift rendrait vert un
  # rail dont personne n'a mesure la moitie.
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  chmod +x "$BIN/curl"
  export PROV_SYSTEM_TOKEN_FILE="$PROV_TOKENS_DIR/x.gitea_token"
  printf 'TOK\n' > "$PROV_SYSTEM_TOKEN_FILE"
  run bash "$MODULE" apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"injoignable"* ]]
}

@test "le nom de la branche est GELE dans le module — il ne se lit dans aucune variable" {
  # Son autorite est `Fleet.Toolchain.branch/0`, et le contrat `toolchain.branch_single_source` du
  # gate tient la recopie. Ce temoin-ci garde l'autre moitie : que ce fichier ne rouvre pas une
  # molette locale, ce qui redonnerait au nom deux sources dont une seule serait verifiee.
  grep -qE '^readonly OPS_BRANCH="tool_request"' "$MODULE"
  ! grep -q 'LCARS_SYSADMIN_BRANCH' "$MODULE"
}
