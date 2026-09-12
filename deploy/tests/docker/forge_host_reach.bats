#!/usr/bin/env bats
# SOURCE: deploy/tests/docker/forge_host_reach.bats
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

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

load ../refute

setup() {
  # Le decor possede l'environnement : ce module lit des `PROV_*` que l'appelant peut porter.
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  # ⚠ LE SIEGE SE LIT DANS UN FICHIER AVANT LA VARIABLE (`prov_seat_uid`), et ce fichier existe sur toute
  # machine provisionnee : sans decor, un temoin qui attend que celui qui joue passe GUARD B rougit des
  # le second run du gate — le siege, c'est lui (banc .63, 2026-08-30). Le decor nomme un fichier absent.
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/etc/lcars/seat.uid"

  SRC="$BATS_TEST_DIRNAME/../../modules.d/48-forge-host.sh"
  [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=48-forge-host
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  export PROV_FLEET_GROUP
  PROV_FLEET_GROUP="$(id -gn)"
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
  code | sed -n '/^announce_password()/,/^}/p' | refute_out 'read -r'
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

@test "D7: un 401 sur /users n'est pas « pas de compte » — seul un 404 dit absent" {
  # Un jeton perime rend 401 ; la forge repond sur /version ; le verdict disait « absent », et
  # l'apply annoncait une inscription libre pour un compte qui existe. Le code HTTP se lit :
  # 404 seul vaut absent, un 200 se parse, tout le reste est « unknown ».
  mkdir -p "$PROV_TOKENS_DIR"; printf 'jeton\n' > "$PROV_TOKENS_DIR/forge-master.token"
  local stub="$BATS_TEST_TMPDIR/stub"; mkdir -p "$stub"
  cat > "$stub/curl" <<'STUB'
#!/usr/bin/env bash
# curl rejoue : CURL_CODE/CURL_BODY pour /users/*, 200 pour /version ; `-f` coupe a >= 400
fail=0; url=""
for a in "$@"; do case "$a" in -f|-fsS|-fs|-sf) fail=1 ;; http*) url="$a" ;; esac; done
[[ " $* " == *" -K - "* ]] && cat > /dev/null
case "$url" in */version) code=200; body='{"version":"1"}' ;; *) code="${CURL_CODE:-200}"; body="${CURL_BODY:-{}}" ;; esac
if (( fail && code >= 400 )); then exit 22; fi
printf '%s' "$body"; [[ " $* " == *" -w "* ]] && printf '\n%s' "$code"
exit 0
STUB
  chmod +x "$stub/curl"
  CURL_CODE=401 head_sh "PATH=$stub:\$PATH; forge_admin_state quiconque"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
  CURL_CODE=404 head_sh "PATH=$stub:\$PATH; forge_admin_state quiconque"
  [ "$output" = "absent" ]
  CURL_CODE=200 CURL_BODY='{"is_admin":true}' head_sh "PATH=$stub:\$PATH; forge_admin_state quiconque"
  [ "$output" = "admin" ]
  CURL_CODE=200 CURL_BODY='{"is_admin":false}' head_sh "PATH=$stub:\$PATH; forge_admin_state quiconque"
  [ "$output" = "plain" ]
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
  # ⚠ L'ANCRAGE A DU DEVENIR PRECIS (§ 13, 2026-08-31). Il interdisait `if ! forge_up; then` PARTOUT,
  # et il a attrape une garde qui n'a rien a voir avec le montage : celle qui refuse une forge
  # FOURNIE muette. Ce qu'il garde est que le montage n'est pas conditionne par la liveness — pas
  # qu'aucune ligne du fichier ne teste `forge_up`.
  local bloc; bloc="$(sed -n '/^  # ─── LE MONTAGE/,/^  fi$/p' "$SRC")"
  [ -n "$bloc" ]
  [ "$(grep -cE 'if ! forge_up; then[[:space:]]*$' <<<"$bloc")" -eq 0 ]
  grep -q 'local was_up=0; forge_up && was_up=1' "$SRC"
  # et le compose reste bien dans le chemin nominal du montage, pas dans une branche de liveness
  grep -qE '^\s+run_quiet d compose -f "\$COMPOSE_FILE" -p "\$PROV_FORGE_PROJECT" up -d' <<<"$bloc"
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

