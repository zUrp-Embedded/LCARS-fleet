#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/forge_gestures.bats
# AUTHOR: drdree
# STARDATE: 2026-08-16
# STATUS: bats tests for services/forge-gestures.sh — LA porte des gestes forge du conteneur

# shellcheck disable=SC2030,SC2031

@test "TEMOIN STRUCTUREL : la porte cherche le geste sur l'hote quand le conteneur n'est pas la" {
  local container="$BATS_TEST_DIRNAME/../container"
  [ -f "$container" ]
  local body; body="$(grep -vE '^\s*#' "$container" | sed -n '/^gesture()/,/^}/p')"
  [ -n "$body" ]
  # Les deux chemins, et la condition qui les separe.
  grep -q 'compose ps -q lcars' <<<"$body"
  grep -qF '"$RACINE_CONTENEUR/forge-gestures.sh"' <<<"$body"
  grep -qF '[[ -x "$PROV_ROOT/forge-gestures.sh" ]]' <<<"$body"
  # ⚠ ET AUCUN `sudo` : la promesse auditee de ce rail est de n'en jamais demander. Un operateur
  # sans droit sur le fichier doit se faire REFUSER par eux, pas les contourner.
  refute grep -q 'sudo' <<<"$body"
}

load refute

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../runtime/services/forge-gestures.sh"
  [ -f "$SCRIPT" ]
  # ⚖ decision 3 : le geste SOURCE le lecteur des faits, qu'il cherche a cote de lui puis sous la
  # racine du produit (`/opt/lcars/services/lib`) — aucune des deux sous un decor, et les copies A
  # PLAT de `_flat_copy` en sont le cas limite. On le NOMME ici : la resolution des deux mondes est
  # tenue par son propre temoin (`runtime/test/services/faits.bats`), pas par ce fichier.
  export LCARS_FACTS_SH="$BATS_TEST_DIRNAME/../../runtime/services/lib/facts.sh"

  BIN="$BATS_TEST_TMPDIR/bin"
  PRIV="$BATS_TEST_TMPDIR/private"
  RECIPE="$BATS_TEST_TMPDIR/deps"
  mkdir -p "$BIN" "$RECIPE/instance" "$PRIV"
  ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
  STDIN_LOG="$BATS_TEST_TMPDIR/stdin.log"
  TOFU_LOG="$BATS_TEST_TMPDIR/tofu.log"
  : > "$ARGV_LOG"; : > "$STDIN_LOG"; : > "$TOFU_LOG"

  cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
if [[ " $* " == *" -K "* ]]; then cat >> "$STDIN_LOG"; fi
if [[ " $* " == *" registration-token"* || "$*" == *registration-token* ]]; then
  printf '{"token":"REG-TOKEN-42"}'
  exit 0
fi
# La team des approbateurs, dérivée du drapeau site-admin par `derive_admins` : trois lectures et
# une écriture. Sans elles, le geste refuse — à raison : une protection qui nomme une team vide ne
# débloque personne (mesure du 2026-09-18, banc vierge 2004).
case "$*" in
  */api/v1/teams/9/members/*) printf '204'; exit 0 ;;
  */api/v1/teams/9/members)   printf '[]'; exit 0 ;;
  */api/v1/orgs/*/teams)      printf '[{"id":9,"name":"admins"}]'; exit 0 ;;
  */api/v1/admin/users*)      printf '[{"login":"le-siege","is_admin":true,"active":true}]'; exit 0 ;;
esac
printf '%s' "${FAKE_AUTH_CODE:-200}"
FAKE
  chmod +x "$BIN/curl"

  # La doublure de tofu JOURNALISE SON REPERTOIRE : c'est la seule facon de prouver l'ORDRE des
  # deux modules, qui est un invariant (une adhesion ne cree pas le compte qu'elle nomme).
  cat > "$BIN/tofu" <<'FAKE'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$PWD" >> "$TOFU_LOG"
exit "${FAKE_TOFU_RC:-0}"
FAKE
  chmod +x "$BIN/tofu"

  cat > "$BIN/jq" <<FAKE
