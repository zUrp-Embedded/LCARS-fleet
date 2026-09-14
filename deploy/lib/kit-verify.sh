#!/usr/bin/env bash
# SOURCE: deploy/lib/kit-verify.sh
# AUTHOR: bob
# STARDATE: 2026-09-08
# STATUS: ce qu'un kit doit porter — manifestes et constantes, tampon de révision, release, doc bâtie, entrées de release.manifest, listes des constantes que pose 62, médias — vérifié avant que le tar ne ferme
# USAGE : . kit-verify.sh (après provision-lib.sh) ; kit_verifie <stage> <release relative au stage>   → 0 si le kit est complet, 1 sinon (manques nommés)
# Les constantes lues sont celles du kit, par env_field : une donnée, jamais sourcée.

kit_verifie() { # kit_verifie <stage> <release-relative-au-stage> -> 0 si complet ; sinon 1, manques NOMMÉS
  local stage="$1" rel="$2"
  local manques=() n
  local manifest="$stage/deploy/system.manifest"
  local constantes="$stage/deploy/installer-constants.env"
  local relman="$stage/runtime/etc/release.manifest"

  local f
  for f in "$manifest" "$constantes" "$relman"; do
    [[ -r "$f" ]] || manques+=("le kit n'a pas ${f#"$stage"/} — ce n'est pas un kit")
  done
  if [[ "${#manques[@]}" -gt 0 ]]; then kv_dire "${manques[@]}"; return 1; fi
  local tampon
  tampon="$(env_field "$constantes" PROV_SOURCE_STAMP)"
  if [[ -z "$tampon" ]]; then
    manques+=("deploy/installer-constants.env ne déclare pas PROV_SOURCE_STAMP — le tampon de révision n'est pas vérifiable")
  elif [[ ! -r "$stage/$tampon" ]]; then
    manques+=("$tampon absent — l'install se croirait SOURCE et bâtirait dans le kit")
  fi
  if [[ "${#manques[@]}" -gt 0 ]]; then kv_dire "${manques[@]}"; return 1; fi

  [[ -x "$stage/$rel" ]] \
    || manques+=("la release n'est pas dans le kit ($rel) — pack.sh la bâtit et l'y copie avant")
  [[ -s "$stage/assets/github.io/dist/index.html" ]] \
    || manques+=("la doc bâtie manque (assets/github.io/dist/index.html) — un kit sans sa doc est une demi-livraison")

  while read -r name _; do
    [[ -r "$stage/runtime/bin/$name" ]] \
      || manques+=("release.manifest nomme bin/$name, absent du kit")
  done < <(awk 'NF && $1 !~ /^#/ { print $1 }' "$relman")
  [[ -r "$stage/runtime/etc/fleet.env.template" ]] \
    || manques+=("runtime/etc/fleet.env.template absent — le provisionnement en dérive l'environnement")

  local cle h
  local -a liste
  for cle in PROV_HELPERS PROV_HELPERS_DATA PROV_SHELL_RC; do
    read -ra liste <<<"$(env_field "$constantes" "$cle")"
    if [[ "${#liste[@]}" -eq 0 ]]; then
      manques+=("deploy/installer-constants.env ne déclare pas $cle — ce que 62-runtime-helpers en pose n'est pas vérifié")
      continue
    fi
    for h in "${liste[@]}"; do
      h="${h##*/}"
      [[ -r "$stage/runtime/services/$h" ]] \
        || manques+=("$cle nomme $h, absent du kit (runtime/services/$h)")
    done
  done

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