@test "le module ne pose AUCUN nom d'humain integre — la recette est alimentee par son autorite" {
  # ⚠ CETTE LIGNE A PORTE LE MAUVAIS NOM DEUX FOIS. D'abord `SUDO_USER` — l'operateur, cf. la
  # cicatrice ci-dessus. Puis `PROV_FLEET_HUMAN`, vide dans le cas nominal : une variable qui ne
  # portait un nom que si un drapeau l'avait dit, donc une seconde source pour un fait qui en a une.
  # Le drapeau est retire ; la bonne valeur ici est AUCUNE.
  local code
  code="$(sed 's/#.*//' "$SRC")"
  run grep -c 'LCARS_BUILTIN_HUMAN' <<<"$code"
  [ "$output" = "0" ]
  # GARDE D'INSTRUMENT : le depouillement laisse le reste de la commande, sinon deux zeros pourraient
  # venir d'un `sed` casse plutot que du code.
  grep -qE 'PROV_MASTER_TOKEN_FILE' <<<"$code"
}

@test "le defaut de l'humain integre vit dans forge-gestures, et LUI SEUL le declare" {
  # Un litteral `lcars` dans le module en ferait un SECOND defaut pour un meme fait, et deux defauts
  # ne restent d'accord que tant que personne n'en touche un.
  # ⚠ ON EPINGLE QUE LA RECETTE EST ALIMENTEE DEPUIS LA-BAS, PAS LA FORME DE LA LIGNE. Ce temoin
  # citait le litteral `"${LCARS_BUILTIN_HUMAN:-lcars}"` : le jour ou ce fichier a resolu son defaut
  # UNE fois pour ses trois lecteurs, le temoin est tombe sur un changement qui allait dans son
  # propre sens. Ce qui compte est la direction — le nom vient de forge-gestures, pas du module.
  local g="$BATS_TEST_DIRNAME/../../../runtime/services/forge-gestures.sh"
  grep -qE '^\s*export TF_VAR_builtin_human=' "$g"
  grep -qE '^\s*BUILTIN_HUMAN="\$\{LCARS_BUILTIN_HUMAN:-' "$g"
  # et le module ne grave aucun nom de compte humain, sous aucune forme
  refute grep -qE '"lcars"|:-lcars\}' <<<"$(sed 's/#.*//' "$SRC")"
}

@test "le PORT est sonde avant le montage, et le verdict NOMME l'occupant" {
  # ⚖ USER 2026-08-22 : « les ports que tu montes, ils sont testes pour voir si c'est dispo ? » —
  # non. Et l'echec etait MAL NOMME, ce qui est pire que bruyant : `compose up -d` rendait « port is
  # already allocated » dans une sortie dumpee, et le module concluait « la forge ne converge pas ».
  # L'operateur cherche un defaut de LCARS quand le fait est « autre chose tient 3000 ».
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  code | grep -q 'port_state "\$PROV_FORGE_HOST_PORT" "\$PROV_FORGE_PROJECT"'
  # le refus nomme le levier, pas seulement le probleme
  code | grep -q 'PROV_FORGE_HOST_PORT=<port>'
}

@test "« PRIS PAR NOUS » n'est pas « PRIS PAR UN AUTRE » — sinon le second passage casse" {
  # Au second passage, NOTRE forge tient le port. Refuser la rendrait non idempotente, et
  # l'idempotence de ce module a deja ete cassee une fois pendant toute sa vie sous un commentaire
  # qui disait le contraire.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  # la garde exige les DEUX : port pris ET forge muette
  code | grep -qE 'was_up" -eq 0 && "\$etat" == pris\*'
}

@test "les deux sondes de port vivent dans la lib, et nulle part ailleurs" {
  local lib="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh" deploy; deploy="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  grep -q '^port_taken()' "$lib"
  grep -q '^port_holder()' "$lib"
  # aucune seconde implémentation ailleurs dans deploy/
  [ -d "$deploy/modules.d" ] && [ -d "$deploy/docker" ]
  [ "$(grep -rlE '^port_(taken|holder)\(\)' "$deploy" --include='*.sh' --include=provision --include=workstation --include=container | grep -v /tests/ | wc -l)" -eq 1 ]
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
  local bench="$BATS_TEST_DIRNAME/../../docker/bench/bench-up.sh"
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
  # `66-deck-oidc` savait deja : il appelle `advertise_addr`, qui connait le NAT. Deux derivations
  # d'un meme fait — « quelle adresse un tiers peut composer » — et c'est celle qui l'ignorait qui
  # ecrivait le fichier que trois modules relisent.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  # ⚠ ON EPINGLE L'APPEL, PAS SA FORME D'ARGUMENT. Ce temoin exigeait `advertise_addr
  # "$PROV_FORGE_BIND"` mot pour mot et est tombe des que l'argument est devenu
  # `${PROV_FORGE_ADVERTISE:-$PROV_FORGE_BIND}` — une correction qui RENFORCE la regle qu'il garde.
  code | grep -qE 'advertise_addr "\$\{?PROV_FORGE'
  code | refute_out 'lan_addr'
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
  code | grep -qE '^\s*\[\[ -s "\$PROV_MASTER_TOKEN_FILE" \]\] && reset_admin_password_if_asked 1'
}