#!/usr/bin/env bash
# Assez de jq pour les DEUX questions posees : le jeton d'enregistrement, et le login de l'id 1.
# « jq -n » ne lit pas son entree : sous un terminal, un « cat » inconditionnel attendrait une ligne tapee
body=""; [[ " \$* " == *" -n "* || " \$* " == *" -cn "* ]] || body="\$(cat)"
case "\$*" in
  *'.id == 1'*) cat "$BATS_TEST_TMPDIR/master.out" 2>/dev/null || true ;;
  # la team des approbateurs et sa composition, derivee du drapeau site-admin (\`derive_admins\`) :
  # l'ID de la team, la liste des site-admins actifs, et les membres actuels
  *'select(.name==\$n)'*) echo "\${FAKE_TEAM_ID:-9}" ;;
  *'.is_admin == true'*)  printf '%s\n' \${FAKE_ADMINS-le-siege} ;;
  *'.[].login'*)          printf '%s' "\${FAKE_MEMBRES:-}" ;;
  *'.login'*)   echo "le-siege" ;;
  *'[\$s]'*)    echo '["le-siege"]' ;;
  *) [[ "\$body" =~ \"token\":\"([^\"]*)\" ]] && printf '%s\n' "\${BASH_REMATCH[1]}" ;;
esac
FAKE
  chmod +x "$BIN/jq"

  export ARGV_LOG STDIN_LOG TOFU_LOG
  export PATH="$BIN:$PATH"
  export LCARS_PRIVATE_DIR="$PRIV"
  export LCARS_RECIPE_DIR="$RECIPE"
  export FORGE_BASE_URL="http://forge.test"
  # le dossier de travail, qui est aussi le verrou d'apply, propre à chaque cas
  export LCARS_CATALOGUES_WORK="$BATS_TEST_TMPDIR/tofu"
  mkdir -p "$LCARS_CATALOGUES_WORK"
  # Le CACHE local du materiel. Pointe dans le tmpdir : sans ca le temoin ecrirait dans
  # `/home/catalogues`, c'est-a-dire dans le conteneur de celui qui lance la suite.
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/catalogues"

  # La porte outil du release, doublee : elle journalise SON verbe et rend ce que le cas veut.
  ENTRY_LOG="$BATS_TEST_TMPDIR/entry.log"
  # le catalogue que la release embarque : `apply` l'installe comme n'importe quel catalogue, et sa
  # source est cet arbre-ci ; un cas qui nomme LCARS_REFERENCE_CATALOGUE l'emporte sur cette porte
  REFERENCE="$BATS_TEST_TMPDIR/release-catalogue"; mkdir -p "$REFERENCE"
  printf 'api_version: 1\nname: fleet\n' > "$REFERENCE/catalogue.yaml"
  export REFERENCE
  cat > "$BIN/entrypoint" <<FAKE
#!/usr/bin/env bash
[[ "\$1" == tool ]] && shift   # la porte est « lcars tool <verbe> » (lot 6)
printf '%s\n' "\$*" >> "$ENTRY_LOG"
case "\$1" in
  catalogue-root) printf '%s\n' "$REFERENCE" ;;
  catalogue-source)
    rc="\$(cat "$BATS_TEST_TMPDIR/src.rc" 2>/dev/null || echo 0)"
    [[ "\$rc" -eq 0 ]] || { echo "ABSENT \$2" >&2; exit "\$rc"; }
    cat "$BATS_TEST_TMPDIR/src.out" 2>/dev/null || echo "alice/cat main deadbeef"
    ;;
  verify)       exit "\$(cat "$BATS_TEST_TMPDIR/verify.rc" 2>/dev/null || echo 0)" ;;
  roles-tfvars) echo '{"org":"cat","roles":["cat_dev"]}' ;;
esac
exit 0
FAKE
  chmod +x "$BIN/entrypoint"
  # La doublure tient le role de la CLI du produit : « lcars tool <verbe> » (lot 6).
  export LCARS_CLI="$BIN/entrypoint"
  export ENTRY_LOG

  # `git` double : il journalise, et ne touche pas au reseau.
  GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  cat > "$BIN/git" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GIT_LOG"
case "\$1" in
  clone) d="\${@: -1}"; mkdir -p "\$d"; printf 'name: cat\n' > "\$d/catalogue.yaml" ;;
esac
exit 0
FAKE
  chmod +x "$BIN/git"
  export GIT_LOG
}

@test "config-token: le jeton n'apparait JAMAIS dans argv" {
  run bash -c "printf '%s' 'JETON-MASTER-SECRET' | '$SCRIPT' config-token"
  [ "$status" -eq 0 ]
  run grep -c "JETON-MASTER-SECRET" "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "config-token: TEMOIN — il est bien presente, par stdin (sinon on aurait supprime l'auth)" {
  run bash -c "printf '%s' 'JETON-MASTER-SECRET' | '$SCRIPT' config-token"
  [ "$status" -eq 0 ]
  grep -q 'header = "Authorization: token JETON-MASTER-SECRET"' "$STDIN_LOG"
}

@test "config-token: un jeton qui porte des guillemets traverse INTACT" {
  printf '%s' 'a"b\c' > "$BATS_TEST_TMPDIR/tok"
  run bash -c "'$SCRIPT' config-token < '$BATS_TEST_TMPDIR/tok'"
  [ "$status" -eq 0 ]
  grep -qF 'header = "Authorization: token a\"b\\c"' "$STDIN_LOG"
  run grep -cF 'a"b' "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "config-token: 200 => le fichier est ecrit, en 0600" {
  run bash -c "printf '%s' 'JETON-OK' | '$SCRIPT' config-token"
  [ "$status" -eq 0 ]
  [ -f "$PRIV/forge-master.token" ]
  [ "$(cat "$PRIV/forge-master.token")" = "JETON-OK" ]
  [ "$(stat -c '%a' "$PRIV/forge-master.token")" = "600" ]
}

@test "config-token: un jeton qui ne s'authentifie pas n'est PAS ecrit" {
  # LE MENSONGE QUE CE TEMOIN INTERDIT : un conteneur qui croit tenir son autorite et le decouvre au
  # premier geste structurel, des mois plus tard, sur une forge de production.
  FAKE_AUTH_CODE=401 run bash -c "printf '%s' 'JETON-MORT' | '$SCRIPT' config-token"
  [ "$status" -eq 3 ]
  [ ! -e "$PRIV/forge-master.token" ]
  [[ "$output" == *"RIEN n'a ete ecrit"* ]]
}

@test "config-token: sans FORGE_BASE_URL, on refuse au lieu de poser un jeton sans forge" {
  run env -u FORGE_BASE_URL bash -c "printf '%s' 'X' | '$SCRIPT' config-token"
  [ "$status" -eq 2 ]
  [ ! -e "$PRIV/forge-master.token" ]
}

@test "config-seed: pose le seed en 0600, et un seed vide est refuse" {
  run bash -c "printf '%s' 'MON-SEED' | '$SCRIPT' config-seed"
  [ "$status" -eq 0 ]
  [ "$(cat "$PRIV/forge-seed.pass")" = "MON-SEED" ]
  [ "$(stat -c '%a' "$PRIV/forge-seed.pass")" = "600" ]
  run bash -c "printf '' | '$SCRIPT' config-seed"
  [ "$status" -ne 0 ]
}

@test "apply: sans rien, il NOMME les trois manques au lieu d'en deviner un" {
  run env -u FORGE_BASE_URL bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"l'URL de la forge"* ]]
  [[ "$output" == *"l'autorité"* ]]
  [[ "$output" == *"le seed des comptes"* ]]
  [[ "$output" == *"deploy/workstation up"* ]]
  [[ "$output" == *"deploy/container config"* ]]
}

