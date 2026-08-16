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

  # La porte du depot modele : une doublure qui journalise, pour prouver qu'elle est appelee APRES
  # les deux applys et avec un FICHIER de jeton (jamais le jeton en argv).
  TPL_LOG="$BATS_TEST_TMPDIR/tpl.log"
  cat > "$BIN/tplsync" <<FAKE
#!/usr/bin/env bash
{ printf 'argv=%s\n' "\$*"; printf 'tokfile=%s\n' "\${FORGE_TOKEN_FILE:-}"; } >> "$TPL_LOG"
exit "\$(cat "$BATS_TEST_TMPDIR/tpl.rc" 2>/dev/null || echo 0)"
FAKE
  chmod +x "$BIN/tplsync"

  export ARGV_LOG STDIN_LOG TOFU_LOG
  export PATH="$BIN:$PATH"
  export LCARS_PRIVATE_DIR="$PRIV"
  export LCARS_RECIPE_DIR="$RECIPE"
  export LCARS_TEMPLATE_SYNC="$BIN/tplsync"
  export FORGE_BASE_URL="http://forge.test"
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
  run bash -c "'$SCRIPT' apply < /dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"l'autorite"* ]]
  [[ "$output" == *"le seed des comptes"* ]]
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