@test "la repose ne se declenche QUE sur demande, et jamais sur un compte tout juste cree" {
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  local body; body="$(code | sed -n '/^reset_admin_password_if_asked()/,/^}/p')"
  [ -n "$body" ]
  # Deux gardes, et les deux comptent : le drapeau, puis « le compte existait deja ».
  grep -q 'PROV_FORGE_ADMIN_RESET:-' <<<"$body"
  grep -qE '\[\[ "\$\{1:-1\}" -ne 0 \]\] \|\| return 0' <<<"$body"
}
# ─── LE COMPTE DE DEMONSTRATION A QUITTE CE MODULE ──────────────────────────────────────────────
#
# ⚠ QUATRE TEMOINS VIVAIENT ICI, ET LEUR SUJET EST PARTI (⚖ user 2026-08-30). Ils tenaient
# `announce_builtin_human_password` : le mot de passe forge PROPRE de l'humain integre (pas le
# seed partage), son login demande a l'autorite, et la repose couvrant les DEUX comptes.
#
# Le rail ne seme plus d'humain. Il pose les AUTORITES — le siege, l'admin de forge, le master
# token — et les personnes s'inscrivent sur la forge sous leur nom. Un compte de TRAVAIL dont le
# mot de passe est pose puis annonce en console etait un geste de BANC, herite de l'epoque ou le
# poste en etait un ; `bench-forge-bootstrap.sh` le tient toujours, la ou il a un sens.
#
# La repose ne couvre donc plus qu'un compte, et « une porte a moitie » n'a plus de moitie : il n'y
# a qu'une serrure. Ce que ces temoins protegeaient d'autre — le seed n'est pas un mot de passe
# d'humain — est desormais vrai par construction : aucun humain n'est cree ici.
#
# UNE SEULE CHOSE SURVIT, ET ELLE VAUT PLUS LARGE QU'AVANT : la cicatrice 6-141. Elle etait mesuree
# sur le corps de la fonction disparue ; elle porte maintenant sur TOUT le module, ce qu'elle aurait
# du faire des le debut — un secret en ARGV ne devient pas acceptable parce qu'il sort d'une autre
# fonction.

@test "aucun secret ne passe par ARGV — la cicatrice 6-141 porte sur TOUT le module" {
  # `-d` met la donnee dans la ligne de commande, lisible dans /proc de tout l'hote pendant l'appel.
  # Le fichier de config de curl accepte `data =`, donc stdin : c'est la forme que ce module emploie.
  code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }
  local body; body="$(code)"
  # Il parle bien a curl par un fichier de config — sinon l'assertion suivante serait vraie a vide.
  grep -q 'curl -K -' <<<"$body"
  refute grep -qE 'curl[^|]* -d ' <<<"$body"
}

@test "le nom du compte integre a UNE autorite, et elle repond" {
  local g="$BATS_TEST_DIRNAME/../../../runtime/services/forge-gestures.sh"
  [ -f "$g" ]
  run bash "$g" builtin-human
  [ "$status" -eq 0 ]
  # ⚠ `[ -n "$output" ]` VIVAIT ICI, ET L'ARBITRAGE DU 2026-08-30 L'A RENVERSE. Le defaut est VIDE :
  # le rail pose les autorites, il ne fabrique plus d'humain de travail. Les trois etats du nom
  # (rien / le defaut de la destination / l'explicite) sont gardes par le temoin « § 13 : la
  # DESTINATION a son porteur » — un seul endroit, et c'est celui qui porte la decision.
  # La surcharge passe par la meme porte — sinon ce serait une seconde autorite deguisee en defaut.
  run env LCARS_BUILTIN_HUMAN=vanille bash "$g" builtin-human
  [ "$output" = "vanille" ]
  # Et le litteral n'existe qu'UNE fois dans le CODE du fichier qui le porte — les commentaires en
  # parlent, et un compte qui les inclut mesure la prose au lieu de la regle.
  [ "$(grep -vE '^\s*#' "$g" | grep -c 'LCARS_BUILTIN_HUMAN:-')" -eq 1 ]
}

