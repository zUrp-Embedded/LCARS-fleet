#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/store_volumes.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: bats tests for the STORE — what survives a destruction, and what says so
#
# WHY THIS EXISTS, AND IT IS NOT HYPOTHETICAL. The store was declared with TWO volumes for FIVE
# declared paths, and the defect was found by a human reader, not by a test:
#
#   - the volume was named `lcars-toolchain` and the path is `toolchains/` — ONE character, and the
#     artefact that costs three hours of CPU lands NEXT TO its own volume, on the container layer,
#     where the next rebuild takes it;
#   - `sysroots/` had no volume at all;
#   - `env.d/` and `egress.d/` had none either — and losing those costs NOTHING VISIBLE: the
#     toolchain stays, the pod simply stops seeing it, the install reports green and the build
#     fails with nothing linking the two symptoms.
#
# So the contract under test is not "a volume exists". It is: EVERY path the store mounts is backed
# by an external volume, and no mount silently falls through to the container layer. That is a
# structural property of the compose files, and it is checked by reading them.
#
# WHAT IS PROVEN HERE: the declared names, that every store mount is external, that the two compose
# files agree, and that both destruction gestures NAME what they spare. WHAT IS NOT: that docker
# actually spares them — that is docker's behaviour, measured live on 2026-08-19 (marker written in
# `lcars-toolchains`, `-p storetest down -v`, project volume destroyed, the four externals and the
# marker intact) and recorded in `docker-compose.yml`. A stub cannot answer for it.

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

load refute

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/.."
  STORE_LIB="$DEPLOY/lib/store.sh"
  COMPOSE="$DEPLOY/docker/docker-compose.yml"
  COMPOSE_INSTALL="$DEPLOY/docker/docker-compose.install.yml"
  # shellcheck source=../lib/store.sh
  source "$STORE_LIB"
  # Le prefixe est EXIGE par la lib (aucun defaut, pour que deux installations ne puissent pas
  # retomber sur le meme magasin). Les temoins s'en donnent un, arbitraire.
  export LCARS_STORE_PREFIX="testproj"
}

# Les montages du magasin declares dans un compose : « <clef>:<chemin> » sous `/var/lib/lcars`.
# ⚠ LA CLEF LOCALE, PAS LE NOM REEL. Un volume `external` porte deux identites : la clef que le
# service monte (`lcars-cache`, interne au fichier) et le `name:` que docker voit
# (`<projet>-cache`). Ce qui se lit sur une ligne de montage est toujours la premiere.
store_mounts() { grep -oE '^\s*- lcars-[a-z]+:/var/lib/lcars/[a-z.]+' "$1" | sed 's/^\s*- //'; }

@test "chaque nature declaree par store.sh est montee par le compose — aucun orphelin" {
  local nature
  for nature in "${LCARS_STORE_TREES[@]}"; do
    grep -q "^\s*- lcars-${nature}:/var/lib/lcars/${nature}\$" "$COMPOSE" \
      || { echo "nature declaree et JAMAIS montee : $nature"; return 1; }
  done
}

@test "REGRESSION — le nom REEL porte le projet : deux installations ne partagent AUCUN volume" {
  # ⚠ LE DEFAUT QUE CE TEMOIN GARDE, ET IL A ETE LIVRE. `external: true` sort le volume du projet
  # DANS LES DEUX SENS : compose ne le detruit pas, et ne le prefixe pas. Les quatre volumes
  # s'appelaient donc `lcars-cache` etc. pour TOUTE LA MACHINE — une prod et un test cote a cote
  # (le cas meme que docker sert) partageaient leur magasin, et jouer avec le test vidait la prod.
  local a b
  a="$(LCARS_STORE_PREFIX=prod store_volume_names | sort)"
  b="$(LCARS_STORE_PREFIX=test store_volume_names | sort)"
  [ -n "$a" ]
  [ "$a" != "$b" ]
  # Disjoints, pas seulement differents : une seule collision suffit a faire le degat.
  [ -z "$(comm -12 <(printf '%s\n' "$a") <(printf '%s\n' "$b"))" ]
}

@test "le prefixe n'a AUCUN defaut — sans lui, la derivation refuse au lieu de retomber sur un nom nu" {
  # Un `:-lcars` ici ressusciterait le defaut par commodite : deux installations mal cablees
  # retomberaient sur les memes noms, et rien ne le dirait.
  unset LCARS_STORE_PREFIX
  run store_volume_names
  [ "$status" -ne 0 ]
  [[ "$output" == *"LCARS_STORE_PREFIX"* ]]
  # RIEN d'ecrit : une liste partielle ferait croire a un appelant qui detruit qu'il a fini.
  [[ "$output" != *"-cache"* ]]
}

