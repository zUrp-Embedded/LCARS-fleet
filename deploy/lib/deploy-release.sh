#!/usr/bin/env bash
# SOURCE: deploy/lib/deploy-release.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-22
# STATUS: la release du runtime — bâtie depuis les sources (gate puis mix release) ou reprise du kit, posée sous le préfixe et câblée sur le PATH
#
# ENV   LCARS_INSTALL_PREFIX      où la release est posée (défaut /opt/lcars/runtime)
#       LCARS_INSTALL_LINK_DIR    où ses commandes sont câblées (défaut /usr/local/bin)
#       LCARS_INSTALL_SKIP_GATE=1 saute le gate avant le build ; la release n'est alors pas attestée
# EXIT  0 posée et câblée · 1 échec, rien d'utilisable posé · 3 posée, mais au moins un lien du PATH manque
set -euo pipefail

say() { echo "install: $*" >&2; }
die() { echo "install: ERREUR — $*" >&2; exit 1; }

atomic_swap_dir() {
  local src="$1" dst="$2" probe="$3"
  local stage="${dst}.staging.$$" prev="${dst}.prev"

  rm -rf "$stage"
  cp -a "$src" "$stage" || { rm -rf "$stage"; die "copie du build vers le staging echouee ($stage)"; }

  [[ -x "$stage/$probe" ]] || { rm -rf "$stage"; die "build stage invalide : $probe absent ou non-executable"; }

  rm -rf "$prev"
  [[ -e "$dst" ]] && mv "$dst" "$prev"
  mv "$stage" "$dst"
}

atomic_swap_file() {
  local src="$1" dst="$2"
  local tmp="${dst}.new.$$"

  cp -a "$src" "$tmp" || { rm -f "$tmp"; die "copie de $(basename "$dst") vers le staging echouee"; }
  mv "$tmp" "$dst"
}

release_app_dir() { # release_app_dir <racine de release> -> lib/lcars_fleet-<vsn> de la version qui DEMARRE
  local root="$1" vsn d
  vsn="$(awk '{print $2; exit}' "$root/releases/start_erl.data" 2>/dev/null || true)"
  if [[ -n "$vsn" && -d "$root/lib/lcars_fleet-$vsn" ]]; then printf '%s\n' "$root/lib/lcars_fleet-$vsn"; return 0; fi
  d=("$root"/lib/lcars_fleet-*)
  [[ "${#d[@]}" -eq 1 && -d "${d[0]}" ]] && { printf '%s\n' "${d[0]}"; return 0; }
  return 1
}

build_release() {
  local runtime_dir="$1"

  local rel="$runtime_dir/_build/prod/rel/lcars_fleet"
  if [[ -x "$rel/bin/lcars_fleet" ]]; then
    if [[ -f "$runtime_dir/../.source-revision" ]]; then
      echo "install: kit — release bâtie par pack.sh, déjà passée au gate : ni gate ni compilation" >&2
      return 0
    fi
    local src_sha built_sha m
    src_sha="$(git -C "$runtime_dir" rev-parse --short HEAD 2>/dev/null || true)"
    m="$(release_app_dir "$rel" || true)"
    [[ -n "$m" && -f "$m/priv/api/build_info.txt" ]] && built_sha="$(sed -n 's/^sha=//p' "$m/priv/api/build_info.txt" 2>/dev/null | head -1)"
    if [[ -n "$src_sha" && "$src_sha" == "${built_sha:-}" ]] \
       && git -C "$runtime_dir" diff --quiet HEAD -- . 2>/dev/null; then
      echo "install: release déjà bâtie et attestée ($src_sha, arbre propre) — ni gate ni compilation" >&2
      return 0
    fi
    echo "install: un _build/prod/rel existe mais n'atteste pas cette source (build ${built_sha:-inconnu} vs HEAD ${src_sha:-inconnu}) — rebâti" >&2
  fi

  (
    set -e
    cd "$runtime_dir"
    MIX_ENV=prod mix deps.get >/dev/null || exit 1

    if [[ "${LCARS_INSTALL_SKIP_GATE:-0}" == "1" ]]; then
      echo "install: gate sauté (LCARS_INSTALL_SKIP_GATE=1) : la release ne sera pas attestée par le gate de ce commit" >&2
    else
      echo "install: gate complet sur l'arbre source (compile-strict + tests + bats + topologie + dialyzer)…" >&2
      MIX_ENV="test" mix gate || exit 1   # les guillemets : sans eux, SC2209 lit « test » comme une commande
    fi

    rm -rf "_build/prod/rel/lcars_fleet"
    MIX_ENV=prod mix release --overwrite || exit 1
  )
}

