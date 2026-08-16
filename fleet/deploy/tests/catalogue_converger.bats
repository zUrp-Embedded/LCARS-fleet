#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/catalogue_converger.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for modules.d/45-catalogues.sh + prov_roles — le materiel suit la FORGE
#
# CE QUE CES TEMOINS TIENNENT, ET POURQUOI CE MODULE EST LE PLUS DANGEREUX DE LA SERIE : il
# SUPPRIME. C'est legitime — le materiel local est un cache re-clonable — mais exactement une
# condition rend la suppression sure, et c'est que la lecture de la forge ait REUSSI. Une forge
# injoignable rend une liste vide, et une liste vide se lit « plus rien n'est installe ». Le module
# effacerait alors tous les catalogues de la boite en annoncant qu'il converge.
#
# La forge est simulee par un `curl` et un `git` poses en tete de PATH : ces temoins n'ouvrent aucune
# socket et ne clonent rien de reel. Ce qui est mesure est la DECISION du module, qui est tout ce
# qu'il apporte — le clone lui-meme est le travail de git.

setup() {
  MOD="$BATS_TEST_DIRNAME/../modules.d/45-catalogues.sh"
  LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  [ -x "$MOD" ]
  export PROVISION_LIB="$LIB"
  export PROV_CATALOGUES_DIR="$BATS_TEST_TMPDIR/catalogues"
  export PROV_FORGE_URL="http://forge.invalid"
  mkdir -p "$PROV_CATALOGUES_DIR" "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# La forge repond ce qu'on lui dit de repondre. `$1` = corps JSON ; sans argument, elle est DOWN
# (curl sort non-zero, ce que `-fsS` fait sur un echec reseau comme sur un 5xx).
fake_forge() {
  if [[ $# -eq 0 ]]; then
    printf '#!/usr/bin/env bash\nexit 7\n' > "$BATS_TEST_TMPDIR/bin/curl"
  else
    { printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n'; printf '%s\n' "$1"; printf 'JSON\n'; } \
      > "$BATS_TEST_TMPDIR/bin/curl"
  fi
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
}

# `git` qui trace ce qu'on lui demande sans rien faire. `clone` cree la cible pour que la suite du
# module trouve ce qu'il attend.
fake_git() {
  cat > "$BATS_TEST_TMPDIR/bin/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_TRACE_FILE"
case "$1" in
  clone) mkdir -p "${@: -1}/.git"; printf 'api_version: 1\nname: x\n' > "${@: -1}/catalogue.yaml"; exit 0 ;;
  ls-remote) echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef	HEAD"; exit 0 ;;
esac
# `-C <dir> rev-parse HEAD`
[[ "$*" == *rev-parse* ]] && { echo "0000000000000000000000000000000000000000"; exit 0; }
exit 0
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  export GIT_TRACE_FILE="$BATS_TEST_TMPDIR/git.log"
  : > "$GIT_TRACE_FILE"
}

# Du materiel deja pose, avec son manifeste — ce qui le rend visible du module.
seed_local() {
  mkdir -p "$PROV_CATALOGUES_DIR/$1/.git"
  printf 'api_version: 1\nname: %s\n' "$1" > "$PROV_CATALOGUES_DIR/$1/catalogue.yaml"
}

json_one() { printf '{"data":[{"name":"catalogue","empty":false,"owner":{"login":"%s"},"clone_url":"http://forge.invalid/%s/catalogue.git"}]}' "$1" "$1"; }

# ─── LA REGLE DE SURETE : on ne supprime QUE sur une lecture reussie ─────────────────────────────

@test "forge DOWN a l'apply : rien n'est supprime, et le refus le DIT" {
  fake_forge          # down
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"materiel laisse EN L'ETAT"* ]]
  # LE TEMOIN CENTRAL DE CE FICHIER : le materiel a survecu a une forge muette.
  [ -d "$PROV_CATALOGUES_DIR/web" ]
}

@test "forge DOWN au check : DRIFT, jamais « rien n'est installe »" {
  fake_forge
  fake_git
  run bash "$MOD" check
  [ "$status" -ne 0 ]
  [[ "$output" == *"forge injoignable"* ]]
}

@test "forge JOIGNABLE et vide : le materiel orphelin est retire" {
  fake_forge '{"data":[]}'
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"la forge ne l'installe plus"* ]]
  [ ! -d "$PROV_CATALOGUES_DIR/web" ]
}

# ─── CE QUI COMPTE COMME CATALOGUE ──────────────────────────────────────────────────────────────

@test "un repo nomme catalogue-perso ne signe RIEN — le filtre est exact, pas une sous-chaine" {
  # `q=catalogue` est un match de sous-chaine cote Gitea. Sans le filtre exact, le depot personnel
  # d'un humain ferait installer un catalogue que personne n'a installe.
  fake_forge '{"data":[{"name":"catalogue-perso","empty":false,"owner":{"login":"alice"},"clone_url":"http://forge.invalid/alice/catalogue-perso.git"}]}'
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [ ! -d "$PROV_CATALOGUES_DIR/alice" ]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
}

@test "un depot VIDE ne signe rien — une org creee sans sa source est un install interrompu" {
  fake_forge '{"data":[{"name":"catalogue","empty":true,"owner":{"login":"web"},"clone_url":"http://forge.invalid/web/catalogue.git"}]}'
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [ ! -d "$PROV_CATALOGUES_DIR/web" ]
}

@test "un repertoire local SANS manifeste n'est pas un catalogue — ni compte, ni supprime" {
  # Un clone interrompu ou un `lost+found`. Le compter le ferait verifier par le boot ; le supprimer
  # ferait de ce module le nettoyeur d'un repertoire dont il ne sait rien.
  fake_forge '{"data":[]}'
  fake_git
  mkdir -p "$PROV_CATALOGUES_DIR/moitie-de-clone"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [ -d "$PROV_CATALOGUES_DIR/moitie-de-clone" ]
}

