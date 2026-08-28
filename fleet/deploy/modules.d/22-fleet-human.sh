#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/22-fleet-human.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — l'humain de fleet du POSTE : la forge le sème, le convergeur le pose, CE MODULE ATTESTE
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
#
# ⚖ ARBITRAGE USER 2026-08-21 : « pourquoi, tout en étant loggé sur mon compte lordzurp, je pourrais
# pas avoir une fleet qui tourne sous UID 1001 ? la porte d'entrée de la fleet c'est le deck, et la
# porte d'entrée du deck c'est le login sur la forge. on garde UID=1000 comme admin avec fleet
# bloqué. »
#
# ─── CE QUE CE MODULE FERME ────────────────────────────────────────────────────────────────────
# Le rail poste installait un runtime que personne ne pouvait lancer, et il se contredisait en le
# faisant. Mesure du 2026-08-21, install à froid sur machine dédiée, humain = l'opérateur (uid 1000) :
#
#     POSÉ  20-groups:   lordzurp ∈ fleet
#     POSÉ  70-human:    ~/.lcars, ~/pods, env  →  pour lordzurp
#     OK    75-projects: lordzurp n'est pas un humain de fleet (compte systeme ou sysadmin)
#
# Deux modules le traitaient comme l'humain, un troisième le récusait — et GUARD B, dans
# `bin/fleet_v2`, applique la même règle que `is_fleet_human` : `uid >= UID_MIN` ET
# `uid != LCARS_SYSADMIN_UID` (défaut 1000). Or le premier utilisateur d'une Linux ou d'une WSL
# standard EST uid 1000. La règle « uid >= 1001 » n'était écrite que pour la BOÎTE (entrypoint,
# bench-up) ; le rail poste n'en avait aucune.
#
# ─── POURQUOI UN COMPTE SÉPARÉ N'EST PAS UNE GÊNE ──────────────────────────────────────────────
# L'opérateur n'a pas à ÊTRE l'humain de fleet. Il lance (`sudo -u <humain> fleet_v2 start`) et il
# ATTEINT le deck par le groupe : la socket est `0660` et son dossier `2710 <humain>:fleet`, donc
# tout membre du groupe l'ouvre. `Fleet.EventRouter.UnixListener` le dit dans son propre contrat —
# « the landing — a DIFFERENT uid holding the console group — must open it ». Son identité, à lui,
# c'est son compte de FORGE : le deck s'ouvre sur un login forge, pas sur un uid.
#
# ─── CE MODULE NE CRÉE PAS, ET IL NE NOMME PLUS NON PLUS ───────────────────────────────────────
# ⚖ QUESTION USER 2026-08-25, posée plusieurs fois : « pourquoi on n'utilise pas le convergeur pour
# créer les humains à l'install ? on crée l'humain sur la forge, et on fait tourner le convergeur.
# ya une bonne raison pour ne pas faire ça ? »
#
# Il n'y en avait pas. Ce module portait son propre `useradd`, et la boîte a le sien dans
# `human-converger.sh` : DEUX créateurs pour un même objet, donc deux jeux de règles d'uid, de shell
# et de groupe qui ne dérivent pas au même rythme. Le rail poste testait alors un chemin que la
# production n'emprunte jamais — l'inverse exact de ce qu'un poste de démo doit prouver.
#
# ⚠ ET IL A ENSUITE PASSÉ UN MOIS À « NOMMER », CE QUI N'ÉTAIT PAS UN GESTE. Le drapeau
# `--fleet-human` était présenté comme la validation par laquelle l'opérateur autorisait la création.
# Il n'autorisait rien : sans lui, `48-forge-host` semait quand même le compte intégré sous le défaut
# de `forge-gestures.sh`, et `64-services` le matérialisait. Le drapeau ne choisissait qu'un NOM, en
# concurrence avec une autorité qui en tenait déjà un — deux sources pour un fait, et quatre sites qui
# arbitraient entre elles chacun de son côté. Il est retiré. Le nom se DEMANDE :
# `fleet/services/forge-gestures.sh builtin-human`.
#
# CE QUE FAIT CE MODULE MAINTENANT : il ATTESTE. `48-forge-host` sème le compte sur la forge (la
# recette tofu l'ajoute déjà à la team `humans`), `64-services` déclenche le convergeur UNE FOIS en
# synchrone après l'avoir semé, et le compte unix apparaît par le SEUL chemin qui existe aussi en
# production. Un seul créateur, un seul jeu de règles, un seul endroit à corriger.
#
# ⚠ ET IL PORTE UNE ASSERTION QUE PERSONNE D'AUTRE NE PORTE : L'ADHÉSION AU GROUPE. `fleet_humans`
# (provision-lib) balaie `/etc/passwd` par plage d'uid — il répond « qui peut lancer une fleet », pas
# « qui pourra lire ce dont elle a besoin » — et le `usermod -aG` du convergeur est suivi d'un
# `|| true`, donc son échec est muet. Un humain de fleet hors du groupe démarre et ne lit ni
# `/home/private` ni `/local/LCARS_v2` : la fleet part, et échoue sur une traversée.
# `probe_fleet_humans` de `64-services` mesure la population ; celui-ci mesure ses DROITS.
#
# ⚠ ET LE PRÉ-SEMIS RESTE, PARCE QU'IL A UNE RAISON. ⚖ USER 2026-08-25 : « lcars, l'idée derrière,
# c'est de livrer out of the box un user "fleet enabled", par confort puisqu'on verrouille admin hors
# de la fleet. le poste/bench c'est pour la démo, le test, l'évaluation ou le dev, il faut que ça
# démarre directement. en prod (le mode boîte), on peut se passer de pré-seed un user (…) et
# l'inscription reste ouverte sur la forge, donc les users peuvent s'enrôler eux-mêmes. »
#
# D'où `APPLY-ON: wsl linux` : la boîte ne joue pas ce module, et n'a personne à attester. Le confort
# est pour le poste ; le mécanisme est le même partout.
#
# ⚠ IL DÉRIVE, IL N'ÉCHOUE PAS. Un compte absent n'est pas une machine cassée : c'est un geste qui
# manque, et tout le reste du provisionnement est déjà posé quand on arrive ici. Un échec ferait
# rendre 1 à l'apply entier — la faute exacte que `52-ops-branch` portait le même jour.
#
# Données : PROV_FLEET_GROUP · le nom de l'humain intégré, LU chez son autorité

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# ─── LE NOM VIENT DE SON AUTORITÉ, ET SON ABSENCE EST UN DÉFAUT D'INSTRUMENT ───────────────────
#
# ⚠ AUCUN LITTÉRAL ICI, ET C'EST LA RÈGLE QUI A COÛTÉ LE PLUS CHER SUR CE FAIT. Le nom du compte
# intégré est écrit à neuf endroits du dépôt ; `forge-gestures.sh` est le seul qui le DÉCLARE, et
# c'est celui que la recette consomme. Un `lcars` gravé ici resterait d'accord avec lui jusqu'au jour
# où l'un des deux bouge — et c'est celui qu'on ne relit pas qui gagne ce jour-là.
#
# ⚠ ET UN NOM ILLISIBLE N'EST PAS « PAS D'HUMAIN ». C'est « je ne peux pas mesurer », et les deux
# appellent des gestes opposés : l'un fait chercher un compte manquant, l'autre fait réparer l'arbre.
# On le dit comme un défaut d'instrument, jamais comme un verdict sur la machine.
FLEET_HUMAN="$(bash "$(repo_root)/fleet/services/forge-gestures.sh" builtin-human 2>/dev/null || true)"

