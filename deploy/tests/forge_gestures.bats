#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/forge_gestures.bats
# AUTHOR: drdree
# STARDATE: 2026-08-16
# STATUS: bats tests for services/forge-gestures.sh — LA porte des gestes forge du conteneur

# shellcheck disable=SC2030,SC2031

# bats test_tags=structure
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
body="\$(cat)"
case "\$*" in
  *'.id == 1'*) cat "$BATS_TEST_TMPDIR/master.out" 2>/dev/null || true ;;
  *) [[ "\$body" =~ \"token\":\"([^\"]*)\" ]] && printf '%s\n' "\${BASH_REMATCH[1]}" ;;
esac
FAKE
  chmod +x "$BIN/jq"

  export ARGV_LOG STDIN_LOG TOFU_LOG
  export PATH="$BIN:$PATH"
  export LCARS_PRIVATE_DIR="$PRIV"
  export LCARS_RECIPE_DIR="$RECIPE"
  export FORGE_BASE_URL="http://forge.test"
  # Le verrou d'apply vit dans le tmpdir du test : `/run/lock` n'est pas ecrivable par le temoin,
  # et un verrou PARTAGE entre les cas ferait echouer le second sur le premier.
  export LCARS_APPLY_LOCK="$BATS_TEST_TMPDIR/apply.lock"
  export LCARS_CATALOGUES_WORK="$BATS_TEST_TMPDIR/tofu"
  # Le CACHE local du materiel. Pointe dans le tmpdir : sans ca le temoin ecrirait dans
  # `/home/catalogues`, c'est-a-dire dans le conteneur de celui qui lance la suite.
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/catalogues"

  # La porte outil du release, doublee : elle journalise SON verbe et rend ce que le cas veut.
  ENTRY_LOG="$BATS_TEST_TMPDIR/entry.log"
  cat > "$BIN/entrypoint" <<FAKE
#!/usr/bin/env bash
[[ "\$1" == tool ]] && shift   # la porte est « lcars tool <verbe> » (lot 6)
printf '%s\n' "\$*" >> "$ENTRY_LOG"
case "\$1" in
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
  ( flock 9 && sleep 5 ) 9>"$LCARS_APPLY_LOCK" &
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
  [ ! -s "$ENTRY_LOG" ]
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
  [ "$(sed -n '1p' "$ENTRY_LOG" | cut -d' ' -f1)" = "catalogue-source" ]
  [ "$(sed -n '2p' "$ENTRY_LOG" | cut -d' ' -f1)" = "verify" ]
  [ "$(sed -n '3p' "$ENTRY_LOG" | cut -d' ' -f1)" = "roles-tfvars" ]
  grep -q "$LCARS_CATALOGUES_WORK/cat" "$TOFU_LOG"
  grep -q 'push .*cat/_catalogue' "$GIT_LOG"
}

@test "install: le MATERIEL local est pose dans le meme geste, clone depuis le store" {
  setup_install
  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -eq 0 ]
  [ -f "$LCARS_CATALOGUES_DIR/cat/catalogue.yaml" ]
  grep -q "clone .*http://forge.test/cat/_catalogue.git" "$GIT_LOG"
  [[ "$output" == *"materiel pose"* ]]
}


