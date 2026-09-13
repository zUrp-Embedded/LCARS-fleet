#!/usr/bin/env bash
# SOURCE: deploy/lib/kit-verify.sh
# AUTHOR: bob
# STARDATE: 2026-09-08
# STATUS: ce qu'un kit doit porter, contre release.manifest et les listes de 62, vérifié avant que le tar ne ferme
# USAGE : . kit-verify.sh ; kit_verifie <stage> <release relative au stage>   → 0 si le kit est complet, 1 sinon (manques nommés)

[[ -n "${LCARS_KIT_VERIFY_LOADED:-}" ]] && return 0
LCARS_KIT_VERIFY_LOADED=1

kv_tableau() { # kv_tableau <fichier> <nom> → les éléments du tableau ; rc 1 si la liste ne se lit pas ou est vide
  local f="$1" n="$2" blk out
  blk="$(grep -E "^$n=\(.*\)\$" "$f" || true)"
  [[ -n "$blk" ]] || blk="$(sed -n "/^$n=(/,/^)/p" "$f")"
  [[ -n "$blk" ]] || return 1
  out="$( set -u; HELPERS_DIR=/opt/lcars; LCARS_BASHRC=/etc/lcars/lcars.bashrc; export HELPERS_DIR LCARS_BASHRC
          eval "$blk" && eval 'printf "%s\n" "${'"$n"'[@]}"' )" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
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

  local liste
  if liste="$(kv_tableau "$mod62" HELPERS)"; then
    while read -r h; do
      [[ -r "$stage/runtime/services/$h" ]] \
        || manques+=("62-runtime-helpers nomme l'auxiliaire $h, absent du kit")
    done <<<"$liste"
  else
    manques+=("62-runtime-helpers : la liste HELPERS ne se lit pas — rien de ce qu'il embarque n'est vérifié")
  fi
  if liste="$(kv_tableau "$mod62" DATA)"; then
    while read -r d_src _; do
      [[ -r "$stage/runtime/services/$d_src" ]] \
        || manques+=("62-runtime-helpers nomme la donnée $d_src, absente du kit")
    done <<<"$liste"
  else
    manques+=("62-runtime-helpers : la liste DATA ne se lit pas — rien de ce qu'il embarque n'est vérifié")
  fi

  local src
  for src in runtime/bin/lcars-toolchain-converge runtime/bin/lcars-authority-ask; do
    [[ -r "$stage/$src" ]] || manques+=("62-runtime-helpers pose $src hors de ses listes, et le kit ne le porte pas")
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
  printf 'ÉCHEC : le kit ne porte pas ce que les listes déclarent — %d manque(s) :\n' "$#" >&2
  printf '  · %s\n' "$@" >&2
  printf '       Le tar n'"'"'a pas été scellé. Les listes sont la source : soit le fichier manque à\n' >&2
  printf '       l'"'"'arbre, soit la liste nomme quelque chose qui n'"'"'existe plus.\n' >&2
}