@test "apply: avec l'URL mais rien d'autre, il ne nomme QUE ce qui manque" {
  # Le contre-temoin : sans lui, une implementation qui recite les trois manques en toutes
  # circonstances passerait le test ci-dessus.
  run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" != *"l'URL de la forge"* ]]
  [[ "$output" == *"l'autorité"* ]]
}

@test "apply: l'ORDRE des deux modules est instance PUIS catalogue" {
  # Ce n'est pas une preference : une adhesion peut nommer un compte qu'elle ne cree pas, jamais un
  # compte qui n'existe pas. L'inversion echoue en 404 cote Gitea, tard et sur un autre sujet.
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$TOFU_LOG")" = "init $RECIPE/instance" ]
  [ "$(sed -n '2p' "$TOFU_LOG")" = "apply $RECIPE/instance" ]
  [ "$(sed -n '3p' "$TOFU_LOG")" = "init $RECIPE" ]
  [ "$(sed -n '4p' "$TOFU_LOG")" = "apply $RECIPE" ]
}



@test "apply: un tofu en echec, LUI, est fatal et nomme le module" {
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  FAKE_TOFU_RC=1 run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"instance"* ]]
}

@test "apply: un jeton sur stdin l'emporte sur celui que le conteneur garde" {
  printf 'TOK-CONTENEUR\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  run bash -c "printf '%s' 'TOK-APPELANT' | '$SCRIPT' apply"
  [ "$status" -eq 0 ]
  # Le fichier du conteneur n'est PAS reecrit : `apply` consomme, il ne pose pas.
  [ "$(cat "$PRIV/forge-master.token")" = "TOK-CONTENEUR" ]
}

@test "apply depuis un terminal : il n'attend aucune ligne tapée" {
  command -v script >/dev/null || skip "script (util-linux) absent"
  printf 'TOK-FICHIER\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  # un terminal ouvert qui ne tape rien : sans la garde, le geste attendrait jusqu'au timeout (124)
  run bash -c "(sleep 30) | timeout 15 script -qec \"'$SCRIPT' apply\" /dev/null"
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$TOFU_LOG")" = "init $RECIPE/instance" ]
}

@test "apply: DEUX applys concurrents — le second REFUSE, il n'attend pas" {
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"

  # Un tiers tient le verrou pendant que l'apply tente sa chance.
  ( flock 9 && sleep 5 ) 9<"$LCARS_CATALOGUES_WORK" &
  holder=$!
  sleep 0.3
  run bash -c "'$SCRIPT' apply < /dev/null"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$status" -ne 0 ]
  [[ "$output" == *"un autre apply de structure est en cours"* ]]
  # TEMOIN : rien n'a ete TENTE — pas un seul tofu n'a tourne.
  [ ! -s "$TOFU_LOG" ]
}

@test "apply: TEMOIN — verrou libre, l'apply passe (sinon le refus ci-dessus serait un blocage permanent)" {
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]
  [ -s "$TOFU_LOG" ]
}


setup_install() {
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  printf 'SYS\n' > "$PRIV/system_starfleet.gitea_token"
}

@test "install: la LECTURE de la source va sous le jeton SYSTEME, jamais le master" {
  setup_install
  cat > "$BIN/entrypoint" <<FAKE
#!/usr/bin/env bash
printf '%s TOK=%s TOKFILE=%s\n' "\$*" "\${FORGE_TOKEN:-}" "\${FORGE_TOKEN_FILE:-}" >> "$ENTRY_LOG"
case "\$1" in
  catalogue-source) echo "alice/cat main deadbeef" ;;
  roles-tfvars)     echo '{"org":"cat","roles":["cat_dev"]}' ;;
esac
exit 0
FAKE
  chmod +x "$BIN/entrypoint"

  run bash -c "'$SCRIPT' install cat < /dev/null"
  # `SYS` est le contenu de `system_starfleet.gitea_token` ; `TOK` celui du master (setup_install).
  grep -q "catalogue-source cat TOK=SYS " "$ENTRY_LOG"
  refute grep -q "catalogue-source cat TOK=TOK " "$ENTRY_LOG"
  # ET PLUS AUCUN CHEMIN NE TRAVERSE : le passer reviendrait a donner a la porte un fichier qu'elle
  # ne peut pas ouvrir — un refus de permission presente comme un catalogue introuvable.
  refute grep -q "catalogue-source .*TOKFILE=$PRIV" "$ENTRY_LOG"
}

@test "install: un jeton systeme VIDE est refuse AVANT la porte, et il est nomme" {
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  : > "$PRIV/system_starfleet.gitea_token"

  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"VIDE"* ]]
  [[ "$output" == *"system_starfleet.gitea_token"* ]]
}

@test "install: sans jeton systeme, il REFUSE en le NOMMANT (pas un echec de lecture opaque)" {
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  rm -f "$PRIV/system_starfleet.gitea_token"

  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"system_starfleet.gitea_token"* ]]
  [[ "$output" == *"deploy/workstation up"* ]]
  [[ "$output" == *"deploy/container up"* ]]
  # la seule porte jouee est la question « est-ce le catalogue de la release ? » ; aucune resolution
  refute grep -q '^catalogue-source' "$ENTRY_LOG"
  refute grep -q '^verify' "$ENTRY_LOG"
}

@test "install: sans autorite, il REFUSE avant de toucher quoi que ce soit" {
  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"container config"* ]]
  [ ! -s "$ENTRY_LOG" ]
}

