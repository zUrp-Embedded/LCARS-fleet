#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/26-store.sh
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: PROTO-V2 — les MODES du magasin d'outillage, sur les quatre volumes externes
# APPLY-ON: docker
# CHECK-ON: docker
# NEEDS: root
#
# ─── POURQUOI CE N'EST PAS UNE LIGNE DE PLUS DANS 25-directories.sh ─────────────────────────────
# 25 est `APPLY-ON: any`. Y poser ces chemins les creerait AUSSI sur un poste — et un magasin
# PRESENT est un magasin ACTIF : le lanceur de pod ne se tait que si le repertoire n'existe pas.
# Chaque pod du poste recevrait alors un bind `ro` sur un magasin vide, plus l'avertissement du
# marqueur d'application a chaque spawn.
#
# La frontiere est reelle, pas administrative : un poste sert UN projet, dont la toolchain est une
# propriete de build de la machine (15-toolchain, `APPLY-ON: wsl linux`). Une boite sert n projets
# inconnus a l'avance, dont l'outillage est une demande signee a l'execution. Le garde de substrat
# rend cette frontiere MECANIQUE au lieu de la laisser en prose.
#
# ─── LE SEUL MODE QUI PORTE EST CELUI DU CACHE ─────────────────────────────────────────────────
# Un volume docker neuf se monte `root:root 0755`, et le pod tourne sous l'uid de son humain.
# `cache/` est le SEUL des quatre qu'un pod ECRIT : le lanceur le bind en `rw` par-dessus l'arbre
# `ro`, parce que pip, npm et cargo y ecrivent et qu'un `ro` leur rend EROFS. Sans groupe ni mode,
# ce bind `rw` rend un repertoire que le pod voit et ne peut pas ecrire — la meme panne, en EACCES,
# apres toute la precaution d'ordre des binds.
#
# `2` (setgid) : ce que le pod d'un humain depose y reste attribue au groupe, donc reutilisable par
# le pod du suivant. Sans lui le cache se fragmente par humain en silence, et un cache qui n'est pas
# partage n'est pas un cache — c'est un doublon qui coute un volume.
#
# Les trois autres sont lus en `ro` par les pods et ecrits par le convergeur sous root : `0755` est
# le mode JUSTE d'un arbre publie, pas un defaut qu'on n'aurait pas tranche. Ils figurent quand meme
# dans la table parce que `check` les SONDE — un volume non monte se dit ici, au lieu de se
# decouvrir en EACCES au premier `pip install` d'un pod.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non pose — lance via ./provision, pas le module nu}"
# shellcheck source=../lib/store.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/store.sh"

# LA RACINE VIENT DU COMPOSE, ELLE NE SE REDERIVE PAS ICI. Le compose possede le chemin
# (`LCARS_STORE_ROOT`), `lib/store.sh` possede les noms de volumes, ce module possede les MODES.
# Trois proprietaires, aucun recouvrement. Absente, c'est une panne de cablage et pas un magasin
# desactive : le module ne tourne que sur substrat docker, ou le compose est le seul poseur.
store_root() { printf '%s' "${LCARS_STORE_ROOT:-}"; }

# LA TABLE — une entree par volume, `sous-repertoire mode owner:groupe`.
#
# ⚠ `DELEGUE` EST UN MODE A PART ENTIERE, ET IL EXISTE POUR UNE PANNE MESUREE. `state/` a deja un
# proprietaire : `45-sudoers-toolchain` le cree en `install -d -m 2775` pour y poser le marqueur
# `pilot.assignee`, avec son motif ecrit au site. Ce module-ci le declarait `0755 root:root`, donc
# DEUX modules convergeaient le meme repertoire vers deux modes — 26 posait 755, 45 reposait 2775,
# et la passe suivante rendait FAIL sur un banc parfaitement sain. Une derive permanente par
# construction, mesuree sur banc neuf le 2026-08-20.
#
# La reponse n'est pas d'aligner les deux valeurs a la main : deux ecritures d'un meme fait
# derivent. C'est de dire QUI decide. Un volume delegue reste dans la table — la garde de completude
# ci-dessous exige toujours qu'aucun volume ne soit sans decision — mais ce module n'en converge
# pas le mode : il verifie seulement que le repertoire EXISTE, parce que c'est le point de montage
# du volume et que son absence est une panne de compose que son proprietaire ne saurait pas nommer.
prov_store_dirs() {
  printf '%s\n' \
    "cache      2775 root:$PROV_FLEET_GROUP" \
    "toolchains 0755 root:root" \
    "sysroots   0755 root:root" \
    "state      DELEGUE 45-sudoers-toolchain"
}