@test "VERROU : le drapeau de repose SURVIT a l'escalade sudo du rail POSTE" {
  # `sudo` fait env_reset : un drapeau absent de REEXEC_ENV est mange en silence, et le geste de
  # l'operateur ne produit RIEN. C'est le cinquieme exemplaire de ce piege dans ce fichier.
  # ⚠ CE TEMOIN A SUIVI SON SUJET (E2, 2026-08-31). L'escalade a quitte `install.sh` pour
  # `deploy/workstation` ; continuer de lire la porte l'aurait rendu vert a vide, sur un
  # fichier qui n'escalade plus. Verifie a la fusion du 2026-09-03 : `install.sh` ne porte plus
  # aucune ligne `for _v in … PROV_FORGE_ADMIN_RESET`, `workstation` porte l'`ESCALADE_ENV`.
  local rail="$BATS_TEST_DIRNAME/../../workstation"
  [ -f "$rail" ]
  grep -qE '^ESCALADE_ENV=\(.*PROV_FORGE_ADMIN_RESET' "$rail"
}

# ─── CHANGER LE PORT SANS CHANGER LE PROJET DEPLACE LA FORGE ────────────────────────────────────
#
# `compose up` sur le meme projet RECREE le conteneur avec le nouveau mapping. Les volumes suivent,
# donc rien n'est perdu — mais l'ancienne adresse cesse de repondre, et `forge.url`, la config du
# runner et le callback OIDC la pointent encore. Rien ne le disait : `forge_up` sonde le port
# DEMANDE, n'y trouve rien, et le module conclut « pas de forge » avant d'en monter une qui est
# l'ancienne, ailleurs.

@test "forge_running_port : le port PUBLIE se lit chez docker, pas sur l'adresse qu'on espere" {
  # Les trois formes que `docker ps --format '{{.Ports}}'` rend reellement — dual-stack, bind
  # precis, et rien. Une extraction qui ne tient pas les trois rend un port faux ou vide, et un
  # port faux ici DEPLACE une forge en croyant en monter une.
  head_sh 'd() { printf "%s\n" "0.0.0.0:21000->3000/tcp, [::]:21000->3000/tcp"; }
           echo "[$(forge_running_port)]"'
  [[ "$output" == *"[21000]"* ]]

  head_sh 'd() { printf "%s\n" "127.0.0.1:3002->3000/tcp"; }
           echo "[$(forge_running_port)]"'
  [[ "$output" == *"[3002]"* ]]

  head_sh 'd() { printf "%s\n" ""; }
           echo "[$(forge_running_port)]"'
  [[ "$output" == *"[]"* ]]
}

@test "forge_running_port : c'est le port de CE projet — le filtre porte le label compose" {
  # Sans le filtre, la sonde lirait le premier conteneur venu — une autre forge, un banc — et
  # refuserait un montage legitime en citant le port de quelqu'un d'autre.
  code() { grep -vE '^\s*#' "$SRC"; }
  code | grep -q 'com.docker.compose.project=\$PROV_FORGE_PROJECT'
  # ⚠ CETTE LIGNE EPINGLAIT `service=forge`, C'EST-A-DIRE LA FAUTE. `b01fe3164` a renomme le service
  # `forge:` en `gitea:` ; ce temoin a fige l'ancien nom et l'a protege pendant quinze jours. Un mur
  # qui recopie ce qu'il devrait deriver ne garde pas l'invariant : il garde la copie.
  code | grep -q 'com.docker.compose.service=\$FORGE_SERVICE'
  run bash -c "! { $(declare -f code); code; } | grep -q 'compose.service=forge\b'"
  [ "$status" -eq 0 ]
}

@test "la garde du nom de service est posee sur les DEUX chemins, apres le verdict docker" {
  # ⚠ CE TEMOIN EXISTE PARCE QUE LA MUTATION NE POUVAIT PAS L'ATTRAPER. Retirer la garde ne change
  # RIEN au seul cas qu'un test sans docker sait jouer — sans daemon, le module refuse avant de
  # l'atteindre. Elle serait donc supprimable en silence, et le compose illisible redeviendrait un
  # filtre vide : une sonde qui ne reconnait plus AUCUNE forge, donc un refus qui accuse la machine.
  #
  # ⚠ ET L'ORDRE EST L'INVARIANT, PAS LA PRESENCE. Posee AVANT le verdict docker, elle tue le module
  # sur un compose absent alors que le fait utile est « aucun daemon » — c'est exactement la
  # regression que la premiere ecriture de ce correctif a produite, et que le temoin voisin
  # « sans daemon, un REFUS » a rattrapee.
  code() { grep -vE '^\s*#' "$SRC"; }
  local mode
  for mode in check apply; do
    local ldocker lgarde
    ldocker="$(code | grep -n "verdict_$mode\$" | head -1 | cut -d: -f1)"
    lgarde="$(code | grep -n "forge_service_known || verdict_$mode" | head -1 | cut -d: -f1)"
    [ -n "$ldocker" ] || { echo "pas de verdict_$mode trouve" >&2; return 1; }
    [ -n "$lgarde" ]  || { echo "la garde manque sur le chemin $mode" >&2; return 1; }
    [ "$lgarde" -gt "$ldocker" ] || {
      echo "la garde du chemin $mode est posee AVANT le verdict docker : un compose absent" >&2
      echo "   masquerait « aucun daemon », qui est le fait utile" >&2; return 1; }
  done
}