@test "install: un catalogue SANS depot remonte le refus de la porte, il ne le traduit pas" {
  # Les codes de la porte distinguent trois refus qui appellent trois gestes differents. Les aplatir
  # en « echec » perdrait l'information a l'endroit exact ou elle sert.
  setup_install
  echo 2 > "$BATS_TEST_TMPDIR/src.rc"
  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ABSENT"* ]]
  [ ! -s "$TOFU_LOG" ]
}

@test "install: un catalogue qui ne passe pas la VERIFICATION ne pose RIEN" {
  # Le meme controle que le boot, joue AVANT la forge. Refuse ici, il coute un message ; installe,
  # il coute un boot qui refuse ou un dispatch qui boucle, loin de sa cause.
  setup_install
  echo 1 > "$BATS_TEST_TMPDIR/verify.rc"
  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ne passe pas la verification"* ]]
  [ ! -s "$TOFU_LOG" ]
  grep -q '^verify ' "$ENTRY_LOG"
}

@test "install: l'ordre est source -> verify -> roster -> tofu -> store" {
  setup_install
  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -eq 0 ]
  # d'abord « est-ce le catalogue de la release ? » (son nom, demande a la release), puis la voie de la forge
  [ "$(sed -n '1p' "$ENTRY_LOG" | cut -d' ' -f1)" = "catalogue-root" ]
  [ "$(sed -n '2p' "$ENTRY_LOG" | cut -d' ' -f1)" = "catalogue-source" ]
  [ "$(sed -n '3p' "$ENTRY_LOG" | cut -d' ' -f1)" = "verify" ]
  [ "$(sed -n '4p' "$ENTRY_LOG" | cut -d' ' -f1)" = "roles-tfvars" ]
  grep -q "$LCARS_CATALOGUES_WORK/cat" "$TOFU_LOG"
  # le magasin : SA branche du depot du systeme, jamais un depot par catalogue
  grep -q 'push -q --force http://forge.test/lcars/_catalogues.git HEAD:refs/heads/cat' "$GIT_LOG"
}

@test "install: le MATERIEL local est pose dans le meme geste, clone depuis le store" {
  setup_install
  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -eq 0 ]
  [ -f "$LCARS_CATALOGUES_DIR/cat/catalogue.yaml" ]
  grep -q "clone --quiet --depth 1 --branch cat http://forge.test/lcars/_catalogues.git" "$GIT_LOG"
  [[ "$output" == *"materiel pose"* ]]
}


@test "install: materiel local en echec — le dire en echec, ne pas defaire ce qui est bon" {
  # L'org et la source sont posees avant lui. Defaire ce qui est bon parce que le cache a rate
  # serait perdre le travail utile pour une moitie rattrapable au prochain boot. Rendre 0 ferait
  # dire « installe » a une machine qui ne sert pas le catalogue (banc beta3, deux rails).
  setup_install
  # Un cache impossible a ecrire : le parent est un FICHIER.
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/pas-un-dossier/sub"
  : > "$BATS_TEST_TMPDIR/pas-un-dossier"

  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -eq 1 ] || { echo "rc=$status"; echo "$output"; return 1; }
  [[ "$output" == *"est posé sur la forge (org, comptes, source sur lcars/_catalogues:cat), mais son matériel local n'a pas pu être posé"* ]]
  [[ "$output" == *"prochain démarrage du conteneur"* ]]
  [[ "$output" == *"deploy/workstation up"* ]]
  grep -q 'push -q --force http://forge.test/lcars/_catalogues.git HEAD:refs/heads/cat' "$GIT_LOG"
}

@test "install: L'ETAT DE TOFU N'EST JAMAIS COPIE — installer un catalogue ne desinstalle pas l'autre" {
  setup_install
  printf '{"version":4,"resources":[{"name":"role"}]}\n' > "$RECIPE/terraform.tfstate"
  printf 'backup\n' > "$RECIPE/terraform.tfstate.backup"
  mkdir -p "$RECIPE/.terraform" "$RECIPE/instance/.terraform"
  printf 'etat instance\n' > "$RECIPE/instance/terraform.tfstate"

  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -eq 0 ]
  [ ! -e "$LCARS_CATALOGUES_WORK/cat/terraform.tfstate" ]
  [ ! -e "$LCARS_CATALOGUES_WORK/cat/terraform.tfstate.backup" ]
  [ ! -e "$LCARS_CATALOGUES_WORK/cat/.terraform" ]
  [ ! -e "$LCARS_CATALOGUES_WORK/cat/instance/terraform.tfstate" ]
  # TEMOIN DE NON-VACUITE : la recette ELLE-MEME est bien arrivee.
  [ -f "$LCARS_CATALOGUES_WORK/cat/roles.auto.tfvars.json" ]
}

@test "install: l'etat DE CE CATALOGUE-CI survit au rejeu — sinon tout se re-importe a chaque fois" {
  setup_install
  printf '{"version":4,"resources":[{"name":"role"}]}\n' > "$RECIPE/terraform.tfstate"
  mkdir -p "$LCARS_CATALOGUES_WORK/cat"
  printf 'ETAT-DE-CAT\n' > "$LCARS_CATALOGUES_WORK/cat/terraform.tfstate"

  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -eq 0 ]
  run cat "$LCARS_CATALOGUES_WORK/cat/terraform.tfstate"
  [ "$output" = "ETAT-DE-CAT" ]
}

@test "install: UN DOSSIER DE RECETTE PAR CATALOGUE — le roster n'ecrase pas celui d'un autre" {
  setup_install
  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -eq 0 ]
  [ -f "$LCARS_CATALOGUES_WORK/cat/roles.auto.tfvars.json" ]
  [ ! -f "$RECIPE/roles.auto.tfvars.json" ]
}

