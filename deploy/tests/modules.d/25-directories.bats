#!/usr/bin/env bats
# SOURCE: deploy/tests/modules.d/25-directories.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-20
# STATUS: bats tests for 25-directories.sh — la racine des sockets de console, et sa survie au reboot
#
# CE QUE CES TEMOINS FERMENT. `Fleet.Observation` fait ecouter le deck sur
# `/run/lcars/console/<humain>/deck.sock`. Ce dossier n'etait cree que par `console.sh`, artefact de
# CONTENEUR, jamais joue par une install native. Sur le poste natif du 2026-08-20 : `provision
# apply` vert sur ses 14 modules, release posee, `fleet start` annoncant « fleet up » — et zero
# `beam.smp` une seconde plus tard, parce que Ranch n'avait pas pu binder :
#
#   [error] Failed to start Ranch listener … ip: {:local, "/run/lcars/console/lcars/deck.sock"}
#           … for reason :enoent (no such file or directory)
#
# `max_restarts: 0` au sommet : la mort d'un domaine tue le node. Le lanceur ne mentait pas, il
# rendait la main avant que le BEAM ne meure — c'est-a-dire que le SEUL endroit ou la panne se voit
# est le journal, et personne n'y va apres une commande qui a dit oui.
#
# ⚠ CES TEMOINS N'APPELLENT NI `check` NI `apply` EN ENTIER, et c'est delibere : les deux creent
# de vrais dossiers sous `/run`, ce qui demande root et sortirait du bac a sable. Ce qui se mesure
# ici est la TABLE (la donnee dont les deux modes derivent) et le poseur de la declaration
# tmpfiles — les seules parties ou une faute serait silencieuse.
#
# LOT 14 (⚖ user 2026-09-04, 17-DEUX-OUVERTS, solution A) : le stage `verify` de l'image joue ce
# module AU BUILD, sur `--substrate docker`. La table y est filtree par le substrat que le
# MANIFESTE declare (une seule source), et par les volumes du conteneur ; /run et tmpfiles n'y
# existent pas. Les temoins « docker : » ci-dessous jouent `check` pour de vrai, dans un decor.

load ../refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../modules.d/25-directories.sh"
  [ -f "$SRC" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=25-directories
  export PROV_HUMAN=temoin
  export PROV_FLEET_GROUP=fleet
  # ⚠ LE DECOR FIXE LE SUBSTRAT. Sans lui, le module retombe sur la sonde (`detect_substrate`), qui
  # repond `docker` dans le conteneur de la CI : la table runtime y serait VIDE et les temoins du
  # poste changeraient de forme selon la machine qui les joue. Les temoins docker le surchargent.
  export PROV_SUBSTRATE=linux
  # ⚠ LE DECOR POSSEDE L'HUMAIN DE FLEET, SINON IL MESURE LE /etc/passwd DE LA MACHINE. Le dossier
  # de console appartient a qui LANCE la fleet, et le module retombe sur `--human` seulement quand
  # cet humain n'existe pas encore. Sans cette ligne, le resultat depend de la presence d'un compte
  # `lcars` sur le poste qui joue les tests — vert ici, rouge ailleurs, pour un code identique.
  #
  # ⚠ ET LA COUTURE A CHANGE DE MAISON : le decor posait `PROV_FLEET_HUMAN`, la variable du drapeau
  # `--fleet-human`, retire. Le module interroge desormais l'AUTORITE du nom, et la seule facon
  # honnete de la piloter est sa propre surcharge — celle que `forge-gestures.sh` declare. Poser une
  # variable que le code ne lit plus aurait rendu ces temoins verts sur la machine du lanceur.
  LCARS_BUILTIN_HUMAN="$(id -un)"; export LCARS_BUILTIN_HUMAN
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  export PROV_CATALOGUES_DIR="$BATS_TEST_TMPDIR/catalogues"
  export PROV_CATALOGUES_WORK="$BATS_TEST_TMPDIR/catalogues-work"

  # Le decor possede son dossier runtime : `prov_lock_path` le veut, et un compte de service n'en a
  # pas (cf. le meme bloc dans provision_lib.bats — mesure du 2026-08-20).
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"

  # La declaration tmpfiles atterrit dans le bac a sable, jamais dans le /etc de qui joue les tests.
  export LCARS_TMPFILES_CONF="$BATS_TEST_TMPDIR/tmpfiles.d/lcars-console.conf"
  mkdir -p "$(dirname "$LCARS_TMPFILES_CONF")"

  # Le corps du module SANS son dispatch final : on appelle ses fonctions, on ne le lance pas.
  MOD="$BATS_TEST_TMPDIR/mod.sh"
  sed '/^case "${1:?usage/,$d' "$SRC" > "$MOD"
}