@test "le nom de service que le module derive EST celui que le compose declare" {
  # Le seul temoin qui puisse voir revenir la divergence : il ne compare pas le module a une
  # constante ecrite ici — il rejoue la derivation DU MODULE sur le compose REEL et confronte le
  # resultat au premier service du bloc `services:`. Une troisieme copie ne peut plus s'installer.
  #
  # ⚠ MESURE DU 2026-08-28 (banc 1241) : le filtre cherchait `forge`, le conteneur s'appelait
  # `vanille_3-forge-gitea-1`. Une DEUXIEME install sur une machine dont la forge tourne deja
  # echouait sur « ce n'est pas la forge de cette machine » — a propos de sa propre forge.
  local compose derive declared
  compose="$BATS_TEST_DIRNAME/../../docker/forge-compose.yml"
  [ -f "$compose" ]

  # La derivation, telle qu'elle est ECRITE dans le module — extraite du module, pas recopiee.
  # ⚠ ON CAPTURE TOUT L'INTERIEUR DE `$( )`, PAS UNE LIGNE DE FORME FIXE. Ma premiere ecriture
  # ancrait sur « … | head -n1)" » : ajouter un `|| true` a la ligne du module — un correctif
  # legitime, et necessaire sous `set -e` — faisait rougir ce temoin sans qu'aucun invariant
  # n'ait bouge. Un mur qui epingle la MISE EN FORME d'une ligne se casse a chaque retouche.
  derive="$(grep -vE '^\s*#' "$SRC" | sed -n 's/^FORGE_SERVICE="\$(\(.*\))"$/\1/p' | head -n1)"
  [ -n "$derive" ]

  # Ce que le compose declare : premier service du bloc, borne pour ne pas mordre sur `volumes:`.
  declared="$(sed -nE '/^services:/,/^[a-z]/{ s/^  ([a-z][a-z0-9_-]*):[[:space:]]*$/\1/p }' "$compose" | head -n1)"
  [ -n "$declared" ]

  run bash -c "$(sed "s#\"\$COMPOSE_FILE\"#'$compose'#" <<<"$derive") | head -n1"
  [ "$status" -eq 0 ]
  [ "$output" = "$declared" ]

  # Et le nom de conteneur derive du MEME fait, sans le recopier non plus.
  grep -vE '^\s*#' "$SRC" | grep -q 'FORGE_CONTAINER="\${PROV_FORGE_PROJECT}-\${FORGE_SERVICE}-1"'
}

@test "le refus de deplacement vient AVANT le montage, et il nomme les DEUX intentions" {
  # Un refus pose apres `compose up` n'est pas un refus : la forge a deja bouge.
  code() { grep -vE '^\s*#' "$SRC"; }
  local refus montage
  refus="$(code | grep -n 'tourne deja sur le port\|tourne déjà sur le port' | head -1 | cut -d: -f1)"
  montage="$(code | grep -n 'compose -f "\$COMPOSE_FILE"' | head -1 | cut -d: -f1)"
  [ -n "$refus" ] && [ -n "$montage" ]
  [ "$refus" -lt "$montage" ]
  # Les deux gestes : en monter une seconde, ou deplacer celle-ci. Nommer l'un sans l'autre
  # laisserait l'operateur deviner laquelle des deux on lui refuse.
  code | grep -q 'forge-project'
  code | grep -q 'compose -p \$PROV_FORGE_PROJECT down'
}

# ─── UNE FORGE QUI REPOND N'EST PAS FORCEMENT LA NOTRE ──────────────────────────────────────────
#
# ⚠ MESURE DU 2026-08-23, DEUXIEME INSTALL SUR LE MEME HOTE WINDOWS. Docker Desktop sert UN daemon a
# toutes les distributions WSL, donc un seul espace de ports : le 21000 par defaut etait publie par
# `final-forge-1`, la forge d'une AUTRE instance. `forge_up` repondait oui, le module concluait
# « deja vivante », et la passe a cree ses comptes d'administration DANS la forge du voisin en
# ecrivant son adresse dans `forge.url`. Aucune ligne ne l'a dit. Mesure : `48-forge-host check`
# rendait CONFORME sur cette machine.