@test "install: le jeton n'apparait JAMAIS dans l'argv de git" {
  # `/proc/<pid>/cmdline` est lisible par tout le monde ; l'environ ne l'est que par le processus.
  setup_install
  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -eq 0 ]
  run grep -c 'TOK' "$GIT_LOG"
  [ "$output" = "0" ]
}

@test "install: TEMOIN — le jeton EST fourni a git, par l'environnement" {
  # Sans lui, un correctif qui supprimerait l'auth passerait le test ci-dessus.
  setup_install
  cat > "$BIN/git" <<FAKE
#!/usr/bin/env bash
printf '%s|%s\n' "\$*" "\${GIT_CONFIG_VALUE_0:-}" >> "$GIT_LOG"
case "\$1" in clone) d="\${@: -1}"; mkdir -p "\$d";; esac
exit 0
FAKE
  chmod +x "$BIN/git"
  run bash -c "'$SCRIPT' install cat < /dev/null"
  grep -q 'Authorization: token TOK' "$GIT_LOG"
}

@test "apply: le catalogue de DEMONSTRATION est depose chez le master (id=1), pas installe" {
  # Depose = `available`. Installe serait une decision qu'on prend a la place de l'operateur, et le
  # nom `web-demo` existe justement pour le pousser au fork plutot qu'a l'installation.
  setup_install
  demo="$BATS_TEST_TMPDIR/web-demo"
  mkdir -p "$demo"
  printf 'name: web-demo\n' > "$demo/catalogue.yaml"

  echo "le-master" > "$BATS_TEST_TMPDIR/master.out"

  LCARS_DEMO_CATALOGUE="$demo" run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]
  grep -q 'push .*le-master/web-demo' "$GIT_LOG"
}

@test "apply: master (id=1) NON resolu — le refus NOMME le catalogue qu'il n'a pas depose" {
  # Un refus qui ne nomme pas son objet est un demi-message : celui qui le lit ne sait pas ce qui
  # manque a sa forge. Et on ne depose PAS chez un compte devine.
  setup_install
  demo="$BATS_TEST_TMPDIR/web-demo"
  mkdir -p "$demo"
  # Le manifeste est ce qui donne son NOM au depot : sans lui le geste s'arrete avant meme de
  # chercher le master, et ce temoin passerait sur un refus qui n'est pas le sien.
  printf 'api_version: 1\nname: web-demo\n' > "$demo/catalogue.yaml"
  : > "$BATS_TEST_TMPDIR/master.out"

  LCARS_DEMO_CATALOGUE="$demo" run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"web-demo NON depose"* ]]
  # Aucun push de la demo. Le magasin du catalogue de la release, lui, EST pousse : c'est une
  # installation, pas un depot chez le master.
  refute grep -q 'push .*web-demo' "$GIT_LOG"
  grep -q 'push -q --force http://forge.test/lcars/_catalogues.git HEAD:refs/heads/fleet' "$GIT_LOG"
}

@test "apply: SANS catalogue de demonstration dans l'image, l'apply ne dit rien" {
  # Un deploiement qui ne livre pas la demo ne doit produire aucun bruit — ni avertissement, ni
  # ligne de verdict sur un objet absent par choix.
  setup_install
  LCARS_DEMO_CATALOGUE="$BATS_TEST_TMPDIR/pas-de-demo" run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" != *"demonstration"* ]]
}

@test "apply: le catalogue de REFERENCE est depose aussi, au meme endroit" {
  setup_install
  ref="$BATS_TEST_TMPDIR/reference"
  mkdir -p "$ref"
  printf 'api_version: 1\nname: fleet\n' > "$ref/catalogue.yaml"
  echo "le-master" > "$BATS_TEST_TMPDIR/master.out"

  LCARS_REFERENCE_CATALOGUE="$ref" LCARS_DEMO_CATALOGUE="$BATS_TEST_TMPDIR/rien" \
    run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]
  grep -q 'push .*le-master/fleet' "$GIT_LOG"
}

@test "apply: le nom du depot vient du MANIFESTE, jamais du repertoire" {
  setup_install
  ref="$BATS_TEST_TMPDIR/un-repertoire-mal-nomme"
  mkdir -p "$ref"
  printf 'api_version: 1\nname: le-vrai-nom\n' > "$ref/catalogue.yaml"
  echo "le-master" > "$BATS_TEST_TMPDIR/master.out"

  LCARS_REFERENCE_CATALOGUE="$ref" LCARS_DEMO_CATALOGUE="$BATS_TEST_TMPDIR/rien" \
    run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]
  grep -q 'push .*le-master/le-vrai-nom' "$GIT_LOG"
  [[ "$(cat "$GIT_LOG")" != *un-repertoire-mal-nomme* ]]
}

@test "apply: un catalogue de release SANS \`name:\` en colonne zero ne s'installe pas — echec NOMME apres la structure, rien n'est pousse" {
  # Le nom est l'org des projets : sans lui, l'installation n'a pas d'org a poser, et une forge sans
  # org de projets n'accueille rien. Ce n'est plus « non depose », c'est un echec.
  setup_install
  ref="$BATS_TEST_TMPDIR/reference"
  mkdir -p "$ref"
  printf 'api_version: 1\nroles:\n  name: dev\n' > "$ref/catalogue.yaml"
  echo "le-master" > "$BATS_TEST_TMPDIR/master.out"

  LCARS_REFERENCE_CATALOGUE="$ref" LCARS_DEMO_CATALOGUE="$BATS_TEST_TMPDIR/rien" \
    run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"la release ne nomme pas son catalogue — la structure est posee, mais AUCUNE org de projets ne l'est"* ]]
  grep -q "^apply $RECIPE\$" "$TOFU_LOG"
  [ ! -s "$GIT_LOG" ]
}

