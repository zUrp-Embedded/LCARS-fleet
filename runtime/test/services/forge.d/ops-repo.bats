#!/usr/bin/env bats
# SOURCE: runtime/test/services/forge.d/ops-repo.bats
# AUTHOR: bob
# STARDATE: 2026-09-16
# STATUS: temoins de forge.d/ops-repo.sh — le depot du systeme est VERIFIE, jamais pose par ce geste
#
# CE QUE CES TEMOINS TIENNENT (⚖ user 2026-09-16) : la recette de la forge pose le depot du systeme,
# ses branches et la protection de `tool_request` ; ce geste mesure et NOMME ce qui manque, avec le
# remede qui est toujours la recette. Il ne cree rien : aucun POST, aucun PUT, aucun git. Un objet
# absent est un DRIFT (rc 2), une forge qui ne repond pas lisiblement est un ECHEC (rc 1), et `check`
# comme `apply` font exactement la meme mesure.

# shellcheck disable=SC2016,SC2030,SC2031

load ../../support/refute

setup() {
  MODULE="$BATS_TEST_DIRNAME/../../../services/forge.d/ops-repo.sh"
  [ -f "$MODULE" ]
  export LCARS_MODULE_PROTOCOL="$BATS_TEST_DIRNAME/../../../services/lib/module-protocol.sh"
  export LCARS_MODULE_TAG=65-ops-repo
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
  export FORGE_BASE_URL="http://forge.test"
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/private"; mkdir -p "$LCARS_PRIVATE_DIR"
  export LCARS_SYSTEM_TOKEN_FILE="$LCARS_PRIVATE_DIR/system_starfleet.gitea_token"
  printf 'SYS\n' > "$LCARS_SYSTEM_TOKEN_FILE"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  unset LCARS_OPS_REPO
}

# stub_forge <depot> <tool_request> <incidents> <protection JSON ou vide ou "000">
# Les codes des sondes, dans l'ordre des questions ; la protection est un corps JSON (ou rien).
# ⚠ L'ORDRE DES MOTIFS EST LE TEMOIN : l'URL du depot est un prefixe de celles des branches et de la
# protection ; les plus longues se testent en premier.
stub_forge() {
  cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
w=0; url=""; method=GET
for a in "\$@"; do
  case "\$a" in -w) w=1 ;; -X) method=NEXT ;; http*) url="\$a" ;; esac
  [[ "\$method" == NEXT && "\$a" != -X ]] && method="\$a"