@test "forge_is_ours : c'est docker qui repond, pas le port" {
  head_sh 'PROV_FORGE_HOST_PORT=21000
           forge_running_port() { echo 21000; }
           forge_is_ours && echo OURS || echo FOREIGN'
  [[ "$output" == *"OURS"* ]]

  # Rien du projet ne publie : quoi qu'il y ait derriere le port, ce n'est pas a nous.
  head_sh 'PROV_FORGE_HOST_PORT=21000
           forge_running_port() { echo ""; }
           forge_is_ours && echo OURS || echo FOREIGN'
  [[ "$output" == *"FOREIGN"* ]]

  # ⚠ CONTRE-TEMOIN : notre forge AILLEURS n'est pas notre forge ICI. Sans cette branche, un port
  # deplace passerait pour conforme et le refus de deplacement juste au-dessus serait mort.
  head_sh 'PROV_FORGE_HOST_PORT=21000
           forge_running_port() { echo 21001; }
           forge_is_ours && echo OURS || echo FOREIGN'
  [[ "$output" == *"FOREIGN"* ]]
}

@test "docker muet ne vaut PAS forge etrangere — on ne refuse pas sur une sonde sans reponse" {
  head_sh 'd() { return 1; }
           docker_answers && echo PARLE || echo MUET'
  [[ "$output" == *"MUET"* ]]

  head_sh 'd() { echo abc123; }
           docker_answers && echo PARLE || echo MUET'
  [[ "$output" == *"PARLE"* ]]
}

@test "le refus nomme le projet, le port, et le geste qui repare" {
  head_sh 'PROV_FORGE_PROJECT=lcars-forge; PROV_FORGE_HOST_PORT=21000
           LOCAL_URL=http://127.0.0.1:21000
           foreign_forge_refusal 2>&1'
  [[ "$output" == *"lcars-forge"* ]]
  [[ "$output" == *"21000"* ]]
  [[ "$output" == *"--port-forge"* ]]
}

@test "le refus de forge etrangere vient AVANT tout geste qui ecrit dans une forge" {
  # Un refus pose apres la creation des comptes n'est pas un refus : les comptes sont chez le voisin.
  code() { grep -vE '^\s*#' "$SRC"; }
  local refus montage
  refus="$(code | grep -n 'docker_answers && ! forge_is_ours' | head -1 | cut -d: -f1)"
  montage="$(code | grep -n 'compose -f "\$COMPOSE_FILE"' | head -1 | cut -d: -f1)"
  [ -n "$refus" ] && [ -n "$montage" ]
  [ "$refus" -lt "$montage" ]
  # Les DEUX portes : `check` ne doit pas rendre CONFORME sur la forge d'un autre non plus.
  [ "$(code | grep -c 'docker_answers && ! forge_is_ours')" -ge 2 ]
}

# ─── LE SIEGE — le lien unix <-> #1 de la forge, et la branche qui n'existait pas ────────────────

@test "siege: le lien s'ENREGISTRE a l'apply, et le check le voit ensuite" {
  head_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/map"
    export PROV_MASTER_TOKEN_FILE="$BATS_TEST_TMPDIR/pas-de-jeton"
    export PROV_FORGE_URL=""
    PROV_FORGE_ADMIN="$(id -un)"
    seat_binding_report apply
    [ "$(awk -F"\t" "\$1 == 1 { print \$3 }" "$PROV_UID_MAP_FILE")" = "$(id -un)" ]
    seat_binding_report check
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"enregistré"* ]]
}

@test "siege: le CHECK ne pose RIEN — un doctor qui ecrit n'est plus un doctor" {
  head_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/map"
    export PROV_MASTER_TOKEN_FILE="$BATS_TEST_TMPDIR/pas-de-jeton"
    export PROV_FORGE_URL=""
    PROV_FORGE_ADMIN="$(id -un)"
    seat_binding_report check
    [ ! -e "$PROV_UID_MAP_FILE" ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"NON enregistré"* ]]
}

