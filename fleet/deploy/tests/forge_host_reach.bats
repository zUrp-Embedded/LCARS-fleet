#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/forge_host_reach.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: bats tests for 48-forge-host — les DEUX adresses de la forge du poste, et ce qu'elles coutent
#
# ⚖ USER 2026-08-21 : « un container docker inaccessible sur le reseau ET MEME PAR SON RUNNER, ca
# sert a quoi ? »
#
# CE QUE CES TEMOINS FERMENT. Le module a publie la forge en LOOPBACK SEUL pendant trois jours, sous
# couvert de prudence, et cablait `127.0.0.1` aux DEUX endroits — l'interface de publication ET le
# `ROOT_URL` que Gitea ecrit dans ses liens.
#
# Deux consequences, et la seconde tue le produit :
#
#   1. les liens. Ouvrir le bind sans bouger `ROOT_URL` donne une UI joignable dont chaque lien,
#      chaque URL de clone et chaque retour OAuth pointe sur la loopback du VISITEUR. `bench-up.sh`
#      a paye cette lecon et l'a ecrite : « LE RECAP DIT L'ADRESSE QU'ON COMPOSE, PAS CELLE SUR
#      LAQUELLE ON ECOUTE. »
#
#   2. la CI. La carte canon declare `ci: required` : sans runner, chaque PR attend 45 min puis
#      ESCALADE. Et un runner n'atteint PAS une forge en loopback — ses conteneurs de job vivent sur
#      un reseau par job, ou `127.0.0.1` les designe eux-memes, et un port publie sur la loopback de
#      l'hote n'est pas routable depuis la passerelle du bridge. Une forge fermee n'est donc pas une
#      forge prudente : c'est une forge qui ne peut pas faire son travail.
#
# ⚠ CES TEMOINS NE MONTENT AUCUN CONTENEUR. Ce qui se mesure ici est la DERIVATION des deux
# adresses — c'est la que la faute etait, et c'est la seule partie qui serait silencieuse. Monter la
# forge demande docker et plusieurs minutes ; ce n'est pas ce qu'un temoin joue.

setup() {
  # Le decor possede l'environnement : ce module lit des `PROV_*` que l'appelant peut porter.
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)

  SRC="$BATS_TEST_DIRNAME/../modules.d/48-forge-host.sh"
  [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export PROVISION_MODULE=48-forge-host
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  export PROV_FLEET_GROUP="$(id -gn)"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  # L'EN-TETE SEULE : tout ce qui precede `check()`. C'est la que vivent les deux derivations, et
  # ca evite d'embarquer les fonctions qui parlent a docker.
  HEAD="$BATS_TEST_TMPDIR/head.sh"
  sed '/^check() {/,$d' "$SRC" > "$HEAD"
}

head_sh() { run bash -c "set -euo pipefail; source '$HEAD' >/dev/null 2>&1; $1"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  run head -8 "$SRC"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
}

@test "le defaut PUBLIE — une forge que son runner ne peut pas joindre ne sert a rien" {
  head_sh 'echo "$PROV_FORGE_BIND"'
  [ "$status" -eq 0 ]
  [ "$output" != "127.0.0.1" ]
  [ "$output" != "localhost" ]
}

@test "LOCAL_URL reste la loopback — le module et ses voisins parlent en local" {
  # `forge.url`, lue par 50-forge et 55-deck-oidc, et la sonde `forge_up` : elles tournent SUR la
  # machine. Ouvrir la publication ne doit pas les envoyer faire un tour par le reseau.
  head_sh 'echo "$LOCAL_URL"'
  [ "$status" -eq 0 ]
  [[ "$output" == "http://127.0.0.1:"* ]]
}

@test "PUBLIC_URL est ce qu'un TIERS compose — jamais la loopback quand on publie" {
  head_sh 'echo "$PUBLIC_URL"'
  [ "$status" -eq 0 ]
  [[ "$output" != "http://127.0.0.1:"* ]]
  [[ "$output" != *"0.0.0.0"* ]]
}

@test "un JOKER d'ecoute n'est pas une adresse : \`0.0.0.0\` annonce retombe sur l'adresse de sortie" {
  # « deck 0.0.0.0:20999 » est une ligne qu'on ne peut pas taper. Meme faute, meme correctif que
  # `bench-up.sh` : ce qu'on ANNONCE doit etre composable.
  PROV_FORGE_ADVERTISE=0.0.0.0 head_sh 'echo "$PUBLIC_URL"'
  [ "$status" -eq 0 ]
  [[ "$output" != *"0.0.0.0"* ]]
}

@test "fermer reste POSSIBLE, et l'annonce suit le bind" {
  # Le geste existe pour qui le veut — il prive la machine de sa CI, et c'est son choix. Ce qui ne
  # doit pas arriver, c'est que l'annonce continue de promettre une adresse reseau.
  PROV_FORGE_BIND=127.0.0.1 head_sh 'echo "$PROV_FORGE_BIND|$PUBLIC_URL"'
  [ "$status" -eq 0 ]
  [[ "$output" == "127.0.0.1|http://127.0.0.1:"* ]]
}

# ─── D7 : LE SIEGE, C'EST CELUI QUI INSTALLE ────────────────────────────────────────────────────
#
# ⚖ USER 2026-08-21 : « l'user qui installe devient admin, et son login remonte sur la forge. »
#
# Ce module cablait `admiral` en dur. Mesure du meme jour sur un poste natif : le proprietaire de la
# machine n'etait PAS administrateur de sa propre forge, et le compte qui l'etait portait un nom que
# personne n'avait choisi, avec un mot de passe genere puis JETE — un compte d'administration ou
# personne ne pouvait entrer.

@test "D7: l'administrateur de la forge est l'OPERATEUR, jamais un nom cable" {
  head_sh 'echo "$PROV_FORGE_ADMIN"'
  [ "$status" -eq 0 ]
  [ "$output" != "admiral" ]
  [ -n "$output" ]
  head_sh 'echo "$PROV_FORGE_ADMIN|$PROV_HUMAN"'
  [[ "$output" == "$(echo "$output" | cut -d'|' -f2)|"* ]]
}

