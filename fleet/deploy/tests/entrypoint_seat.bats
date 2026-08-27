#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/entrypoint_seat.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-23
# STATUS: bats tests for entrypoint.sh — le SIEGE de la boite est le #1 de la forge, et il le DERIVE
#
# ─── LA REGLE QUE CES TEMOINS GARDENT ───────────────────────────────────────────────────────────
#
# Le siege est le #1 de la forge. Celui des deux qui existe nomme l'autre, et le lien est enregistre
# dans `forge-uid.map`, ligne `forge_id = 1` — la MEME table que le convergeur tient pour les humains
# de fleet.
#
# ⚠ AUCUN RAIL NE PART DE RIEN, et c'est ce qui interdit d'inventer un nom. Le poste a son systeme
# avant LCARS, la boite vise une forge qui tourne deja. Le seul cas from-scratch est `--bench`, qui
# cree tout — et il PASSE le nom lui-meme (`bench-up.sh:353`). Un defaut `admiral` ne sert donc aucun
# appelant, et il nuit : c'est exactement la coincidence que ce code retire. D'ou le REFUS en
# derniere branche, la ou l'ancienne ecriture nommait.
#
# ⚠ ET LE DEFAUT NE DOIT PAS VIVRE PLUS HAUT NON PLUS. Les composes posaient
# `LCARS_ADMIRAL: "${LCARS_ADMIRAL:-admiral}"` : la variable etait alors TOUJOURS definie dans le
# conteneur, la premiere branche court-circuitait tout, et la derivation ne s'executait JAMAIS sur
# une boite composee. Le dernier temoin de ce fichier garde ca, et c'est le seul qui aurait attrape
# le defaut — les autres appellent la fonction avec un decor qui efface la variable.

setup() {
  SRC="$BATS_TEST_DIRNAME/../docker/entrypoint.sh"
  [ -f "$SRC" ]
  # ⚠ LE DECOR POSSEDE L'ENVIRONNEMENT. Ce fichier lit `LCARS_ADMIRAL` et `FORGE_BASE_URL` : un
  # temoin qui les herite mesure la machine qui le lance, pas la regle.
  unset LCARS_ADMIRAL FORGE_BASE_URL LCARS_UID_MAP_FILE LCARS_MASTER_TOKEN_FILE
  MAP="$BATS_TEST_TMPDIR/forge-uid.map"
  TOKF="$BATS_TEST_TMPDIR/forge-master.token"
  # LA TETE SEULE : tout ce qui precede l'etape 1. La resolution y vit, et ca evite d'embarquer le
  # `useradd`, qui exige root et n'est pas ce qu'on mesure.
  HEAD="$BATS_TEST_TMPDIR/head.sh"
  sed '/^# ⚠ LE REFUS EST EXPLICITE/,$d' "$SRC" > "$HEAD"
}

seat_sh() { # seat_sh <corps> — joue la tete puis le corps, decor complet
  run env LCARS_UID_MAP_FILE="$MAP" LCARS_MASTER_TOKEN_FILE="$TOKF" \
          FORGE_BASE_URL="${FORGE_BASE_URL:-}" \
          LCARS_PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh" \
      bash -c 'source "$1" >/dev/null 2>&1; shift; eval "$@"' _ "$HEAD" "$1"
}

@test "siege : la TABLE du convergeur fait foi — aucune forge n'est interrogee" {
  printf '1\t1000\tzoe\n2\t1001\tbob\n' > "$MAP"
  seat_sh 'curl() { echo "CURL NE DOIT PAS ETRE APPELE"; }
           resolve_admiral; echo "SIEGE=$LCARS_ADMIRAL"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"SIEGE=zoe"* ]]
  [[ "$output" != *"CURL NE DOIT PAS ETRE APPELE"* ]]
}

@test "siege : c'est la ligne forge_id=1, pas la premiere ligne du fichier" {
  # La table est append-only et le convergeur y ecrit ses humains ; rien ne garantit l'ordre.
  printf '7\t1007\tautre\n1\t1000\tzoe\n' > "$MAP"
  seat_sh 'resolve_admiral; echo "SIEGE=$LCARS_ADMIRAL"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"SIEGE=zoe"* ]]
}

@test "siege : sans table, il se DERIVE du #1 de la forge — et s'enregistre au format du convergeur" {
  printf 'jeton\n' > "$TOKF"
  FORGE_BASE_URL="http://forge:3000" \
  seat_sh 'curl() { printf "%s" "[{\"id\":2,\"login\":\"bob\"},{\"id\":1,\"login\":\"lordzurp\"}]"; }
           resolve_admiral; echo "SIEGE=$LCARS_ADMIRAL"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"SIEGE=lordzurp"* ]]
  # ENREGISTRE, et dans le format de la table du convergeur : <forge_id>\t<uid>\t<login>
  run cat "$MAP"
  [ "$output" = "$(printf '1\t1000\tlordzurp')" ]
}

@test "siege : le #1 est resolu par son ID, jamais par son rang ni par son nom" {
  # ⚠ L'`id` de Gitea ne bouge PAS au renommage ; le login, si. Ce temoin porte les deux pieges a la
  # fois : `admiral` est PREMIER dans la liste et porte le nom de l'ancien defaut.
  printf 'jeton\n' > "$TOKF"
  FORGE_BASE_URL="http://forge:3000" \
  seat_sh 'curl() { printf "%s" "[{\"id\":7,\"login\":\"admiral\"},{\"id\":1,\"login\":\"renomme\"}]"; }
           resolve_admiral; echo "SIEGE=$LCARS_ADMIRAL"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"SIEGE=renomme"* ]]
}

