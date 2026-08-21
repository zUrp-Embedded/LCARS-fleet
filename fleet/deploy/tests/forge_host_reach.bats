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

@test "D7: le mot de passe est AFFICHE avec son login, et ne bloque pas sans terminal" {
  # Sans tty (CI, unite systemd, install.sh pilote) on ne s'arrete pas — on le DIT.
  head_sh 'announce_password zoe MotDePasse < /dev/null'
  [ "$status" -eq 0 ]
  [[ "$output" == *"zoe"* ]]
  [[ "$output" == *"MotDePasse"* ]]
  [[ "$output" == *"confirmé par personne"* ]]
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
