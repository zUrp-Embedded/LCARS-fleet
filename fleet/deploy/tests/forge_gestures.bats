#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/forge_gestures.bats
# AUTHOR: drdree
# STARDATE: 2026-08-16
# STATUS: bats tests for services/forge-gestures.sh — LA porte des gestes forge de la boite
#
# CE SCRIPT PORTE LE JETON SITE-ADMIN, celui qui peut tout creer et tout detruire sur la forge, et
# il est joue par DEUX appelants (`box` et le banc). Une regression ici ne se voit ni dans
# l'un ni dans l'autre : elle se voit sur la forge de quelqu'un.
#
# Dispositif identique a `forge_charte.bats` et `forge_existing.bats` : un faux `curl` en tete de
# PATH qui journalise `"$@"` ET son stdin. Chaque assertion d'attaque va par paire avec un temoin.

# ─── LE GESTE VIT DES DEUX COTES, ET LA PORTE DOIT LE SAVOIR ────────────────────────────────────
#
# `deploy/box` entrait dans le conteneur `lcars` pour jouer `forge-gestures.sh`. Sur un poste ce
# conteneur n'existe pas — la fleet y tourne nativement et seule la forge est conteneurisee — donc
# tout verbe qui passe par la mourait sur l'absence d'un objet sans rapport avec la demande. Le meme
# script est pose sur l'hote par `62-runtime-helpers` : la porte doit chercher les DEUX.
# ⚠ SC2030/SC2031 : CHAQUE `@test` DE BATS EST UN SOUS-SHELL, et c'est la propriete qu'on veut —
# un test ne teinte pas le suivant. Que les variables posees dans un test soient « locales » est
# l'isolation, pas une fuite.
# shellcheck disable=SC2030,SC2031

@test "TEMOIN STRUCTUREL : la porte cherche le geste sur l'hote quand la boite n'est pas la" {
  local box="$BATS_TEST_DIRNAME/../box"
  [ -f "$box" ]
  local body; body="$(grep -vE '^\s*#' "$box" | sed -n '/^gesture()/,/^}/p')"
  [ -n "$body" ]
  # Les deux chemins, et la condition qui les separe.
  grep -q 'compose ps -q lcars' <<<"$body"
  grep -q '/opt/lcars/forge-gestures.sh' <<<"$body"
  # ⚠ ET AUCUN `sudo` : la promesse auditee de ce rail est de n'en jamais demander. Un operateur
  # sans droit sur le fichier doit se faire REFUSER par eux, pas les contourner.
  refute grep -q 'sudo' <<<"$body"
}

load refute

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../services/forge-gestures.sh"
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
printf '%s\n' "$PWD" >> "$TOFU_LOG"
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
  export LCARS_CATALOGUE_WORK="$BATS_TEST_TMPDIR/tofu"
  # Le CACHE local du materiel. Pointe dans le tmpdir : sans ca le temoin ecrirait dans
  # `/home/catalogues`, c'est-a-dire dans la boite de celui qui lance la suite.
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/catalogues"

  # La porte outil du release, doublee : elle journalise SON verbe et rend ce que le cas veut.
  ENTRY_LOG="$BATS_TEST_TMPDIR/entry.log"
  cat > "$BIN/entrypoint" <<FAKE
#!/usr/bin/env bash
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
  export LCARS_ENTRYPOINT="$BIN/entrypoint"
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
  # La config de curl est un format CITE : une valeur non echappee couperait le jeton en deux et
  # l'auth partirait tronquee — un echec qui ressemble a un jeton revoque.
  # Le jeton passe par un FICHIER, pas par une chaine imbriquee : trois niveaux de quoting
  # (bats -> bash -c -> printf) transformaient `a"b\c` en `a"b\\c`, et le test mesurait alors
  # une autre valeur que celle qu'il nomme.
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
  # LE MENSONGE QUE CE TEMOIN INTERDIT : une boite qui croit tenir son autorite et le decouvre au
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
  # LE TITRE DISAIT TROIS ET LE TEMOIN EN VERIFIAIT DEUX (audit 2026-08-16) : le `setup` injecte
  # `FORGE_BASE_URL`, donc le troisieme manque n'etait jamais atteint. Un temoin qui promet plus
  # qu'il ne mesure est pire qu'un temoin absent — on le croit.
  run env -u FORGE_BASE_URL bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"l'URL de la forge"* ]]
  [[ "$output" == *"l'autorite"* ]]
  [[ "$output" == *"le seed des comptes"* ]]
}