@test "siege: DIVERGENCE — deux acteurs pour un role, et RIEN n'est enregistre" {
  # La quatrieme branche. Renommer un compte unix ou un compte forge est une decision d'operateur :
  # on NOMME le desaccord, on ne le tranche pas, et surtout on n'entérine pas un des deux noms.
  head_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/map"
    printf "1\t1000\tzoe\n" > "$PROV_UID_MAP_FILE"
    PROV_FORGE_ADMIN="$(id -un)"
    seat_binding_report apply
    [ "$(awk -F"\t" "\$1 == 1 { print \$3 }" "$PROV_UID_MAP_FILE")" = zoe ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"deux acteurs pour un rôle"* ]]
  [[ "$output" == *"$(id -un)"* ]]
  [[ "$output" == *"zoe"* ]]
}

@test "siege: la TABLE nomme l'admin forge des qu'elle existe, PROV_HUMAN n'est que la semence" {
  # Etape 3 : le nom cesse d'avoir deux sources. Sans ca, un renommage cote forge laissait ce module
  # promouvoir et sonder l'adminite d'un compte que plus rien d'autre ne designait.
  run bash -c "set -euo pipefail
    export PROV_UID_MAP_FILE='$BATS_TEST_TMPDIR/map'
    printf '1\t1000\tzoe\n' > \"\$PROV_UID_MAP_FILE\"
    export PROV_HUMAN=quelquun-dautre
    source '$HEAD' >/dev/null 2>&1
    echo \"ADMIN=\$PROV_FORGE_ADMIN\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"ADMIN=zoe"* ]]
}

@test "siege: SANS table, PROV_HUMAN seme — le premier passage n'a rien a lire" {
  run bash -c "set -euo pipefail
    export PROV_UID_MAP_FILE='$BATS_TEST_TMPDIR/absente'
    export PROV_HUMAN=loperateur
    source '$HEAD' >/dev/null 2>&1
    echo \"ADMIN=\$PROV_FORGE_ADMIN\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"ADMIN=loperateur"* ]]
}

# ─── § 13 : MONTER, OU CONSOMMER — L'AXE FORGE ──────────────────────────────────────────────────
#
# ⚠ UN TEMOIN EST MORT ICI : « LOCAL_URL reste la loopback ». Il gardait que le module et ses voisins
# parlent EN LOCAL — vrai tant que ce rail montait sa forge, et seulement pour cette raison-la. Le
# § 13 separe l'axe FORGE (montee / fournie) de l'axe SUBSTRAT : une forge fournie vit ailleurs, par
# construction, et exiger la loopback reviendrait a interdire l'etat qu'on vient d'ouvrir.
#
# Ce qui le remplace garde la propriete REELLE : le defaut, lui, reste la loopback.

@test "SANS FORGE_BASE_URL : le defaut reste la loopback, et le module MONTE" {
  head_sh 'echo "$FORGE_URL $FORGE_MONTEE"'
  [ "$status" -eq 0 ]
  [[ "$output" == "http://127.0.0.1:"*" 1" ]]
}

@test "AVEC FORGE_BASE_URL : le module CONSOMME, et il ne monte rien" {
  FORGE_BASE_URL="http://forge.example:3000" head_sh 'echo "$FORGE_URL $FORGE_MONTEE"'
  [ "$status" -eq 0 ]
  [ "$output" = "http://forge.example:3000 0" ]
}

@test "l URL fournie perd son slash final — deux formes d une adresse en font deux adresses" {
  # `$FORGE_URL/api/v1/version` sur une base qui finit par `/` donne `//api`, que certains reverse
  # proxies traitent autrement. La normalisation se fait UNE fois, a la source.
  FORGE_BASE_URL="http://forge.example:3000/" head_sh 'echo "$FORGE_URL"'
  [ "$output" = "http://forge.example:3000" ]
}

@test "UNE FORGE FOURNIE NE DEMANDE PAS DOCKER — c est la premiere consequence de l axe" {
  # ⚠ LE REFUS « la forge du poste est un CONTENEUR » VAUT POUR CELLE QU'ON MONTE, pas pour celle de
  # quelqu'un d'autre. Exiger un daemon pour parler a une URL refuserait une machine parfaitement
  # capable de travailler. Les quatre gardes du conteneur — docker, le compose, le nom de service,
  # « est-ce la notre » — vivent donc sous la condition.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  local c_check; c_check="$(sed -n '/^check() {/,/^}/p' <<<"$code")"
  local c_apply; c_apply="$(sed -n '/^apply() {/,/^}/p' <<<"$code")"
  grep -q 'FORGE_MONTEE" -eq 1' <<<"$c_check"
  grep -q 'FORGE_MONTEE" -eq 1' <<<"$c_apply"
  # Aucun `docker_endpoint` hors de la condition : on remonte du haut de la fonction jusqu'au `if`.
  local avant; avant="$(sed -n '/^check() {/,/FORGE_MONTEE" -eq 1/p' <<<"$c_check")"
  refute grep -q 'docker_endpoint' <<<"$avant"
}

