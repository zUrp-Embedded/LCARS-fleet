#!/usr/bin/env bats
# SOURCE: runtime/test/services/container/boot_gestes.bats
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: bats tests for container/boot.sh — la boucle des gestes de forge : son ordre, et ce qu'elle fait d'un code
#
# CE QUE CES TEMOINS FERMENT. Deux choses que le rail du poste tenait et pas celui-ci.
#
# L'ORDRE. Les roles a minter viennent des catalogues installes : sur un poste, le module des
# catalogues (50) precede celui des jetons (63). Le boot jouait `tokens` EN PREMIER, donc mintait
# sur le seul catalogue de la release, sans ceux que l'operateur a poses.
#
# LA MORT AVANT VERDICT. Un geste qui meurt sous `set -e` sort du code de la commande qui a echoue :
# 1 et 2 se lisent alors comme « echec » et « drift residuel », deux verdicts que personne n'a rendus.
# La garde du protocole (LCARS_MODULE_RUN) rend 3, et le boot doit le NOMMER — sinon le conteneur
# demarre en disant qu'un geste a derive la ou rien n'a ete conclu.
#
# ⚠ CES TEMOINS EXECUTENT LE BLOC REEL, extrait du fichier : un temoin de texte epinglerait
# l'orthographe de la boucle, pas ce qu'elle fait d'un code.

load ../../support/refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../../services/container/boot.sh"
  [ -f "$SRC" ]
  export LCARS_MODULE_PROTOCOL="$BATS_TEST_DIRNAME/../../../services/lib/module-protocol.sh"
  [ -f "$LCARS_MODULE_PROTOCOL" ]
  GESTES="$BATS_TEST_TMPDIR/forge.d"; mkdir -p "$GESTES"
  JOURNAL="$BATS_TEST_TMPDIR/journal"; : > "$JOURNAL"
  JOUES="$BATS_TEST_TMPDIR/joues"; : > "$JOUES"
  BLOC="$BATS_TEST_TMPDIR/bloc.sh"
  sed -n '/^for gesture in /,/^done$/p' "$SRC" > "$BLOC"
}

# geste <nom> <corps> — une doublure de geste, jouee par la boucle reelle
geste() {
  { printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
      ". \"\$LCARS_MODULE_PROTOCOL\"" \
      "echo \"$1\" >> '$JOUES'"
    printf '%s\n' "$2"
  } > "$GESTES/$1.sh"
  chmod 0755 "$GESTES/$1.sh"
}

tous_les_gestes() { # les quatre, chacun rendant son verdict
  local g
  for g in catalogues tokens ops-branch deck-oidc; do geste "$g" 'verdict_apply'; done
}