mod() { run bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; $1"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  run head -6 "$BATS_TEST_DIRNAME/../../modules.d/25-directories.sh"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
}

@test "substrat natif: la table porte la racine des sockets de console ET le dossier de l'humain" {
  PROV_SUBSTRATE=linux mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/run/lcars/console 0711 root:root"* ]]
  [[ "$output" == *"/run/lcars/console/$LCARS_BUILTIN_HUMAN 2710 $LCARS_BUILTIN_HUMAN:lcars-console"* ]]
  # Le parent aussi : sans lui, `install -d` du dossier de console echoue sur un /run nu.
  [[ "$output" == *"/run/lcars 0755 root:root"* ]]
}

@test "le dossier de console est celui de l'humain qui LANCE, pas de --human" {
  # Ce sont deux personnes differentes sur le rail poste : `--human` est l'OPERATEUR (uid 1000, le
  # siege), la fleet tourne sous l'humain de fleet. Le deck derive son chemin du `USER` du BEAM.
  #
  # Mesure du 2026-08-21, install a froid : `/run/lcars/console/lordzurp` cree, fleet lancee sous
  # `lcars`, node MORT au boot sur `:enoent`. Le meme echec que la veille, deplace d'un compte.
  PROV_SUBSTRATE=linux mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [[ "$output" != *"/run/lcars/console/temoin"* ]]
}

@test "humain de fleet PAS ENCORE la : repli sur --human, jamais aucune racine du tout" {
  # C'est le cas NOMINAL d'une install neuve, pas l'exotique : ce module joue au rang 25, la forge
  # seme le compte au rang 48 et le convergeur le materialise au rang 64. Sans repli, la machine
  # perdrait AUSSI sa racine de console — deux pannes pour une cause, et la seconde sans rapport
  # visible avec la premiere.
  PROV_SUBSTRATE=linux LCARS_BUILTIN_HUMAN="n-existe-pas-$$" mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/run/lcars/console/temoin 2710 temoin:lcars-console"* ]]
}

@test "le nom vient de l'AUTORITE, pas d'un litteral ni d'un drapeau" {
  # ⚠ CE RATTRAPAGE ETAIT MORT DANS LE CAS NOMINAL. La fonction lisait `PROV_FLEET_HUMAN`, pose par
  # `--fleet-human` : sans le drapeau elle rendait l'operateur IMMEDIATEMENT, y compris sur un
  # re-roll ou le compte existe depuis l'install precedente. La declaration tmpfiles — celle qui
  # survit au reboot — nommait donc le mauvais humain pour toujours, pendant que le commentaire
  # promettait que « le prochain apply corrigera ».
  #
  # On mesure les DEUX moities : le module demande le nom, et il n'en grave aucun.
  local code; code="$(sed 's/#.*//' "$SRC")"
  grep -q 'forge-gestures.sh" builtin-human' <<<"$code"
  run grep -cE 'PROV_FLEET_HUMAN|"lcars"|:-lcars\}' <<<"$code"
  [ "$output" = "0" ]
}

@test "le dossier de l'humain ne NOMME jamais un groupe homonyme — le groupe primaire est celui de la fleet" {
  # Meme faute que `chown <humain>:<humain>` corrigee le 2026-08-20 : un groupe au nom de l'humain
  # n'existe que la ou `USERGROUPS_ENAB yes` en a cree un. Ici le groupe est celui de la FLEET, qui
  # est declare par 20-groups.sh — donc il existe par construction. (Le groupe est `lcars-console`
  # depuis le 2026-08-21 : `fleet` porte deja la lecture de tout le runtime, et traverser un
  # repertoire n'a pas besoin de ca.)
  PROV_SUBSTRATE=linux mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [[ "$output" != *"temoin:temoin"* ]]
}