@test "D7: un nom EXPLICITE garde la priorite — le defaut n'est pas une contrainte" {
  PROV_FORGE_ADMIN=quelquun head_sh 'echo "$PROV_FORGE_ADMIN"'
  [ "$status" -eq 0 ]
  [ "$output" = "quelquun" ]
}

@test "D7: le mot de passe du #1 fait 10 caracteres ALPHABETIQUES — il se recopie a la main" {
  head_sh 'new_password'
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 10 ]
  [[ "$output" =~ ^[A-Za-z]{10}$ ]]
}

@test "D7: deux appels ne rendent pas le meme mot de passe" {
  head_sh 'a=$(new_password); b=$(new_password); [ "$a" != "$b" ] && echo different'
  [ "$status" -eq 0 ]
  [ "$output" = "different" ]
}

@test "D7: le mot de passe rejoint le BANNER FINAL, il ne s'imprime plus au rang 48" {
  # ⚠ UN SECRET IMPRIME AU RANG 48 A DEFILE QUAND ON LE LIT : quarante modules de sortie passent
  # par-dessus. Et une pause `read` pour le faire noter retient un installeur au milieu de son
  # travail, pour une valeur qu'on ne pourra plus relire a la fin. Le seul endroit ou un operateur
  # lit vraiment, c'est la fin — le canal l'y porte, `install.sh` l'imprime et DETRUIT le fichier.
  export PROV_ANNOUNCE_FILE="$BATS_TEST_TMPDIR/creds"
  head_sh 'announce_password zoe MotDePasse < /dev/null'
  [ "$status" -eq 0 ]
  # Rien sur place : ce qui s'imprimerait ici serait ce qui aurait defile.
  [[ "$output" != *"MotDePasse"* ]]
  # Mais le secret est bien passe, avec son login et ce qu'il ouvre.
  run cat "$PROV_ANNOUNCE_FILE"
  [[ "$output" == *"zoe"* ]]
  [[ "$output" == *"MotDePasse"* ]]
  [[ "$output" == *"administration"* ]]
}

@test "D7: SANS canal, on imprime sur place — se taire serait strictement pire" {
  # Un `provision apply` joue a la main n'a pas de banner final. Le canal ameliore l'affichage, il
  # n'en est pas la condition : sinon on echangerait un secret defile contre un secret jamais montre.
  unset PROV_ANNOUNCE_FILE
  head_sh 'announce_password zoe MotDePasse < /dev/null'
  [ "$status" -eq 0 ]
  [[ "$output" == *"zoe"* ]]
  [[ "$output" == *"MotDePasse"* ]]
}

@test "D7: plus AUCUNE pause — un module ne retient pas un installeur au rang 48" {
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  ! code | sed -n '/^announce_password()/,/^}/p' | grep -q 'read -r'
}

