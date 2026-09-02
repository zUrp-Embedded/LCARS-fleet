#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/forge_existing.bats
# AUTHOR: drdree
# STARDATE: 2026-08-16
# STATUS: bats tests for deps/forge-existing.sh — la sonde qui alimente les blocs `import`
#
# CE QUE CETTE SONDE DECIDE. Sa sortie EST le jeu de blocs `import` de l'apply. Un objet qu'elle
# oublie est un objet que tofu tente de creer, et Gitea rend 409 — loin d'ici. Un objet qu'elle
# invente est un import sur objet absent, panne dure. Les deux fautes sont silencieuses a l'endroit
# ou elles se commettent, ce qui est exactement la raison d'etre de ces temoins.
#
# Dispositif identique a `forge_charte.bats` et `role_tokens.bats` : un faux `curl` en tete de PATH
# qui journalise `"$@"` ET son stdin. Chaque assertion d'attaque va par paire avec un temoin (P-40).

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../services/forge-recipe/forge-existing.sh"
  [ -f "$SCRIPT" ]

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
  STDIN_LOG="$BATS_TEST_TMPDIR/stdin.log"
  : > "$ARGV_LOG"
  : > "$STDIN_LOG"

  # Le faux curl rend un corps ET un code, comme le vrai sous `-w '\n%{http_code}'`. Le code est
  # pilote par `FAKE_CODE_<slug>` ; sans variable, 200. `users/absent` est en dur a 404 parce que
  # l'absence est le cas nominal, pas une panne.
  cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
if [[ " $* " == *" -K "* ]]; then cat >> "$STDIN_LOG"; fi
url="${@: -1}"
path="${url#*/api/v1/}"
slug="$(printf '%s' "$path" | tr -c 'A-Za-z0-9' '_')"
var="FAKE_CODE_$slug"
code="${!var:-200}"
case "$path" in
  users/absent*) code=404 ;;
