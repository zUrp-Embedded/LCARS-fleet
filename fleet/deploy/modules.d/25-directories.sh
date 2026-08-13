#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/25-directories.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — arborescence systeme : /local + /home/private, et les ZONES DE FACE
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# DEUX dossiers systeme, et les zones de face. (La v1 en posait une dizaine — commons, handoffs,
# fleet-state, spool, projects, tmp — pour l'IPC de sa fleet bash ; le runtime v2 n'a besoin
# d'AUCUN d'eux : son etat vit sous ~/.lcars per-humain, pose par `fleet_v2 start` lui-meme.)
#
#   /local          0755 root:root — les prefixes d'install y sont crees par 60-deploy ;
#                   root-only en ecriture = personne ne remplace un runtime deploye par surprise.
#   /home/private   0750 root:fleet — les role-tokens forge (contrat FORGE_ROLE_TOKENS_DIR,
#                   fichiers 0640 poses par etc/provision-role-tokens.sh). Lecture : groupe fleet
#                   (le BEAM per-humain lit via le groupe) ; traversee interdite au reste.
#
# ─── LES ZONES DE FACE, ET POURQUOI ELLES SONT ICI ────────────────────────────────────────────
# Une racine par face — le miroir shell de `Fleet.Layout.face_root/1`, tenu en phase avec lui par
# le contrat `layout.face_roots_provisioned` de `mix lcars.contracts.check`.
#
# ELLES N'ETAIENT CREEES QUE PAR L'ENTRYPOINT DOCKER, et le rail reconnait TROIS substrats. Sur
# `wsl` elles existaient « par histoire du substrat » — c'est-a-dire a la main, un jour, sur la
# machine de l'auteur — et sur un `linux` natif, pas du tout. Le runtime tourne sous l'humain et
# `/home` appartient a root : creer la zone n'est donc PAS un geste qu'il peut rattraper. La boite
# demarrait saine et le premier onboarding mourait sur un `permission denied`, exactement comme la
# face `doc` absente de l'entrypoint l'avait fait le 2026-08-09 — meme panne, sur le chemin que le
# contrat ne couvrait pas.
#
# setgid + groupe fleet : chaque humain du groupe cree ses projets et ses worktrees dans la zone,
# et ce qu'il y pose reste lisible par les autres. Un `mkdir` de rattrapage cote runtime herite de
# l'umask, donc sans setgid ni groupe — le partage se casse en silence, ce qui est pire que
# l'echec franc.
#
# ⚠ L'entrypoint docker garde SA propre creation de ces memes zones, et ce n'est pas un doublon
# oublie : il clone la source dans `/home/projects/LCARS` bien AVANT d'appeler `provision apply`,
# donc les zones doivent exister plus tot que ce module ne tourne. Les deux miroirs sont tenus par
# le meme contrat, qui les compare tous les deux a `Fleet.Layout` — l'ordre de boot est la raison
# d'etre du second, pas une negligence.
#
# CHAQUE dossier est pose creation+mode+owner en un geste convergent (la v1 separait mkdir des
# perms → un crash entre les deux laissait des dossiers ownes root par defaut, silencieusement).

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# LA TABLE, source unique des deux modes. `check` et `apply` la déroulent tous les deux : une
# entrée ajoutée ici est vérifiée ET posée, sans qu'on puisse en oublier la moitié.
# Les zones de face sont le MIROIR SHELL de `Fleet.Layout.face_root/1` — en ajouter une sans
# l'ajouter là-bas (ou l'inverse) fait rougir `layout.face_roots_provisioned`, en la NOMMANT.
prov_dirs() {
  printf '%s\n' \
    "/local 0755 root:root" \
    "$PROV_TOKENS_DIR 0750 root:$PROV_FLEET_GROUP" \
    "/home/projects 2775 root:$PROV_FLEET_GROUP" \
    "/home/projects.ops 2775 root:$PROV_FLEET_GROUP" \
    "/home/projects.workshop 2775 root:$PROV_FLEET_GROUP"
}

check() {
  local spec path mode owner cur
  # La table est LA donnée ; le code ne fait que la dérouler (une entrée = "chemin mode owner:groupe").
  # `done < <(...)` et non `prov_dirs | while` : un pipe met la boucle dans un SOUS-SHELL, et les
  # compteurs de drift qu'y posent `p_drift`/`p_ok` meurent avec lui — le module rendrait « aucun
  # drift » en ayant vu tous les siens.
  while read -r spec; do
    read -r path mode owner <<< "$spec"
    if [[ ! -d "$path" ]]; then
      p_drift "$path absent"
      continue
    fi
    cur="$(stat -c '%a %U:%G' "$path")"
    if [[ "$cur" == "${mode#0} $owner" ]]; then
      p_ok "$path ($cur)"
    else
      p_drift "$path : $cur ≠ ${mode#0} $owner"
    fi
  done < <(prov_dirs)
  verdict_check
}

apply() {
  local spec path mode owner
  while read -r spec; do
    read -r path mode owner <<< "$spec"
    ensure_dir "$path" "$mode" "$owner" || verdict_apply
  done < <(prov_dirs)
  verdict_apply
}

case "${1:?usage: 25-directories.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