# ─── LA CONVERGENCE ELLE-MEME ───────────────────────────────────────────────────────────────────

@test "materiel absent : il est clone, et le clone atterrit a cote avant d'etre renomme" {
  # Le staging est ce qui empeche un clone interrompu de laisser un demi-catalogue SOUS son nom
  # definitif — le boot suivant le verifierait comme s'il etait entier.
  fake_forge "$(json_one web)"
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [ -d "$PROV_CATALOGUES_DIR/web" ]
  [[ "$(cat "$GIT_TRACE_FILE")" == *"clone --quiet --depth 1 http://forge.invalid/web/catalogue.git $PROV_CATALOGUES_DIR/web.tmp"* ]]
  [ ! -e "$PROV_CATALOGUES_DIR/web.tmp" ]
}

@test "materiel present : fetch + reset --hard, JAMAIS pull" {
  # Le cache n'a pas d'historique a preserver. Un `pull` sur un depot reecrit par son proprietaire
  # s'arrete sur un conflit de merge que personne ne viendra resoudre dans un provisionnement.
  fake_forge "$(json_one web)"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$(cat "$GIT_TRACE_FILE")" == *"fetch --quiet --depth 1 origin HEAD"* ]]
  [[ "$(cat "$GIT_TRACE_FILE")" == *"reset --quiet --hard FETCH_HEAD"* ]]
  [[ "$(cat "$GIT_TRACE_FILE")" != *" pull"* ]]
}

@test "check : materiel en retard sur sa source = DRIFT nomme" {
  fake_forge "$(json_one web)"
  fake_git   # ls-remote rend deadbeef…, rev-parse rend 0000… : deux shas differents
  seed_local "web"

  run bash "$MOD" check
  [ "$status" -ne 0 ]
  [[ "$output" == *"web en retard sur sa source"* ]]
}

# ─── LE ROSTER DERIVE ───────────────────────────────────────────────────────────────────────────

@test "prov_roles sans release : le plancher tenu a la main, et rien de plus" {
  # Chemin WSL avant `60-deploy`, ou boite sans release pose. Une boite doit pouvoir minter de quoi
  # demarrer meme quand la derivation est impossible.
  run bash -c "set -euo pipefail; export PROVISION_LIB='$LIB' PROV_CATALOGUES_DIR='$PROV_CATALOGUES_DIR' PROV_ENTRYPOINT=/inexistant; source '$LIB'; prov_roles"
  [ "$status" -eq 0 ]
  [[ "$output" == *"system_architect"* ]]
  [[ "$output" == *"fleet_engineer"* ]]
}

@test "prov_roles avec un catalogue installe : ses roles ENTRENT, dedupliques et tries" {
  # LA QUATRIEME LISTE TENUE A LA MAIN MEURT ICI. Un catalogue installe apporte ses comptes sans
  # qu'aucun fichier de deploiement ne le sache — c'est tout l'interet de la derivation.
  seed_local "web"
  cat > "$BATS_TEST_TMPDIR/bin/entrypoint" <<'SH'
#!/usr/bin/env bash
# ⚠ LA PORTE EST `roles-tfvars`, PAS `roles`. La premiere rend des COMPTES (`web_dev`), la seconde
# des noms de ROLE (`dev`) — et `PROV_ROLES` est une liste de comptes. La doublure REFUSE `roles`
# pour que le temoin tombe si la derivation y revenait : mesure sur banc du 2026-08-16, branchee sur
# `roles`, elle faisait entrer `dev` et `writer` dans le roster a minter.
[[ "$1" == "roles-tfvars" ]] || exit 1
printf '{"roles":["web_dev","web_writer","fleet_engineer"],"system_roles":["system_architect"]}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/entrypoint"
  : > "$BATS_TEST_TMPDIR/bin/release"; chmod +x "$BATS_TEST_TMPDIR/bin/release"

  run bash -c "set -euo pipefail; export PROVISION_LIB='$LIB' PROV_CATALOGUES_DIR='$PROV_CATALOGUES_DIR' PROV_ENTRYPOINT='$BATS_TEST_TMPDIR/bin/entrypoint' PROV_RELEASE_BIN='$BATS_TEST_TMPDIR/bin/release'; source '$LIB'; prov_roles"
  [ "$status" -eq 0 ]
  [[ "$output" == *"web_dev"* ]]
  [[ "$output" == *"web_writer"* ]]
  # `fleet_engineer` est dans le plancher ET dans la sortie du catalogue : il ne sort qu'une fois.
  [ "$(printf '%s\n' $output | grep -c '^fleet_engineer$')" -eq 1 ]
}

@test "prov_roles : un catalogue dont la porte REFUSE n'ajoute rien, et ne casse pas le mint" {
  # Un catalogue incoherent est un catalogue que le boot refusera. Ce n'est pas au mint de trancher,
  # et faire echouer la derivation entiere priverait de jetons les catalogues sains.
  seed_local "casse"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$BATS_TEST_TMPDIR/bin/entrypoint"
  chmod +x "$BATS_TEST_TMPDIR/bin/entrypoint"
  : > "$BATS_TEST_TMPDIR/bin/release"; chmod +x "$BATS_TEST_TMPDIR/bin/release"

  run bash -c "set -euo pipefail; export PROVISION_LIB='$LIB' PROV_CATALOGUES_DIR='$PROV_CATALOGUES_DIR' PROV_ENTRYPOINT='$BATS_TEST_TMPDIR/bin/entrypoint' PROV_RELEASE_BIN='$BATS_TEST_TMPDIR/bin/release'; source '$LIB'; prov_roles"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet_engineer"* ]]
}