@test "muette : DRIFT au check, ECHEC a l apply — les deux verbes ne disent pas la meme chose" {
  # Constater qu'une adresse est muette n'est pas une panne ; s'engager a structurer une forge qu'on
  # ne joint pas en est une, et tout ce qui suit echouerait un geste plus loin.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  local c_check; c_check="$(sed -n '/^check() {/,/^}/p' <<<"$code")"
  local c_apply; c_apply="$(sed -n '/^apply() {/,/^}/p' <<<"$code")"
  grep -qE 'p_drift "forge FOURNIE muette' <<<"$c_check"
  grep -qE 'p_fail "forge FOURNIE muette' <<<"$c_apply"
}

@test "LA STRUCTURE EST COMMUNE AUX DEUX ETATS — une seule recette, pas deux qui derivent" {
  # ⚠ C'EST LE POINT DU § 13. Amorcer, minter l'autorite, promouvoir l'admin, poser la structure : le
  # travail est le MEME sur une forge fournie. Ce qui change est de savoir qui possede le conteneur.
  # Un module qui aurait duplique sa seconde moitie aurait deux recettes a tenir d'accord.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  # Le compose n'apparait qu'UNE fois. (La pose de structure vit dans 61-forge-structure depuis
  # le 2026-09-04, avec son propre temoin d'unicite.)
  [ "$(grep -c 'run_quiet d compose' <<<"$code")" -eq 1 ]
}

@test "§ 13 : il n y a PAS d axe destination — seul le banc seme un humain, et il le NOMME" {
  # ⚠ UN « AXE DESTINATION » A VECU ICI (travail / jetable), porte par `--disposable` sur la porte,
  # `PROV_DISPOSABLE` dans le runner, `LCARS_DISPOSABLE=1` dans ce module, et un defaut « lcars »
  # dans `forge-gestures.sh`. ⚖ user 2026-09-04 : « un vieux reliquat a virer » — quatre etages
  # pour un nom par defaut que plus personne ne demandait : le banc nomme le sien
  # (`bench-forge-bootstrap.sh`, `LCARS_BUILTIN_HUMAN`), un deploiement de travail ne seme
  # personne (canon du 30/08). Ce temoin garde l'ABSENCE de l'axe a chaque etage, et l'unique voie.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -qi 'DISPOSABLE' <<<"$code"
  refute grep -qE 'WITH_BENCH|BENCH.*BUILTIN_HUMAN' <<<"$code"
  # ⚠ ET CE MODULE NE NOMME PERSONNE. Deux temoins de ce fichier gardent l'autorite unique du nom.
  refute grep -q 'LCARS_BUILTIN_HUMAN' <<<"$code"
  # Ni le runner, ni la porte ne portent plus le drapeau — la porte le REFUSE, en se nommant.
  local runner; runner="$BATS_TEST_DIRNAME/../../provision"
  refute grep -qi 'DISPOSABLE' <<<"$(grep -vE '^\s*#' "$runner")"
  local door; door="$BATS_TEST_DIRNAME/../../../install.sh"
  run bash "$door" --disposable </dev/null
  [ "$status" -eq 1 ] && [[ "$output" == *"--disposable est retiré"* ]]
  # Et l'AUTORITE du nom n'a plus que DEUX etats : rien, ou l'explicite.
  local g="$BATS_TEST_DIRNAME/../../../runtime/services/forge-gestures.sh"
  [ -z "$(bash "$g" builtin-human)" ]
  [ -z "$(LCARS_DISPOSABLE=1 bash "$g" builtin-human)" ]
  [ "$(LCARS_BUILTIN_HUMAN=zoe bash "$g" builtin-human)" = "zoe" ]
}

@test "§ 13 : la porte OUVRE --bench au poste, et le refus a disparu" {
  # Il constatait une CAPACITE ABSENTE, pas un choix : `48-forge-host` montait en dur, donc « monte
  # la forge » n'avait aucun sens sur ce rail. Il la consomme desormais aussi.
  local door; door="$BATS_TEST_DIRNAME/../../../install.sh"
  local code; code="$(grep -vE '^\s*#' "$door")"
  refute grep -q "bench n'a pas d'objet sur le rail poste" <<<"$code"
  # Le transport vers le runner existe — par PAIRES : il n'y a plus de drapeau solo.
  grep -q 'PASSTHRU+=("$1" "' <<<"$code"
}