@test "install: materiel local en echec — le dire, ne pas defaire ce qui est bon" {
  # L'org et la source sont posees avant lui. Defaire ce qui est bon parce que le cache a rate
  # serait perdre le travail utile pour une moitie rattrapable au prochain boot.
  setup_install
  # Un cache impossible a ecrire : le parent est un FICHIER.
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/pas-un-dossier/sub"
  : > "$BATS_TEST_TMPDIR/pas-un-dossier"

  run bash -c "'$SCRIPT' install cat < /dev/null"
  [[ "$output" == *"INSTALLE sur la forge"* ]]
  [[ "$output" == *"prochain démarrage du conteneur"* ]]
  [[ "$output" == *"deploy/workstation up"* ]]
  grep -q 'push .*cat/_catalogue' "$GIT_LOG"
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
  # Aucun push : `git` n'a meme pas ete appele, donc son journal n'existe pas. Tester le CONTENU
  # d'un fichier absent ferait echouer le temoin sur sa propre mise en scene et pas sur le sujet.
  [ ! -s "$GIT_LOG" ]
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

@test "apply: un arbre SANS \`name:\` en colonne zero n'est pas depose, et le refus le DIT" {
  setup_install
  ref="$BATS_TEST_TMPDIR/reference"
  mkdir -p "$ref"
  printf 'api_version: 1\nroles:\n  name: dev\n' > "$ref/catalogue.yaml"
  echo "le-master" > "$BATS_TEST_TMPDIR/master.out"

  LCARS_REFERENCE_CATALOGUE="$ref" LCARS_DEMO_CATALOGUE="$BATS_TEST_TMPDIR/rien" \
    run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ne declare pas de"* ]]
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


@test "le verrou vit dans le repertoire de travail, pas dans /run/lock" {
  unset LCARS_APPLY_LOCK
  export LCARS_CATALOGUES_WORK="$BATS_TEST_TMPDIR/tofu-work"
  mkdir -p "$LCARS_CATALOGUES_WORK"
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"

  run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]

  LOCK="$LCARS_CATALOGUES_WORK/.apply.lock"
  [ -e "$LOCK" ]
  run bash -c "sed 's/#.*//' '$SCRIPT' | grep -c '/run/lock' || true"
  [ "$output" -eq 0 ]
}

@test "un verrou DEJA pose garde son mode — un durcissement d'operateur n'est pas contredit" {
  unset LCARS_APPLY_LOCK
  export LCARS_CATALOGUES_WORK="$BATS_TEST_TMPDIR/tofu-work2"
  mkdir -p "$LCARS_CATALOGUES_WORK"
  : > "$LCARS_CATALOGUES_WORK/.apply.lock"
  # un mode que le geste ne pose jamais lui-meme : le garder se distingue de le reposer
  chmod 0640 "$LCARS_CATALOGUES_WORK/.apply.lock"
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"

  run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$LCARS_CATALOGUES_WORK/.apply.lock")" = "640" ]
}

# Le verrou passe d'une identite a l'autre : `apply` en root, `install` sous le compte d'autorite.
# Un seul uid ne le voit pas. Le decor : root de namespace, un compte d'autorite double dont l'uid
# est un sous-uid (`--map-auto`, donc un vrai proprietaire distinct sur le disque), /etc/passwd et
# /etc/group doubles par un montage prive, et /opt en tmpfs pour que ce compte traverse jusqu'au
# verrou par le chemin et le mode de la machine.
AUTORITE_UID=4242

_deux_identites() { # <scenario bash, joue en root de namespace dans le decor> -> run
  unshare --map-auto -r -m true 2>/dev/null \
    || skip "sous-uids indisponibles pour ce compte (unshare --map-auto) : le passage de root au compte d'autorité ne se joue pas ici"
  unset LCARS_APPLY_LOCK LCARS_CATALOGUES_WORK
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
export LCARS_AUTHORITY_USER=autorite-double
SCRIPT="$SCRIPT"
LOCK=/opt/lcars/var/tofu/.apply.lock
# le verrou ouvert comme install l'ouvre : la meme fonction, sous le compte d'autorite
ouvre_sous_autorite() {
  setpriv --reuid "$AUTORITE_UID" --regid "$AUTORITE_UID" --clear-groups \
    bash -c 'source /opt/lcars/forge-gestures.sh; with_apply_lock echo verrou-tenu'
}
$1
EOF
  run unshare --map-auto -r -m bash "$BATS_TEST_TMPDIR/scenario.sh"
}