@test "prefixe absent : les deux gestes ECHOUENT — jamais un succes muet sur un magasin fantome" {
  # ⚠ LE PIEGE ETAIT DANS LA FORME DE LA BOUCLE, PAS DANS LE GARDE. `while read … < <(f)` JETTE le
  # code de retour de `f` : zero ligne lue, corps jamais execute, `rc` reste 0. Les deux gestes
  # rendaient donc un SUCCES sans avoir touche un seul volume — « magasin pose » sur rien, et
  # « magasin detruit » sur rien, ce qui est le pire des deux.
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  local calls="$BATS_TEST_TMPDIR/calls"; : > "$calls"
  printf '#!/usr/bin/env bash\necho "$*" >> %s\nexit 0\n' "$calls" > "$bin/dockerstub"
  chmod 0755 "$bin/dockerstub"

  unset LCARS_STORE_PREFIX
  run store_ensure_volumes "$bin/dockerstub"
  [ "$status" -ne 0 ]
  run store_destroy_volumes "$bin/dockerstub"
  [ "$status" -ne 0 ]
  # Et docker n'a JAMAIS ete appele : refuser, ce n'est pas agir a moitie.
  [ ! -s "$calls" ]
}

@test "les deux compose EXIGENT le prefixe — un up sans lui est refuse, jamais silencieux" {
  # `:?` et non `:-` : c'est la moitie compose du temoin precedent. Sans elle, la lib refuserait de
  # creer pendant que le compose monterait joyeusement un nom nu.
  local f
  for f in "$COMPOSE" "$COMPOSE_INSTALL"; do
    [ "$(grep -c 'LCARS_STORE_PREFIX:?' "$f")" -eq 4 ] \
      || { echo "les 4 volumes de $f n'exigent pas tous le prefixe"; return 1; }
  done
}

@test "REGRESSION — chaque montage du magasin a son volume EXTERNE, aucun ne tombe sur la couche conteneur" {
  # LE TEMOIN QUI MANQUAIT. Un montage dont le volume n'est pas declare `external: true` est cree
  # par compose, prefixe par le projet, et EMPORTE par `down -v` — silencieusement. C'est le
  # defaut qui a mis `toolchains/` a cote de `lcars-toolchain`.
  local mount vol
  while read -r mount; do
    [[ -n "$mount" ]] || continue
    vol="${mount%%:*}"
    grep -A 2 "^  ${vol}:\$" "$COMPOSE" | grep -q "external: true" \
      || { echo "monte mais PAS external (donc emporte par down -v) : $vol"; return 1; }
  done < <(store_mounts "$COMPOSE")
}

@test "les deux compose qui portent la boite montent EXACTEMENT le meme magasin" {
  # `docker-compose.install.yml` porte la meme boite que `docker-compose.yml` (le banc l'utilise).
  # Un magasin present d'un cote et pas de l'autre donnerait une install ou un banc qui perd ses
  # artefacts sans que rien ne le dise — et c'est le banc qui les fabrique.
  [ "$(store_mounts "$COMPOSE" | sort)" = "$(store_mounts "$COMPOSE_INSTALL" | sort)" ]
}

@test "le chemin du magasin est ecrit par les compose SEULS, jamais par un script" {
  # store.sh possede les NOMS, le compose possede le CHEMIN. Un `/var/lib/lcars` en dur dans un
  # script serait une seconde verite, et c'est celle qu'on ne relit pas qui derive.
  grep -q "LCARS_STORE_ROOT: /var/lib/lcars" "$COMPOSE"
  grep -q "LCARS_STORE_ROOT: /var/lib/lcars" "$COMPOSE_INSTALL"
  refute grep -q "/var/lib/lcars" "$STORE_LIB"
}

@test "store_ensure_volumes cree TOUS les volumes, et rejouer ne casse rien" {
  local calls="$BATS_TEST_TMPDIR/calls"; : > "$calls"
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\necho "$*" >> %s\nexit 0\n' "$calls" > "$bin/dockerstub"
  chmod 0755 "$bin/dockerstub"

  store_ensure_volumes "$bin/dockerstub"
  store_ensure_volumes "$bin/dockerstub"   # idempotent : `volume create` rend 0 sur un existant

  local vol
  while read -r vol; do
    grep -q "^volume create $vol\$" "$calls" || { echo "jamais cree : $vol"; return 1; }
  done < <(store_volume_names)
  # Et ce qu'il cree porte bien le prefixe — sinon il fabriquerait le magasin d'une autre install.
  grep -q "^volume create testproj-cache\$" "$calls"
}

