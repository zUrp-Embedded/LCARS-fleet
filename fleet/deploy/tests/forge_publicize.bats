#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/forge_publicize.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-17
# STATUS: bats tests for `publicize_org_members` — le geste qui rend les workers VISIBLES
#
# CE QUE CE GESTE FAIT, ET POURQUOI IL EST ICI ET PAS DANS LA BOUCLE DE BOOT. Une adhesion d'org
# creee par API est PRIVEE : elle n'est visible que des membres. Un humain qui ouvre l'org ne voit
# donc pas quels workers y travaillent — c'est de l'UX, pas de la surete (⚖ user 2026-08-17), et
# rien dans le depot ne LIT cette visibilite. Le geste vivait dans `50-forge.sh`, rejoue a CHAQUE
# `provision apply` : une convergence a chaque demarrage pour un fait qui ne peut changer qu'au
# moment ou des comptes sont crees. Il vit desormais dans les deux gestes qui les creent.
#
# CE QUE CES TEMOINS TIENNENT, et le second est le seul qui compte vraiment :
#
#   1. il pose ce qui est prive, et NE REJOUE PAS ce qui est deja public ;
#   2. il est AUTO-LIMITANT — un 401/403 signifie « ce compte n'est pas a nous » et se compte comme
#      un saut, jamais comme une panne. C'est le cas NOMINAL d'une vraie personne : elle a change
#      son mot de passe, sa visibilite lui appartient, et on n'y touche pas. Sans ce temoin, une
#      regression qui traiterait le 403 comme une erreur ferait rougir un geste correct — ou pire,
#      une qui essaierait plus fort finirait par publiciser des humains.
#
# ⚠ `publicize` EST SELF-ONLY (mesure Gitea 1.26.4 : jeton master sur autrui -> 403, sur soi -> 204),
# donc la seule voie est la basic-auth DU COMPTE. C'est cette contrainte qui rend l'auto-limitation
# gratuite : on ne peut publiciser que ce dont on detient le secret.
#
# Le script est SOURCE, pas execute : sa frontiere de sourcing existe pour ca, et appeler la
# fonction seule evite de monter un `cmd_apply` entier (tofu, secrets, depot modele) pour mesurer
# une boucle de trois appels.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../services/forge-gestures.sh"
  [ -f "$SCRIPT" ]

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  export PUT_LOG="$BATS_TEST_TMPDIR/put.log"
  : > "$PUT_LOG"
  export PATH="$BIN:$PATH"
  export FORGE_BASE_URL="http://forge.test"
}

# Le stub AIGUILLE sur la methode ET sur le chemin. Un stub qui rendrait un code unique ne
# distinguerait pas « deja public » de « rendu public », et les deux temoins passeraient sur la
# meme mise en scene.
#
# $1 = logins membres (espaces) · $2 = logins DEJA publics · $3 = logins qui refusent l'auth
stub_curl() {
  cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
url=""; method="GET"; user=""
prev=""
for a in "\$@"; do
  case "\$prev" in -X) method="\$a" ;; -u) user="\${a%%:*}" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$url" in
  */orgs/*/members)
    for m in $1; do printf '{"login":"%s"}\n' "\$m"; done | jq -s .
    exit 0 ;;
esac
acct="\${url##*/}"
if [[ "\$method" == "PUT" ]]; then
  printf '%s\n' "PUT \$acct as=\$user" >> "\$PUT_LOG"
  for r in $3; do [[ "\$r" == "\$acct" ]] && { printf '403'; exit 0; }; done
  printf '204'; exit 0
fi
for p in $2; do [[ "\$p" == "\$acct" ]] && { printf '204'; exit 0; }; done
printf '404'
exit 0
EOF
  chmod +x "$BIN/curl"
}

@test "les adhesions privees sont posees, les publiques ne sont PAS rejouees" {
  stub_curl "bot_a bot_b bot_c" "bot_b" ""
  source "$SCRIPT"
  run publicize_org_members "fleet" "TOK" "SEED"

  [[ "$output" == *"2 adhesion(s) rendue(s) visible(s)"* ]]
  # `bot_b` etait deja public : aucun PUT ne doit le concerner.
  grep -q "PUT bot_a" "$PUT_LOG"
  grep -q "PUT bot_c" "$PUT_LOG"
  ! grep -q "PUT bot_b" "$PUT_LOG"
}

@test "AUTO-LIMITANT : un 403 est un compte hors de notre autorite, pas une panne" {
  # `zoe` est une vraie personne : elle a change son mot de passe, le seed ne l'ouvre plus.
  stub_curl "bot_a zoe" "" "zoe"
  source "$SCRIPT"
  run publicize_org_members "fleet" "TOK" "SEED"

  [ "$status" -eq 0 ]
  [[ "$output" == *"1 adhesion(s) rendue(s) visible(s)"* ]]
  [[ "$output" == *"1 compte(s) hors de notre autorite"* ]]
  # LE FAIT QUI COMPTE : on a bien ESSAYE sous l'identite de zoe et pas sous une autre — c'est la
  # nature self-only du geste qui garantit qu'on ne peut pas publiciser quelqu'un d'autre.
  grep -q "PUT zoe as=zoe" "$PUT_LOG"
}

@test "chaque compte est publicise SOUS SA PROPRE identite (publicize est SELF-ONLY)" {
  stub_curl "bot_a bot_b" "" ""
  source "$SCRIPT"
  run publicize_org_members "fleet" "TOK" "SEED"

  grep -q "PUT bot_a as=bot_a" "$PUT_LOG"
  grep -q "PUT bot_b as=bot_b" "$PUT_LOG"
  # Le jeton de lecture ne doit JAMAIS servir a poser : il rendrait 403 sur autrui, et un geste qui
  # l'utiliserait echouerait partout en ayant l'air d'essayer.
  ! grep -q "as=TOK" "$PUT_LOG"
}

@test "org dont les membres ne se lisent pas -> on ne pose RIEN et on le DIT" {
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "PUT-INTERDIT" >> "$PUT_LOG"
exit 22
EOF
  chmod +x "$BIN/curl"
  source "$SCRIPT"
  run publicize_org_members "web-demo" "TOK" "SEED"

  [ "$status" -eq 0 ]
  [[ "$output" == *"aucun membre lu"* ]]
  # Une liste vide n'est PAS « rien a faire » : ne rien poser est correct, se taire ne l'est pas.
  [[ "$output" != *"rendue(s) visible(s)"* ]]
}

@test "l'org est un ARGUMENT — le geste n'est pas mono-org (c'etait le defaut d'origine)" {
  stub_curl "bot_a" "" ""
  source "$SCRIPT"
  run publicize_org_members "web-demo" "TOK" "SEED"

  # Le message porte l'org : sans elle, deux appels dans le meme apply seraient indiscernables dans
  # la sortie, et c'est exactement ce qui a permis au defaut mono-org de vivre si longtemps.
  [[ "$output" == *"web-demo"* ]]
}
