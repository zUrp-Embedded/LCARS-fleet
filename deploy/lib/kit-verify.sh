#!/usr/bin/env bash
# SOURCE: deploy/lib/kit-verify.sh
# AUTHOR: bob
# STARDATE: 2026-09-08
# STATUS: PROTO — le kit porte-t-il ce que les LISTES déclarent ? Le mur, avant que le tar ne ferme
#
# ─── POURQUOI CE FICHIER EXISTE, ET CE QU'IL A REMPLACÉ───────────────────────────────────────────
#
# La chaîne `.deb` (retirée le 2026-09-11) dérivait les `contents:` de ses paquets de la table et du
# stage, et vérifiait AU PASSAGE que les deux disaient la même chose : une ancre déclarée dont la
# source manque, un `bin/<nom>` que `release.manifest` nomme sans qu'il soit là, un auxiliaire que
# `62-runtime-helpers` embarque et qui n'existe pas. Chacun de ces cas y était un refus nommé.
#
# Sans ce fichier, cette vérification serait partie avec elle, et PERSONNE ne referait le
# rapprochement : le tar serait scellé sur un kit dont rien n'atteste qu'il porte ce que les listes
# promettent.
#
# ⚠ ET IL ARRIVE PLUS TÔT QU'ELLE. `pack.sh` scelle le tar à la ligne du `tar -czf` et la chaîne
# Debian tournait APRÈS : la vérification protégeait les `.deb` et JAMAIS le tar. Un kit incomplet
# partait en archive. Ce mur-ci se joue AVANT le scellement : c'est le tar qui est refusé.
#
# Une seule question ici : « ce que les listes nomment est-il dans le kit ? » — pas de découpage en
# paquets, pas de modes, pas de conffiles : c'était du packaging, et le packaging est parti.
#
# USAGE : . kit-verify.sh ; kit_verifie <stage>   → 0 si le kit est complet, 1 sinon (manques NOMMÉS)

[[ -n "${LCARS_KIT_VERIFY_LOADED:-}" ]] && return 0
LCARS_KIT_VERIFY_LOADED=1

# kv_tableau <fichier> <NOM> — les éléments du tableau bash NOM tel que le fichier le déclare.
#
# ⚠ ÉVALUÉ DANS UN SOUS-SHELL, et les variables que les listes citent y sont posées à la valeur que
# le module leur donne. C'est le même geste que `gen-contents.sh` faisait : lire la LISTE plutôt que
# de la recopier ici, sinon deux écritures d'un même fait divergent au premier ajout.
kv_tableau() {
  local f="$1" n="$2" blk
  blk="$(sed -n "/^$n=(/,/^)/p" "$f")"
  [[ -n "$blk" ]] || blk="$(grep -E "^$n=\(.*\)\$" "$f" || true)"
  [[ -n "$blk" ]] || return 1
  ( HELPERS_DIR=/opt/lcars; LCARS_BASHRC=/etc/lcars/lcars.bashrc; export HELPERS_DIR LCARS_BASHRC
    eval "$blk"; eval 'printf "%s\n" "${'"$n"'[@]}"' )
}