@test "MANIFESTE vs TABLE : mode et proprietaire s'accordent sur chaque repertoire runtime" {
  local manifest="$BATS_TEST_DIRNAME/../../system.manifest"
  [ -f "$manifest" ]
  PROV_SUBSTRATE=linux mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  local path mode owner m_mode m_owner row key want_owner bad=0 n=0
  while read -r path mode owner; do
    [[ -n "$path" ]] || continue
    # Le manifeste ecrit le dossier de l'humain avec un joker ; la table rend le nom reel.
    key="$path"; want_owner="$owner"
    if [[ "$path" == /run/lcars/console/* ]]; then
      key="/run/lcars/console/<human>"
      want_owner="<human>:${owner#*:}"
    fi
    row="$(awk -v p="$key" '{c=$1;sub(/:.*/,"",c)} c=="runtime" && $2==p {print; exit}' "$manifest")"
    [[ -n "$row" ]] || { echo "DANS LA TABLE, PAS AU MANIFESTE : $path"; bad=1; continue; }
    m_mode="$(awk '{print $3}' <<<"$row")"
    m_owner="$(awk '{print $4}' <<<"$row")"
    n=$((n + 1))
    [[ "${m_mode#0}" == "${mode#0}" ]] \
      || { echo "MODE : $path — manifeste $m_mode, table $mode"; bad=1; }
    [[ "$m_owner" == "$want_owner" ]] \
      || { echo "OWNER : $path — manifeste $m_owner, table $want_owner"; bad=1; }
  done <<<"$output"

  # ⚠ GARDE DE POPULATION : zero ligne comparee et zero desaccord rendent le meme vert. Sans elle,
  # un `prov_runtime_dirs` qui rendrait vide ferait passer ce temoin pour un accord parfait.
  [ "$n" -ge 5 ] || { echo "seulement $n lignes comparees — le decor ne rend pas la table"; return 1; }
  [ "$bad" -eq 0 ]
}

@test "la declaration tmpfiles est DERIVEE de la table — une seule source, pas deux" {
  PROV_SUBSTRATE=linux mod 'prov_tmpfiles_body'
  [ "$status" -eq 0 ]
  [[ "$output" == *"d /run/lcars/console 0711 root root -"* ]]
  [[ "$output" == *"d /run/lcars/console/$LCARS_BUILTIN_HUMAN 2710 $LCARS_BUILTIN_HUMAN lcars-console -"* ]]
  # Autant de lignes `d ` que d'entrees dans la table : une entree ajoutee a la table arrive ici
  # sans geste, et une entree qui n'y est pas ne peut pas y apparaitre.
  PROV_SUBSTRATE=linux mod 'prov_tmpfiles_body | grep -c "^d "'
  [ "$output" = "$(PROV_SUBSTRATE=linux bash -c "source '$MOD' >/dev/null 2>&1; prov_runtime_dirs | wc -l" | tr -d ' ')" ]
}