@test "apply: avec l'URL mais rien d'autre, il ne nomme QUE ce qui manque" {
  # Le contre-temoin : sans lui, une implementation qui recite les trois manques en toutes
  # circonstances passerait le test ci-dessus.
  run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" != *"l'URL de la forge"* ]]
  [[ "$output" == *"l'autorite"* ]]
}

@test "apply: l'ORDRE des deux modules est instance PUIS catalogue" {
  # Ce n'est pas une preference : une adhesion peut nommer un compte qu'elle ne cree pas, jamais un
  # compte qui n'existe pas. L'inversion echoue en 404 cote Gitea, tard et sur un autre sujet.
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$TOFU_LOG")" = "$RECIPE/instance" ]
  [ "$(sed -n '2p' "$TOFU_LOG")" = "$RECIPE" ]
}



@test "apply: un tofu en echec, LUI, est fatal et nomme le module" {
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  FAKE_TOFU_RC=1 run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"instance"* ]]
}

@test "apply: un jeton sur stdin l'emporte sur celui que la boite garde" {
  printf 'TOK-BOITE\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  run bash -c "printf '%s' 'TOK-APPELANT' | '$SCRIPT' apply"
  [ "$status" -eq 0 ]
  # Le fichier de la boite n'est PAS reecrit : `apply` consomme, il ne pose pas.
  [ "$(cat "$PRIV/forge-master.token")" = "TOK-BOITE" ]
}

@test "apply: DEUX applys concurrents — le second REFUSE, il n'attend pas" {
  # Deux applys sur le meme `terraform.tfstate` : le second rendrait un verdict sur un travail
  # qu'il n'a pas fait. Attendre serait pire que refuser — il repartirait sur une forge qui a
  # bouge sous lui pendant qu'il patientait.
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

# ─── install ────────────────────────────────────────────────────────────────────────────────────

setup_install() {
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  printf 'SYS\n' > "$PRIV/system_starfleet.gitea_token"
}

@test "install: la LECTURE de la source va sous le jeton SYSTEME, jamais le master" {
  # ⚠ MESURE SUR BANC, 2026-08-16 : l'install mourait sur
  # `UNREACHABLE {:config, {:token_file, …, :eacces}}`. La porte `catalogue-source` tourne en
  # `nobody:fleet` parce que c'est une lecture ; le jeton master est `0600 root`, donc illisible
  # pour elle. Le refus de permission ressortait en « pas de source installable » — le mauvais
  # diagnostic pour le mauvais probleme, sur le geste central du chantier.
  #
  # ⚠ CE TEMOIN MESURAIT LE MECANISME, ET LE MECANISME A CHANGE SOUS LUI. Il epinglait un CHEMIN
  # (`TOKFILE=<…>/system_starfleet.gitea_token`). Depuis que `/home/private` est
  # `0700 lcars-authority`, la porte `nobody` ne peut plus ouvrir AUCUN fichier d'ici — pas plus le
  # jeton systeme que le master. Ce qui traverse est donc la VALEUR, lue par le service qui la
  # possede et transmise par l'environnement (`/proc/<pid>/environ` n'est lisible que du
  # proprietaire du process ; un argv l'est de tout le monde).
  #
  # L'EXIGENCE, ELLE, N'A PAS BOUGE D'UN MOT : la lecture se fait sous l'identite SYSTEME, jamais
  # sous l'autorite totale de la boite. C'est elle qui est epinglee ici, la ou elle se lit
  # maintenant.
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

# ⚠ LE TEMOIN DU VIDE, ET IL GARDE UN DIAGNOSTIC. Un jeton systeme present mais VIDE donnerait
# `FORGE_TOKEN=`, que la resolution traite comme « pas de source » : la forge repond 401 et le refus
# accuse le catalogue. Le geste doit mourir ICI, en nommant le fichier. C'est la contrepartie de la
# lecture par valeur : un chemin illisible se diagnostique tout seul, une chaine vide non.
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
  [[ "$output" == *"provision apply"* ]]
  [ ! -s "$ENTRY_LOG" ]
}

@test "install: sans autorite, il REFUSE avant de toucher quoi que ce soit" {
  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"box config"* ]]
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
  grep -q "$LCARS_CATALOGUE_WORK/cat" "$TOFU_LOG"
  grep -q 'push .*cat/_catalogue' "$GIT_LOG"
}

@test "install: le MATERIEL local est pose dans le meme geste, clone depuis le store" {
  # Sans ca, la commande rend la main sur une boite qui n'a pas encore le catalogue qu'elle vient
  # d'installer, et rien ne dit a l'admin qu'il doit redemarrer. Le clone vient du STORE et non de
  # l'arbre en main : le convergeur compare des shas, et une copie sans `.git` n'en a pas.
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
  [[ "$output" == *"redemarrage"* ]]
  grep -q 'push .*cat/_catalogue' "$GIT_LOG"
}