@test "runner-token: imprime le jeton et RIEN d'autre sur stdout" {
  # Un appelant capture cette sortie pour la donner a son compose : une ligne de politesse en plus
  # deviendrait un jeton d'enregistrement invalide, et le runner resterait « Waiting » pour toujours.
  printf 'TOK\n' > "$PRIV/forge-master.token"
  run bash -c "'$SCRIPT' runner-token < /dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "REG-TOKEN-42" ]
}

@test "runner-token: sans autorite, il refuse au lieu de rendre une chaine vide" {
  run bash -c "'$SCRIPT' runner-token < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"container config"* ]]
}

@test "un geste inconnu est refuse, et les gestes sont NOMMES" {
  run bash -c "'$SCRIPT' pas-un-geste < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config-token"* ]]
  [[ "$output" == *"apply"* ]]
}


@test "le verrou est le dossier de travail lui-même : un apply n'y crée que le dossier du catalogue de la release, comme un install" {
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(ls -A "$LCARS_CATALOGUES_WORK")" = fleet ]
  [ -f "$LCARS_CATALOGUES_WORK/fleet/roles.auto.tfvars.json" ]
}

# `apply` en root, `install` sous le compte d'autorité : un seul uid ne voit pas le passage. Le décor :
# root de namespace, un compte d'autorité doublé dont l'uid est un sous-uid (`--map-auto`), /etc/passwd
# et /etc/group doublés par un montage privé, /opt en tmpfs au chemin et au mode de la machine.
AUTORITE_UID=4242

_deux_identites() { # <scenario bash, joue en root de namespace dans le decor> -> run
  unshare --map-auto -r -m true 2>/dev/null \
    || skip "sous-uids indisponibles pour ce compte (unshare --map-auto) : le passage de root au compte d'autorité ne se joue pas ici"
  unset LCARS_CATALOGUES_WORK
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  { cat /etc/passwd; printf 'autorite-double:x:%s:%s::/nonexistent:/usr/sbin/nologin\n' "$AUTORITE_UID" "$AUTORITE_UID"; } > "$BATS_TEST_TMPDIR/passwd"
  { cat /etc/group; printf 'autorite-double:x:%s:\n' "$AUTORITE_UID"; } > "$BATS_TEST_TMPDIR/group"
  chmod 0644 "$BATS_TEST_TMPDIR/passwd" "$BATS_TEST_TMPDIR/group"
  cat > "$BATS_TEST_TMPDIR/scenario.sh" <<EOF
set -euo pipefail
mount --bind "$BATS_TEST_TMPDIR/passwd" /etc/passwd
mount --bind "$BATS_TEST_TMPDIR/group" /etc/group
mount -t tmpfs tmpfs /opt
mkdir -p /opt/lcars/var
install -d -m 0700 -o autorite-double -g autorite-double /opt/lcars/var/tofu
# le compte d'autorite ne traverse pas l'arbre du depot : il joue la copie posee, comme sur la machine
install -m 0755 "$SCRIPT" /opt/lcars/forge-gestures.sh
# ⚖ decision 3 : une machine porte ses FAITS et leur lecteur sous la racine du produit. Ce decor
# EST une machine (tmpfs sur /opt) : il les pose la ou 62-runtime-helpers les pose, et la
# surcharge de l'arbre est retiree — c'est la resolution reelle qui doit jouer ici.
unset LCARS_FACTS_SH
install -d -m 0755 /opt/lcars/services/lib /opt/lcars/etc
install -m 0644 "$(dirname "$SCRIPT")/lib/facts.sh" /opt/lcars/services/lib/facts.sh
install -m 0644 "$(dirname "$SCRIPT")/../etc/facts.env" /opt/lcars/etc/facts.env
export LCARS_AUTHORITY_USER=autorite-double
SCRIPT="$SCRIPT"
sous_autorite() { # sous_autorite <scenario> — joue le verrou comme install le prend, sous le compte d'autorite
  setpriv --reuid "$AUTORITE_UID" --regid "$AUTORITE_UID" --clear-groups bash -c "\$1"
}
$1
EOF
  run unshare --map-auto -r -m bash "$BATS_TEST_TMPDIR/scenario.sh"
}

@test "un apply joué en root ne laisse rien à root sous le dossier de travail : l'installation, sous le compte d'autorité, tient le verrou" {
  _deux_identites '
bash "$SCRIPT" apply </dev/null >/dev/null
printf "a-root:[%s]\n" "$(find /opt/lcars/var/tofu -mindepth 1 -uid 0 | tr "\n" " ")"
printf "catalogue-de-la-release:[%s]\n" "$(stat -c "%U:%G" /opt/lcars/var/tofu/fleet /opt/lcars/var/tofu/fleet/roles.auto.tfvars.json | sort -u | tr "\n" " ")"
sous_autorite "source /opt/lcars/forge-gestures.sh; with_apply_lock echo verrou-tenu"'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"a-root:[]"* ]] || { echo "$output"; return 1; }
  # l'apply en root a installe le catalogue de la release, et l'a RENDU au compte d'autorite
  [[ "$output" == *"catalogue-de-la-release:[autorite-double:autorite-double ]"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"verrou-tenu"* ]]
}

@test "le compte d'autorité tient le verrou : un apply en root est refusé sans rien tenter, et l'inverse" {
  _deux_identites '
sous_autorite "exec 9</opt/lcars/var/tofu; flock 9; sleep 3" &
tenu=$!
sleep 0.5
bash "$SCRIPT" apply </dev/null || echo "apply-root rc=$?"
wait "$tenu"
( exec 9</opt/lcars/var/tofu; flock 9; sleep 3 ) &
tenu=$!
sleep 0.5
sous_autorite "source /opt/lcars/forge-gestures.sh; with_apply_lock echo verrou-tenu" || echo "autorite rc=$?"
wait "$tenu"'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"apply-root rc=1"*"autorite rc=1"* ]]
  [ "$(grep -c "un autre apply de structure est en cours" <<<"$output")" -eq 2 ]
  refute grep -q verrou-tenu <<<"$output"
  refute grep -q "^init " "$TOFU_LOG"
}