# ⚠ LE CHEMIN DE LA RELEASE BÂTIE EST UN PARAMÈTRE, ET CE N'EST PAS UN CAPRICE. `racines_prefixe`
# tient un mur : AUCUN fichier de `deploy/` ne porte un chemin `_build/prod/rel/…/bin/lcars_fleet`
# — « un chemin qui réapparaîtrait ici serait la devinette qui revient », celle qui déduisait la
# structure de la release du PAQUET au lieu de la release POSÉE. Ce mur a rougi sur la première
# version de ce fichier, et il avait raison : `pack.sh` est le seul à savoir où `mix release`
# dépose, puisque c'est lui qui l'y prend pour l'embarquer. Il passe donc le chemin ; la lib n'en
# porte aucun, et le fait n'a qu'une écriture.
kit_verifie() { # kit_verifie <stage> <release-relative-au-stage> -> 0 si complet ; sinon 1, manques NOMMÉS
  local stage="${1:?kit_verifie: <stage> manquant}"
  local rel="${2:?kit_verifie: <release relative au stage> manquant — pack.sh la connaît, pas cette lib}"
  local manques=() n
  local manifest="$stage/deploy/system.manifest"
  local relman="$stage/runtime/etc/release.manifest"
  local mod62="$stage/deploy/modules.d/62-runtime-helpers.sh"

  # 1. LES QUATRE FICHIERS SANS LESQUELS LE KIT N'EST PAS UN KIT. Un stage qui n'a pas sa table
  #    n'est pas un kit incomplet : c'est autre chose, et le dire ainsi évite trente refus en aval.
  local f
  for f in "$manifest" "$relman" "$mod62"; do
    [[ -r "$f" ]] || manques+=("le kit n'a pas ${f#"$stage"/} — ce n'est pas un kit")
  done
  # ⚠ `.source-revision` EST CE QUI DISTINGUE UNE LIVRAISON BINAIRE D'UN CHECKOUT. Sans lui,
  # l'install se croirait SOURCE et lancerait `npm ci` dans un arbre qui n'a pas vocation à bâtir —
  # 176 Mo posés avant l'échec, mesuré (cf. l'en-tête de `44-media`).
  [[ -r "$stage/.source-revision" ]] \
    || manques+=(".source-revision absent — l'install se croirait SOURCE et bâtirait dans le kit")
  if [[ "${#manques[@]}" -gt 0 ]]; then kv_dire "${manques[@]}"; return 1; fi

  # 2. LA RELEASE ET LA DOC : les deux choses que `git archive` n'emporte pas (gitignorées) et que
  #    `pack.sh` ajoute à la main. Un kit sans elles s'installe et ne sert rien.
  [[ -x "$stage/$rel" ]] \
    || manques+=("la release n'est pas dans le kit ($rel) — pack.sh la bâtit et l'y copie avant")
  [[ -s "$stage/assets/github.io/dist/index.html" ]] \
    || manques+=("la doc bâtie manque (assets/github.io/dist/index.html) — un kit sans sa doc est une demi-livraison")

  # 3. CE QUE `release.manifest` NOMME. Chaque `bin/<nom>` qu'il déclare doit être là : c'est
  #    `60-deploy` qui les câble, et une entrée sans fichier fait un lien mort sur la machine.
  if [[ -r "$relman" ]]; then
    while read -r name _; do
      [[ -n "$name" ]] || continue
      [[ -r "$stage/runtime/bin/$name" ]] \
        || manques+=("release.manifest nomme bin/$name, absent du kit")
    done < <(awk 'NF && $1 !~ /^#/ { print $1 }' "$relman")
  fi
  [[ -r "$stage/runtime/etc/fleet.env.template" ]] \
    || manques+=("runtime/etc/fleet.env.template absent — le rail en dérive l'environnement")

  # 4. CE QUE `62-runtime-helpers` EMBARQUE. HELPERS pose des auxiliaires à plat sous la racine,
  #    DATA des données à leur adresse : les deux listes NOMMENT des fichiers de `runtime/services`.
  if [[ -r "$mod62" ]]; then
    while read -r h; do
      [[ -n "$h" ]] || continue
      [[ -r "$stage/runtime/services/$h" ]] \
        || manques+=("62-runtime-helpers nomme l'auxiliaire $h, absent du kit")
    done < <(kv_tableau "$mod62" HELPERS || true)
    while read -r d_src _; do
      [[ -n "$d_src" ]] || continue
      [[ -r "$stage/runtime/services/$d_src" ]] \
        || manques+=("62-runtime-helpers nomme la donnée $d_src, absente du kit")
    done < <(kv_tableau "$mod62" DATA || true)
  fi

  # 5. LES TROIS ANCRES QUE LA TABLE DÉCLARE ET QUE LE KIT PORTE. Les autres ancres se dérivent à
  #    l'install (`.helpers-revision`) ou viennent d'un outillage (`tofu`) : elles n'ont pas de
  #    source dans le kit, et les exiger ferait rougir un kit correct.
  local src
  for src in runtime/bin/lcars-toolchain-converge runtime/bin/lcars-authority-ask \
             runtime/services/lcars.bashrc; do
    [[ -r "$stage/$src" ]] || manques+=("la table déclare une ancre dont la source manque : $src")
  done

  # 6. LES ARBRES QUE `44-media` POSE. Il les copie sans les bâtir : absents du kit, ils sont
  #    absents de la machine, et le module échoue à l'apply au lieu de le dire ici.
  local t
  for t in avatars favicon; do
    [[ -d "$stage/assets/$t" ]] || manques+=("assets/$t absent — 44-media en dépend")
  done

  n="${#manques[@]}"
  [[ "$n" -eq 0 ]] && return 0
  kv_dire "${manques[@]}"
  return 1
}

kv_dire() {
  printf 'ECHEC: le kit ne porte pas ce que les listes declarent — %d manque(s) :\n' "$#" >&2
  printf '  · %s\n' "$@" >&2
  printf '       Le tar n a PAS ete scelle. Les listes sont la source : soit le fichier manque a\n' >&2
  printf '       l arbre, soit la liste nomme quelque chose qui n existe plus.\n' >&2
}