# ─── LA GARDE DE COMPLETUDE ─────────────────────────────────────────────────────────────────────
# Un cinquieme volume ajoute a `lib/store.sh` sans entree ici ne doit PAS heriter d'un mode par
# defaut : personne ne se demanderait alors si un pod l'ecrit. La table et la liste des volumes
# doivent se recouvrir exactement, dans les deux sens — un volume sans mode est une question non
# posee, un mode sans volume est un chemin qui n'existera jamais et que `check` reclamera a vie.
store_completeness() {
  local tabled declared missing=() extra=()
  # ⚠ ON LIT LES NATURES, PLUS DES NOMS DEPREFIXES A LA MAIN. Cette ligne faisait
  # `"${LCARS_STORE_VOLUMES[@]#lcars-}"` — elle retirait un prefixe LITTERAL pour retrouver le nom du
  # sous-repertoire. Depuis que le nom du volume porte le projet (`lcars-b2-cache`), ce strip ne rend
  # plus « cache » mais « b2-cache », et la garde de completude accuse une table parfaitement juste.
  # Le sous-repertoire n'a jamais ete un nom de volume ampute : c'est la NATURE, et `lib/store.sh` la
  # publie telle quelle.
  tabled="$(prov_store_dirs | awk '{print $1}' | sort)"
  declared="$(printf '%s\n' "${LCARS_STORE_TREES[@]}" | sort)"
  mapfile -t missing < <(set_diff "$tabled" "$declared")
  mapfile -t extra   < <(set_diff "$declared" "$tabled")
  (( ${#missing[@]} == 0 )) || { p_fail "volume sans mode declare ici : ${missing[*]}"; return 1; }
  (( ${#extra[@]} == 0 ))   || { p_fail "mode sans volume dans lib/store.sh : ${extra[*]}"; return 1; }
  return 0
}

check() {
  local root spec sub mode owner path cur
  root="$(store_root)"
  [[ -n "$root" ]] || { p_fail "LCARS_STORE_ROOT absent — le compose ne l'a pas pose"; verdict_check; }
  store_completeness || { verdict_check; }
  while read -r spec; do
    read -r sub mode owner <<< "$spec"
    path="$root/$sub"
    if [[ ! -d "$path" ]]; then
      p_drift "$path absent — volume non monte ?"
      continue
    fi
    cur="$(stat -c '%a %U:%G' "$path")"
    if [[ "$mode" == "DELEGUE" ]]; then
      # On SONDE sans juger : le mode appartient a `$owner`, pas a nous. Ce qui se verifie ici est
      # la seule chose dont ce module reponde — le point de montage existe.
      p_ok "$path ($cur) — mode delegue a $owner"
    elif [[ "$cur" == "${mode#0} $owner" ]]; then
      p_ok "$path ($cur)"
    else
      p_drift "$path : $cur ≠ ${mode#0} $owner"
    fi
  done < <(prov_store_dirs)
  verdict_check
}

apply() {
  local root spec sub mode owner
  root="$(store_root)"
  [[ -n "$root" ]] || { p_fail "LCARS_STORE_ROOT absent — le compose ne l'a pas pose"; verdict_apply; }
  store_completeness || { verdict_apply; }
  while read -r spec; do
    read -r sub mode owner <<< "$spec"
    if [[ "$mode" == "DELEGUE" ]]; then
      # Le repertoire est cree par son proprietaire ; on ne le devance pas et on ne le corrige pas.
      [[ -d "$root/$sub" ]] || p_drift "$root/$sub absent — $owner le pose, volume non monte ?"
      continue
    fi
    ensure_dir "$root/$sub" "$mode" "$owner" || verdict_apply
  done < <(prov_store_dirs)
  verdict_apply
}

case "${1:?usage: 26-store.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) echo "26-store.sh: verbe inconnu: $1" >&2; exit 2 ;;
esac