@test "sous le compte d'autorité, un dossier de travail qui ne lui revient pas se dit, et nomme qui pose ce dossier" {
  _deux_identites '
chown root:root /opt/lcars/var/tofu
chmod 0700 /opt/lcars/var/tofu
sous_autorite "source /opt/lcars/forge-gestures.sh; with_apply_lock echo verrou-tenu" || echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"dossier de travail des applies inaccessible (/opt/lcars/var/tofu) — ce geste se joue en root ou sous autorite-double"*"deploy/workstation up"* ]]
  refute grep -q verrou-tenu <<<"$output"
}


_flat_copy() { # <racine> -> pose une copie du script a plat, et rend son chemin
  mkdir -p "$1"
  cp "$SCRIPT" "$1/forge-gestures.sh"
  chmod +x "$1/forge-gestures.sh"
  printf '%s/forge-gestures.sh' "$1"
}

_fake_entry() { # <chemin> <marqueur> [mode]
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
#!/usr/bin/env bash
[[ "\$1" == tool ]] && shift
printf '%s %s\n' "$2" "\$*" >> "$ENTRY_LOG"
case "\$1" in
  catalogue-source) echo "alice/cat main deadbeef" ;;
  roles-tfvars)     echo '{"org":"cat","roles":["cat_dev"]}' ;;
esac
exit 0
EOF
  chmod "${3:-0755}" "$1"
}


@test "cli: la SURCHARGE LCARS_CLI gagne sur tout" {
  setup_install
  _fake_entry "$BATS_TEST_TMPDIR/surcharge/lcars" SURCHARGE
  _fake_entry "$BIN/lcars" PATH
  run env LCARS_CLI="$BATS_TEST_TMPDIR/surcharge/lcars" PATH="$BIN:/usr/bin:/bin" \
      bash -c "'$SCRIPT' install cat < /dev/null"
  grep -q "^SURCHARGE catalogue-source cat" "$ENTRY_LOG"
  refute grep -q "^PATH" "$ENTRY_LOG"
}

@test "cli: la CLI du PATH gagne sur le voisin de l'arbre — la disposition des deux rails" {
  setup_install
  local flat; flat="$(_flat_copy "$BATS_TEST_TMPDIR/arbre/services")"
  _fake_entry "$BATS_TEST_TMPDIR/arbre/bin/lcars" VOISIN
  _fake_entry "$BIN/lcars" PATH
  run env -u LCARS_CLI PATH="$BIN:/usr/bin:/bin" bash -c "'$flat' install cat < /dev/null"
  grep -q "^PATH catalogue-source cat" "$ENTRY_LOG"
  refute grep -q "^VOISIN" "$ENTRY_LOG"
}

@test "cli: SANS CLI sur le PATH ni dans le repertoire des liens, le voisin ../bin/lcars de l'arbre repond — le cas d'un checkout" {
  setup_install
  local flat; flat="$(_flat_copy "$BATS_TEST_TMPDIR/arbre2/services")"
  _fake_entry "$BATS_TEST_TMPDIR/arbre2/bin/lcars" VOISIN
  rm -f "$BIN/lcars"
  run env -u LCARS_CLI LCARS_LINK_DIR="$BATS_TEST_TMPDIR/liens-vides" PATH="$BIN:/usr/bin:/bin" \
      bash -c "'$flat' install cat < /dev/null"
  grep -q "^VOISIN catalogue-source cat" "$ENTRY_LOG"
}

@test "cli: la copie a plat, sans CLI sur le PATH, trouve la CLI posee dans le repertoire des liens (A-202)" {
  # La disposition des deux rails : `/opt/lcars/forge-gestures.sh`, dont le `../bin/lcars` est
  # `/opt/bin/lcars`, qui n'existe pas ; la CLI est posee dans `/usr/local/bin`.
  setup_install
  local flat; flat="$(_flat_copy "$BATS_TEST_TMPDIR/opt/lcars")"
  _fake_entry "$BATS_TEST_TMPDIR/usr/local/bin/lcars" POSEE
  rm -f "$BIN/lcars"
  [ ! -e "$BATS_TEST_TMPDIR/opt/bin/lcars" ]
  run env -u LCARS_CLI LCARS_LINK_DIR="$BATS_TEST_TMPDIR/usr/local/bin" PATH="$BIN:/usr/bin:/bin" \
      bash -c "'$flat' install cat < /dev/null"
  [ "$status" -eq 0 ]
  grep -q "^POSEE catalogue-source cat" "$ENTRY_LOG"
}

@test "cli: AUCUN candidat -> refus A LA PORTE qui nomme ce qui a ete cherche, jamais un chemin qui n'existe pas" {
  setup_install
  local flat; flat="$(_flat_copy "$BATS_TEST_TMPDIR/opt/lcars")"
  rm -f "$BIN/lcars"
  run env -u LCARS_CLI LCARS_LINK_DIR="$BATS_TEST_TMPDIR/liens-vides" PATH="$BIN:/usr/bin:/bin" \
      bash -c "'$flat' install cat < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"portes outil du release introuvables (ni « lcars » sur le PATH, ni $BATS_TEST_TMPDIR/liens-vides/lcars, ni $BATS_TEST_TMPDIR/opt/lcars/../bin/lcars)"* ]]
  [[ "$output" == *"deploy/workstation up"* ]]
  [[ "$output" != *"pas de source installable"* ]]
  [ ! -s "$ENTRY_LOG" ]
}