# shellcheck disable=SC2120
refuse_root() {
  local uid="${1:-$EUID}"
  [[ "$uid" -ne 0 ]] || die "lancé en root — le build laisserait des artefacts root dans l'arbre source. À lancer sous le compte propriétaire de l'install ; seule la pose demande des droits"
}

require_prefix_writable() {
  local prefix="$1" probe="$1"
  while [[ ! -e "$probe" && "$probe" != "/" ]]; do probe="$(dirname "$probe")"; done
  [[ -w "$probe" ]] || die "prefix non inscriptible : $probe (destination $prefix). À lancer sous le compte propriétaire, ou lui donner le droit d'écriture — pas en sudo"
}

wire_path_links() {
  local i f
  link_fail=0
  linked=""

  for i in "${!MF_FILES[@]}"; do
    [[ "${MF_LINKS[$i]}" -eq 1 ]] || continue
    f="${MF_FILES[$i]}"

    if ln -sf "$PREFIX/bin/$f" "$LINK_DIR/$f" 2>/dev/null; then
      linked="$linked $f"
    else
      link_fail=1
      say "lien $LINK_DIR/$f non posé (droits ?) — à la main : sudo ln -sf $PREFIX/bin/$f $LINK_DIR/"
    fi
  done

  [[ "$link_fail" -eq 0 ]] &&
    say "liens $LINK_DIR/{${linked# }} → $PREFIX/bin/ (entrées « link » du manifest)"

  return "$link_fail"
}

prune_bin_dir() {
  local e f m known
  for e in "$PREFIX"/bin/*; do
    [[ -e "$e" || -L "$e" ]] || continue
    f="${e##*/}"
    known=0
    for m in "${MF_FILES[@]}"; do [[ "$m" == "$f" ]] && { known=1; break; }; done
    [[ "$known" -eq 0 ]] || continue
    if rm -rf -- "$e"; then
      say "retire $e (absent du manifest)"
    else
      say "retrait impossible : $e (absent du manifest, droits ?) — à la main : sudo rm -rf $e"
    fi
    if [[ -L "$LINK_DIR/$f" && "$(readlink "$LINK_DIR/$f")" == "$PREFIX/bin/$f" ]]; then
      if rm -f -- "$LINK_DIR/$f" 2>/dev/null; then
        say "retire le lien $LINK_DIR/$f (il pointait sur $e, absent du manifest)"
      else
        say "lien $LINK_DIR/$f non retiré (droits ?) — il pointe sur un fichier retiré ; 60-deploy le retire en root, ou : sudo rm $LINK_DIR/$f"
      fi
    fi
  done
  return 0
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

PREFIX="${LCARS_INSTALL_PREFIX:-/opt/lcars/runtime}"
LINK_DIR="${LCARS_INSTALL_LINK_DIR:-/usr/local/bin}"   # lu par la pose (elagage) ET par le cablage

SELF="$(readlink -f "$0")"
RUNTIME_DIR="${LCARS_RUNTIME_DIR:-$(readlink -f "$(dirname "$SELF")/../../runtime")}"
ETC_DIR="$RUNTIME_DIR/etc"
SRC_BIN="$RUNTIME_DIR/bin"

RAW_PREFIX="$PREFIX"
PREFIX="${PREFIX%/}"
case "$PREFIX" in
  /?*/?*) : ;;
  *) die "LCARS_INSTALL_PREFIX doit etre absolu, profondeur >= 2 (recu : '$RAW_PREFIX')" ;;
esac