@test "install: L'ETAT DE TOFU N'EST JAMAIS COPIE — installer un catalogue ne desinstalle pas l'autre" {
  # ⚠ MESURE SUR BANC, 2026-08-16. `apply` joue la recette DANS `$RECIPE_DIR` et y laisse le
  # `terraform.tfstate` du catalogue de reference ; le `cp -r` de l'install l'emportait — 26 Ko
  # d'etat de `fleet` recopies a l'identique dans la recette de `web-demo`.
  #
  # LE DANGER N'EST PAS L'ERREUR QU'ON A VUE (`user not found with id 12`), C'EST CELLE QU'ON N'A
  # PAS VUE : un etat portant les comptes de `fleet`, applique avec les variables de `web-demo`,
  # decrit ces comptes comme « plus dans la configuration ». Le plan suivant les DETRUIT.
  setup_install
  printf '{"version":4,"resources":[{"name":"role"}]}\n' > "$RECIPE/terraform.tfstate"
  printf 'backup\n' > "$RECIPE/terraform.tfstate.backup"
  mkdir -p "$RECIPE/.terraform" "$RECIPE/instance/.terraform"
  printf 'etat instance\n' > "$RECIPE/instance/terraform.tfstate"

  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -eq 0 ]
  [ ! -e "$LCARS_CATALOGUE_WORK/cat/terraform.tfstate" ]
  [ ! -e "$LCARS_CATALOGUE_WORK/cat/terraform.tfstate.backup" ]
  [ ! -e "$LCARS_CATALOGUE_WORK/cat/.terraform" ]
  [ ! -e "$LCARS_CATALOGUE_WORK/cat/instance/terraform.tfstate" ]
  # TEMOIN DE NON-VACUITE : la recette ELLE-MEME est bien arrivee.
  [ -f "$LCARS_CATALOGUE_WORK/cat/roles.auto.tfvars.json" ]
}

@test "install: l'etat DE CE CATALOGUE-CI survit au rejeu — sinon tout se re-importe a chaque fois" {
  # La symetrique du temoin ci-dessus, et sans elle le remede tuait ce qu'il protegeait : `cp -r`
  # ecrase l'etat de `web-demo` avec celui de `fleet`, et le nettoyage effacait alors les deux. Le
  # rejeu repartait de zero — ca converge, l'etat est jetable par construction, mais ca ne tient pas
  # la promesse affichee par la CLI : « rien n'a bouge -> il ne touche rien ».
  setup_install
  printf '{"version":4,"resources":[{"name":"role"}]}\n' > "$RECIPE/terraform.tfstate"
  mkdir -p "$LCARS_CATALOGUE_WORK/cat"
  printf 'ETAT-DE-CAT\n' > "$LCARS_CATALOGUE_WORK/cat/terraform.tfstate"

  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -eq 0 ]
  run cat "$LCARS_CATALOGUE_WORK/cat/terraform.tfstate"
  [ "$output" = "ETAT-DE-CAT" ]
}

@test "install: UN DOSSIER DE RECETTE PAR CATALOGUE — le roster n'ecrase pas celui d'un autre" {
  # La recette lit `roles.auto.tfvars.json` dans SON dossier, et ce fichier porte l'org ET le
  # roster : deux catalogues dans un meme dossier, c'est le dernier installe qui decide de ce que
  # le suivant applique.
  setup_install
  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -eq 0 ]
  [ -f "$LCARS_CATALOGUE_WORK/cat/roles.auto.tfvars.json" ]
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
  # ⚖ user, 2026-08-21 : « il faut republier le catalogue de base fleet ». Il vit dans le release et
  # tourne sans la forge ; ce qu'il gagne a y etre est la LISIBILITE — on ne forke pas ce qu'on ne
  # peut pas ouvrir. Il reste NON installable pour autant : `CatalogueDeposits` ecarte toute
  # candidature portant le nom du catalogue livre.
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
  # Un arbre range sous un nom et qui en declare un autre serait pousse sous le nom du repertoire, et
  # n'apparaitrait JAMAIS dans « catalogue list » — qui indexe par identite declaree. Le depot serait
  # la, visible sur la forge, et introuvable par la commande faite pour le trouver.
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
  # ⚠ COLONNE ZERO, la meme regle qu'en Elixir et pour la meme raison : en YAML un `name:` INDENTE
  # appartient a la cle du dessus. Un `name:` sous `roles:` declare un ROLE, et le prendre pour
  # l'identite du catalogue deposerait le catalogue sous le nom d'un de ses roles.
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
  [[ "$output" == *"box config"* ]]
}