@test "apply pose la declaration, et check la voit" {
  PROV_SUBSTRATE=linux mod 'apply_tmpfiles'
  [ "$status" -eq 0 ]
  [ -f "$LCARS_TMPFILES_CONF" ]
  [[ "$(stat -c %a "$LCARS_TMPFILES_CONF")" == "644" ]]

  PROV_SUBSTRATE=linux mod 'check_tmpfiles'
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "declaration ABSENTE = drift, et le drift dit la CONSEQUENCE (la fleet ne demarrera pas)" {
  # Le motif importe plus que le fait : « un fichier manque » n'apprend rien, « au reboot la fleet
  # ne demarrera pas » designe ce qu'on perd. /run est un tmpfs, donc l'absence ne se paie pas
  # aujourd'hui — elle se paie des jours plus tard, au premier redemarrage de la machine.
  PROV_SUBSTRATE=linux mod 'check_tmpfiles'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT"* || "$output" == *"drift"* ]]
  [[ "$output" == *"reboot"* ]]
}

@test "declaration PERIMEE = drift — un contenu qui ne suit plus la table ment au boot" {
  printf 'd /run/quelque-part-dautre 0755 root root -\n' > "$LCARS_TMPFILES_CONF"
  PROV_SUBSTRATE=linux mod 'check_tmpfiles'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ne correspond plus"* ]]
}

@test "une entree en echec n'arrete pas la table : les suivantes sont posees quand meme" {
  # `/proc/...` ne peut pas etre cree, a coup sur et sans droits speciaux : la premiere entree
  # echoue pour de vrai, pas par un stub.
  local bonne="$BATS_TEST_TMPDIR/apres"
  run bash -c "set -uo pipefail
    source '$MOD' >/dev/null 2>&1
    prov_dirs() { printf '%s\n' '/proc/impossible-a-creer 0700 root:root' '$bonne 0755 $(id -un):$(id -gn)'; }
    apply_tmpfiles() { :; }
    apply"

  # MOITIE 1 : l'entree d'APRES est posee. Sans le correctif, la boucle mourait sur la premiere.
  [ -d "$bonne" ] || { echo "la table s'est arretee a la premiere entree en echec" >&2; return 1; }
  # MOITIE 2 : et le module rend quand meme un echec.
  [ "$status" -ne 0 ] || { echo "un module en echec a rendu 0 — le correctif a avale le verdict" >&2; return 1; }
}

@test "une table SANS echec rend toujours 0 — le correctif n'a pas rendu l'echec permanent" {
  # LE TEMOIN DU TEMOIN. Sans lui, un module qui echouerait TOUJOURS passerait celui du dessus — il
  # ne demande qu'un statut non nul — et chaque install serait rouge sur une machine saine.
  local a="$BATS_TEST_TMPDIR/ok-a" b="$BATS_TEST_TMPDIR/ok-b"
  run bash -c "set -uo pipefail
    source '$MOD' >/dev/null 2>&1
    prov_dirs() { printf '%s\n' '$a 0755 $(id -un):$(id -gn)' '$b 0755 $(id -un):$(id -gn)'; }
    apply_tmpfiles() { :; }
    apply"
  [ "$status" -eq 0 ]
  [ -d "$a" ]
  [ -d "$b" ]
}

@test "le compteur de changement VOIT l'ecriture du tmpfiles — write_atomic ne tourne plus dans un pipe" {
  # `printf … | write_atomic` : le dernier element d'un pipeline est un sous-shell, `PROV_CHANGED`
  # y etait incremente puis perdu. Le fichier etait ecrit, l'apply disait « rien change ». Le mur
  # I1bis (idiom_walls.bats) interdit la forme ; ce temoin pinne le compteur.
  PROV_SUBSTRATE=linux mod 'PROV_CHANGED=0; apply_tmpfiles; echo "changed=$PROV_CHANGED"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed=1"* ]]
}

# ─── LOT 14 : SUR DOCKER, LE MODULE MESURE CE QUE L'IMAGE POSE — ET RIEN D'AUTRE ────────────────
#
# Le decor : un manifeste de DECOR (la seule source du substrat), une racine `PROV_ROOT` sous le bac
# a sable (donc un « volume » `$PROV_ROOT/var` de decor), et une table de quatre entrees qui portent
# chacune un cas — declaree `any`, declaree `wsl+linux`, sur un volume, inconnue du manifeste.
# `check` est joue POUR DE VRAI : il ne fait que des `stat`, aucun droit n'est requis.

docker_decor() {
  export LCARS_SYSTEM_MANIFEST="$BATS_TEST_TMPDIR/system.manifest"
  export PROV_ROOT="$BATS_TEST_TMPDIR/root"
  ME="$(id -un):$(id -gn)"
  D_ANY="$PROV_ROOT/pose-par-l-image"
  D_POSTE="$PROV_ROOT/poste-seulement"
  D_VOL="$PROV_ROOT/var/tokens"
  D_INCONNU="$PROV_ROOT/inconnu-du-manifeste"
  cat > "$LCARS_SYSTEM_MANIFEST" <<EOF
# un manifeste de decor : classe, objet, mode, proprietaire, substrat
dir  $D_ANY    0755  $ME  any
dir  $D_POSTE  0755  $ME  wsl+linux
dir  $D_VOL    0710  $ME  any
EOF
  mkdir -p "$D_ANY" "$D_POSTE" "$D_VOL" "$D_INCONNU"
  chmod 0755 "$D_ANY" "$D_POSTE" "$D_INCONNU"; chmod 0710 "$D_VOL"
  TABLE="printf '%s\n' '$D_ANY 0755 $ME' '$D_POSTE 0755 $ME' '$D_VOL 0710 $ME' '$D_INCONNU 0755 $ME'"
}

# check_on <substrat> : joue `check` sur la table de decor, sous ce substrat
check_on() {
  run env PROV_SUBSTRATE="$1" bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; prov_dirs() { $TABLE; }; check"
}

@test "docker : la table runtime est VIDE — /run est un fait de boot, et il n'y a pas de tmpfiles a declarer" {
  PROV_SUBSTRATE=docker mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  PROV_SUBSTRATE=docker mod 'prov_dirs'
  [ "$status" -eq 0 ]
  refute_out '^/run/' <<<"$output"
  # et `runtime_dirs_declared` le dit a `check_tmpfiles` : « ce substrat ne le porte pas »
  PROV_SUBSTRATE=docker mod 'runtime_dirs_declared'
  [ "$status" -ne 0 ]
  # ⚠ GARDE DU TEMOIN : la meme table, sur le poste, n'est PAS vide — un `return 0` inconditionnel
  # passerait les trois lignes du dessus.
  PROV_SUBSTRATE=linux mod 'prov_runtime_dirs | grep -c "^/run/"'
  [ "$output" -ge 5 ]
}

@test "docker : sans declaration tmpfiles, check_tmpfiles ne dit RIEN ; avec une, c'est un drift nomme" {
  PROV_SUBSTRATE=docker mod 'check_tmpfiles'
  [ "$status" -eq 0 ]
  refute_out -i 'drift' <<<"$output"
  printf 'd /run/lcars/console 0711 root root -\n' > "$LCARS_TMPFILES_CONF"
  PROV_SUBSTRATE=docker mod 'check_tmpfiles; echo "drift=$PROV_DRIFT"'
  [[ "$output" == *"ne le porte pas"* ]]
  [[ "$output" == *"drift=1"* ]]
}

@test "docker : une entree any avec un mauvais mode est un DRIFT NOMME — l'instrument est stat, pas -r" {
  docker_decor
  chmod 0700 "$D_ANY"
  check_on docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"$D_ANY : 700 $ME ≠ 755 $ME"* ]]
  # repare, le verdict revient a 0 : le drift etait celui-la et pas un autre
  chmod 0755 "$D_ANY"
  check_on docker
  [ "$status" -eq 0 ]
}