MANIFEST="$ETC_DIR/release.manifest"
[[ -f "$MANIFEST" ]] || die "manifest absent : $MANIFEST (checkout incomplet ?)"
declare -a MF_FILES=() MF_MODES=() MF_LINKS=()
while read -r mf_name mf_mode mf_flag mf_extra; do
  [[ -z "$mf_name" || "$mf_name" == \#* ]] && continue
  [[ -z "$mf_extra" ]] || die "manifest : token en trop « $mf_extra » sur l'entree « $mf_name »"
  case "$mf_mode" in
    exec|noexec) : ;;
    *) die "manifest : mode inconnu « ${mf_mode:-<vide>} » pour « $mf_name » (exec|noexec)" ;;
  esac
  mf_link=0
  if [[ -n "$mf_flag" ]]; then
    [[ "$mf_flag" == "link" ]] || die "manifest : flag inconnu « $mf_flag » pour « $mf_name » (seul : link)"
    mf_link=1
  fi
  MF_FILES+=("$mf_name"); MF_MODES+=("$mf_mode"); MF_LINKS+=("$mf_link")
done < "$MANIFEST"
[[ "${#MF_FILES[@]}" -gt 0 ]] || die "manifest vide : $MANIFEST"

[[ -f "$RUNTIME_DIR/mix.exs" ]] || die "pas la racine du runtime source ($RUNTIME_DIR/mix.exs absent)"
if [[ ! -f "$RUNTIME_DIR/../.source-revision" ]]; then
  command -v mix >/dev/null 2>&1 || die "mix introuvable (Elixir requis pour construire la release)"
fi

# shellcheck disable=SC2119  # sans argument = le defaut `$EUID` : c'est le cas de production.
refuse_root
require_prefix_writable "$PREFIX"

say "build release prod (gate complet puis MIX_ENV=prod mix release)…"
build_release "$RUNTIME_DIR" || die "gate rouge ou build en échec — la release n'est pas posée (arbre source non attesté)"
REL_SRC="$RUNTIME_DIR/_build/prod/rel/lcars_fleet"
[[ -x "$REL_SRC/bin/lcars_fleet" ]] || die "release introuvable une fois le build fini ($REL_SRC)"

say "pose sous $PREFIX…"
mkdir -p "$PREFIX/bin" "$PREFIX/etc" "$PREFIX/rel"

atomic_swap_dir "$REL_SRC" "$PREFIX/rel/lcars_fleet" "bin/lcars_fleet"

for i in "${!MF_FILES[@]}"; do
  f="${MF_FILES[$i]}"
  [[ -e "$SRC_BIN/$f" ]] || die "entrée du manifest absente du source bin/ : $f"
  atomic_swap_file "$SRC_BIN/$f" "$PREFIX/bin/$f"
  if [[ "${MF_MODES[$i]}" == "exec" ]]; then
    chmod +x "$PREFIX/bin/$f" || die "chmod +x refusé : $PREFIX/bin/$f"
  fi
done
prune_bin_dir

atomic_swap_file "$RUNTIME_DIR/etc/fleet.env.template" "$PREFIX/etc/fleet.env.template"

if chgrp -R fleet "$PREFIX" 2>/dev/null; then
  if chmod -R g+rX,g-w,o-rwx "$PREFIX" 2>/dev/null; then
    say "modes : groupe fleet en lecture seule, rien pour les autres"
  else
    say "chmod refusé — la lecture seule (groupe r-x, autres rien) n'est pas en place ; 60-deploy la pose en root"
  fi
else
  say "chgrp fleet refusé (droits ?) — 60-deploy le pose en root"
fi

wire_path_links || true

if [[ "$link_fail" -ne 0 ]]; then
  say "installation incomplète — la release est en place sous $PREFIX, mais au moins un lien de"
  say "  $LINK_DIR n'a pas pu être posé (voir les lignes « lien … non posé » ci-dessus)."
  say "  Les commandes du PATH sont donc absentes, ou pointent encore sur une version précédente."
  say "  Réparer les liens ci-dessus, ou relancer avec les droits sur $LINK_DIR."
  exit 3
fi

say "release en place sous $PREFIX (version : $(cat "$PREFIX/rel/lcars_fleet/releases/start_erl.data" 2>/dev/null || echo '?'))."
say "Lancer : fleet start   (l'état par humain vit sous ~/.lcars/ ; le dépôt n'est pas requis à l'exécution)."
