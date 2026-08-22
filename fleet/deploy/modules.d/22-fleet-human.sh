#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/22-fleet-human.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — l'humain de fleet du POSTE : un compte unix qui n'est pas le siège
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
# ─── CE MODULE N'EST PAS UN CONVERGEUR D'HUMAINS ───────────────────────────────────────────────
# Dans la boîte, `human-converger.sh` matérialise N humains inconnus depuis la team `humans` de la
# forge, et il continue de le faire. Ici il y a UN poste, UN humain de fleet, et la forge n'existe
# pas forcément encore quand ce module tourne (48-forge-host peut dériver). Ce module pose donc le
# compte, rien d'autre — pas de roster, pas de boucle, pas de révocation.
#
# ⚠ IL DÉRIVE, IL N'ÉCHOUE PAS. Un `useradd` refusé n'est pas une machine cassée : c'est un geste
# qui manque, et tout le reste du provisionnement est déjà posé quand on arrive ici. Un échec ferait
# rendre 1 à l'apply entier — la faute exacte que `52-ops-branch` portait le même jour.
#
# Données : PROV_FLEET_HUMAN (défaut `lcars`) · PROV_FLEET_GROUP · LCARS_SYSADMIN_UID

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# ⚖ ARBITRAGE USER 2026-08-21 : « on crée pas un user sur une machine nue. dans docker c'est sans
# gravité, là ça demande au moins une validation user. »
#
# DONC AUCUN NOM PAR DÉFAUT. Ce module portait `: "${PROV_FLEET_HUMAN:=lcars}"` : un `provision
# apply` sur une machine dédiée faisait alors apparaître un utilisateur `lcars` que personne n'avait
# demandé, sur un rail qui n'a AUCUN désinstalleur. Dans un conteneur c'est sans conséquence — il se
# jette ; sur la machine de quelqu'un, c'est une mutation qu'on ne défait pas.
#
# NOMMER LE COMPTE EST LA VALIDATION. `--fleet-human <nom>` (ou `PROV_FLEET_HUMAN`) est le geste par
# lequel l'opérateur autorise la création ET choisit le nom — parce que `lcars` n'a rien de spécial :
# sur ce parc les humains s'appellent `vanille`, `bob`, `alice`. Sans ce drapeau, le module ne crée
# RIEN et dérive en nommant le geste exact.
FLEET_HUMAN="${PROV_FLEET_HUMAN:-}"
FLEET_SHELL="${PROV_FLEET_HUMAN_SHELL:-/bin/bash}"

# LE PLANCHER D'UID SE DÉRIVE, IL NE S'ÉCRIT PAS. `is_fleet_human` exige `uid >= UID_MIN` ET
# `uid != LCARS_SYSADMIN_UID` : le premier uid acceptable est donc juste au-dessus du plus grand des
# deux. Recopier « 1001 » ici en ferait un troisième exemplaire d'un nombre que le système et la lib
# déclarent déjà — et il serait faux le jour où l'un des deux bouge.
fleet_uid_floor() {
  local uid_min sysadmin
  uid_min="$(awk '/^UID_MIN/ {print $2}' "${PASSWD_DEFS:-/etc/login.defs}" 2>/dev/null | head -n1 || true)"
  [[ "$uid_min" =~ ^[0-9]+$ ]] || uid_min=1000
  sysadmin="${LCARS_SYSADMIN_UID:-1000}"
  (( uid_min > sysadmin )) && { echo "$uid_min"; return 0; }
  echo "$(( sysadmin + 1 ))"
}

# Le premier uid LIBRE au-dessus du plancher. On ne le laisse pas à `useradd` : son propre choix
# part de UID_MIN, donc il rendrait l'uid du siège si celui-ci était libre — exactement le compte
# qu'on ne veut pas créer.
first_free_uid() {
  local uid; uid="$(fleet_uid_floor)"
  while getent passwd "$uid" >/dev/null 2>&1; do uid=$(( uid + 1 )); done
  echo "$uid"
}

