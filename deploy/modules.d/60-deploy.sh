#!/usr/bin/env bash
# SOURCE: deploy/modules.d/60-deploy.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: la release du runtime — bâtie (ou reprise du kit) par deploy-release.sh sous l'humain, verrouillée root:fleet, câblée sur le PATH
# APPLY-ON: wsl linux docker
# CHECK-ON: any
# NEEDS: root

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

RUNTIME_DIR="$(product_tree)"
MANIFEST="$RUNTIME_DIR/etc/release.manifest"
PREFIX_REL="$PROV_PREFIX/rel/lcars_fleet"

mf_entries() { # mf_entries → « <nom> <exec|noexec> <link:0|1> » par entrée du manifeste
  awk 'NF && $1 !~ /^#/ { print $1, $2, ($3 == "link" ? 1 : 0) }' "$MANIFEST"
}
mf_names_has() { # mf_names_has <nom> → 0 si le manifeste nomme ce fichier
  local n
  while read -r n _ _; do [[ "$n" == "$1" ]] && return 0; done < <(mf_entries)
  return 1
}
release_present() { [[ -x "$PREFIX_REL/bin/lcars_fleet" ]]; }

intrus_bin() { # intrus_bin → les entrées de $PROV_PREFIX/bin que le manifeste ne nomme pas
  local e
  [[ -d "$PROV_PREFIX/bin" && -x "$PROV_PREFIX/bin" ]] || return 0
  for e in "$PROV_PREFIX"/bin/*; do
    [[ -e "$e" || -L "$e" ]] || continue
    mf_names_has "${e##*/}" || printf '%s\n' "$e"
  done
}
intrus_links() { # intrus_links → les symlinks de $PROV_LINK_DIR qui visent un intrus de $PROV_PREFIX/bin
  local e t
  [[ -d "$PROV_LINK_DIR" && -x "$PROV_LINK_DIR" ]] || return 0
  for e in "$PROV_LINK_DIR"/*; do
    [[ -L "$e" ]] || continue
    t="$(readlink "$e")"
    [[ "$t" == "$PROV_PREFIX/bin/"* ]] || continue
    mf_names_has "${t##*/}" || printf '%s\n' "$e"
  done
}
prune_intrus() { # prune_intrus — retire les intrus des deux côtés, une ligne par retrait
  local e
  while read -r e; do
    [[ -n "$e" ]] || continue
    rm -rf -- "$e" || { p_fail "intrus non retiré : $e"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "retiré $e (absent de release.manifest)"
  done < <(intrus_bin)
  while read -r e; do
    [[ -n "$e" ]] || continue
    rm -f -- "$e" || { p_fail "symlink intrus non retiré : $e"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "retiré symlink $e (sa cible n'est pas dans release.manifest)"
  done < <(intrus_links)
  return 0
}

# mix release --overwrite laisse les lib/lcars_fleet-<ancienne> d'une assemblée précédente : celle qui démarre est dans start_erl.data
release_app_dir() { # release_app_dir <racine de release> → lib/lcars_fleet-<vsn> de la version qui démarre
  local root="$1" vsn d
  vsn="$(awk '{print $2; exit}' "$root/releases/start_erl.data" 2>/dev/null || true)"
  if [[ -n "$vsn" && -d "$root/lib/lcars_fleet-$vsn" ]]; then printf '%s\n' "$root/lib/lcars_fleet-$vsn"; return 0; fi
  d=("$root"/lib/lcars_fleet-*)
  [[ "${#d[@]}" -eq 1 && -d "${d[0]}" ]] && { printf '%s\n' "${d[0]}"; return 0; }
  return 1
}
build_sha() {
  local d; d="$(release_app_dir "$PREFIX_REL" || true)"
  [[ -n "$d" && -f "$d/priv/api/build_info.txt" ]] || return 0
  sed -n 's/^sha=//p' "$d/priv/api/build_info.txt" 2>/dev/null | head -1 || true
}
release_libs_count() { local d=("$PREFIX_REL"/lib/lcars_fleet-*); [[ -d "${d[0]}" ]] && printf '%s\n' "${#d[@]}" || printf '0\n'; }

# le canal s'écrit après la pose, jamais avant : écrit d'abord, une pose ratée laisserait une machine « kit » qui n'a rien
poser_canal() { prov_channel_write "$(prov_channel_here)"; }

check() {
  [[ -f "$MANIFEST" ]] || { p_fail "manifest introuvable: $MANIFEST (checkout incomplet)"; verdict_check; }
  local _pfx; _pfx="$(prov_file_state "$PROV_PREFIX")"
  if release_present; then
    p_ok "release posée ($PROV_PREFIX, build $(build_sha))"
    local _nl; _nl="$(release_libs_count)"
    [[ "$_nl" -le 1 ]] || p_drift "la release posée porte $_nl lib/lcars_fleet-* — une assemblée n'en a qu'une ; celle qui démarre est $(release_app_dir "$PREFIX_REL" 2>/dev/null | sed 's|.*/||'), l'autre est morte"
  elif [[ "$_pfx" != "present" && "$_pfx" != "absent" ]]; then
    p_warn "release non mesurable — $PROV_PREFIX $(prov_state_why "$_pfx" "$PROV_PREFIX")"
    verdict_check
  else
    p_drift "release absente sous $PROV_PREFIX"
    verdict_check
  fi
  local cur
  cur="$(stat -c '%U:%G %a' "$PROV_PREFIX")"
  if [[ "$cur" == "root:$PROV_FLEET_GROUP 750" ]]; then
    p_ok "verrou RO du prefix ($cur)"
  else
    p_drift "prefix non verrouillé : $cur ≠ root:$PROV_FLEET_GROUP 750"
  fi
  local name mode is_link
  while read -r name mode is_link; do
    if [[ "$mode" == "exec" && ! -x "$PROV_PREFIX/bin/$name" ]]; then
      p_drift "bin/$name absent/non exécutable sous $PROV_PREFIX/bin"
    elif [[ "$mode" == "noexec" && ! -r "$PROV_PREFIX/bin/$name" ]]; then
      case "$(prov_file_state "$PROV_PREFIX/bin/$name")" in
        absent) p_drift "bin/$name absent sous $PROV_PREFIX/bin — l'apply le pose" ;;
        *)      p_warn  "bin/$name $(prov_state_why "$(prov_file_state "$PROV_PREFIX/bin/$name")" "$PROV_PREFIX/bin/$name")" ;;
      esac
    else
      p_ok "bin/$name"
    fi
    if [[ "$is_link" -eq 1 ]]; then
      if [[ "$(readlink "$PROV_LINK_DIR/$name" 2>/dev/null)" == "$PROV_PREFIX/bin/$name" ]]; then
        p_ok "symlink $PROV_LINK_DIR/$name"
      else
        p_drift "$PROV_LINK_DIR/$name ≠ symlink vers $PROV_PREFIX/bin/$name"
      fi
    fi
  done < <(mf_entries)
  local e
  while read -r e; do
    [[ -n "$e" ]] || continue
    p_drift "intrus $e — absent de release.manifest : l'apply le retire"
  done < <(intrus_bin)
  while read -r e; do
    [[ -n "$e" ]] || continue
    p_drift "symlink intrus $e → $(readlink "$e") — sa cible n'est pas dans release.manifest : l'apply le retire"
  done < <(intrus_links)
  if [[ -d "$PREFIX_REL.prev" ]]; then
    p_ok "génération précédente gardée : $PREFIX_REL.prev ($(du -sh "$PREFIX_REL.prev" 2>/dev/null | cut -f1 || echo '?')) — rollback de deploy-release.sh ; « sudo rm -rf $PREFIX_REL.prev » pour libérer l'espace"
  fi
  verdict_check
}