@test "un geste inconnu est refuse, et les gestes sont NOMMES" {
  run bash -c "'$SCRIPT' pas-un-geste < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config-token"* ]]
  [[ "$output" == *"apply"* ]]
}

# ─── le verrou d'apply se partage entre root et l'humain admin ───────────────────────────────────

@test "le verrou vit dans le repertoire de travail, pas dans /run/lock" {
  # LE DEFAUT MESURE (2026-08-18, reproduit sur deux bancs). Le verrou vivait dans `/run/lock`, en
  # `1777` : n'importe qui y cree un fichier, mais le boot joue l'apply en ROOT, donc root le creait
  # en `0644 root:root` — et l'humain qui jouait `lcars catalogue install` ensuite ouvrait en
  # ecriture un fichier qui n'etait pas le sien. « Permission denied », puis « verrou d'apply
  # inouvrable » : un refus qui accuse le verrou pour un probleme de proprietaire, et un geste
  # injouable par un humain sur toute boite ayant demarre une fois.
  #
  # ⚠ LE PARTAGE ENTRE DEUX IDENTITES N'A PLUS D'OBJET, ET LE MODE N'EST PLUS EPINGLE. Les deux
  # appelants sont ROOT desormais — le boot, et `catalogue-executor.py`. Ce qui reste vrai, et ce
  # que ce temoin garde, est l'EMPLACEMENT : un verrou dans un repertoire dont le proprietaire est
  # connu, jamais dans un `/run/lock` que tout le monde peuple.
  unset LCARS_APPLY_LOCK
  export LCARS_CATALOGUE_WORK="$BATS_TEST_TMPDIR/tofu-work"
  mkdir -p "$LCARS_CATALOGUE_WORK"
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"

  run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]

  LOCK="$LCARS_CATALOGUE_WORK/.apply.lock"
  [ -e "$LOCK" ]
  # Et il n'est PAS dans /run/lock, qui est le defaut qu'on a paye. ⚠ ON MESURE LE CODE, PAS LA
  # PROSE : la cicatrice qui explique ce defaut NOMME `/run/lock`, et une premiere ecriture de cette
  # assertion rougissait dessus. Un instrument qui attrape l'explication interdit d'expliquer.
  run bash -c "sed 's/#.*//' '$SCRIPT' | grep -c '/run/lock' || true"
  [ "$output" -eq 0 ]
}

@test "un verrou DEJA pose garde son mode — un durcissement d'operateur n'est pas contredit" {
  unset LCARS_APPLY_LOCK
  export LCARS_CATALOGUE_WORK="$BATS_TEST_TMPDIR/tofu-work2"
  mkdir -p "$LCARS_CATALOGUE_WORK"
  : > "$LCARS_CATALOGUE_WORK/.apply.lock"
  chmod 0600 "$LCARS_CATALOGUE_WORK/.apply.lock"
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"

  run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$LCARS_CATALOGUE_WORK/.apply.lock")" = "600" ]
}

# ─── LA RESOLUTION DE L'ENTRYPOINT — UN CHEMIN D'IMAGE DANS UN SCRIPT SANS HYPOTHESE DE CONTENEUR ──
#
# ⚠ MESURE DU 2026-08-22, SUR UN POSTE. `lcars catalogue install web-demo` rendait
# « /opt/lcars/entrypoint.sh: No such file or directory », traduit en « pas de source installable » :
# un fichier absent presente comme un catalogue introuvable. Le defaut de `$ENTRYPOINT` etait le
# chemin de l'IMAGE, dans le seul script que le miroir des auxiliaires pose a plat sur l'hote — et
# `62-runtime-helpers` exclut `entrypoint.sh` de ce miroir au motif qu'« il n'a pas de sens hors
# conteneur » : vrai de son metier de BOOT, faux de son metier de PORTES OUTIL.
#
# IL N'Y A RIEN A COPIER : l'arbre `deploy/` est deja pose (`EMBEDDED=(deploy etc)`). Ces temoins
# tiennent les DEUX dispositions ou ce script vit, et le refus quand il n'en trouve aucune.

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
printf '%s %s\n' "$2" "\$*" >> "$ENTRY_LOG"
case "\$1" in
  catalogue-source) echo "alice/cat main deadbeef" ;;
  roles-tfvars)     echo '{"org":"cat","roles":["cat_dev"]}' ;;
esac
exit 0
EOF
  chmod "${3:-0755}" "$1"
}

