#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/22-fleet-human.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — l'humain de fleet du POSTE : il le NOMME, la forge le sème, le convergeur le pose
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
# ─── CE MODULE NOMME. IL NE CRÉE PLUS. ─────────────────────────────────────────────────────────
# ⚖ QUESTION USER 2026-08-25, posée plusieurs fois : « pourquoi on n'utilise pas le convergeur pour
# créer les humains à l'install ? on crée l'humain sur la forge, et on fait tourner le convergeur.
# ya une bonne raison pour ne pas faire ça ? »
#
# Il n'y en avait pas. Ce module portait son propre `useradd`, et la boîte a le sien dans
# `human-converger.sh` : DEUX créateurs pour un même objet, donc deux jeux de règles d'uid, de shell
# et de groupe qui ne dérivent pas au même rythme. Le rail poste testait alors un chemin que la
# production n'emprunte jamais — l'inverse exact de ce qu'un poste de démo doit prouver.
#
# CE QUE FAIT CE MODULE MAINTENANT : il NOMME l'humain, et il vérifie. `48-forge-host` sème le compte
# sur la forge (la recette tofu l'ajoute déjà à la team `humans`), `64-services` déclenche le
# convergeur UNE FOIS en synchrone après l'avoir semé, et le compte unix apparaît par le SEUL chemin
# qui existe aussi en production. Un seul créateur, un seul jeu de règles, un seul endroit à corriger.
#
# ⚠ ET LE PRÉ-SEMIS RESTE, PARCE QU'IL A UNE RAISON. ⚖ USER 2026-08-25 : « lcars, l'idée derrière,
# c'est de livrer out of the box un user "fleet enabled", par confort puisqu'on verrouille admin hors
# de la fleet. le poste/bench c'est pour la démo, le test, l'évaluation ou le dev, il faut que ça
# démarre directement. en prod (le mode boîte), on peut se passer de pré-seed un user (…) et
# l'inscription reste ouverte sur la forge, donc les users peuvent s'enrôler eux-mêmes. »
#
# D'où `APPLY-ON: wsl linux` : la boîte ne joue pas ce module, et n'a personne à nommer. Le confort
# est pour le poste ; le mécanisme est le même partout.
#
# ⚠ IL DÉRIVE, IL N'ÉCHOUE PAS. Un compte absent n'est pas une machine cassée : c'est un geste qui
# manque, et tout le reste du provisionnement est déjà posé quand on arrive ici. Un échec ferait
# rendre 1 à l'apply entier — la faute exacte que `52-ops-branch` portait le même jour.
#
# Données : PROV_FLEET_HUMAN (aucun défaut — le nommer EST la validation) · PROV_FLEET_GROUP

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

# ⚠ LE PLANCHER D'UID VIVAIT ICI, IL VIT MAINTENANT DANS `human-converger.sh` (`uid_floor`,
# `first_free_uid`), AVEC SES TÉMOINS. Ce module ne crée plus de compte — il NOMME, et la forge plus
# le convergeur matérialisent — donc garder ici le calcul qui garde `useradd` en aurait fait un
# deuxième exemplaire d'une règle appliquée ailleurs : celui qu'on lit quand on cherche pourquoi un
# uid surprend, et celui qu'on corrige sans rien changer. Le garde déménage avec le geste qu'il garde.
#
# `PROV_FLEET_HUMAN_SHELL` est mort avec : ce module le lisait sans jamais s'en servir, et personne
# d'autre ne le posait. Le shell se règle là où le compte se crée — `LCARS_HUMAN_SHELL`, chez le
# convergeur. Deux noms pour un même réglage, dont un inerte, c'est celui qu'on tourne pour rien.

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

# ─── OBSERVER N'EST PAS JUGER ───────────────────────────────────────────────────────────────────
#
# ⚠ CETTE SÉPARATION EST LA CONTRAINTE DU HAUT DE FICHIER, ENFIN ÉCRITE EN CODE. `apply()` finissait
# par `check`, et `check` finit par `verdict_check` — qui `exit`, et dont le `1` veut dire DRIFT
# quand le `1` d'un apply veut dire ÉCHEC. Le module rendait donc son verdict dans le mauvais
# dialecte, et le runner le traduisait fidèlement en panne.
#
# ⚠ ET LE DÉFAUT VENAIT DE DEVENIR CERTAIN. Tant que ce module créait le compte, `check` le trouvait
# juste après ; depuis qu'il ne fait que NOMMER, le compte est TOUJOURS absent au rang 22 d'une
# install neuve — la délégation aurait donc fait échouer l'apply à chaque fois. Un défaut latent que
# le changement voisin arme : c'est exactement ce qui ne se voit pas en relisant le diff.
#
# Ce qui suit n'a donc pas de verdict : il DÉCRIT, chaque verbe conclut.
observe() {
  local uid
  if [[ -z "$FLEET_HUMAN" ]]; then
    announce_no_fleet_human
    return 0
  fi
  if ! uid="$(id -u -- "$FLEET_HUMAN" 2>/dev/null)"; then
    p_drift "humain de fleet « $FLEET_HUMAN » absent — la forge posera son compte (48) et le convergeur le matérialisera (64) ; « 64-services » vérifie avant de rendre la main"
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
    p_drift "« $FLEET_HUMAN » hors du groupe $PROV_FLEET_GROUP — il ne lira ni /opt/lcars/var/tokens ni les zones de face"
  fi
}