@test "cli: une SURCHARGE qui pointe dans le vide est refusee comme une absence" {
  setup_install
  run env LCARS_CLI="$BATS_TEST_TMPDIR/nulle-part.sh" \
      bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"portes outil du release introuvables"* ]]
  [[ "$output" == *"nulle-part.sh"* ]]
  [[ "$output" != *"pas de source installable"* ]]
}

@test "install: une porte MUETTE qui rend 0 est refusee — jamais un clone sur du vide" {
  setup_install
  cat > "$BIN/entrypoint" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  chmod +x "$BIN/entrypoint"

  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 sans reponse exploitable"* ]]
  [[ "$output" == *"RIEN"* ]]
  # Le geste ne doit RIEN avoir tente : pas de clone sur une URL construite a partir de vide.
  [ "$(grep -c clone "$GIT_LOG" 2>/dev/null || echo 0)" -eq 0 ]
}

@test "install: une reponse TRONQUEE est refusee aussi — la forme, pas seulement la presence" {
  # `<depot>` seul, sans branche ni sha : le clone partirait sur une reference vide et echouerait
  # plus loin, pour une raison apparente qui n'est pas la sienne.
  setup_install
  cat > "$BIN/entrypoint" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == tool ]] && shift
[[ "$1" == catalogue-source ]] && echo "alice/cat"
exit 0
FAKE
  chmod +x "$BIN/entrypoint"

  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 sans reponse exploitable"* ]]
  [[ "$output" == *"alice/cat"* ]]
  [ "$(grep -c clone "$GIT_LOG" 2>/dev/null || echo 0)" -eq 0 ]
}

# B1 — la sortie de `lcars tool catalogue-source web-demo` relevée sur banc (v0.9-beta2) et rejouée
# sur le release : le journal Elixir sur stderr, une ligne vide puis une ligne `[info]`, et la
# réponse seule sur stdout. Lus ensemble, la première ligne est vide et la réponse juste est refusée.
_porte_bavarde() { # <stdout de la porte>
  cat > "$BIN/entrypoint" <<FAKE
#!/usr/bin/env bash
[[ "\$1" == tool ]] && shift
printf '%s\n' "\$*" >> "$ENTRY_LOG"
case "\$1" in
  catalogue-source)
    printf '\n20:26:15.108 [info] CatalogueDeposits: admiral/fleet declares '"'"'fleet'"'"', the catalogue carried by the release. It is installed by construction\n' >&2
    printf '%b' '$1'
    ;;
  roles-tfvars) echo '{"org":"cat","roles":["cat_dev"]}' ;;
esac
exit 0
FAKE
  chmod +x "$BIN/entrypoint"
}

@test "install: le journal du release sur stderr ne prend pas la place de la réponse lue sur stdout (B1)" {
  setup_install
  _porte_bavarde 'alice/cat main deadbeef\n'
  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cat <- alice/cat (main@deadbeef)"* ]]
  grep -q "clone .*--branch main http://forge.test/alice/cat.git" "$GIT_LOG"
  # une réponse exploitable ne montre pas le journal à l'opérateur
  refute grep -q 'CatalogueDeposits' <<<"$output"
}

@test "install: une porte qui rend 0 sans réponse montre son journal avec le refus (B1)" {
  setup_install
  _porte_bavarde ''
  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 sans reponse exploitable"* ]]
  [[ "$output" == *"Recu : RIEN"* ]]
  [[ "$output" == *"[info] CatalogueDeposits"* ]]
  [ "$(grep -c clone "$GIT_LOG" 2>/dev/null || echo 0)" -eq 0 ]
}


setup_material() {
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/catalogues"
  mkdir -p "$LCARS_CATALOGUES_DIR/deja-la"
  echo "NE ME PERDS PAS" > "$LCARS_CATALOGUES_DIR/deja-la/marqueur"
  cat > "$BIN/git" <<'FAKE'
#!/usr/bin/env bash
# `clone … <dest>` : la destination est le DERNIER argument.
[[ "$1" == clone ]] && { mkdir -p "${!#}"; echo clone > "${!#}/.cloned"; }
exit 0
FAKE
  chmod +x "$BIN/git"
  export PATH="$BIN:$PATH"
}

@test "install_material: un « name » VIDE dans la portee appelante n'emporte pas les voisins" {
  # LE TEMOIN QUI COMPTE. `set -u` ne protege pas d'une variable posee-mais-vide, et c'est
  # exactement la forme qu'un `local name` declare puis assigne conditionnellement produit.
  setup_material
  run bash -c "source '$SCRIPT'; name=''; install_material demo /inutile"
  [ -f "$LCARS_CATALOGUES_DIR/deja-la/marqueur" ]
  [ "$status" -eq 0 ]
  [ -f "$LCARS_CATALOGUES_DIR/demo/.cloned" ]
}

@test "install_material: sans « name » dans la portee appelante, la cible reste l'argument" {
  setup_material
  run bash -c "source '$SCRIPT'; install_material demo /inutile"
  [ "$status" -eq 0 ]
  [ -f "$LCARS_CATALOGUES_DIR/deja-la/marqueur" ]
  [ -f "$LCARS_CATALOGUES_DIR/demo/.cloned" ]
}

@test "install_material: c'est l'ARGUMENT qui nomme le repertoire, pas un « name » d'ailleurs" {
  # Meme propriete par l'autre bout : une variable homonyme HOSTILE ne deplace pas la cible.
  setup_material
  run bash -c "source '$SCRIPT'; name=AUTRE; install_material demo /inutile"
  [ "$status" -eq 0 ]
  [ -f "$LCARS_CATALOGUES_DIR/demo/.cloned" ]
  [ ! -e "$LCARS_CATALOGUES_DIR/AUTRE" ]
  [ -f "$LCARS_CATALOGUES_DIR/deja-la/marqueur" ]
}
