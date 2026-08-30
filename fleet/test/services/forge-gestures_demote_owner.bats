#!/usr/bin/env bats
# SOURCE: fleet/test/services/forge-gestures_demote_owner.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-20
# STATUS: bats tests for `demote_creator_from_owners` — la liste des proprietaires cesse de mentir
#
# CE QUE LE GESTE CORRIGE. Gitea fait de qui cree une org un membre de son equipe `Owners`. La
# recette n'a jamais declare ca : `forge.tf` ne nomme QU'UN owner, le compte systeme. Le master s'y
# retrouvait donc par effet de bord — c'est SON jeton que tofu porte — et une liste de proprietaires
# qui nomme quelqu'un qui n'a fait que creer ment sur qui tient l'org.
#
# ⚠ CE N'EST PAS UNE QUESTION DE POUVOIR. Le master est site-admin : il passe outre toutes les
# permissions de team, avant comme apres. Mesure du 2026-08-20 sur banc neuf : apres le retrait, le
# compte systeme lit toujours les membres d'une team (200 — la capacite qui exigeait la propriete,
# il l'a parce que c'est LUI l'owner), et le master atteint l'org avec un jeton sans droit d'org.
# Ce qui change est ce que la liste DIT.
#
# CE QUE CES TEMOINS TIENNENT, et le second est celui qui compte :
#
#   1. le retrait a lieu, et il s'annonce ;
#   2. la PRECONDITION EST LUE, jamais supposee — sans le compte systeme dans la liste, on ne retire
#      rien. Une org sans proprietaire ne se repare pas sans site-admin, et l'ordre des gestes ne
#      suffit pas a le garantir : une passe ou tofu n'a pas encore pose l'adhesion doit s'arreter
#      la. C'est la meme discipline que `toolchain-protection` — la RELECTURE fait foi, pas
#      l'ordre suppose.
#
# Le script est SOURCE, pas execute : appeler la fonction seule evite de monter un `cmd_apply`
# entier (tofu, secrets, depot modele) pour mesurer quatre appels.

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC1090 — sources dynamiques : le chemin de la lib se calcule, c'est le contrat de ces temoins
# shellcheck disable=SC1090

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../services/forge-gestures.sh"
  [ -f "$SCRIPT" ]
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  export DELETE_LOG="$BATS_TEST_TMPDIR/delete.log"
  : > "$DELETE_LOG"
  export PATH="$BIN:$PATH"
  export FORGE_BASE_URL="http://forge.test"
}

# $1 = membres de Owners (espaces) · $2 = login que rend `GET /user` (le master) ·
# $3 = "noteam" pour simuler une equipe Owners introuvable
stub_curl() {
  cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
url=""; method="GET"; prev=""
for a in "\$@"; do
  case "\$prev" in -X) method="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$url" in
  */orgs/*/teams)
    if [[ "$3" == "noteam" ]]; then echo '[{"id":9,"name":"writers"}]'
    else echo '[{"id":9,"name":"writers"},{"id":7,"name":"Owners"}]'; fi
    exit 0 ;;
  */teams/7/members)
    { for m in $1; do printf '{"login":"%s"}\n' "\$m"; done; } | jq -s .
    exit 0 ;;
  */api/v1/user)
    printf '{"login":"%s"}' "$2"; exit 0 ;;
esac
if [[ "\$method" == "DELETE" ]]; then
  printf '%s\n' "DELETE \${url##*/}" >> "\$DELETE_LOG"
  printf '204'; exit 0
fi
printf '404'
EOF
  chmod +x "$BIN/curl"
}

@test "le compte systeme est owner : le master est retire, et le geste le DIT" {
  stub_curl "admiral system_starfleet" "admiral"
  source "$SCRIPT"
  run demote_creator_from_owners fleet tok
  [ "$status" -eq 0 ]
  [[ "$output" == *"admiral retire des Owners"* ]]
  # Le motif voyage avec le verdict : « par creation, pas par decision ».
  [[ "$output" == *"par creation"* ]]
  [[ "$(cat "$DELETE_LOG")" == "DELETE admiral" ]]
}

@test "PRECONDITION : sans le compte systeme dans Owners, RIEN n'est retire" {
  # Le cas qui compte. Une passe ou tofu n'a pas (encore) pose l'adhesion : retirer le master
  # laisserait une org sans proprietaire, et aucun geste de la recette ne sait la reparer.
  stub_curl "admiral" "admiral"
  source "$SCRIPT"
  run demote_creator_from_owners fleet tok
  [ "$status" -eq 0 ]
  [[ "$output" == *"n'est PAS owner"* ]]
  [[ "$output" == *"le master y reste"* ]]
  [ ! -s "$DELETE_LOG" ]
}

@test "IDEMPOTENT : master deja hors de Owners — aucun appel, aucun bruit" {
  stub_curl "system_starfleet" "admiral"
  source "$SCRIPT"
  run demote_creator_from_owners fleet tok
  [ "$status" -eq 0 ]
  [ ! -s "$DELETE_LOG" ]
  [[ "$output" != *"retire des Owners"* ]]
}

@test "equipe Owners introuvable : on ne retire rien a l'aveugle" {
  stub_curl "admiral system_starfleet" "admiral" noteam
  source "$SCRIPT"
  run demote_creator_from_owners fleet tok
  [ "$status" -eq 0 ]
  [[ "$output" == *"introuvable"* ]]
  [ ! -s "$DELETE_LOG" ]
}

@test "le master est DEMANDE a la forge, jamais devine — son login est variable" {
  # En prod c'est le login de l'installeur, au banc c'est `admiral`. Un geste qui ecrirait `admiral`
  # en dur ne retirerait rien chez qui a nomme son master autrement, en silence.
  stub_curl "capitaine system_starfleet" "capitaine"
  source "$SCRIPT"
  run demote_creator_from_owners fleet tok
  [ "$status" -eq 0 ]
  [[ "$(cat "$DELETE_LOG")" == "DELETE capitaine" ]]
}
