#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/directories_runtime.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-20
# STATUS: bats tests for 25-directories.sh — la racine des sockets de console, et sa survie au reboot
#
# CE QUE CES TEMOINS FERMENT. `Fleet.Observation` fait ecouter le deck sur
# `/run/lcars/console/<humain>/deck.sock`. Ce dossier n'etait cree que par `console.sh`, artefact de
# CONTENEUR, jamais joue par une install native. Sur le poste natif du 2026-08-20 : `provision
# apply` vert sur ses 14 modules, release posee, `fleet_v2 start` annoncant « fleet up » — et zero
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

setup() {
  SRC="$BATS_TEST_DIRNAME/../modules.d/25-directories.sh"
  [ -f "$SRC" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export PROVISION_MODULE=25-directories
  export PROV_HUMAN=temoin
  export PROV_FLEET_GROUP=fleet
  # ⚠ LE DECOR POSSEDE L'HUMAIN DE FLEET, SINON IL MESURE LE /etc/passwd DE LA MACHINE. Le dossier
  # de console appartient a qui LANCE la fleet, et le module retombe sur `--human` seulement quand
  # cet humain n'existe pas encore. Sans cette ligne, le resultat depend de la presence d'un compte
  # `lcars` sur le poste qui joue les tests — vert ici, rouge ailleurs, pour un code identique.
  export PROV_FLEET_HUMAN="$(id -un)"
  export PROV_ADMIN_GROUP=fleet
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
  run head -6 "$BATS_TEST_DIRNAME/../modules.d/25-directories.sh"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
}

@test "substrat natif: la table porte la racine des sockets de console ET le dossier de l'humain" {
  PROV_SUBSTRATE=linux mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/run/lcars/console 0711 root:root"* ]]
  [[ "$output" == *"/run/lcars/console/$PROV_FLEET_HUMAN 2710 $PROV_FLEET_HUMAN:fleet"* ]]
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
  # `22-fleet-human` peut deriver (useradd refuse). Sans repli, la machine perdrait AUSSI sa racine
  # de console — deux pannes pour une cause, et la seconde sans rapport visible avec la premiere.
  PROV_SUBSTRATE=linux PROV_FLEET_HUMAN="n-existe-pas-$$" mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/run/lcars/console/temoin 2710 temoin:fleet"* ]]
}

@test "le dossier de l'humain ne NOMME jamais un groupe homonyme — le groupe primaire est celui de la fleet" {
  # Meme faute que `chown <humain>:<humain>` corrigee le 2026-08-20 : un groupe au nom de l'humain
  # n'existe que la ou `USERGROUPS_ENAB yes` en a cree un. Ici le groupe est celui de la FLEET, qui
  # est declare par 20-groups.sh — donc il existe par construction.
  PROV_SUBSTRATE=linux mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [[ "$output" != *"temoin:temoin"* ]]
}

@test "substrat docker: la table n'en porte AUCUN — console.sh les possede la-bas" {
  # Deux createurs avec deux groupes (`fleet` ici, `lcars-console` dans l'image) donneraient un
  # dossier dont le mode depend de qui a couru le premier — et `install -d` ne repose PAS le mode
  # d'un dossier existant, donc le desaccord serait SILENCIEUX.
  PROV_SUBSTRATE=docker mod 'prov_runtime_dirs | wc -l'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "la declaration tmpfiles est DERIVEE de la table — une seule source, pas deux" {
  PROV_SUBSTRATE=linux mod 'prov_tmpfiles_body'
  [ "$status" -eq 0 ]
  [[ "$output" == *"d /run/lcars/console 0711 root root -"* ]]
  [[ "$output" == *"d /run/lcars/console/$PROV_FLEET_HUMAN 2710 $PROV_FLEET_HUMAN fleet -"* ]]
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

@test "substrat docker: une declaration qui traine est RETIREE, pas laissee vivre" {
  # Un fichier tmpfiles qui decrit des dossiers dont ce module ne repond plus est un ordre donne au
  # boot par un composant qui a change d'avis. Cas reel : une boite provisionnee en natif puis
  # rebasculee en conteneur.
  printf 'd /run/lcars/console 0711 root root -\n' > "$LCARS_TMPFILES_CONF"
  PROV_SUBSTRATE=docker mod 'apply_tmpfiles'
  [ "$status" -eq 0 ]
  [ ! -e "$LCARS_TMPFILES_CONF" ]
  [[ "$output" == *"retiree"* ]]
}