@test "docker : une entree wsl+linux n est PAS mesuree — meme absente, meme fausse — et le module le DIT" {
  docker_decor
  chmod 0700 "$D_POSTE"
  check_on docker
  [ "$status" -eq 0 ]
  refute_out -- "$D_POSTE : " <<<"$output"
  rm -rf "$D_POSTE"
  check_on docker
  [ "$status" -eq 0 ]
  refute_out -- "$D_POSTE absent" <<<"$output"
  [[ "$output" == *"hors substrat docker"*"$D_POSTE"* ]]
}

@test "docker : une entree sur un VOLUME du conteneur n'a pas de verite au build — non mesuree, et DITE" {
  docker_decor
  rm -rf "$D_VOL"
  check_on docker
  [ "$status" -eq 0 ]
  refute_out -- "$D_VOL absent" <<<"$output"
  [[ "$output" == *"volume du conteneur"*"$D_VOL"* ]]
}

@test "docker : une entree que le manifeste NE CONNAIT PAS se mesure quand meme — un absent nomme au build vaut mieux qu'un silence" {
  docker_decor
  rm -rf "$D_INCONNU"
  check_on docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"$D_INCONNU absent"* ]]
}

@test "poste : le meme decor, tout se mesure — l'entree wsl+linux ET celle du volume, et rien n'est dit hors mesure" {
  # Le filtre docker ne fuit pas sur le poste : `wsl+linux` y est chez lui, et un volume n'y existe pas.
  docker_decor
  chmod 0700 "$D_POSTE"; rm -rf "$D_VOL"
  check_on linux
  [ "$status" -eq 1 ]
  [[ "$output" == *"$D_POSTE : 700 $ME ≠ 755 $ME"* ]]
  [[ "$output" == *"$D_VOL absent"* ]]
  refute_out 'hors substrat|volume du conteneur' <<<"$output"
}

