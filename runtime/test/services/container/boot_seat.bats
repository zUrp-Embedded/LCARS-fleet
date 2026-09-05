#!/usr/bin/env bats
# SOURCE: runtime/test/services/container/boot_seat.bats
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

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# ⚠ SC2030/SC2031 : CHAQUE `@test` DE BATS EST UN SOUS-SHELL, et c'est la propriete qu'on veut —
# un test ne teinte pas le suivant. Que les variables posees dans un test soient « locales » est
# l'isolation, pas une fuite.
# shellcheck disable=SC2016,SC2030,SC2031

load ../../support/refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../../services/container/boot.sh"
  [ -f "$SRC" ]
  # ⚠ LE DECOR POSSEDE L'ENVIRONNEMENT. Ce fichier lit `LCARS_ADMIRAL` et `FORGE_BASE_URL` : un
  # temoin qui les herite mesure la machine qui le lance, pas la regle.
  unset LCARS_ADMIRAL FORGE_BASE_URL LCARS_UID_MAP_FILE LCARS_MASTER_TOKEN_FILE
  # L'uid du siege et sa reservation : meme regle de decor. Les heriter ferait mesurer la machine
  # qui lance les temoins au lieu de la derivation.
  unset LCARS_UID LCARS_SYSADMIN_UID
  # ⚠ COUTURE OBLIGATOIRE : la tete de l'entrypoint ECRIT ce fichier au moment ou on la source.
  # Sans elle, ces temoins ecriraient dans le /etc/lcars de la machine qui les lance.
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/seat.uid"
  MAP="$BATS_TEST_TMPDIR/forge-uid.map"
  TOKF="$BATS_TEST_TMPDIR/forge-master.token"
  # LA TETE SEULE : tout ce qui precede l'etape 1. La resolution y vit, et ca evite d'embarquer le
  # `useradd`, qui exige root et n'est pas ce qu'on mesure.
  HEAD="$BATS_TEST_TMPDIR/head.sh"
  # La tete : les portes outil et la garde du siege — tout ce qui precede l'init de l'instance.
  sed '/^CONTAINER_INIT=/,$d' "$SRC" > "$HEAD"
}

seat_sh() { # seat_sh <corps> — joue la tete puis le corps, decor complet
  run env LCARS_UID_MAP_FILE="$MAP" LCARS_MASTER_TOKEN_FILE="$TOKF" \
          FORGE_BASE_URL="${FORGE_BASE_URL:-}" \
      bash -c 'source "$1" >/dev/null 2>&1; shift; eval "$@"' _ "$HEAD" "$1"
}

# ─── L'UID DU SIEGE : UN FAIT, UN NOM ──────────────────────────────────────────────────────────
#
# ⚠ IL Y AVAIT DEUX NOMS ET UN SEUL POSEUR. `LCARS_UID` est l'uid AUQUEL cet entrypoint cree le
# siege (`useradd -u`) ; `LCARS_SYSADMIN_UID` est celui que les gardes RESERVENT — GUARD B dans
# `bin/fleet`, son miroir dans `config/runtime.exs`, `is_fleet_human`, et le plancher `uid_floor`
# du convergeur. Rien ne posait le second dans la boite : ni le compose, ni ce fichier.
#
# LES DEUX DEFAUTS VALANT 1000, ILS S'ACCORDAIENT PAR COINCIDENCE — et le second temoin ci-dessous
# est le seul des deux qui aurait attrape le defaut : le premier passe aussi bien avant qu'apres.

@test "siege : LCARS_SYSADMIN_UID est POSE, pas laisse a la coincidence de deux defauts" {
  seat_sh 'echo "UID=$LCARS_UID SYSADMIN=$LCARS_SYSADMIN_UID"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"UID=1000 SYSADMIN=1000"* ]]
}