@test "entrypoint: le VOISIN gagne — la disposition de l'image" {
  setup_install
  local flat; flat="$(_flat_copy "$BATS_TEST_TMPDIR/flat")"
  _fake_entry "$BATS_TEST_TMPDIR/flat/entrypoint.sh" VOISIN
  _fake_entry "$BATS_TEST_TMPDIR/flat/fleet/deploy/docker/entrypoint.sh" EMBARQUE

  run env -u LCARS_ENTRYPOINT bash -c "'$flat' install cat < /dev/null"
  grep -q "^VOISIN catalogue-source cat" "$ENTRY_LOG"
  refute grep -q "^EMBARQUE" "$ENTRY_LOG"
}

@test "entrypoint: SANS voisin, l'arbre EMBARQUE repond — c'est le cas du poste" {
  # ⚠ LE TEMOIN DU DEFAUT MESURE. Sur un poste, ce script vit a plat dans `/opt/lcars/` et son
  # voisin `entrypoint.sh` n'existe pas ; l'arbre est deux crans plus bas. C'est exactement cet
  # etat qui rendait « No such file or directory ».
  setup_install
  local flat; flat="$(_flat_copy "$BATS_TEST_TMPDIR/flat2")"
  _fake_entry "$BATS_TEST_TMPDIR/flat2/fleet/deploy/docker/entrypoint.sh" EMBARQUE

  run env -u LCARS_ENTRYPOINT bash -c "'$flat' install cat < /dev/null"
  grep -q "^EMBARQUE catalogue-source cat" "$ENTRY_LOG"
}

@test "entrypoint: un fichier NON EXECUTABLE repond quand meme — le mode du \`cp -a\`" {
  # ⚠ `entrypoint.sh` est `100644` DANS LE DEPOT ; seule l'image le passe en `0755` (`RUN chmod`).
  # Le `cp -a` de l'arbre embarque preserve donc un mode non executable, et un garde sur `-x`
  # rejetterait exactement le fichier qu'il vient de trouver. On resout sur `-r`, on invoque par
  # `bash` : le mode cesse d'etre une condition.
  setup_install
  local flat; flat="$(_flat_copy "$BATS_TEST_TMPDIR/flat3")"
  _fake_entry "$BATS_TEST_TMPDIR/flat3/fleet/deploy/docker/entrypoint.sh" EMBARQUE 0644

  run env -u LCARS_ENTRYPOINT bash -c "'$flat' install cat < /dev/null"
  grep -q "^EMBARQUE catalogue-source cat" "$ENTRY_LOG"
}

@test "entrypoint: AUCUN candidat -> refus A LA PORTE qui nomme le chemin, pas « pas de source »" {
  # Un fichier absent annonce comme un catalogue introuvable envoie l'operateur interroger sa forge
  # pour un manque qui est celui de sa boite. Le garde est donc a la porte du geste, avant tout le
  # reste — quatre etapes plus tot que la ou l'absence se manifestait.
  setup_install
  local flat; flat="$(_flat_copy "$BATS_TEST_TMPDIR/flat4")"

  run env -u LCARS_ENTRYPOINT bash -c "'$flat' install cat < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"portes outil du release introuvables"* ]]
  [[ "$output" == *"entrypoint.sh"* ]]
  [[ "$output" != *"pas de source installable"* ]]
}

@test "entrypoint: une SURCHARGE qui pointe dans le vide est refusee comme une absence" {
  # La surcharge court-circuite la resolution — c'est son metier — donc elle court-circuite aussi
  # les deux candidats qui auraient repondu. Le garde doit la traiter comme n'importe quelle
  # absence : ce qui compte est qu'aucune porte outil ne repond, pas la raison pour laquelle.
  setup_install

  run env LCARS_ENTRYPOINT="$BATS_TEST_TMPDIR/nulle-part.sh" \
      bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"portes outil du release introuvables"* ]]
  [[ "$output" == *"nulle-part.sh"* ]]
  [[ "$output" != *"pas de source installable"* ]]
}

@test "install: une porte MUETTE qui rend 0 est refusee — jamais un clone sur du vide" {
  # ⚠ MESURE DU 2026-08-23, SUR UN POSTE. La porte a rendu 0 sans rien imprimer ; les trois champs
  # sont sortis VIDES, le geste a construit une URL a partir de rien, git a repondu
  # « repository 'http://.../.git/' not found », et le refus final a dit « clone de  impossible ».
  # Trois messages, aucun ne nommant le vrai manque — et le seul cite accusait git, a qui on venait
  # de passer du vide.
  #
  # Aucune branche de `eval_source/1` ne rend 0 sans imprimer : un zero muet ne vient pas de la
  # porte, il vient de ce qui a repondu a sa place. Le refus doit donc nommer CA.
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