# ─── LE MESSAGE EST PARTAGÉ, LE VERDICT NE L'EST JAMAIS ─────────────────────────────────────────
#
# ⚠ CETTE SÉPARATION EST LA CONTRAINTE DU HAUT DE FICHIER, ÉCRITE EN CODE, parce que les codes de
# sortie sont INVERSÉS entre les deux verbes :
#
#     check   0 conforme · 1 DRIFT          · 2 erreur de sonde
#     apply   0 convergé · 1 ÉCHEC          · 2 appliqué, drift résiduel
#
# L'assignation est justifiée VERBE PAR VERBE — chacun donne `1` à son mauvais résultat principal :
# l'échec pour un apply (la convention shell), la dérive pour une sonde. Le `2` d'apply a été AJOUTÉ
# parce qu'un module qui constatait une non-convergence rendait `0`, donc « tout convergé », sur une
# machine qui venait d'imprimer DRIFT (cf. `provision:38`).
#
# ⚠ ET RIEN N'AVAIT JAMAIS ÉCRIT LA CONTRAINTE EN TRAVERS. `apply()` faisait `{ check; return; }`, et
# `verdict_check` fait un `exit`, pas un `return` : le module sortait donc en `1` pendant un APPLY,
# et le runner — qui lit un apply — traduisait fidèlement « apply en echec … MORT avant de rendre
# son verdict ». Le module avait parfaitement rendu son verdict, dans le mauvais dialecte.
#
# ─── OBSERVER N'EST PAS JUGER ───────────────────────────────────────────────────────────────────
#
# Ce qui suit n'a donc pas de verdict : il DÉCRIT, chaque verbe conclut.
observe() {
  local uid
  if [[ -z "$FLEET_HUMAN" ]]; then
    p_drift "le nom de l'humain intégré est indéterminable — « fleet/services/forge-gestures.sh builtin-human » ne répond pas.
     Ce n'est pas un constat sur cette machine : c'est l'arbre du provisionnement qui est incomplet,
     et RIEN ici ne peut être mesuré tant qu'il l'est."
    return 0
  fi
  if ! uid="$(id -u -- "$FLEET_HUMAN" 2>/dev/null)"; then
    # ⚠ LE GESTE MANUEL RESTE PROPOSÉ (P-40), ET IL N'EST PAS UN DOUBLON DU RAIL. Le rail est le
    # chemin ; celui-ci est ce que l'opérateur peut taper quand le rail n'a pas abouti. Le retirer
    # au motif que « 48 et 64 s'en chargent » laisserait sans recours exactement celui pour qui ils
    # ne s'en sont pas chargés.
    p_drift "humain de fleet « $FLEET_HUMAN » absent — la forge pose son compte (48) et le convergeur le matérialise (64) ; « 64-services » vérifie avant de rendre la main.
     Si le rail n'a pas abouti, le geste à la main : « useradd -m -G $PROV_FLEET_GROUP $FLEET_HUMAN »"
    return 0
  fi
  if is_fleet_human "$FLEET_HUMAN"; then
    p_ok "humain de fleet « $FLEET_HUMAN » (uid $uid) — il peut lancer la fleet"
  else
    # Le cas se produit si quelqu'un a créé le compte à la main sur l'uid du siège. On le DIT plutôt
    # que de le déplacer : changer l'uid d'un compte existant orphelinerait tout ce qu'il possède.
    p_drift "« $FLEET_HUMAN » existe en uid $uid, que GUARD B refuse (siège ou compte système) — la fleet ne démarrera pas sous lui"
  fi
  if id -nG "$FLEET_HUMAN" 2>/dev/null | tr ' ' '\n' | grep -qx "$PROV_FLEET_GROUP"; then
    p_ok "« $FLEET_HUMAN » ∈ $PROV_FLEET_GROUP"
  else
    p_drift "« $FLEET_HUMAN » hors du groupe $PROV_FLEET_GROUP — il ne lira ni /home/private ni les zones de face"
  fi
}