@test "siege : la garde SUIT l'uid du siege — le cas ou les deux defauts se separent" {
  # ⚠ LE TEMOIN QUI COMPTE. `LCARS_UID` est une molette documentee (`deploy/container`) : la tourner
  # creait le siege a 1005 pendant que GUARD B continuait de reserver 1000. admiral pouvait alors
  # lancer une fleet, et ses pods heritent de son uid sudo-capable — l'exact inverse de la sandbox
  # que la garde existe pour tenir.
  export LCARS_UID=1005
  seat_sh 'echo "UID=$LCARS_UID SYSADMIN=$LCARS_SYSADMIN_UID"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"UID=1005 SYSADMIN=1005"* ]]
}

# ─── LA DERIVATION DU SIEGE EST DU PRODUIT (lot 6) : `runtime/test/services/container/init_seat.bats` ───

@test "VERROU : aucun compose ne pose de defaut sur LCARS_ADMIRAL" {
  # ⚠ LE SEUL TEMOIN QUI AURAIT ATTRAPE LE DEFAUT REEL, et les huit ci-dessus ne le pouvaient pas :
  # ils appellent la fonction avec un decor qui EFFACE la variable. Le rail, lui, ne l'efface jamais
  # — les composes posaient `${LCARS_ADMIRAL:-admiral}`, donc la variable etait toujours definie
  # dans le conteneur, donc la premiere branche court-circuitait tout et la derivation ne
  # s'executait JAMAIS. Un temoin vert sur un chemin que le produit n'atteint pas.
  #
  # La semence n'a pas de defaut : elle vient d'un appelant qui la POSE, jamais d'un `:-`.
  local d="$BATS_TEST_DIRNAME/../../../../deploy/docker"
  for f in "$d/docker-compose.yml" "$d/docker-compose.install.yml"; do
    [ -f "$f" ]
    run grep -c 'LCARS_ADMIRAL:-[^}]' "$f"
    [ "$output" = "0" ]
  done
}

# ─── LE REFUS N'EMPORTE PLUS LE CONTENEUR ───────────────────────────────────────────────────────

@test "siege indeterminable : la boite RESTE DEBOUT — le remede qu'elle nomme exige un docker exec" {
  # ⚠ MESURE DE LA 4e FORME — boite + forge FOURNIE, sans `--bench` (.63, 2026-08-30). Le refus
  # etait `resolve_admiral || exit 1`, et sous `restart: unless-stopped` la boite BOUCLAIT :
  #     politique : unless-stopped (max 0) · redemarrages: 25
  # Or le geste que ce refus NOMME lui-meme — « container config » — passe par un `docker exec`, et
  # docker le refuse sur un conteneur qui redemarre :
  #     Container … is restarting, wait until the container is running
  # Le diagnostic etait juste, le remede nomme, et l'etat de la boite le rendait INJOUABLE.
  #
  # Le refus n'a pas bouge — un siege inventable ne s'invente toujours pas. Ce qui change, c'est
  # qu'il n'emporte plus le conteneur avec lui : meme arbitrage que pour l'echec de convergence,
  # « elle tourne et reste joignable POUR ETRE REPAREE ».
  local src="$BATS_TEST_DIRNAME/../../../services/container/boot.sh"
  local code; code="$(grep -vE '^\s*#' "$src")"
  # Lot 6 : la derivation est dans `container/init.sh seat` (rc 3 = indeterminable) ; l'entrypoint lit ce
  # code et reste debout.
  grep -qE '^\s*3\) say "boite EN ATTENTE DE CONFIGURATION' <<<"$code"
  grep -q 'exec sleep infinity' <<<"$code"
  # ⚠ CE COMMENTAIRE DISAIT « la negation s'ecrit `!`, terminale sous `set -e` », ET IL ETAIT FAUX
  # DEUX FOIS : cette ligne n'est pas terminale (une assertion la suit), et `!` est de toute facon
  # exempte d'`errexit` par POSIX. L'assertion s'executait, rendait 1, et bats passait a la suite —
  # verte au moment precis ou le `|| exit 1` qu'elle interdit serait revenu.
  refute grep -qE 'init\.sh" apply \|\| exit' <<<"$code"
  # ET ELLE DIT POURQUOI ELLE ATTEND : une boite muette debout serait pire qu'une boite qui boucle.
  grep -q 'EN ATTENTE DE CONFIGURATION' <<<"$code"
}
