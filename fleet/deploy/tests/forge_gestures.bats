#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/forge_gestures.bats
# AUTHOR: drdree
# STARDATE: 2026-08-16
# STATUS: bats tests for docker/forge-gestures.sh — LA porte des gestes forge de la boite
#
# CE SCRIPT PORTE LE JETON SITE-ADMIN, celui qui peut tout creer et tout detruire sur la forge, et
# il est joue par DEUX appelants (`docker.sh` et le banc). Une regression ici ne se voit ni dans
# l'un ni dans l'autre : elle se voit sur la forge de quelqu'un.
#
# Dispositif identique a `forge_charte.bats` et `forge_existing.bats` : un faux `curl` en tete de
# PATH qui journalise `"$@"` ET son stdin. Chaque assertion d'attaque va par paire avec un temoin.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../docker/forge-gestures.sh"
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

  cat > "$BIN/jq" <<'FAKE'
#!/usr/bin/env bash
# Assez de jq pour `.token // empty` sur le corps du mint.
body="$(cat)"
[[ "$body" =~ \"token\":\"([^\"]*)\" ]] && printf '%s\n' "${BASH_REMATCH[1]}"
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

  # La porte outil du release, doublee : elle journalise SON verbe et rend ce que le cas veut.
  TPL_LOG="$BATS_TEST_TMPDIR/tpl.log"
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
  template-sync)
    { printf 'argv=%s\n' "\$*"; printf 'tokfile=%s\n' "\${FORGE_TOKEN_FILE:-}"; } >> "$TPL_LOG"
    exit "\$(cat "$BATS_TEST_TMPDIR/tpl.rc" 2>/dev/null || echo 0)"
    ;;
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

@test "apply: le depot modele part APRES les applys, et par FICHIER de jeton" {
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]
  grep -q 'argv=template-sync' "$BATS_TEST_TMPDIR/tpl.log"
  # Le jeton passe par un FICHIER, jamais en argv ni en variable de ligne de commande.
  tokfile="$(sed -n 's/^tokfile=//p' "$BATS_TEST_TMPDIR/tpl.log")"
  [ -n "$tokfile" ]
  run grep -c 'argv=.*TOK' "$BATS_TEST_TMPDIR/tpl.log"
  [ "$output" = "0" ]
}

@test "apply: un modele qui echoue ne fait PAS echouer l'apply — la structure est posee" {
  printf 'TOK\n' > "$PRIV/forge-master.token"
  printf 'SEED\n' > "$PRIV/forge-seed.pass"
  echo 1 > "$BATS_TEST_TMPDIR/tpl.rc"
  run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bare-create"* ]]
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
}

@test "install: sans autorite, il REFUSE avant de toucher quoi que ce soit" {
  run bash -c "'$SCRIPT' install cat < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"docker.sh config"* ]]
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
  grep -q 'push .*cat/catalogue' "$GIT_LOG"
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
  [[ "$output" == *"docker.sh config"* ]]
}

@test "un geste inconnu est refuse, et les gestes sont NOMMES" {
  run bash -c "'$SCRIPT' pas-un-geste < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config-token"* ]]
  [[ "$output" == *"apply"* ]]
}