done
[[ " \$* " == *" -K "* ]] && cat >/dev/null
echo "CURL:\$method \${url#http://forge.test}" >> "\$CALLS"
code() { [[ \$w -eq 1 ]] && printf '%s' "\$1"; return 0; }
case "\$url" in
  */api/v1/version)                              [[ "${FORGE_MUETTE:-}" == 1 ]] && exit 7; exit 0 ;;
  */branch_protections/tool_request)             [[ '$4' == 000 ]] && exit 7
                                                 if [[ -n '$4' ]]; then printf '%s' '$4'; code "\$(printf '\\n200')"; else printf '{"message":"The target couldn'"'"'t be found."}'; code "\$(printf '\\n404')"; fi ;;
  */branches/tool_request)                       code '$2' ;;
  */branches/incidents)                          code '$3' ;;
  */api/v1/repos/*/_ops)                         code '$1' ;;
  *)                                             code 500 ;;
esac
exit 0
EOF
  chmod +x "$BIN/curl"
}
PROT='{"rule_name":"tool_request","required_approvals":1,"dismiss_stale_approvals":true,"enable_approvals_whitelist":true,"approvals_whitelist_username":["le-siege"]}'

rien_de_cree() {
  refute grep -q '^CURL:POST\|^CURL:PUT\|^CURL:DELETE' "$CALLS"
}

@test "tout est la : conforme (rc 0), une ligne qui nomme le depot, les deux branches et les approbateurs — et rien n'est cree" {
  stub_forge 200 200 200 "$PROT"
  run bash "$MODULE" check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    65-ops-repo: lcars/_ops : dépôt, branches tool_request et incidents, protection de tool_request (une approbation de : le-siege, réapprobation à chaque push)"* ]]
  rien_de_cree
  : > "$CALLS"
  run bash "$MODULE" apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    65-ops-repo: lcars/_ops : dépôt"* ]]
  rien_de_cree
}

@test "depot ABSENT : drift (rc 2) qui dit ce qui manque sans lui, et nomme la recette — rien n'est cree" {
  stub_forge 404 404 404 ""
  run bash "$MODULE" apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"DRIFT 65-ops-repo: dépôt lcars/_ops ABSENT — sans lui aucune demande d'outillage, aucun registre d'incidents, aucune escalade ; la recette de la forge le pose : sur un poste, « deploy/workstation up » ; pour un conteneur, « deploy/container forge-apply » depuis l'hôte"* ]]
  refute grep -q 'branches/' "$CALLS"
  rien_de_cree
}

@test "depot dont l'existence est INCONNUE (HTTP 500) : echec (check rc 2) — rien n'est conclu" {
  stub_forge 500 200 200 "$PROT"
  run bash "$MODULE" check
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  65-ops-repo: lcars/_ops : la forge ne dit pas s'il existe (HTTP 500) — rien n'est conclu"* ]]
}

@test "une branche ABSENTE : un drift par branche, chacun dit ce qui manque sans elle, et la protection n'est pas sondee" {
  stub_forge 200 404 404 "$PROT"
  run bash "$MODULE" apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"DRIFT 65-ops-repo: lcars/_ops:tool_request ABSENTE — un pod qui demande un outil n'a pas de base de PR"*"la recette de la forge le pose"* ]]
  [[ "$output" == *"DRIFT 65-ops-repo: lcars/_ops:incidents ABSENTE — le pilote ne peut pas écrire son registre d'incidents"* ]]
  refute grep -q 'branch_protections' "$CALLS"
  rien_de_cree
}

@test "branches la, protection ABSENTE (404 avec un corps JSON, comme la forge le rend) : drift qui dit qu'une PR se mergerait sans signature" {
  stub_forge 200 200 200 ""
  run bash "$MODULE" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 65-ops-repo: lcars/_ops:tool_request SANS protection — une PR d'outillage se mergerait sans signature ; la recette de la forge le pose"* ]]
  [[ "$output" != *"AUTREMENT"* ]]
}

@test "protection ILLISIBLE (la forge ne repond pas sur cette sonde) : echec, rien n'est conclu — ni absente ni autre" {
  stub_forge 200 200 200 000
  run bash "$MODULE" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  65-ops-repo: protection de lcars/_ops:tool_request illisible (HTTP sans réponse) — rien n'est conclu"* ]]
}

@test "protection AUTRE que celle de la recette (deux approbations, pas d'approbateur) : drift qui cite ce qui est lu" {
  stub_forge 200 200 200 '{"required_approvals":2,"dismiss_stale_approvals":false,"approvals_whitelist_username":[]}'
  run bash "$MODULE" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"protégée AUTREMENT que la recette ne le dit (approbations « 2 », réapprobation « false », approbateurs « aucun »)"* ]]
}

@test "jeton systeme ABSENT : la protection n'est pas sondable — drift qui nomme le geste des jetons, pas un echec" {
  rm -f "$LCARS_SYSTEM_TOKEN_FILE"
  stub_forge 200 200 200 "$PROT"
  run bash "$MODULE" apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"protection de lcars/_ops:tool_request non sondable — jeton système absent"*"le geste des jetons le minte"* ]]
  refute grep -q 'branch_protections' "$CALLS"
}

@test "forge injoignable : DRIFT (rc 2) — pas converge, pas casse, rien n'est conclu" {
  FORGE_MUETTE=1 stub_forge 200 200 200 "$PROT"
  FORGE_MUETTE=1 run bash "$MODULE" apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"forge injoignable (http://forge.test) — état du dépôt lcars/_ops INCONNU"* ]]
  refute grep -q 'repos/' "$CALLS"
}

@test "sans FORGE_BASE_URL : drift qui le dit" {
  unset FORGE_BASE_URL
  stub_forge 200 200 200 "$PROT"
  run bash "$MODULE" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FORGE_BASE_URL non posé — le dépôt du système n'a pas pu être vérifié"* ]]
}

@test "le depot systeme suit LCARS_OPS_REPO quand l'hote le nomme" {
  export LCARS_OPS_REPO=flotte/_ops
  stub_forge 404 404 404 ""
  run bash "$MODULE" check
  [[ "$output" == *"dépôt flotte/_ops ABSENT"* ]]
  grep -q '^CURL:GET /api/v1/repos/flotte/_ops$' "$CALLS"
}

# ─── ce que le geste ne fait plus, et les noms qu'il tient ──────────────────────────────────────

@test "le geste ne cree RIEN : ni git, ni POST, ni PUT, ni depot temporaire — la recette pose" {
  refute grep -q 'git \|git push\|mktemp\|-X POST\|-X PUT' "$MODULE"
}

@test "les noms des branches sont GELES dans le module — tool_request (contrat toolchain.branch_single_source) et incidents (le defaut du registre)" {
  grep -q '^OPS_BRANCH="tool_request"$' "$MODULE"
  grep -q '^INCIDENTS_BRANCH="incidents"$' "$MODULE"
  refute grep -q 'BRANCH:-\|BRANCH:=' "$MODULE"
  # le meme nom que le registre du pilote
  grep -q ':pilot_incident_registry_branch, "incidents")' "$BATS_TEST_DIRNAME/../../../lib/fleet/pilot/incident_registry/store.ex"
}

@test "la tete du module se SOURCE deux fois dans un meme shell — aucune constante readonly (M11)" {
  run bash -c "source <(sed -n '1,/^: \"\${LCARS_OPS_REPO/p' '$MODULE'); source <(sed -n '1,/^: \"\${LCARS_OPS_REPO/p' '$MODULE'); echo ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}
