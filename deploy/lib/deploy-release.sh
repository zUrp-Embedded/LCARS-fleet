#!/usr/bin/env bash
# SOURCE: deploy/lib/deploy-release.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-22
# STATUS: la release du runtime — bâtie depuis les sources par mix release, ou reprise du kit, puis basculée sous le préfixe
#
# ENV   LCARS_RUNTIME_DIR   l'arbre du runtime à poser (60-deploy le passe)
# EXIT  0 posée · 1 échec, nommé sur stderr ; la génération précédente de rel/ reste en .prev
#
# Jouée par 60-deploy sous l'humain qui bâtit ; 60 pose ensuite les modes, les liens du PATH et
# retire ce que le manifeste ne nomme plus. Le build ne joue pas le gate : un kit porte la release que
# pack.sh a bâtie après le sien ; depuis un clone, la release est bâtie sur le checkout tel qu'il est.
# Sur une livraison source, 60 tire l'outillage mix (hex, rebar) et « mix deps.get » tire hex.pm, sous
# ce compte : la machine joint hex.pm directement, sudo ne transmet aucune variable de proxy.
set -euo pipefail

# shellcheck source=provision-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/provision-lib.sh"

say() { echo "install: $*" >&2; }
die() { echo "install: ERREUR — $*" >&2; exit 1; }

atomic_swap_dir() { # atomic_swap_dir <source> <destination> — la destination précédente est gardée en .prev
  local src="$1" dst="$2"
  local stage="${dst}.staging.$$" prev="${dst}.prev"

  rm -rf "$stage"
  cp -a "$src" "$stage" || { rm -rf "$stage"; die "copie du build vers le staging échouée ($stage)"; }

  rm -rf "$prev"
  [[ -e "$dst" ]] && mv "$dst" "$prev"
  mv "$stage" "$dst"
}

atomic_swap_file() {
  local src="$1" dst="$2"
  local tmp="${dst}.new.$$"

  cp -a "$src" "$tmp" || { rm -f "$tmp"; die "copie de $(basename "$dst") vers le staging échouée"; }
  mv "$tmp" "$dst"
}

build_release() {
  local runtime_dir="$1"

  local rel="$runtime_dir/_build/prod/rel/lcars_fleet"
  if [[ -x "$rel/bin/lcars_fleet" ]]; then
    if [[ -f "$runtime_dir/../$PROV_SOURCE_STAMP" ]]; then
      echo "install: kit — release bâtie par pack.sh, déjà passée au gate : rien à compiler" >&2
      return 0
    fi
    local src_sha built_sha m
    src_sha="$(git -C "$runtime_dir" rev-parse --short HEAD 2>/dev/null || true)"
    m="$(release_app_dir "$rel" || true)"
    [[ -n "$m" && -f "$m/priv/api/build_info.txt" ]] && built_sha="$(sed -n 's/^sha=//p' "$m/priv/api/build_info.txt" 2>/dev/null | head -1)"
    if [[ -n "$src_sha" && "$src_sha" == "${built_sha:-}" ]] \
       && git -C "$runtime_dir" diff --quiet HEAD -- . 2>/dev/null; then
      echo "install: release déjà bâtie et attestée ($src_sha, arbre propre) — rien à compiler" >&2
      return 0
    fi
    echo "install: un _build/prod/rel existe mais n'atteste pas cette source (build ${built_sha:-inconnu} vs HEAD ${src_sha:-inconnu}) — rebâti" >&2
  fi

  (
    set -e
    cd "$runtime_dir"
    MIX_ENV=prod mix deps.get >/dev/null || exit 1
    rm -rf "_build/prod/rel/lcars_fleet"
    MIX_ENV=prod mix release --overwrite || exit 1
  )
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

RUNTIME_DIR="$LCARS_RUNTIME_DIR"
MANIFEST="$RUNTIME_DIR/etc/release.manifest"

declare -a MF_FILES=() MF_MODES=()
while read -r mf_name mf_mode mf_flag mf_extra; do
  [[ -z "$mf_name" || "$mf_name" == \#* ]] && continue
  [[ -z "$mf_extra" ]] || die "manifest : token en trop « $mf_extra » sur l'entrée « $mf_name »"
  case "$mf_mode" in
    exec|noexec) : ;;
    *) die "manifest : mode inconnu « ${mf_mode:-<vide>} » pour « $mf_name » (exec|noexec)" ;;
  esac
  [[ -z "$mf_flag" || "$mf_flag" == "link" ]] || die "manifest : flag inconnu « $mf_flag » pour « $mf_name » (seul : link)"
  MF_FILES+=("$mf_name"); MF_MODES+=("$mf_mode")
done < "$MANIFEST"
[[ "${#MF_FILES[@]}" -gt 0 ]] || die "manifest vide : $MANIFEST"

[[ "$EUID" -ne 0 ]] || die "lancé en root — le build laisserait des artefacts root dans l'arbre source. À lancer sous le compte propriétaire de l'install ; seule la pose demande des droits"

say "build release prod (MIX_ENV=prod mix release)…"
build_release "$RUNTIME_DIR" || die "build en échec — la release n'est pas posée"
REL_SRC="$RUNTIME_DIR/_build/prod/rel/lcars_fleet"
[[ -x "$REL_SRC/bin/lcars_fleet" ]] || die "release introuvable une fois le build fini ($REL_SRC)"

say "pose sous $PROV_PREFIX…"
mkdir -p "$PROV_PREFIX/bin" "$PROV_PREFIX/etc" "$PROV_PREFIX/rel"

atomic_swap_dir "$REL_SRC" "$PROV_PREFIX/rel/lcars_fleet"

for i in "${!MF_FILES[@]}"; do
  f="${MF_FILES[$i]}"
  [[ -e "$RUNTIME_DIR/bin/$f" ]] || die "entrée du manifest absente du source bin/ : $f"
  atomic_swap_file "$RUNTIME_DIR/bin/$f" "$PROV_PREFIX/bin/$f"
  if [[ "${MF_MODES[$i]}" == "exec" ]]; then
    chmod +x "$PROV_PREFIX/bin/$f" || die "chmod +x refusé : $PROV_PREFIX/bin/$f"
  fi
done

atomic_swap_file "$RUNTIME_DIR/etc/fleet.env.template" "$PROV_PREFIX/etc/fleet.env.template"

say "release en place sous $PROV_PREFIX (version : $(cat "$PROV_PREFIX/rel/lcars_fleet/releases/start_erl.data" 2>/dev/null || echo '?'))."