# ─── LE MESSAGE EST PARTAGÉ, LE VERDICT NE L'EST JAMAIS ─────────────────────────────────────────
#
# AUCUN HUMAIN NOMMÉ : ce n'est pas une panne, c'est une décision que personne n'a prise. On le DIT,
# avec le geste exact, et on ne devine pas de nom.
#
# ⚠ CETTE FONCTION EXISTE PARCE QUE LES CODES DE SORTIE SONT INVERSÉS ENTRE LES DEUX VERBES, et que
# ce module servait les deux avec UN SEUL verdict :
#
#     check   0 conforme · 1 DRIFT          · 2 erreur de sonde
#     apply   0 convergé · 1 ÉCHEC          · 2 appliqué, drift résiduel
#
# L'assignation est justifiée VERBE PAR VERBE — chacun donne `1` à son mauvais résultat principal :
# l'échec pour un apply (la convention shell), la dérive pour une sonde. Le `2` d'apply a été AJOUTÉ
# parce qu'un module qui constatait une non-convergence rendait `0`, donc « tout convergé », sur une
# machine qui venait d'imprimer DRIFT (cf. `provision:38`).
#
# ⚠ MAIS RIEN N'A JAMAIS ÉCRIT LA CONTRAINTE EN TRAVERS. `apply()` faisait `{ check; return; }`, et
# `verdict_check` fait un `exit`, pas un `return` : le module sortait donc en `1` pendant un APPLY,
# et le runner — qui lit un apply — traduisait fidèlement « apply en echec … MORT avant de rendre
# son verdict ». Le module avait parfaitement rendu son verdict, dans le mauvais dialecte.
#
# Mesuré le 2026-08-22, install à froid sans `--fleet-human`. Ce module est le SEUL des vingt-six à
# déléguer ainsi ; le défaut n'était donc pas visible ailleurs.
# ⚠ « RIEN N'EST DÉCLARÉ » N'EST PAS « PERSONNE NE PEUT LANCER LA FLEET ». Ce message affirmait la
# seconde phrase en ayant mesuré la première : il lisait une VARIABLE et concluait sur la MACHINE.
# Mesuré le 2026-08-22 sur un poste portant `lcars` (uid 1001) et `mintos` (uid 1002) — deux comptes
# que `is_fleet_human` accepte — pendant que le module annonçait que personne ne pourrait lancer la
# fleet ici. Un instrument qui répond à côté de sa question est pire que muet : il clôt le sujet.
#
# Les deux cas appellent deux gestes différents, donc deux verdicts. Sans aucun compte, il faut en
# créer un. Avec des comptes non désignés, ils existent mais cette passe ne converge pas leur état
# per-humain — et c'est CETTE conséquence-là qui est vraie.
#
# ⚠ ET « AUCUN » EST UN ÉTAT DE RANG 22, PAS UN ÉTAT FINAL. Ce module a longtemps conclu « personne
# ne pourra lancer la fleet ici » — une phrase terminale, énoncée au milieu d'une passe qui va la
# rendre fausse vingt-six modules plus loin : sans `--fleet-human`, `48-forge-host` passe une valeur
# VIDE, la recette applique son propre défaut et crée le compte intégré sur la forge, puis le
# convergeur posé par `64-services` le matérialise. Le rail produit donc un humain de fleet ; il ne
# laisse simplement pas l'opérateur en choisir le nom.
#
# Le nom de ce compte n'est PAS recopié ici : son auteur est `forge-gestures.sh`, et un second
# littéral ne resterait d'accord avec lui que jusqu'au jour où l'un des deux bouge.
announce_no_fleet_human() {
  local found; found="$(fleet_humans | paste -sd' ' -)"
  if [[ -n "$found" ]]; then
    p_drift "aucun humain de fleet DÉCLARÉ, mais cette machine en porte déjà : $found.
     Leur état per-humain (~/.lcars, ~/pods, fleet_v2.env, identité git) n'est PAS convergé par
     cette passe — « provision apply --fleet-human <nom> » désigne celui qui le reçoit."
  else
    p_drift "aucun humain de fleet DÉCLARÉ, et cette machine n'en porte aucun ENCORE.
     L'opérateur (uid $(id -u -- "$PROV_HUMAN" 2>/dev/null || echo '?')) est le siège : GUARD B lui interdit d'en lancer une.
     Sans nom, la suite de cette passe s'en charge : la forge pose son compte intégré (48) et le
     convergeur le matérialise ici (64) — tu ne choisis alors ni son nom ni son moment.
     Pour en avoir un À TOI, MAINTENANT : « provision apply --fleet-human <nom> »
     — ou crée-le toi-même : « useradd -m -G $PROV_FLEET_GROUP <nom> »"
  fi
}

check() {
  local uid
  if [[ -z "$FLEET_HUMAN" ]]; then
    announce_no_fleet_human
    verdict_check
  fi
  if ! uid="$(id -u -- "$FLEET_HUMAN" 2>/dev/null)"; then
    p_drift "humain de fleet « $FLEET_HUMAN » absent — l'apply le CRÉERA (tu l'as nommé, donc autorisé)"
    verdict_check
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
  verdict_check
}

apply() {
  # ⚠ SANS NOM, L'APPLY NE CRÉE RIEN — il dit la même chose que le check et s'arrête. C'est le seul
  # module du rail qui fait APPARAÎTRE UN UTILISATEUR sur la machine de quelqu'un : le défaut ne
  # peut pas être « le faire quand même ».
  # ⚠ LE MÊME MESSAGE, MAIS `verdict_apply` — JAMAIS `check`. Déléguer faisait sortir ce module avec
  # le code d'un CHECK (`1` = drift) pendant un APPLY (`1` = échec), et le runner lisait fidèlement
  # « échec » sur une dérive parfaitement nommée. Le `return` n'était même jamais atteint :
  # `verdict_check` fait un `exit`. Détail des deux dialectes dans `announce_no_fleet_human`.
  [[ -n "$FLEET_HUMAN" ]] || { announce_no_fleet_human; verdict_apply; }

  if ! id -u -- "$FLEET_HUMAN" >/dev/null 2>&1; then
    local uid; uid="$(first_free_uid)"
    if useradd -u "$uid" -m -s "$FLEET_SHELL" -g "$PROV_FLEET_GROUP" -- "$FLEET_HUMAN" 2>/dev/null; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "humain de fleet « $FLEET_HUMAN » créé (uid $uid, groupe $PROV_FLEET_GROUP)"
    else
      p_drift "useradd « $FLEET_HUMAN » (uid $uid) a échoué — le poste reste sans humain de fleet"
      verdict_apply
    fi
  fi

  # L'APPARTENANCE SE CONVERGE MÊME SUR UN COMPTE QUI EXISTAIT DÉJÀ : `useradd -g` ne vaut que pour
  # une création, et un compte posé à la main (ou par une version antérieure) peut être hors groupe.
  if ! id -nG "$FLEET_HUMAN" 2>/dev/null | tr ' ' '\n' | grep -qx "$PROV_FLEET_GROUP"; then
    if usermod -aG "$PROV_FLEET_GROUP" -- "$FLEET_HUMAN" 2>/dev/null; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "« $FLEET_HUMAN » ajouté au groupe $PROV_FLEET_GROUP"
    else
      p_drift "« $FLEET_HUMAN » n'a pas pu rejoindre $PROV_FLEET_GROUP"
    fi
  fi

  check
}

case "${1:?usage: 22-fleet-human.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