@test "D7: sans jeton master, l'adminite est INCONNUE — jamais supposee absente" {
  # « pas admin », « pas de compte » et « je n'ai pas pu demander » appellent trois gestes
  # differents. Confondre le troisieme avec le second ferait creer un compte qui existe deja.
  head_sh 'forge_admin_state quiconque'
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "D7: sans jeton master, aucune promotion n'est TENTEE" {
  head_sh 'forge_promote_admin quiconque || echo refuse'
  [ "$status" -eq 0 ]
  [ "$output" = "refuse" ]
}

@test "le verdict DIT sur quoi elle ecoute — un 200 local ne distingue pas les deux postures" {
  # Une forge ouverte au reseau et une forge fermee rendent le MEME `200` sur la loopback. C'est la
  # seule chose qu'un operateur ne peut pas deviner en la voyant repondre.
  head_sh 'forge_reach_note'
  [ "$status" -eq 0 ]
  [[ "$output" == *"OUVERTE"* ]]

  PROV_FORGE_BIND=127.0.0.1 head_sh 'forge_reach_note'
  [ "$status" -eq 0 ]
  [[ "$output" == *"machine SEULE"* ]]
}

# ─── SONDER LA LIVENESS, CONCLURE SUR LA DECLARATION ────────────────────────────────────────────
#
# ⚠ CE MODULE A ETE NON IDEMPOTENT PENDANT TOUTE SA VIE, SOUS UN COMMENTAIRE QUI DISAIT LE
# CONTRAIRE : « `compose up -d` est idempotent : il ne recree que si la declaration a bouge » —
# vrai de compose, et parfaitement inutile puisque l'appel etait enferme dans un `if ! forge_up`.
#
# Mesure du 2026-08-21 : `PROV_FORGE_BIND` passe de 127.0.0.1 a 0.0.0.0, apply rejoue, verdict
# « forge du poste deja vivante » — et le conteneur toujours publie sur la loopback. Il a fallu
# taper `compose up -d` a la main.

@test "l'apply appelle compose SANS condition — une forge vivante doit pouvoir RECONVERGER" {
  # L'appel ne doit plus etre garde par la liveness : c'est `forge_up` AVANT qui dit si l'on a
  # monte ou simplement reconverge, pas s'il faut agir.
  # ⚠ COMPTE, N'INVERSE PAS : bash exempte de `set -e` toute commande dont le statut est inverse par
  # `!`, donc un `! grep -q` qui n'est pas la DERNIERE instruction du test ne rougit jamais. Mesure
  # du 2026-08-23 : 35 assertions du corpus bats sont dans ce cas.
  [ "$(grep -cE 'if ! forge_up; then[[:space:]]*$' "$SRC")" -eq 0 ]
  grep -q 'local was_up=0; forge_up && was_up=1' "$SRC"
  # et le compose reste bien dans le chemin nominal, pas dans une branche
  grep -qE '^\s+run_quiet d compose -f "\$COMPOSE_FILE" -p "\$PROV_FORGE_PROJECT" up -d' "$SRC"
}

@test "le verdict distingue MONTEE de RECONVERGEE — deux faits differents, deux phrases" {
  grep -q 'forge du poste vivante et convergée' "$SRC"
  grep -q 'forge du poste montée' "$SRC"
}

# ─── L'HUMAIN INTEGRE N'EST PAS L'OPERATEUR ─────────────────────────────────────────────────────
#
# ⚖ USER 2026-08-21 : « l'user qui fait l'installation n'est pas l'user, c'est l'admin. Il doit se
# creer un compte user ensuite. »
#
# La recette le dit d'elle-meme : « CE COMPTE N'EST PAS UNE PERSONNE : il tient le siege du compte
# que l'admin d'une forge cree a son installation. » Les deux autres rails le savent —
# `forge-gestures.sh` defaute sur `lcars`, `bench-forge-bootstrap.sh` passe l'humain de banc. Le rail
# poste etait le SEUL a y mettre `SUDO_USER`.
#
# Ce que ca coutait n'est apparu qu'a froid, et seulement depuis D7 : la recette pose `admin = false`
# sur ce compte ; devenu le #1 de la forge et admin, l'operateur en est le DERNIER admin, et Gitea
# refuse — « can not delete the last admin user [uid: 1] ». Structure non posee, et trois modules en
# cascade derriere.

@test "l'humain integre vient de PROV_FLEET_HUMAN, jamais de l'operateur" {
  grep -q 'LCARS_BUILTIN_HUMAN="${PROV_FLEET_HUMAN:-}"' "$SRC"
  ! grep -q 'LCARS_BUILTIN_HUMAN="\$PROV_HUMAN"' "$SRC"
}

@test "sans humain de fleet, on ne passe RIEN — le defaut vit dans forge-gestures, pas ici" {
  # Un litteral `lcars` ici en ferait un SECOND defaut pour un meme fait, et deux defauts ne restent
  # d'accord que tant que personne n'en touche un.
  # ⚠ ON EPINGLE QUE LA RECETTE EST ALIMENTEE DEPUIS LA-BAS, PAS LA FORME DE LA LIGNE. Ce temoin
  # citait le litteral `"${LCARS_BUILTIN_HUMAN:-lcars}"` : le jour ou ce fichier a resolu son defaut
  # UNE fois pour ses trois lecteurs, le temoin est tombe sur un changement qui allait dans son
  # propre sens. Ce qui compte est la direction — le nom vient de forge-gestures, pas du module.
  local g="$BATS_TEST_DIRNAME/../docker/forge-gestures.sh"
  grep -qE '^\s*export TF_VAR_builtin_human=' "$g"
  grep -qE '^\s*BUILTIN_HUMAN="\$\{LCARS_BUILTIN_HUMAN:-' "$g"
  # et le module ne redit pas ce defaut
  ! grep -qE 'LCARS_BUILTIN_HUMAN="\$\{PROV_FLEET_HUMAN:-lcars\}"' "$SRC"
}

# ─── LA STRUCTURE SE POSE SUR LA MACHINE, PLUS DANS UN CONTENEUR ────────────────────────────────
#
# ⚖ USER 2026-08-22 : « tu build une image complete de 1,2 Go juste pour executer 100 ko de recette
# tofu ? » puis « pourquoi tofu ne peut pas tourner directement ? ».
#
# Ce module montait un conteneur TRANSITOIRE de `lcars-fleet:2` pour jouer `forge-apply`, avec un
# volume nomme et trois `docker cp` — le tout pour contourner un probleme (« le daemon peut vivre
# ailleurs, un chemin d'hote lui est INVISIBLE ») qui n'existe QUE parce qu'on tourne en conteneur.
# Un contournement etait devenu sa propre justification.
#
# ⚠ CES TEMOINS NE LANCENT NI DOCKER NI TOFU. Ce qui se mesure est la FORME de l'appel.

@test "la structure est jouee par le GESTE, pas par un conteneur transitoire" {
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  code | grep -q 'forge-gestures.sh" apply'
  # et plus rien du dispositif de contournement
  ! code | grep -q 'd create --network'
  ! code | grep -q 'd cp '
  ! code | grep -q 'volume create'
  ! code | grep -q 'forge-apply'
}

@test "ce module n'UTILISE plus aucune image — elle n'etait batie que pour lui" {
  # ⚠ SUR LE CODE, PAS SUR LA PROSE. Le module CITE `lcars-fleet:2` dans la cicatrice qui explique
  # pourquoi il ne la reclame plus ; un grep nu attrape cette phrase et fait echouer le temoin sur
  # ce qu'il voulait justement saluer. Troisieme fois en deux jours (`uname -m`, `providers mirror`).
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  ! code | grep -q 'PROV_FORGE_IMAGE'
  ! code | grep -q 'lcars-fleet:2'
  ! code | grep -q 'image inspect'
  # et la cicatrice, elle, RESTE : sans elle un lecteur re-ajoute le build
  grep -q 'NE DÉPEND PLUS D.UNE IMAGE' "$SRC"
}

@test "l'AUTORITE est lue la ou 48 l'a ECRITE — les trois \`docker cp\` deviennent zero geste" {
  # Le conteneur recevait le jeton master et le seed par `docker cp` dans un volume. Sur la machine,
  # `LCARS_PRIVATE_DIR` suffit : le geste y cherche exactement les deux noms que ce module pose.
  local g="$BATS_TEST_DIRNAME/../docker/forge-gestures.sh"
  grep -q 'LCARS_PRIVATE_DIR="\$PROV_TOKENS_DIR"' "$SRC"
  grep -q 'MASTER_TOKEN_FILE="\$PROV_TOKENS_DIR/forge-master.token"' "$SRC"
  grep -q 'SEED_FILE="\$PROV_TOKENS_DIR/forge-seed.pass"' "$SRC"
  grep -q 'MASTER_TOKEN_FILE="${LCARS_MASTER_TOKEN_FILE:-\$PRIVATE_DIR/forge-master.token}"' "$g"
  grep -q 'SEED_FILE="${LCARS_FORGE_SEED_FILE:-\$PRIVATE_DIR/forge-seed.pass}"' "$g"
}

@test "l'URL passee est la LOOPBACK de l'hote, plus le nom de service du reseau compose" {
  # Le conteneur parlait a `http://forge:3000`, resolu par le reseau `${projet}_default`. Depuis la
  # machine, ce nom ne resout pas : c'est le port PUBLIE qu'on compose.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  code | grep -q 'FORGE_BASE_URL="\$LOCAL_URL"'
  ! code | grep -q 'FORGE_BASE_URL="http://forge:3000"'
}

@test "la recette est une COPIE — le checkout de l'operateur ne recoit pas le roster genere" {
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  code | grep -q 'recipe="\$(mktemp -d'
  code | grep -q 'LCARS_RECIPE_DIR="\$recipe"'
  # le roster atterrit DANS la copie, jamais dans l'arbre
  code | grep -q 'cp "\$enroll/roles.auto.tfvars.json" "\$recipe/roles.auto.tfvars.json"'
  ! code | grep -qE 'deps/roles\.auto\.tfvars\.json'
  # et la copie est effacee, dans les deux sorties
  code | grep -q 'rm -rf "\$recipe" "\$enroll"'
}

@test "la copie est INITIALISEE hors-ligne — le geste appelle \`tofu apply\` NU" {
  # Dans l'image, le Dockerfile jouait `tofu init` AU BUILD. En sortant du conteneur on herite de
  # cette dette : sans init, l'apply echoue sur des providers non installes.
  local g="$BATS_TEST_DIRNAME/../docker/forge-gestures.sh"
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  # le geste n'init PAS avant son apply de recette — c'est le fait dont depend le temoin suivant
  ! sed -n '/^  for m in instance \.; do/,/^  done/p' "$g" | grep -q 'tofu init'
  # donc 48 le fait, avec la tofurc du miroir
  code | grep -q 'tofu init -input=false -no-color'
  code | grep -q 'TF_CLI_CONFIG_FILE='
}

@test "le \`.terraform\` de l'arbre NE VOYAGE PAS — un etat decrit un chemin, pas une recette" {
  # `46-tofu` en laisse un dans le depot (gitignore, c'est son temoin de miroir complet). Le
  # recopier ailleurs, c'est heriter d'un etat dont on ne sait pas ce qu'il pointe.
  grep -vE '^\s*#|^\s*`#' "$SRC" | grep -q 'rm -rf "\$recipe/.terraform" "\$recipe/instance/.terraform"'
}

@test "le pre-requis manquant est NOMME avec le module qui le pose" {
  # L'ancienne dérive nommait « ./docker.sh build ». La nouvelle nomme `46-tofu`, et rejuge PAS la
  # version : `46-tofu` est l'autorite du pin, un second avis ici en ferait un second defaut.
  grep -q '46-tofu' "$SRC"
  grep -vE '^\s*#|^\s*`#' "$SRC" | grep -q 'LCARS_TOFU_BIN:-/usr/local/bin/tofu'
  ! grep -q 'docker.sh build' "$SRC"
}

@test "le roster se derive de l'ARBRE sur ce rail — Elixir y est pose 33 crans plus tot" {
  # `enroll-catalogue.sh` PREFERE `--image`, et le dit : `--repo` exige un toolchain Elixir sur la
  # machine qui appelle, que le chemin de LIVRAISON n'a pas. Le rail poste, lui, l'a pose au module
  # 15 — il batit le runtime. La contrainte qui justifiait l'image n'existe pas ici.
  local d="$BATS_TEST_DIRNAME/../modules.d"
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  code | grep -q 'enroll-catalogue.sh" --tofu-dir "\$enroll" --repo'
  ! code | grep -q -- '--image "\$PROV_FORGE_IMAGE"'
  # et le toolchain vient AVANT — l'ordre est le prefixe
  [ -f "$d/15-toolchain.sh" ]
  [[ "15-toolchain" < "48-forge-host" ]]
}

# ─── LES TROIS TROUS DE LA BASCULE, TROUVES EN REVUE (2026-08-22) ───────────────────────────────

@test "le roster REND l'arbre compilable — sinon la premiere passe meurt sur \`deps/\`" {
  # ⚠ « ELIXIR EST POSE » NE SUFFIT PAS. `enroll-catalogue.sh --repo` fait `mix compile`, qui exige
  # `deps/` — GITIGNORE, donc absent d'un clone neuf. Hex, rebar et `deps.get` arrivaient au module
  # 60, DOUZE CRANS plus loin : la premiere passe mourait ici en accusant le module 15.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  code | grep -q 'mix local.hex --force'
  code | grep -q 'mix local.rebar --force'
  code | grep -q 'mix deps.get'
  # et ils viennent AVANT la derivation, pas apres
  local b d
  b="$(code | grep -n 'mix deps.get' | head -1 | cut -d: -f1)"
  d="$(code | grep -n 'enroll-catalogue.sh' | head -1 | cut -d: -f1)"
  [ "$b" -lt "$d" ]
}

@test "tout \`mix\` passe par as_human — un build root pollue le \`_build\` du checkout" {
  # `60-deploy` porte la raison : « un build root polluerait le _build du checkout ». Un mix en root
  # ici laisserait un `_build` et un `deps` que l'humain ne peut plus ecrire, et casserait le module
  # 60 douze crans plus loin — en accusant le module 60.
  # ⚠ ON COMPTE LE VERBE, PAS LE MOT. Un `p_step "outillage mix pour deriver le roster"` contient
  # « mix » dans une CHAINE DE MESSAGE : un compte nu le prend pour une invocation et fait echouer
  # le temoin sur une ligne qui n'execute rien. Meme piege que la prose, un cran plus bas — ici il
  # est dans le code.
  # ⚠ ET LES MESSAGES NE SONT PAS DU CODE NON PLUS. Un `p_fail "« mix run -e … » ne rend rien"` cite
  # la commande DANS SA PHRASE : le compteur la prend pour une invocation et le temoin tombe sur une
  # ligne qui n'execute rien. Meme piege que `p_step`, corrige une fois, reintroduit par la porte
  # d'a cote — on retire donc toute la famille `p_*`, pas un libelle a la fois.
  local n_mix n_as inv='mix (local\.|deps\.|run |compile|release)'
  code_nomsg() { grep -vE '^\s*#|^\s*`#' "$SRC" | grep -vE 'p_(fail|warn|ok|chg|step|drift|die)\b'; }
  n_mix="$(code_nomsg | grep -cE "$inv")"
  n_as="$(code_nomsg | grep -E "$inv" | grep -c 'as_human')"
  [ "$n_mix" -gt 0 ]
  [ "$n_mix" -eq "$n_as" ]
  # et le dossier de sortie lui appartient, sinon il ne peut pas y ecrire
  grep -vE '^\s*#|^\s*`#' "$SRC" | grep -q 'chown "\$PROV_HUMAN" "\$enroll"'
}

@test "les DEUX depots de catalogue sont recables — leurs defauts sont des chemins d'image" {
  # `forge-gestures.sh` publie la demo et la reference APRES la structure, et les deux echecs sont
  # NON FATAUX. Sans recablage : forge structuree, deux depots absents, aucun verdict qui baisse.
  local g="$BATS_TEST_DIRNAME/../docker/forge-gestures.sh"
  # le geste defaute bien sur des chemins de conteneur — c'est le fait qui rend le recablage requis
  grep -q 'DEMO_CATALOGUE="${LCARS_DEMO_CATALOGUE:-/opt/lcars/catalogues/web-demo}"' "$g"

  # ⚠ `ENTRYPOINT` ETAIT LE TROISIEME DE CETTE LISTE, ET IL N'Y EST PLUS — son defaut ne se recable
  # plus, il se RESOUT. Il etait bien un chemin d'image, et il a coute une install le 2026-08-22 sur
  # un poste : « /opt/lcars/entrypoint.sh: No such file or directory », rendu a l'operateur comme
  # « pas de source installable ».
  #
  # UNE SURCHARGE DE PLUS ICI N'AURAIT RIEN REPARE, et c'est pour ca que la reponse est ailleurs :
  # le verbe qui casse est `lcars catalogue install`, un geste HUMAIN que ce module n'appelle
  # jamais. Recabler dans 48 aurait rendu vert le rail qui ne passe pas par la ligne cassee.
  #
  # Et il n'y avait rien a copier : `62-runtime-helpers` pose deja l'arbre `deploy/`
  # (`EMBEDDED=(deploy etc)`), donc le fichier EST la, sous un autre chemin. Le geste se cherche
  # donc lui-meme, dans les deux dispositions ou il vit — comportement tenu par quatre temoins de
  # `forge_gestures.bats`.
  # LA PROPRIETE, PAS LA LIGNE : aucun defaut ABSOLU. Epingler le texte de la resolution
  # (`:-$(_entrypoint_path)`) ferait rougir ce temoin au premier renommage, sans qu'aucun
  # comportement n'ait bouge — et le comportement, lui, est tenu par quatre temoins de
  # `forge_gestures.bats`. Un chemin absolu en defaut est en revanche exactement ce qui a casse,
  # quelle que soit sa valeur : `/opt/lcars/entrypoint.sh` hier, un autre demain.
  # ⚠ PAS `! grep -q`, ET C'EST UNE MESURE : bash EXEMPTE de `set -e` toute commande dont le statut
  # est inverse par `!` (manuel : « or if the command's return value is being inverted with ! »).
  # Un `! grep -q` en temoin est donc INERTE — il ne rougit jamais, quoi qu'il trouve. Mesure du
  # 2026-08-23 : la premiere redaction de cette assertion l'utilisait, et une mutation reintroduisant
  # un defaut absolu (`/opt/lcars/bin/entrypoint.sh`) passait au VERT. On compte, et on compare.
  [ "$(grep -cE 'ENTRYPOINT="\$\{LCARS_ENTRYPOINT:-/' "$g")" -eq 0 ]
  # et 48 les nomme tous les deux
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  code | grep -q 'LCARS_DEMO_CATALOGUE='
  code | grep -q 'LCARS_REFERENCE_CATALOGUE='
  # la demo existe la ou 48 la nomme, et c'est la meme source que le Dockerfile (`COPY catalogues`)
  [ -d "$BATS_TEST_DIRNAME/../../../catalogues/web-demo" ]
  grep -q '^COPY catalogues /opt/lcars/catalogues' "$BATS_TEST_DIRNAME/../docker/Dockerfile"
}

@test "la REFERENCE se demande a son autorite, elle ne se recompose pas" {
  # L'image porte la raison mot pour mot : `catalogue-root` « existe pour que personne ne RECOMPOSE
  # ce chemin […] un appelant shell qui le globberait marcherait jusqu'au jour ou la disposition du
  # release change ». Meme autorite ici, autre lieu d'execution.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  code | grep -q 'Fleet.Catalogue.root()'
  ! code | grep -qE 'LCARS_REFERENCE_CATALOGUE="[^$]'
  # ⚠ ON EPINGLE LA REGLE, PAS LA PHRASE. Ce temoin citait le message d'erreur mot pour mot et est
  # tombe a la premiere reformulation. Ce qui doit tenir : un chemin qui ne repond pas est un ECHEC,
  # pas un depot silencieusement saute.
  # ⚠ LA POLARITE DE LA GARDE N'EST PAS LA REGLE. Ce temoin epinglait `[[ -d "$ref_catalogue" ]]`
  # mot pour mot et est tombe quand la garde est devenue `if [[ ! -d … ]]` — une reecriture qui ne
  # change RIEN a ce qu'elle protege. On exige donc : le chemin derive est teste comme repertoire, et
  # la branche d'echec appelle `p_fail`.
  code | grep -qE '\-d "\$ref_catalogue"'
  code | grep -A3 -E '\-d "\$ref_catalogue"' | grep -q 'p_fail'
}

@test "le roster NOMME son catalogue — \`--catalogue\` n'est facultatif qu'avec \`--image\`" {
  # Mesure a froid du 2026-08-22 : « ERREUR: --catalogue <root> requis (ou --image, qui porte le
  # sien) ». Le script le dit dans son en-tete ; je l'avais lu et pas applique.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  code | grep -q 'enroll-catalogue.sh".*--repo.*--catalogue'
  # et la racine est derivee AVANT le roster, pas apres — elle sert aux deux usages
  local d r
  d="$(code | grep -n 'Fleet.Catalogue.root()' | head -1 | cut -d: -f1)"
  r="$(code | grep -n 'enroll-catalogue.sh' | head -1 | cut -d: -f1)"
  [ "$d" -lt "$r" ]
}

@test "la racine du catalogue est ETIQUETEE, jamais lue a une POSITION" {
  # `mix` ecrit son avancement sur STDOUT — « Compiling N files », « Generated lcars_fleet app » —
  # mele a ce que le script imprime. Un `tail -n1` prend la derniere ligne de BAVARDAGE quand il y
  # en a apres, et rien du tout quand la compilation echoue. Mesure du 2026-08-22, les deux
  # machines, la meme ligne : .63 rendait « Generated lcars_fleet app », la WSL rendait le vide.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  code | grep -q 'LCARS_CATALOGUE_ROOT='
  code | grep -q "grep -m1 '\^LCARS_CATALOGUE_ROOT='"
  ! code | grep -E 'Fleet.Catalogue.root' | grep -q 'tail -n1'
  # et la sortie de mix n'est PAS jetee : sans elle, un vide n'a pas de cause
  ! code | grep -E 'Fleet.Catalogue.root' | grep -q '2>/dev/null'
  code | grep -q 'dernières lignes de mix'
}

@test "GUARD B : les appels mix qui EVALUENT la config portent LCARS_TOOL_EVAL" {
  # `config/runtime.exs` refuse de demarrer sous le siege sysadmin (uid 1000) — « a fleet under the
  # seat would run sudo-capable pods, the exact inverse of the sandbox ». L'operateur EST l'uid 1000
  # et `as_human` lance sous lui : tout `mix` qui evalue la config runtime se fait refuser.
  #
  # Le seam est celui du PRODUIT : `runtime.exs` le declare, et la porte `catalogue-root` de l'image
  # l'emploie exactement ainsi. Mesure du 2026-08-22 sur .63 : sans lui, « R-no-root-runtime ».
  local rt="$BATS_TEST_DIRNAME/../../config/runtime.exs"
  grep -q 'tool_mode? = System.get_env("LCARS_TOOL_EVAL") == "1"' "$rt"
  grep -q 'not tool_mode? do' "$rt"
  # la porte de l'image l'emploie — on ne l'invente pas
  grep -q 'LCARS_TOOL_EVAL=1' "$BATS_TEST_DIRNAME/../docker/entrypoint.sh"
  # et les deux appels de ce module qui evaluent la config le portent
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  code | grep -q 'LCARS_TOOL_EVAL=1 mix run --no-start'
  code | grep -q 'LCARS_TOOL_EVAL=1 "\$tree/etc/enroll-catalogue.sh"'
}

@test "le PORT est sonde avant le montage, et le verdict NOMME l'occupant" {
  # ⚖ USER 2026-08-22 : « les ports que tu montes, ils sont testes pour voir si c'est dispo ? » —
  # non. Et l'echec etait MAL NOMME, ce qui est pire que bruyant : `compose up -d` rendait « port is
  # already allocated » dans une sortie dumpee, et le module concluait « la forge ne converge pas ».
  # L'operateur cherche un defaut de LCARS quand le fait est « autre chose tient 3000 ».
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  code | grep -q 'port_taken "\$PROV_FORGE_HOST_PORT"'
  code | grep -q 'port_holder "\$PROV_FORGE_HOST_PORT"'
  # le refus nomme le levier, pas seulement le probleme
  code | grep -q 'PROV_FORGE_HOST_PORT=<port>'
}

@test "« PRIS PAR NOUS » n'est pas « PRIS PAR UN AUTRE » — sinon le second passage casse" {
  # Au second passage, NOTRE forge tient le port. Refuser la rendrait non idempotente, et
  # l'idempotence de ce module a deja ete cassee une fois pendant toute sa vie sous un commentaire
  # qui disait le contraire.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  # la garde exige les DEUX : port pris ET forge muette
  code | grep -qE 'was_up" -eq 0 \]\] && port_taken'
}

@test "les deux sondes de port vivent dans la LIB, pas dans un module" {
  # Le deck en aura besoin aussi (`64-services`, port 20999) : deux implementations d'une meme
  # question repondraient differemment le jour ou l'une bouge.
  local lib="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  grep -q '^port_taken()' "$lib"
  grep -q '^port_holder()' "$lib"
  # `port_holder` rend VIDE quand il ne sait pas — jamais une phrase creuse
  grep -A6 '^port_holder()' "$lib" | grep -q 'command -v ss'
}

@test "UN SEUL port de forge dans le produit : le poste s'aligne sur le banc" {
  # ⚖ USER 2026-08-22 : « pour le mode bench, on pose 21000 […] poste aussi doit passer sur 21000
  # par defaut. »
  #
  # ⚠ LE DEFAUT ETAIT `3000`, LE PORT LE PLUS DISPUTE D'UN POSTE DE DEV — React, Rails, Vite,
  # Grafana le prennent tous. Un rail qui s'installe SUR le poste de quelqu'un ne peut pas
  # revendiquer ce port : il gagne la course ou il la perd, et quelqu'un perd quelque chose.
  #
  # Deux defauts pour un meme fait ne restent d'accord que tant que personne n'en touche un : ce
  # temoin lit les DEUX et exige l'egalite.
  local bench="$BATS_TEST_DIRNAME/../docker/bench/bench-up.sh"
  local from_module from_bench
  from_module="$(grep -oE '\$\{PROV_FORGE_HOST_PORT:=[0-9]+\}' "$SRC" | head -1 | grep -oE '[0-9]+')"
  from_bench="$(grep -oE '^FORGE_PORT="[0-9]+"' "$bench" | head -1 | grep -oE '[0-9]+')"
  [ -n "$from_module" ]
  [ -n "$from_bench" ]
  [ "$from_module" = "$from_bench" ]
  # et ce n'est PAS 3000
  [ "$from_module" != "3000" ]
}

@test "UNE SEULE derivation de l'adresse annoncee — la lib, jamais lan_addr en direct" {
  # ⚠ CE MODULE AVAIT LA SIENNE, ET ELLE IGNORAIT LE NAT. Il appelait `lan_addr` directement ; sous
  # WSL en NAT ca rend l'adresse INTERNE de la VM, routee depuis aucune autre machine, Windows
  # compris. Mesure du 2026-08-22 sur une instance fraiche : `forge.public.url` valait
  # `http://172.25.115.129:3000`.
  #
  # `55-deck-oidc` savait deja : il appelle `advertise_addr`, qui connait le NAT. Deux derivations
  # d'un meme fait — « quelle adresse un tiers peut composer » — et c'est celle qui l'ignorait qui
  # ecrivait le fichier que trois modules relisent.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  # ⚠ ON EPINGLE L'APPEL, PAS SA FORME D'ARGUMENT. Ce temoin exigeait `advertise_addr
  # "$PROV_FORGE_BIND"` mot pour mot et est tombe des que l'argument est devenu
  # `${PROV_FORGE_ADVERTISE:-$PROV_FORGE_BIND}` — une correction qui RENFORCE la regle qu'il garde.
  code | grep -qE 'advertise_addr "\$\{?PROV_FORGE'
  ! code | grep -q 'lan_addr'
}

@test "sous WSL en NAT, l'adresse annoncee est COMPOSABLE, et le motif remonte" {
  # Le fond : `0.0.0.0` publie DANS la VM, pas sur Windows. Annoncer l'IP de la VM promet une
  # adresse que le navigateur de l'hote ne peut pas atteindre.
  #
  # ⚠ CE TEMOIN A MESURE LA MACHINE PENDANT UNE JOURNEE. Il posait deux stubs et les exportait —
  # mais `head_sh` fait `source`, et la lib REDEFINIT les deux fonctions par-dessus. Les stubs
  # etaient donc morts a l'arrivee, et ce qui repondait, c'etait le `/proc/version` de la machine :
  # vert sur le WSL de l'auteur, rouge le 2026-08-22 sur `.63` (Linux natif) sans qu'une seule
  # regle ait bouge. Un stub qu'on exporte ne survit pas au `source` qui le suit.
  #
  # Les deux coutures de decor tiennent, elles, parce que les fonctions les LISENT :
  # `PROV_SUBSTRATE` est ce que le runner a tranche, `LCARS_WSL_NETWORKING_MODE` remplace `wslinfo`.
  PROV_SUBSTRATE=wsl LCARS_WSL_NETWORKING_MODE=nat \
    head_sh 'echo "$PROV_FORGE_ADVERTISE|${PROV_FORGE_ADVERTISE_WHY:0:12}"'
  [ "$status" -eq 0 ]
  [[ "$output" == "localhost|WSL2 en mode"* ]]
}

@test "hors WSL, la meme regle ne s'applique PAS — c'est le substrat qui tranche, pas la machine" {
  # Le CONTRE-TEMOIN qui manquait, et son absence est ce qui a laisse le precedent mesurer la
  # machine : tant qu'un seul cas est exerce, « ca marche » et « je tourne sur le bon substrat »
  # rendent le meme vert. Sur `linux`, l'adresse annoncee est celle du LAN (ou `127.0.0.1` quand
  # aucune sortie n'est detectable), jamais `localhost`, et le motif NAT n'a rien a dire.
  PROV_SUBSTRATE=linux LCARS_WSL_NETWORKING_MODE=nat \
    head_sh 'echo "$PROV_FORGE_ADVERTISE|${PROV_FORGE_ADVERTISE_WHY:0:12}"'
  [ "$status" -eq 0 ]
  [[ "$output" != "localhost|WSL2 en mode"* ]]
}

@test "un ADVERTISE pose par l'operateur reste souverain — on ne derive que l'absence" {
  PROV_FORGE_ADVERTISE=10.9.9.9 head_sh 'echo "$PROV_FORGE_ADVERTISE|$PUBLIC_URL"'
  [ "$status" -eq 0 ]
  [[ "$output" == "10.9.9.9|http://10.9.9.9:"* ]]
}

@test "le verdict DIT quand l'adresse ne vaut que localement" {
  # Sans ca, il annonce « OUVERTE sur 0.0.0.0 » — vrai du bind, faux de ce qu'un tiers atteint.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  code | sed -n '/^forge_reach_note()/,/^}/p' | grep -q 'PROV_FORGE_ADVERTISE_WHY'
}

# ─── LE MOT DE PASSE ADMIN : TROIS SORTIES, PAS DEUX ─────────────────────────────────────────────
#
# La creation du compte d'administration traduisait TOUT code non nul en « deja present », stderr
# jete. Une creation refusee pour une autre raison ressortait donc en OK sur un compte inexistant,
# et l'operateur ne pouvait pas se connecter a sa propre forge sans qu'une seule ligne le dise.
# Mesure du 2026-08-22, poste Nico : « impossible de me logger ».

@test "creation admin : un refus qui n'est PAS « deja present » est un ECHEC, jamais un OK" {
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  # La sortie d'erreur est CAPTUREE — sans elle, aucune des trois branches n'est decidable.
  code | grep -qE '2>"\$err"'
  # La branche « deja present » se decide sur le MESSAGE, pas sur le code de sortie.
  code | grep -qE "grep -qiE 'already exist"
  # Et le reste est un p_fail qui PORTE le message de la forge, pas une phrase inventee.
  code | grep -q 'p_fail "création du compte'
  code | grep -qE 'REFUSÉE par la forge : \$\('
}

@test "le compte deja present NOMME la porte — sinon le verdict est vrai et inutile" {
  # « son mot de passe est un hash » est un fait, pas un geste. Sans la seconde ligne, l'operateur
  # apprend qu'il ne peut pas lire son mot de passe et repart sans moyen d'en avoir un.
  grep -q 'PROV_FORGE_ADMIN_RESET' "$SRC"
  grep -qE "p_warn .*PROV_FORGE_ADMIN_RESET" "$SRC"
}

@test "la repose vit HORS de la garde du jeton master — sinon elle est inerte quand on en a besoin" {
  # Le bloc de creation ne tourne que sur une forge SANS jeton master : une seule fois par machine.
  # Un operateur qui a perdu son mot de passe est toujours APRES ce moment-la.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  code | grep -qE '^\s*\[\[ -s "\$MASTER_TOKEN_FILE" \]\] && reset_admin_password_if_asked 1'
}

@test "la repose ne se declenche QUE sur demande, et jamais sur un compte tout juste cree" {
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  local body; body="$(code | sed -n '/^reset_admin_password_if_asked()/,/^}/p')"
  [ -n "$body" ]
  # Deux gardes, et les deux comptent : le drapeau, puis « le compte existait deja ».
  grep -q 'PROV_FORGE_ADMIN_RESET:-' <<<"$body"
  grep -qE '\[\[ "\$\{1:-1\}" -ne 0 \]\] \|\| return 0' <<<"$body"
}

# ─── LE SEED N'EST PAS UN MOT DE PASSE D'HUMAIN ─────────────────────────────────────────────────
#
# La recette pose `password = var.seed_password` sur TOUT ce qu'elle cree — roles, compte systeme,
# et l'humain integre. Le credential d'une personne etait donc le meme que celui du compte qui signe
# les marqueurs systeme : le lui communiquer ouvrait les dix. Les roles s'en affranchissent au mint
# (`force_password_for`) ; personne ne le faisait pour l'humain.

@test "l'humain integre recoit son PROPRE mot de passe forge, pas le seed" {
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  local body; body="$(code | sed -n '/^announce_builtin_human_password()/,/^}/p')"
  [ -n "$body" ]
  # Le geste est celui des roles : PATCH admin avec le jeton master, jamais une lecture du seed.
  grep -q 'request = .PATCH.' <<<"$body"
  grep -q 'admin/users/' <<<"$body"
  # Meme raison qu'en tete de fichier : `!` non terminal = assertion inerte.
  [ "$(grep -c 'SEED_FILE' <<<"$body")" -eq 0 ]
  # Et il rejoint le banner par le canal, pas un echo perdu au rang 48.
  grep -q 'prov_announce_credential' <<<"$body"
}

@test "aucun secret ne passe par ARGV — ni le jeton master ni le mot de passe pose" {
  # Cicatrice 6-141 : `-d` met la donnee dans la ligne de commande, lisible dans /proc de tout
  # l'hote pendant l'appel. Le fichier de config de curl accepte `data =`, donc stdin.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  local body; body="$(code | sed -n '/^announce_builtin_human_password()/,/^}/p')"
  grep -q 'curl -K -' <<<"$body"
  ! grep -qE 'curl[^|]* -d ' <<<"$body"
}

@test "sans humain NOMME, le login se DEMANDE — sortir en silence rendait la fonction morte" {
  # ⚠ SANS `--fleet-human` — LE CAS NOMINAL — le compte integre est cree par la recette sous le
  # defaut de `forge-gestures.sh`. Une fonction qui sortirait en silence faute de nom ne poserait
  # donc jamais le mot de passe de ce compte, c'est-a-dire jamais dans le cas ou elle sert.
  #
  # Ne pas recopier ce defaut reste la regle ; on l'INTERROGE. Pas de litteral ici, pas de silence.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  local body; body="$(code | sed -n '/^announce_builtin_human_password()/,/^}/p')"
  grep -qE 'login="\$\{PROV_FLEET_HUMAN:-\}"' <<<"$body"
  grep -q 'forge-gestures.sh" builtin-human' <<<"$body"
  ! grep -q '"lcars"' <<<"$body"
}

@test "le nom du compte integre a UNE autorite, et elle repond" {
  local g="$BATS_TEST_DIRNAME/../docker/forge-gestures.sh"
  [ -f "$g" ]
  run bash "$g" builtin-human
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # La surcharge passe par la meme porte — sinon ce serait une seconde autorite deguisee en defaut.
  run env LCARS_BUILTIN_HUMAN=vanille bash "$g" builtin-human
  [ "$output" = "vanille" ]
  # Et le litteral n'existe qu'UNE fois dans le CODE du fichier qui le porte — les commentaires en
  # parlent, et un compte qui les inclut mesure la prose au lieu de la regle.
  [ "$(grep -vE '^\s*#' "$g" | grep -c 'LCARS_BUILTIN_HUMAN:-')" -eq 1 ]
}

@test "la repose couvre les DEUX comptes — une porte a moitie n'est pas une porte" {
  # L'annonce de l'humain integre est liee a la passe qui POSE la structure : sur une machine deja
  # provisionnee elle est sautee. Un operateur qui a perdu ses identifiants les a perdus tous les
  # deux, donc le recours doit rendre les deux.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  local body; body="$(code | sed -n '/^reset_admin_password_if_asked()/,/^}/p')"
  grep -q 'announce_builtin_human_password' <<<"$body"
  # Et quand le nom manque, il le DIT au lieu de reposer la moitie en silence.
  grep -qE 'p_warn .*--fleet-human' <<<"$body"
}

@test "VERROU : le drapeau de repose SURVIT a l'escalade sudo d'install.sh" {
  # `sudo` fait env_reset : un drapeau absent de REEXEC_ENV est mange en silence, et le geste de
  # l'operateur ne produit RIEN. C'est le cinquieme exemplaire de ce piege dans ce fichier.
  local door="$BATS_TEST_DIRNAME/../../../install.sh"
  [ -f "$door" ]
  grep -qE '^\s*for _v in .*PROV_FORGE_ADMIN_RESET' "$door"
}