@test "le substrat d'une entree vient du MANIFESTE, et de lui seul — la table du module n'en porte aucune colonne" {
  local code; code="$(sed 's/#.*//' "$SRC")"
  grep -q 'prov_manifest_substrate' <<<"$code"
  grep -q '^prov_manifest_substrate()' "$PROVISION_LIB"
  # aucune colonne substrat dans la table : chaque entree de prov_dirs a exactement trois champs
  local liste n_lignes n_trois
  liste="$(sed -n '/^prov_dirs()/,/^}$/p' "$SRC" | grep -E '^\s+"[^"]+" *\\?$' | tr -d '"\\')"
  n_lignes="$(grep -c . <<<"$liste")"
  n_trois="$(awk 'NF==3' <<<"$liste" | grep -c .)"
  [ "$n_lignes" -ge 10 ]
  [ "$n_lignes" -eq "$n_trois" ]
  refute grep -qE 'wsl\+linux|wsl linux' <<<"$code"
}

@test "MANIFESTE vs TABLE : les repertoires DURABLES aussi — chaque entree de prov_dirs est declaree, meme mode, meme proprietaire" {
  # Le pendant du temoin runtime ci-dessus, et ce qui rend sur le filtre par le manifeste : une entree
  # que la table ne connait pas se mesure partout (au build, un absent nomme). Ce temoin garantit que
  # ce cas ne se produit sur AUCUNE entree reelle. Les defauts de la lib sont ceux du poste — le decor
  # de `setup` deplace trois racines dans le bac a sable, on les rend ici.
  local manifest="$BATS_TEST_DIRNAME/../../system.manifest"
  run env -u PROV_TOKENS_DIR -u PROV_CATALOGUES_DIR -u PROV_CATALOGUES_WORK PROV_SUBSTRATE=linux \
    bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; prov_dirs"
  [ "$status" -eq 0 ]
  local path mode owner row bad=0 n=0
  while read -r path mode owner; do
    [[ -n "$path" && "$path" != /run/* ]] || continue
    row="$(awk -v p="$path" '{c=$1;sub(/:.*/,"",c)} (c=="dir"||c=="prefix"||c=="preserve") && $2==p {print $3, $4; exit}' "$manifest")"
    [[ -n "$row" ]] || { echo "DANS LA TABLE, PAS AU MANIFESTE : $path"; bad=1; continue; }
    n=$((n + 1))
    [ "$row" = "$mode $owner" ] || { echo "$path — manifeste « $row », table « $mode $owner »"; bad=1; }
  done <<<"$output"
  [ "$n" -ge 12 ] || { echo "seulement $n lignes comparees — le decor ne rend pas la table"; return 1; }
  [ "$bad" -eq 0 ]
}

@test "les volumes que le module ecarte au build sont ceux que le Dockerfile declare VOLUME — deux ecritures, une valeur" {
  local df="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  local declares; declares="$(grep -E '^VOLUME ' "$df" | tr -d '[]",' | sed 's/^VOLUME //' | tr ' ' '\n' | sort)"
  [ -n "$declares" ]
  run env -u PROV_ROOT bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; prov_container_volumes | sort"
  [ "$status" -eq 0 ]
  [ "$output" = "$declares" ]
}