# UNE SONDE JUGE LA MACHINE MAINTENANT. Un compte absent est ici une vraie dérive : `check` se joue
# APRÈS l'install, quand 48 et 64 sont passés.
check() { observe; verdict_check; }

apply() {
  # ⚠ SANS NOM, L'APPLY NE CRÉE RIEN — il dit la même chose que le check et s'arrête. C'est le seul
  # module du rail qui fait APPARAÎTRE UN UTILISATEUR sur la machine de quelqu'un : le défaut ne
  # peut pas être « le faire quand même ».
  # ⚠ LE MÊME MESSAGE, MAIS `verdict_apply` — JAMAIS `check`. Déléguer faisait sortir ce module avec
  # le code d'un CHECK (`1` = drift) pendant un APPLY (`1` = échec), et le runner lisait fidèlement
  # « échec » sur une dérive parfaitement nommée. Le `return` n'était même jamais atteint :
  # `verdict_check` fait un `exit`. Détail des deux dialectes dans `announce_no_fleet_human`.
  [[ -n "$FLEET_HUMAN" ]] || { announce_no_fleet_human; verdict_apply; }

  # ─── CE MODULE NE CRÉE PLUS DE COMPTE UNIX, ET C'EST LE POINT ───────────────────────────────
  #
  # ⚠ IL Y AVAIT DEUX CRÉATEURS D'HUMAIN DE FLEET, ET ILS DIVERGEAIENT DÉJÀ.
  #     22-fleet-human    useradd -u … -g "$PROV_FLEET_GROUP"   → groupe primaire = fleet
  #     human-converger   useradd … (aucun -g)                  → groupe privé
  # Mesuré sur une install réelle le 2026-08-25 : `lordzurp` en gid `fleet`, `lcars` en gid 1004.
  # Sans conséquence ce jour-là — mais c'est la classe exacte qui a fait tomber trois modules deux
  # heures plus tôt (`useradd -g <groupe existant>` ne crée AUCUN groupe du nom du compte).
  #
  # ⚠ ET SURTOUT : LE RAIL POSTE N'EXERÇAIT PAS LE CHEMIN DE PROD. En mode boîte — le seul cas de
  # production — ni ce module ni `48-forge-host` ne tournent (`APPLY-ON: wsl linux`) : l'humain y est
  # matérialisé par le convergeur, depuis la team `humans` de la forge, exclusivement. Le poste en
  # avait une SECONDE version, unix-first, qui n'existait que pour choisir le nom en ligne de
  # commande. Tester un mécanisme qui ne tourne pas en production est la classe de défaut que ce
  # dépôt traque partout ailleurs, appliquée à son propre rail d'install.
  #
  # ⚖ CE QUI EST GARDÉ, PARCE QUE C'EST LE MÉTIER DU RAIL POSTE : le PRÉ-SEMIS. Une machine de démo,
  # de test, d'évaluation ou de dev doit démarrer avec un humain « fleet enabled » sans geste manuel
  # — l'admin étant verrouillé hors de la fleet, sans lui il n'y aurait personne à lancer. En
  # production ce pré-semis n'a pas lieu d'être : l'admin a déjà testé, il ne veut pas d'un intrus
  # dans sa liste d'utilisateurs, et l'inscription reste ouverte sur SA forge.
  #
  # Ce qui change n'est donc pas le pré-semis, c'est son SENS : le nom part vers la forge
  # (`48-forge-host` lit `PROV_FLEET_HUMAN`, la recette pose le compte ET son adhésion à `humans` —
  # `gitea_team_membership.human`), puis le convergeur le matérialise ici. Une différence de
  # DONNÉES entre les deux rails — un membre de plus dans la team — au lieu d'une différence de
  # MÉCANISME.
  #
  # Et la matérialisation ne se devine pas : `64-services` tire le convergeur en `--once` et VÉRIFIE
  # qu'un humain de fleet existe avant que l'install rende la main.
  # ⚠ UN APPLY NE DÉRIVE PAS SUR UN COMPTE QUI N'EST PAS ENCORE DÛ. Au rang 22 d'une install neuve
  # le compte est TOUJOURS absent — 48 le sème, 64 le matérialise et le VÉRIFIE. Le signaler ici
  # ferait imprimer une dérive à chaque install sur un état parfaitement nominal, et une dérive qui
  # sort toujours n'est plus lue. La sonde, elle, le compte comme une dérive : elle se joue après.
  if ! id -u -- "$FLEET_HUMAN" >/dev/null 2>&1; then
    p_ok "« $FLEET_HUMAN » nommé — la forge pose son compte (48), le convergeur le matérialise (64) : le même chemin qu'en production"
    verdict_apply
  fi

  # LE COMPTE EXISTE DÉJÀ : re-passe, ou compte posé à la main. Le convergeur pose l'adhésion à la
  # création (`useradd … -G`), donc ce qui reste ici est le rattrapage d'un compte qu'il n'a pas créé.
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