apply() {
  # la copie posée sert à rejouer, pas à reconstruire : sans mix.exs, la release en place est l'état-cible
  if prov_dans_la_copie && [[ ! -f "$RUNTIME_DIR/mix.exs" ]] && release_present; then
    p_ok "rejeu depuis la copie posée : release en place, aucune source ici ($RUNTIME_DIR) — rien à bâtir"
    poser_canal || verdict_apply
    verdict_apply
  fi
  [[ -f "$RUNTIME_DIR/mix.exs" ]] || { p_fail "source runtime introuvable: $RUNTIME_DIR"; verdict_apply; }
  [[ -f "$MANIFEST" ]] || { p_fail "manifest introuvable: $MANIFEST (checkout incomplet)"; verdict_apply; }
  if ! prov_delivery_is_binary; then
    command -v mix >/dev/null || { p_fail "mix absent — 15-toolchain le pose"; verdict_apply; }
  fi
  id "$PROV_HUMAN" >/dev/null 2>&1 || { p_fail "humain-bâtisseur inconnu: $PROV_HUMAN"; verdict_apply; }

  # --short nu des deux côtés : le build embarque le short par défaut de git
  local src_sha deployed_sha
  src_sha="$(git -C "$(repo_root)" rev-parse --short HEAD 2>/dev/null || true)"
  deployed_sha="$(build_sha)"
  if [[ -n "$src_sha" && "$src_sha" == "$deployed_sha" ]] \
      && git -C "$(repo_root)" diff --quiet HEAD -- runtime 2>/dev/null && release_present; then
    p_ok "build déployé $deployed_sha == HEAD source (runtime/ propre) — rien à bâtir"
    local name _mode is_link
    while read -r name _mode is_link; do
      [[ "$is_link" -eq 1 ]] || continue
      ensure_symlink "$PROV_LINK_DIR/$name" "$PROV_PREFIX/bin/$name" || verdict_apply
    done < <(mf_entries)
    prune_intrus || verdict_apply
    poser_canal || verdict_apply
    verdict_apply
  fi

  if pgrep -f "$(prov_pgrep_pattern "$PREFIX_REL")" >/dev/null 2>&1; then
    p_warn "une fleet tourne depuis $PROV_PREFIX — le swap est sûr, mais « fleet stop && fleet start » pour prendre le nouveau build"
  fi
  ensure_dir "$PROV_PREFIX" 0750 "$PROV_HUMAN:$PROV_FLEET_GROUP" || verdict_apply
  chown -R "$PROV_HUMAN:$PROV_FLEET_GROUP" "$PROV_PREFIX" || { p_fail "déverrouillage du prefix"; verdict_apply; }
  if prov_delivery_is_binary; then
    p_ok "outillage mix non posé — livraison binaire, la release est déjà bâtie"
  else
    p_step "outillage mix (hex + rebar) pour $PROV_HUMAN"
    run_quiet as_human env -C "$RUNTIME_DIR" mix local.hex --force  || verdict_apply
    run_quiet as_human env -C "$RUNTIME_DIR" mix local.rebar --force || verdict_apply
  fi
  # LCARS_INSTALL_SKIP_GATE : l'installation compile et pose, l'attestation de la source vient de la CI et de pack.sh
  local etape="build de la release"
  ! prov_delivery_is_binary || etape="pose de la release depuis le kit"
  run_step --ok 3 "$etape" -- \
    as_human env LCARS_INSTALL_PREFIX="$PROV_PREFIX" LCARS_INSTALL_LINK_DIR="$PROV_LINK_DIR" LCARS_RUNTIME_DIR="$RUNTIME_DIR" \
      LCARS_INSTALL_SKIP_GATE=1 bash "$(dirname "$PROVISION_LIB")/deploy-release.sh" \
    || { p_warn "le prefix reste déverrouillé pour inspection"; verdict_apply; }
  release_present || { p_fail "deploy-release.sh vert mais release absente ($PREFIX_REL) — incohérence à inspecter"; verdict_apply; }
  chown -R "root:$PROV_FLEET_GROUP" "$PROV_PREFIX" || { p_fail "re-verrouillage chown"; verdict_apply; }
  chmod -R u=rwX,g=rX,o= "$PROV_PREFIX"            || { p_fail "re-verrouillage chmod"; verdict_apply; }
  local name _mode is_link
  while read -r name _mode is_link; do
    [[ "$is_link" -eq 1 ]] || continue
    ensure_symlink "$PROV_LINK_DIR/$name" "$PROV_PREFIX/bin/$name" || verdict_apply
  done < <(mf_entries)
  prune_intrus || verdict_apply
  poser_canal || verdict_apply
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "runtime déployé : $PROV_PREFIX (build $(build_sha)) + /usr/local/bin câblé"
  verdict_apply
}

case "${1:?usage: 60-deploy.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
