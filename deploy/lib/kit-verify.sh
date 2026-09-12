#!/usr/bin/env bash
# SOURCE: deploy/lib/kit-verify.sh
# AUTHOR: bob
# STARDATE: 2026-09-08
# STATUS: PROTO — le kit porte-t-il ce que les LISTES déclarent ? Le mur, avant que le tar ne ferme
# USAGE : . kit-verify.sh ; kit_verifie <stage>   → 0 si le kit est complet, 1 sinon (manques NOMMÉS)

[[ -n "${LCARS_KIT_VERIFY_LOADED:-}" ]] && return 0
LCARS_KIT_VERIFY_LOADED=1

kv_tableau() {
  local f="$1" n="$2" blk
  blk="$(sed -n "/^$n=(/,/^)/p" "$f")"
  [[ -n "$blk" ]] || blk="$(grep -E "^$n=\(.*\)\$" "$f" || true)"
  [[ -n "$blk" ]] || return 1
  ( HELPERS_DIR=/opt/lcars; LCARS_BASHRC=/etc/lcars/lcars.bashrc; export HELPERS_DIR LCARS_BASHRC
    eval "$blk"; eval 'printf "%s\n" "${'"$n"'[@]}"' )
}

kit_verifie() { # kit_verifie <stage> <release-relative-au-stage> -> 0 si complet ; sinon 1, manques NOMMÉS
  local stage="${1:?kit_verifie: <stage> manquant}"
  local rel="${2:?kit_verifie: <release relative au stage> manquant — pack.sh la connaît, pas cette lib}"
  local manques=() n
  local manifest="$stage/deploy/system.manifest"
  local relman="$stage/runtime/etc/release.manifest"
  local mod62="$stage/deploy/modules.d/62-runtime-helpers.sh"

  local f
  for f in "$manifest" "$relman" "$mod62"; do
    [[ -r "$f" ]] || manques+=("le kit n'a pas ${f#"$stage"/} — ce n'est pas un kit")
  done
  [[ -r "$stage/.source-revision" ]] \
    || manques+=(".source-revision absent — l'install se croirait SOURCE et bâtirait dans le kit")
  if [[ "${#manques[@]}" -gt 0 ]]; then kv_dire "${manques[@]}"; return 1; fi

  [[ -x "$stage/$rel" ]] \
    || manques+=("la release n'est pas dans le kit ($rel) — pack.sh la bâtit et l'y copie avant")
  [[ -s "$stage/assets/github.io/dist/index.html" ]] \
    || manques+=("la doc bâtie manque (assets/github.io/dist/index.html) — un kit sans sa doc est une demi-livraison")

  if [[ -r "$relman" ]]; then
    while read -r name _; do
      [[ -n "$name" ]] || continue
      [[ -r "$stage/runtime/bin/$name" ]] \
        || manques+=("release.manifest nomme bin/$name, absent du kit")
    done < <(awk 'NF && $1 !~ /^#/ { print $1 }' "$relman")
  fi
  [[ -r "$stage/runtime/etc/fleet.env.template" ]] \
    || manques+=("runtime/etc/fleet.env.template absent — le provisionnement en dérive l'environnement")

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

  local src
  for src in runtime/bin/lcars-toolchain-converge runtime/bin/lcars-authority-ask \
             runtime/services/lcars.bashrc; do
    [[ -r "$stage/$src" ]] || manques+=("la table déclare une ancre dont la source manque : $src")
  done

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