bloc() {
  run bash -c "
    set -euo pipefail
    say() { printf '%s\n' \"\$*\" >> '$JOURNAL'; }
    GESTES_DIR='$GESTES'
    MODULE_PROTOCOL='$LCARS_MODULE_PROTOCOL'
    LCARS_ADMIRAL=admiral
    prov_rc=0
    source '$BLOC'
    printf 'prov_rc=%s\n' \"\$prov_rc\" >> '$JOURNAL'"
}

@test "le bloc s'extrait, et il joue les quatre gestes — sinon les temoins suivants ne mesurent rien" {
  [ -s "$BLOC" ]
  grep -q 'forge.d' "$BLOC"
  tous_les_gestes
  bloc
  [ "$status" -eq 0 ] || { echo "$output"; cat "$JOURNAL"; return 1; }
  [ "$(wc -l < "$JOUES")" -eq 4 ]
}

@test "l'ordre est celui du poste : les catalogues AVANT les jetons, puis la branche ops et le client du deck" {
  tous_les_gestes
  bloc
  [ "$(tr '\n' ' ' < "$JOUES")" = "catalogues tokens ops-branch deck-oidc " ]
}

@test "un geste qui MEURT avant son verdict rend 3, et le boot le nomme — jamais « drift residuel »" {
  tous_les_gestes
  geste tokens 'false'
  bloc
  grep -q 'MORT avant de rendre son verdict' "$JOURNAL" || { cat "$JOURNAL"; return 1; }
  grep -q 'tokens' "$JOURNAL"
  refute grep -q 'drift residuel' "$JOURNAL"
  grep -q '^prov_rc=3$' "$JOURNAL"
  # la boucle continue : un geste mort n'emporte pas les suivants
  grep -q 'deck-oidc' "$JOUES"
}

@test "un drift residuel se dit comme tel et laisse le conteneur demarrer" {
  tous_les_gestes
  geste ops-branch 'LCARS_DRIFT=1; verdict_apply'
  bloc
  grep -q 'geste de forge « ops-branch » : drift residuel' "$JOURNAL"
  grep -q '^prov_rc=2$' "$JOURNAL"
}

@test "un echec ne se laisse pas effacer par un drift joue apres lui" {
  tous_les_gestes
  geste catalogues 'LCARS_FAILED=1; verdict_apply'
  geste deck-oidc 'LCARS_DRIFT=1; verdict_apply'
  bloc
  grep -q 'geste de forge « catalogues » : ECHEC (rc=1)' "$JOURNAL"
  grep -q '^prov_rc=1$' "$JOURNAL"
}

@test "une mort n'efface pas un echec deja rendu, ni l'inverse — le premier etat non conclusif tient" {
  tous_les_gestes
  geste catalogues 'LCARS_FAILED=1; verdict_apply'
  geste tokens 'false'
  bloc
  grep -q 'geste de forge « catalogues » : ECHEC (rc=1)' "$JOURNAL"
  grep -q 'geste de forge « tokens » : MORT avant' "$JOURNAL"
  grep -q '^prov_rc=1$' "$JOURNAL" || { cat "$JOURNAL"; return 1; }
}

# ─── L'INIT DE L'INSTANCE ──────────────────────────────────────────────────────────────────────
#
# Deux codes, deux conduites opposees pour le meme conteneur : 4 = « en attente de configuration »,
# le conteneur dort en attendant « container config » ; 3 = l'init est MORT sans rien conclure, et
# le conteneur reste debout pour etre LU. Les confondre ferait annoncer une attente de configuration
# sur un init qui a plante. Le bloc reel s'acheve sur `exec sleep infinity` : le temoin le borne.
init_bloc() { # init_bloc <rc de l'init>
  local ib="$BATS_TEST_TMPDIR/init.sh" bl="$BATS_TEST_TMPDIR/initbloc.sh"
  printf '%s\n' '#!/usr/bin/env bash' "exit $1" > "$ib"; chmod 0755 "$ib"
  { sed -n '/^etat_ecrit() {/,/^}/p' "$SRC"; sed -n '/^init_rc=0$/,/^esac$/p' "$SRC"; } > "$bl"
  [ -s "$bl" ]
  run timeout 5 bash -c "
    set -euo pipefail
    say() { printf '%s\n' \"\$*\" >> '$JOURNAL'; }
    CONTAINER_INIT='$ib'
    MODULE_PROTOCOL='$LCARS_MODULE_PROTOCOL'
    LCARS_BOOT_STATE_FILE='$BATS_TEST_TMPDIR/boot.state'
    source '$bl'"
}

@test "init en attente de configuration (4) : le conteneur dort, et l'etat publie le dit" {
  init_bloc 4
  [ "$status" -eq 124 ]   # `exec sleep infinity`, borne par le temoin
  grep -q 'EN ATTENTE DE CONFIGURATION' "$JOURNAL"
  [ "$(cat "$BATS_TEST_TMPDIR/boot.state")" = awaiting-config ]
}

@test "init MORT avant verdict (3) : ce n'est PAS une attente de configuration, et l'etat publie ne ment pas" {
  init_bloc 3
  [ "$status" -eq 124 ]
  grep -q 'MORT avant de rendre son verdict' "$JOURNAL" || { cat "$JOURNAL"; return 1; }
  refute grep -q 'EN ATTENTE DE CONFIGURATION' "$JOURNAL"
  [ "$(cat "$BATS_TEST_TMPDIR/boot.state")" = init-failed ]
}

@test "init en drift (2) : le boot continue, rien ne dort" {
  init_bloc 2
  [ "$status" -eq 0 ] || { echo "$output"; cat "$JOURNAL"; return 1; }
  grep -q 'DRIFT RESIDUEL' "$JOURNAL"
}

# ⚠ UN VERDICT QUI NE SE PUBLIE PAS EST UN VERDICT QUI MENT PAR OMISSION : « container status » lit
# alors l'état du boot précédent et le prend pour le présent. Ce que le boot ne peut pas écrire, il
# le dit — et un MODE qui ne se pose pas n'est pas la même chose qu'un contenu qui ne s'écrit pas.
etat_bloc() { # etat_bloc <fichier> <contenu> [chemin d'un PATH doublé]
  run bash -c "
    set -euo pipefail
    ${3:+export PATH='$3:\$PATH'}
    say() { printf '%s\n' \"\$*\" >> '$JOURNAL'; }
    $(sed -n '/^etat_ecrit() {/,/^}/p' "$SRC")
    etat_ecrit '$1' '$2'"
}

@test "un verdict qu'on ne peut pas ecrire est DIT, et la fonction rend 1" {
  etat_bloc "$BATS_TEST_TMPDIR/nulle-part/forge.rc" 2
  [ "$status" -eq 1 ]
  grep -q 'verdict NON publie' "$JOURNAL" || { cat "$JOURNAL"; return 1; }
}

@test "un MODE qui ne se pose pas ne se dit PAS « non publie » : le fichier est juste, et le rc le dit" {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$bin/chmod"; chmod 0755 "$bin/chmod"
  etat_bloc "$BATS_TEST_TMPDIR/forge.rc" 2 "$bin"
  [ "$status" -eq 0 ] || { cat "$JOURNAL"; return 1; }
  [ "$(cat "$BATS_TEST_TMPDIR/forge.rc")" = 2 ]
  grep -q "mode n'a pas ete pose" "$JOURNAL" || { cat "$JOURNAL"; return 1; }
  refute grep -q 'verdict NON publie' "$JOURNAL"
}