esac
if [[ "$code" != 200 ]]; then printf '\n%s' "$code"; exit 0; fi
case "$path" in
  users/*)      printf '{"id":%s,"login":"%s"}\n%s' "${FAKE_USER_ID:-13}" "${path#users/}" "$code" ;;
  orgs/*/teams*) printf '[{"id":4,"name":"humans"},{"id":6,"name":"system"},{"id":1,"name":"Owners"}]\n%s' "$code" ;;
  orgs/*)       printf '{"id":10,"username":"%s"}\n%s' "${path#orgs/}" "$code" ;;
  *)            printf '{}\n%s' "$code" ;;
esac
FAKE
  chmod +x "$BIN/curl"

  export ARGV_LOG STDIN_LOG
  export PATH="$BIN:$PATH"
}

# Une requete `external` bien formee. Les tests la modifient par `--arg`-style substitution jq pour
# ne pas recopier six fois un litteral JSON dont un seul champ change.
# ⚠ `$output` est ECRASE par le `run` suivant. Deux assertions jq sur la meme sortie ne peuvent
# donc pas passer par `run` deux fois de suite : la seconde lirait `true`, la sortie de la premiere.
# `jq_out` fige la sortie de la sonde et rend son verdict sans toucher a `$output`.
jq_out() { printf '%s' "$PROBE_OUT" | jq -e "$1" >/dev/null; }

probe() { # $1..= paires cle=valeur qui ecrasent le defaut
  local q='{"gitea_url":"http://forge.test","org":"fleet","users":"alpha","teams":"humans,system"}'
  local kv
  for kv in "$@"; do
    q="$(printf '%s' "$q" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = $v')"
  done
  run env FORGE_ADMIN_TOKEN="JETON-MASTER-SECRET" bash -c "printf '%s' '$q' | '$SCRIPT'"
  PROBE_OUT="$output"
}

@test "sonde: le master token n'apparait JAMAIS dans argv" {
  probe
  [ "$status" -eq 0 ]
  run grep -c "JETON-MASTER-SECRET" "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "sonde: TEMOIN — il est bien passe, par stdin (sinon on aurait supprime l'auth)" {
  probe
  grep -q 'header = "Authorization: token JETON-MASTER-SECRET"' "$STDIN_LOG"
}

@test "sonde: un jeton qui porte des guillemets traverse INTACT" {
  # La config de curl est un format cite : une valeur non echappee couperait le jeton en deux et
  # l'auth partirait tronquee — un echec qui ressemble a un jeton revoque.
  run env FORGE_ADMIN_TOKEN='a"b\c' bash -c \
    "printf '%s' '{\"gitea_url\":\"http://forge.test\",\"org\":\"\",\"users\":\"alpha\",\"teams\":\"\"}' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  grep -q 'header = "Authorization: token a\\"b\\\\c"' "$STDIN_LOG"
  run grep -c 'a"b' "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "sonde: rend un objet PLAT de chaines — le contrat de data.external" {
  probe
  [ "$status" -eq 0 ]
  # `type == "object"` seul passerait sur des valeurs numeriques, que tofu refuse.
  jq_out 'type == "object" and (to_entries | all(.value | type == "string"))'
}

@test "sonde: ce qui EXISTE porte son id numerique, prefixe par son type" {
  probe
  [ "$status" -eq 0 ]
  run bash -c "printf '%s' '$PROBE_OUT' | jq -r '.\"user:alpha\", .\"org:fleet\", .\"team:humans\", .\"team:system\"'"
  [ "${lines[0]}" = "13" ]
  [ "${lines[1]}" = "10" ]
  [ "${lines[2]}" = "4" ]
  [ "${lines[3]}" = "6" ]
}

@test "sonde: un compte ABSENT n'entre pas dans la sortie — un import sur absent est une panne dure" {
  probe "users=alpha,absent"
  [ "$status" -eq 0 ]
  jq_out 'has("user:absent") | not'
  # TEMOIN : la sortie n'est pas vide pour autant, sinon ce test passerait sur une sonde muette.
  jq_out 'has("user:alpha")'
}

@test "sonde: une team ABSENTE de la forge n'entre pas dans la sortie" {
  probe "teams=humans,fantome"
  [ "$status" -eq 0 ]
  jq_out '(has("team:fantome") | not) and has("team:humans")'
}

@test "sonde: une forge VIERGE rend {} et pas null — null n'est pas une map" {
  # `jq -s add` sur une liste vide rend `null`, que tofu refuse avec un message qui ne nomme rien.
  # C'est le cas NOMINAL du premier deploiement, donc celui qu'on ne peut pas se permettre de rater.
  FAKE_CODE_orgs_fleet=404 probe "users=absent" "teams="
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "sonde: org absente => aucune lecture de teams, donc AUCUNE autorite requise" {
  # Sans org il n'y a pas de team : demander l'autorite la rendrait obligatoire sur une forge
  # vierge, ou personne n'a encore de jeton.
  run env -u FORGE_ADMIN_TOKEN -u TF_VAR_gitea_token bash -c \
    "printf '%s' '{\"gitea_url\":\"http://forge.test\",\"org\":\"absent\",\"users\":\"alpha\",\"teams\":\"humans\"}' | FAKE_CODE_orgs_absent=404 '$SCRIPT'"
  [ "$status" -eq 0 ]
  run grep -c 'orgs/absent/teams' "$ARGV_LOG"
  [ "$output" = "0" ]
}

@test "sonde: org PRESENTE + teams illisibles => echec FORT, jamais un ensemble vide" {
  # Le mensonge que ce temoin interdit : rendre {} ferait creer par tofu des teams qui existent, et
  # le 409 tomberait a l'apply, loin d'ici. Le message doit NOMMER la variable a exporter.
  run env -u FORGE_ADMIN_TOKEN -u TF_VAR_gitea_token bash -c \
    "printf '%s' '{\"gitea_url\":\"http://forge.test\",\"org\":\"fleet\",\"users\":\"\",\"teams\":\"humans\"}' | FAKE_CODE_orgs_fleet_teams_limit_100=401 '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TF_VAR_gitea_token"* ]]
}

@test "sonde: un 500 n'est PAS lu comme une absence" {
  # « ni present ni absent » : conclure a l'absence sur une panne transitoire ferait creer un compte
  # existant, et le 409 arriverait sans rapport visible avec la panne qui l'a cause.
  FAKE_CODE_users_alpha=500 probe
  [ "$status" -ne 0 ]
  [[ "$output" == *"500"* ]]
}

@test "sonde: TF_VAR_gitea_token sert d'autorite quand FORGE_ADMIN_TOKEN est absent" {
  # C'est le canal que TOUS les appelants de cette recette utilisent deja pour donner le meme secret
  # a tofu : le lire ici n'ajoute aucune exigence a l'appelant.
  run env -u FORGE_ADMIN_TOKEN TF_VAR_gitea_token="JETON-PAR-TF-VAR" bash -c \
    "printf '%s' '{\"gitea_url\":\"http://forge.test\",\"org\":\"fleet\",\"users\":\"\",\"teams\":\"humans\"}' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  grep -q 'header = "Authorization: token JETON-PAR-TF-VAR"' "$STDIN_LOG"
}

@test "sonde: une URL a slash final ne produit pas de double slash" {
  probe "gitea_url=http://forge.test/"
  [ "$status" -eq 0 ]
  run grep -c 'forge.test//api' "$ARGV_LOG"
  [ "$output" = "0" ]
}