# UNE SONDE JUGE LA MACHINE MAINTENANT. Un compte absent est ici une vraie dérive : `check` se joue
# APRÈS l'install, quand 48 et 64 sont passés.
check() { observe; verdict_check; }

apply() {
  # ⚠ UN APPLY NE DÉRIVE PAS SUR UN COMPTE QUI N'EST PAS ENCORE DÛ. Au rang 22 d'une install neuve
  # le compte est TOUJOURS absent — 48 le sème, 64 le matérialise et le VÉRIFIE. Le signaler ici
  # ferait imprimer une dérive à chaque install sur un état parfaitement nominal, et une dérive qui
  # sort toujours n'est plus lue. La sonde, elle, le compte comme une dérive : elle se joue après.
  #
  # ⚠ ET `verdict_apply`, JAMAIS `check` — cf. les deux dialectes ci-dessus. Déléguer faisait sortir
  # ce module avec le code d'un CHECK pendant un APPLY, et le runner lisait « échec » sur une dérive
  # parfaitement nommée.
  # ⚠ DRIFT ET PAS `p_fail`, MÊME ICI. La loi de ce fichier est « il dérive, il n'échoue pas », et un
  # `p_fail` ferait rendre 1 à l'apply ENTIER au rang 22 — pour un arbre incomplet que `48-forge-host`
  # rencontrera de toute façon, en appelant le même script, avec un verdict qui porte la conséquence
  # réelle (structure non posée). Refuser tôt sur une cause qu'un autre module nomme mieux fait
  # chercher au mauvais rang.
  if [[ -z "$FLEET_HUMAN" ]]; then
    observe
    verdict_apply
  fi
  if ! id -u -- "$FLEET_HUMAN" >/dev/null 2>&1; then
    p_ok "« $FLEET_HUMAN » sera posé par la forge (48) puis matérialisé par le convergeur (64) : le même chemin qu'en production"
    verdict_apply
  fi

  # LE COMPTE EXISTE DÉJÀ : re-passe, ou compte posé à la main. Le convergeur pose l'adhésion à la
  # création (`useradd … -G`), mais son `usermod -aG` est suivi d'un `|| true` : un échec y est MUET.
  # Ce rattrapage est donc le seul geste de ce module, et le seul filet sous cette adhésion.
  if ! id -nG "$FLEET_HUMAN" 2>/dev/null | tr ' ' '\n' | grep -qx "$PROV_FLEET_GROUP"; then
    if usermod -aG "$PROV_FLEET_GROUP" -- "$FLEET_HUMAN" 2>/dev/null; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "« $FLEET_HUMAN » ajouté au groupe $PROV_FLEET_GROUP"
    else
      p_drift "« $FLEET_HUMAN » n'a pas pu rejoindre $PROV_FLEET_GROUP"
    fi
  fi

  observe
  verdict_apply
}

case "${1:?usage: 22-fleet-human.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