@test "siege : ni semence, ni table, ni forge → REFUS, jamais un nom invente" {
  # C'est la branche qui remplace l'ancien defaut `admiral`. Un siege invente s'installe dans le
  # volume et survit a la cause qui l'a produit ; un refus se lit et se repare.
  seat_sh 'resolve_admiral; echo "SIEGE=${LCARS_ADMIRAL:-<vide>}"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"IMPOSSIBLE a determiner"* ]]
  [[ "$output" != *"SIEGE=admiral"* ]]
  # et rien n'a ete ecrit : un refus ne laisse pas de trace a demi
  [ ! -s "$MAP" ]
}

@test "siege : une forge MUETTE refuse aussi — elle ne fabrique pas un nom" {
  printf 'jeton\n' > "$TOKF"
  FORGE_BASE_URL="http://forge:3000" \
  seat_sh 'curl() { return 7; }
           resolve_admiral; echo "SIEGE=${LCARS_ADMIRAL:-<vide>}"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"forge muette"* ]]
  [[ "$output" != *"SIEGE=admiral"* ]]
}

@test "siege : LCARS_ADMIRAL est la SEMENCE du cas from-scratch, et elle s'enregistre" {
  # Le bench cree TOUT, forge comprise : il n'y a rien a deriver, donc il seme. C'est le seul
  # appelant legitime de cette variable (`bench-up.sh:353`).
  LCARS_ADMIRAL=admiral seat_sh 'curl() { echo "CURL NE DOIT PAS ETRE APPELE"; }
                                 resolve_admiral; echo "SIEGE=$LCARS_ADMIRAL"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"SIEGE=admiral"* ]]
  [[ "$output" == *"seme par l'appelant"* ]]
  [[ "$output" != *"CURL NE DOIT PAS ETRE APPELE"* ]]
  run cat "$MAP"
  [ "$output" = "$(printf '1\t1000\tadmiral')" ]
}

@test "siege : un nom ENREGISTRE n'est jamais re-ecrit — le home sur le disque fait foi" {
  # Le home du siege vit dans le volume SOUS SON NOM. Re-deriver au boot suivant laisserait un home
  # orphelin et un compte qui ne le retrouve pas.
  printf '1\t1000\tancien\n' > "$MAP"
  seat_sh 'resolve_admiral; prov_seat_record neuf 1000; echo "SIEGE=$LCARS_ADMIRAL"'
  [ "$status" -eq 0 ]
  run cat "$MAP"
  [ "$output" = "$(printf '1\t1000\tancien')" ]
}

@test "siege : la semence et la TABLE divergent -> REFUS, et le refus nomme les DEUX noms" {
  # LA QUATRIEME BRANCHE, celle qui n'existait dans aucun rail. Le home du siege vit sous UN des
  # deux noms : booter sous l'autre creerait un compte de plus et laisserait le premier orphelin.
  # Ce n'est meme pas une devinette qu'on refuse — c'est un desaccord qu'on CONSTATE.
  printf '1\t1000\tzoe\n' > "$MAP"
  LCARS_ADMIRAL=amiral seat_sh 'resolve_admiral; echo "SIEGE=${LCARS_ADMIRAL:-<vide>}"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"DIVERGENCE"* ]]
  [[ "$output" == *"amiral"* ]]
  [[ "$output" == *"zoe"* ]]
  # Et la table n'est PAS reecrite au passage : elle fait foi, c'est elle qui correspond au disque.
  [ "$(awk -F"\t" '$1 == 1 { print $3 }' "$MAP")" = zoe ]
}

@test "siege : la semence et la table qui S ACCORDENT ne refusent pas" {
  # Le pendant du precedent : sans lui, un refus pose sur toute semence passerait pour un succes.
  printf '1\t1000\tzoe\n' > "$MAP"
  LCARS_ADMIRAL=zoe seat_sh 'resolve_admiral; echo "SIEGE=$LCARS_ADMIRAL"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"SIEGE=zoe"* ]]
  [[ "$output" != *"DIVERGENCE"* ]]
}

@test "VERROU : aucun compose ne pose de defaut sur LCARS_ADMIRAL" {
  # ⚠ LE SEUL TEMOIN QUI AURAIT ATTRAPE LE DEFAUT REEL, et les huit ci-dessus ne le pouvaient pas :
  # ils appellent la fonction avec un decor qui EFFACE la variable. Le rail, lui, ne l'efface jamais
  # — les composes posaient `${LCARS_ADMIRAL:-admiral}`, donc la variable etait toujours definie
  # dans le conteneur, donc la premiere branche court-circuitait tout et la derivation ne
  # s'executait JAMAIS. Un temoin vert sur un chemin que le produit n'atteint pas.
  #
  # La semence n'a pas de defaut : elle vient d'un appelant qui la POSE, jamais d'un `:-`.
  local d="$BATS_TEST_DIRNAME/../docker"
  for f in "$d/docker-compose.yml" "$d/docker-compose.install.yml"; do
    [ -f "$f" ]
    run grep -c 'LCARS_ADMIRAL:-[^}]' "$f"
    [ "$output" = "0" ]
  done
}
