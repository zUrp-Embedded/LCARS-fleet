#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/forge_ci_runner.bats
# AUTHOR: bob
# STARDATE: 2026-08-22
# STATUS: bats tests for 50-forge — la sonde du runner CI, et sa distinction entre ZERO et INCONNU
#
# POURQUOI CE FICHIER. Une boite peut sortir sans aucun runner CI. La fleet accepte alors un ticket,
# depense un producteur, ouvre une PR, et la CI attend une machine qui n'existe pas. MESURE DU
# 2026-08-22 sur une forge de deux heures : sept courses `queued`, aucune demarree, zero runner aux
# trois portees (depot, org, instance) — et pas une ligne pour le dire. L'operateur l'a appris par un
# ticket bloque, pas par sa boite.
#
# ⚖ L'ARBITRAGE DU 2026-07-30 TIENT : le runner est un sidecar compose, PAS un module. Cette sonde ne
# le rouvre pas — elle ne pose rien. Elle MESURE une precondition d'instance, exactement comme les
# deux sondes voisines (`probe_registration`, `probe_restricted`) le font pour des reglages que
# l'admin possede et que la fleet subit.
#
# LE COEUR DU FICHIER : « zero runner » et « je ne peux pas savoir » sont deux reponses. Les
# confondre dans un sens envoie enroler un runner qui existe deja ; dans l'autre, ca declare le rail
# sain sur une forge muette. Un jeton trop etroit suffit a produire le silence — la portee du jeton
# master a DEJA mordu ici (`--reg-token` de bench-runner.sh existe pour ca, mesure du 2026-08-09).
#
# ON EXECUTE LE MODULE, on ne le source pas : patron des autres temoins de `deploy/`.

setup() {
  MODULE="$BATS_TEST_DIRNAME/../modules.d/50-forge.sh"
  [ -f "$MODULE" ]

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN" "$BATS_TEST_TMPDIR/tokens"

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export PROV_FORGE_URL="http://forge.test"
  export PROV_HUMAN="zoe"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/tokens"
  export PROV_CATALOGUES_DIR="$BATS_TEST_TMPDIR/nocat"
  export PROV_MASTER_TOKEN_FILE="$BATS_TEST_TMPDIR/tokens/master"
  printf 'MASTERTOK' > "$PROV_MASTER_TOKEN_FILE"
  export PATH="$BIN:$PATH"
}

# Le stub AIGUILLE sur le chemin : `admin/actions/runners` et rien d'autre. Un stub qui repondrait la
# meme chose partout ferait passer une autre sonde pour celle-ci.
stub_curl() { # stub_curl <corps json pour admin/actions/runners | MUET>
  cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
case "\$url" in
  */api/v1/version)                 printf '{"version":"1.26.1"}' ;;
  */api/v1/admin/actions/runners)   [ '$1' = MUET ] && exit 22; printf '%s' '$1' ;;
  *)                                exit 22 ;;
esac
exit 0
EOF
  chmod +x "$BIN/curl"
}

@test "zero runner SUR UNE BOITE -> DRIFT qui nomme la CONSEQUENCE et le GESTE" {
  # ⚠ LE SUBSTRAT EST POSE PAR LE DECOR, ET IL DOIT L'ETRE. Le verdict a deux branches : sur une
  # boite le sidecar compose existe, donc l'absence est une DERIVE ; sur un poste aucun module
  # n'enrole de runner, donc c'est un constat. Sans cette ligne le temoin lit le substrat de la
  # machine qui le joue, et il est vert ou rouge selon le poste — ce qui ne mesure plus la regle.
  stub_curl '{"runners":[],"total_count":0}'
  run env PROV_SUBSTRATE=docker "$MODULE" check

  [[ "$output" == *"AUCUN runner CI"* ]]
  [[ "$output" == *"DRIFT"* ]]
  # Un drift qui dit « 0 runner » et s'arrete laisse l'operateur deviner que ca bloque tout. La
  # consequence MESUREE est ce qui rend le message actionnable.
  [[ "$output" == *"aucune PR ne fusionne"* ]]
  [[ "$output" == *"runner-token"* ]]
}