@test "store_destroy_volumes n'efface QUE le magasin de son projet" {
  # ⚠ CE GESTE N'EXISTAIT PAS, ET C'EST LE PARTAGE QUI L'INTERDISAIT : detruire aurait vide les
  # voisins. La destruction se dictait donc a l'operateur en toutes lettres — une ligne qui, tapee,
  # emportait le magasin du banc d'a cote, en marche. Une ligne dictee est un geste quand meme.
  local calls="$BATS_TEST_TMPDIR/calls"; : > "$calls"
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\necho "$*" >> %s\nexit 0\n' "$calls" > "$bin/dockerstub"
  chmod 0755 "$bin/dockerstub"

  LCARS_STORE_PREFIX=banc2 store_destroy_volumes "$bin/dockerstub"

  [ "$(grep -c '^volume rm -f banc2-' "$calls")" -eq 4 ]
  # Le temoin qui compte : AUCUN nom nu, donc rien qui appartienne a une autre installation.
  refute grep -qE '^volume rm -f lcars-(cache|toolchains|sysroots|state)$' "$calls"
}

@test "store_ensure_volumes ECHOUE bruyamment quand docker refuse — jamais un up sur un magasin absent" {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/dockerko"; chmod 0755 "$bin/dockerko"
  run store_ensure_volumes "$bin/dockerko"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusera de demarrer"* ]]
}

@test "LA CONTREPARTIE — ce que \`box reset\` epargne, il le NOMME" {
  # Sans ca, « reset » se lit comme « la machine est propre » alors que des heures de toolchain
  # restent. Un effacement silencieux sur ce qu'il LAISSE est un mensonge par omission, et il ne se
  # decouvre qu'au moment ou quelqu'un purge un cache.
  run store_spared_line
  [ "$status" -eq 0 ]
  local vol
  while read -r vol; do
    [[ "$output" == *"$vol"* ]] || { echo "epargne mais NON NOMME : $vol"; return 1; }
  done < <(store_volume_names)
  # Et elle donne le geste qui les detruit vraiment : nommer sans dire comment est un demi-aveu.
  [[ "$output" == *"docker volume rm"* ]]
}

@test "les DEUX gestes de destruction, et ils ne font PAS la meme chose" {
  # ⚠ LA DISTINCTION EST LE FOND DU LOT, pas un detail d'implementation. Reinitialiser une BOITE
  # n'est pas jeter une INSTALLATION : le magasin lui survit, c'est tout son interet — `box reset`
  # epargne et le dit. Un BANC est jetable : le sien part avec lui, sinon le mot est faux.
  #
  # ⚠ ET LE TEMOIN GREPPE LE PORTEUR DU GESTE, PAS LA PORTE : un temoin reste sur un relais
  # passerait au vert sur un `reset` devenu muet — il mesurerait un fichier qui ne porte plus le
  # geste.
  grep -q "store_spared_line" "$DEPLOY/box"
  refute grep -q "store_spared_line" "$DEPLOY/docker/bench/bench-down.sh"
  grep -q "store_destroy_volumes" "$DEPLOY/docker/bench/bench-down.sh"
  refute grep -q "store_destroy_volumes" "$DEPLOY/box"
}

@test "tout appelant du magasin POSE le prefixe avant d'appeler compose ou la lib" {
  # Le prefixe n'a pas de defaut : un appelant qui l'oublie ne partage pas — il ECHOUE. Ce temoin
  # garde la moitie qu'un `:?` ne peut pas garder : qu'il soit pose, et pose au PROJET.
  local f
  for f in "$DEPLOY/box" "$DEPLOY/docker/bench/bench-up.sh" "$DEPLOY/docker/bench/bench-down.sh"; do
    grep -qE '^export LCARS_STORE_PREFIX="\$PROJECT"$' "$f" \
      || { echo "n'exporte pas le prefixe au nom du projet : $f"; return 1; }
  done
}

@test "les deux gestes qui montent la boite posent le magasin AVANT" {
  # `external: true` = compose refuse de demarrer sur un volume absent. L'appel doit donc preceder
  # le up/create, et ces deux scripts sont les seuls a s'executer avant.
  grep -q "store_ensure_volumes" "$DEPLOY/docker/bench/bench-up.sh"
  grep -q "store_ensure_volumes" "$DEPLOY/box"

  local up_line ensure_line
  ensure_line="$(grep -n "store_ensure_volumes" "$DEPLOY/box" | head -1 | cut -d: -f1)"
  up_line="$(grep -n "compose up -d" "$DEPLOY/box" | head -1 | cut -d: -f1)"
  [ "$ensure_line" -lt "$up_line" ]
}