@test "un apply joué en root rend le verrou au compte d'autorité en 0600 : l'installation, sous ce compte, l'ouvre" {
  _deux_identites '
bash "$SCRIPT" apply </dev/null >/dev/null
stat -c "verrou %u %a" "$LOCK"
printf "a-root:[%s]\n" "$(find /opt/lcars/var/tofu -uid 0 | tr "\n" " ")"
ouvre_sous_autorite'
  [ "$status" -eq 0 ]
  [[ "$output" == *"verrou $AUTORITE_UID 600"* ]]
  # rien d'autre que le geste pose sous le dossier de travail ne reste a root
  [[ "$output" == *"a-root:[]"* ]]
  [[ "$output" == *"verrou-tenu"* ]]
}

@test "un verrou laissé à root est rendu au compte d'autorité par l'apply suivant, son mode gardé" {
  _deux_identites '
( umask 022; : > "$LOCK" )
bash "$SCRIPT" apply </dev/null >/dev/null
stat -c "verrou %u %a" "$LOCK"
ouvre_sous_autorite'
  [ "$status" -eq 0 ]
  [[ "$output" == *"verrou $AUTORITE_UID 644"* ]]
  [[ "$output" == *"verrou-tenu"* ]]
}

@test "sous le compte d'autorité, un verrou fermé se dit par son propriétaire et son mode, pas par root" {
  _deux_identites '
( umask 022; : > "$LOCK" )
ouvre_sous_autorite || echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"ce geste tourne sous autorite-double, et le verrou appartient à root en mode 644"* ]]
  [[ "$output" == *"deploy/workstation up"* ]]
  refute grep -q "tourne en root" <<<"$output"
  refute grep -q "verrou-tenu" <<<"$output"
}

@test "sous le compte d'autorité, un dossier de travail fermé se dit par son propriétaire et son mode" {
  _deux_identites '
chown root:root /opt/lcars/var/tofu
chmod 0755 /opt/lcars/var/tofu
ouvre_sous_autorite || echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"ce geste tourne sous autorite-double, et ne peut pas créer le verrou dans /opt/lcars/var/tofu (root, mode 755)"* ]]
  refute grep -q "tourne en root" <<<"$output"
}

@test "un apply joué en root sans compte d'autorité sur la machine pose le verrou en 0600 et passe" {
  unshare -Ur true 2>/dev/null || skip "user namespaces indisponibles : le chemin root ne se joue pas ici"
  unset LCARS_APPLY_LOCK
  export LCARS_CATALOGUES_WORK="$BATS_TEST_TMPDIR/tofu-root"
  mkdir -p "$LCARS_CATALOGUES_WORK"
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"

  run unshare -Ur env LCARS_AUTHORITY_USER=compte-absent-du-decor bash "$SCRIPT" apply < /dev/null
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$LCARS_CATALOGUES_WORK/.apply.lock")" = "600" ]
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

@test "cli: SANS CLI sur le PATH, le voisin ../bin/lcars de l'arbre repond — le cas d'un checkout" {
  setup_install
  local flat; flat="$(_flat_copy "$BATS_TEST_TMPDIR/arbre2/services")"
  _fake_entry "$BATS_TEST_TMPDIR/arbre2/bin/lcars" VOISIN
  rm -f "$BIN/lcars"
  run env -u LCARS_CLI PATH="$BIN:/usr/bin:/bin" bash -c "'$flat' install cat < /dev/null"
  grep -q "^VOISIN catalogue-source cat" "$ENTRY_LOG"
}

@test "cli: AUCUN candidat -> refus A LA PORTE qui nomme la CLI, pas « pas de source »" {
  setup_install
  local flat; flat="$(_flat_copy "$BATS_TEST_TMPDIR/arbre3/services")"
  rm -f "$BIN/lcars"
  run env -u LCARS_CLI PATH="$BIN:/usr/bin:/bin" bash -c "'$flat' install cat < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"portes outil du release introuvables"* ]]
  [[ "$output" == *"lcars"* ]]
  [[ "$output" != *"pas de source installable"* ]]
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