@test "un runner -> OK, et il NOMME ses labels" {
  # Les labels sont la moitie du diagnostic suivant : un runner present qui ne sert pas le label
  # demande est l'autre panne (mesure du 2026-08-21, un job `ubuntu-latest` sur une forge dont le
  # seul runner servait `shell,elixir,dood`). Cette sonde ne la TRANCHE pas — `CiGate` le fait au
  # ticket, en nommant le label — mais elle donne a l'operateur de quoi comparer.
  stub_curl '{"total_count":1,"runners":[{"name":"bench-runner","labels":[{"name":"shell"},{"name":"elixir"}]}]}'
  run "$MODULE" check

  [[ "$output" == *"1 runner(s) CI"* ]]
  [[ "$output" == *"bench-runner"* ]]
  [[ "$output" == *"shell,elixir"* ]]
  [[ "$output" != *"AUCUN runner"* ]]
}

@test "API MUETTE -> on ne conclut RIEN, jamais « zero runner »" {
  # ⚠ LE TEMOIN CENTRAL. Une forge qui ne repond pas, ou un jeton dont la portee ne couvre pas
  # l'endpoint admin, produisent le meme silence qu'une forge sans runner. Le lire comme « zero »
  # enverrait enroler un runner par-dessus celui qui tourne deja.
  stub_curl MUET
  run "$MODULE" check

  [[ "$output" == *"non sondables"* ]]
  [[ "$output" == *"rien n'est conclu"* ]]
  [[ "$output" != *"AUCUN runner"* ]]
}

@test "jeton master ABSENT -> non sondable, et ce n'est pas un echec" {
  # Une boite sans ce jeton FONCTIONNE — c'est deja la nuance que porte `check_master_authority`
  # (`p_warn` et pas `p_drift`). Une sonde qui exigerait le jeton transformerait un deploiement
  # legitime en drift permanent.
  rm -f "$PROV_MASTER_TOKEN_FILE"
  stub_curl '{"runners":[],"total_count":0}'
  run "$MODULE" check

  [[ "$output" == *"jeton master absent"* ]]
  [[ "$output" != *"AUCUN runner"* ]]
}

@test "l'APPLY la joue aussi — le boot ne joue jamais le check" {
  # ⚠ SANS CA LA SONDE EST MUETTE LA OU ELLE SERT. `entrypoint.sh` joue `provision apply`, jamais
  # `check` : une sonde qui ne vivrait que dans le check ne parlerait a personne au demarrage,
  # c'est-a-dire au seul moment ou l'operateur peut encore enroler un runner AVANT que la fleet ne
  # depense un producteur sur un rail mort.
  stub_curl '{"runners":[],"total_count":0}'
  run env PROV_SUBSTRATE=docker "$MODULE" apply

  [[ "$output" == *"AUCUN runner CI"* ]]
}

@test "zero runner SUR UN POSTE -> un CONSTAT, pas une derive que rien ne peut lever" {
  # ⚠ UN DRIFT DIT « PAS TENU, ET CE RAIL PEUT LE TENIR ». Aucun module du rail poste n'enrole de
  # runner : les seuls qui le font sont les scripts de banc, que ce message citait — il envoyait un
  # operateur de poste chercher son geste dans l'outillage d'un autre rail. Meme idiome que les
  # credentials claude de `70-human` : on constate, on nomme le geste, on ne compte pas de derive.
  stub_curl '{"runners":[],"total_count":0}'
  run env PROV_SUBSTRATE=wsl "$MODULE" check

  # ⚠ ON VISE LA LIGNE DU RUNNER, PAS LA SORTIE ENTIERE. Ce module porte d'autres sondes qui
  # derivent legitimement (structure, inscription) : un `output != *DRIFT*` interdirait toute
  # derive du module et tomberait pour une raison sans rapport avec ce qu'on mesure ici.
  local line; line="$(grep -i 'runner CI' <<<"$output" | head -1)"
  [ -n "$line" ]
  [[ "$line" == *"WARN"* ]]
  [[ "$line" != *"DRIFT"* ]]
  # Et il ne renvoie plus vers l'outillage de banc comme si c'etait le geste de ce rail-ci.
  [[ "$line" != *"bench-runner.sh"* ]]
}
