#!/usr/bin/env bash
# SOURCE: deploy/modules.d/60-deploy.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: la release du runtime — bâtie (ou reprise du kit) par deploy-release.sh sous l'humain, verrouillée root:fleet, câblée sur le PATH
# APPLY-ON: wsl linux docker
# CHECK-ON: any
# NEEDS: root
# AFTER: 10-packages 15-toolchain 20-groups 25-directories

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
  [[ -d "$PROV_PREFIX/bin" ]] || return 0
  for e in "$PROV_PREFIX"/bin/*; do
    [[ -e "$e" || -L "$e" ]] || continue
    mf_names_has "${e##*/}" || printf '%s\n' "$e"
  done
}
intrus_links() { # intrus_links → les symlinks de $PROV_LINK_DIR qui visent un intrus de $PROV_PREFIX/bin
  local e t
  [[ -d "$PROV_LINK_DIR" ]] || return 0
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

build_sha() {
  local d; d="$(release_app_dir "$PREFIX_REL" || true)"
  [[ -n "$d" && -f "$d/priv/api/build_info.txt" ]] || return 0
  sed -n 's/^sha=//p' "$d/priv/api/build_info.txt" 2>/dev/null | head -1 || true
}

source_build() { # source_build → la révision que porte la source, vide si runtime/ est modifié ou si rien ne la dit
  local root; root="$(repo_root)"
  if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$root" diff --quiet HEAD -- runtime 2>/dev/null || return 0
    git -C "$root" rev-parse --short HEAD 2>/dev/null || true
  elif [[ -r "$root/$PROV_SOURCE_STAMP" ]]; then
    head -n1 "$root/$PROV_SOURCE_STAMP" | tr -d '[:space:]'
  fi
}
meme_build() { [[ -n "$1" && -n "$2" && ( "$1" == "$2"* || "$2" == "$1"* ) ]]; }

PREFIX_OWNER="$(prov_owner "root:$PROV_FLEET_GROUP")"
BUILDER_OWNER="$(prov_owner "$PROV_HUMAN:$PROV_FLEET_GROUP")"

prefix_verrouille() {
  [[ "$(stat -c '%U:%G %a' "$PROV_PREFIX" 2>/dev/null)" == "$PREFIX_OWNER 750" ]] || return 1
  [[ -z "$(find "$PROV_PREFIX" \( ! -user "${PREFIX_OWNER%%:*}" -o ! -group "${PREFIX_OWNER##*:}" -o -perm /o=rwx -o -perm /g=w \) -print -quit 2>/dev/null)" ]]
}
verrouiller_prefix() {
  prefix_verrouille && return 0
  chown -R "$PREFIX_OWNER" "$PROV_PREFIX" || { p_fail "re-verrouillage chown de $PROV_PREFIX"; return 1; }
  chmod -R u=rwX,g=rX,o= "$PROV_PREFIX"   || { p_fail "re-verrouillage chmod de $PROV_PREFIX"; return 1; }
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "prefix verrouillé : $PROV_PREFIX ($PREFIX_OWNER 750)"
}

# le canal s'écrit en dernier : écrit avant la pose, une pose ratée laisserait une machine « kit » qui n'a rien
clore_la_pose() {
  local name _mode is_link
  verrouiller_prefix || verdict_apply
  while read -r name _mode is_link; do
    [[ "$is_link" -eq 1 ]] || continue
    ensure_symlink "$PROV_LINK_DIR/$name" "$PROV_PREFIX/bin/$name" || verdict_apply
  done < <(mf_entries)
  prune_intrus || verdict_apply
  prov_channel_write "$(prov_channel_here)" || verdict_apply
}

check() {
  [[ -f "$MANIFEST" ]] || { p_fail "manifest introuvable: $MANIFEST (checkout incomplet)"; verdict_check; }
  if release_present; then
    p_ok "release posée ($PROV_PREFIX, build $(build_sha))"
  else
    p_drift "release absente sous $PROV_PREFIX"
    verdict_check
  fi
  if prefix_verrouille; then
    p_ok "verrou RO du prefix ($PREFIX_OWNER 750)"
  else
    p_drift "prefix non verrouillé : $(stat -c '%U:%G %a' "$PROV_PREFIX") — attendu $PREFIX_OWNER 750, et dans l'arbre rien qui soit à un autre, inscriptible par le groupe ou ouvert aux autres"
  fi
  local name mode is_link
  while read -r name mode is_link; do
    if [[ "$mode" == "exec" && ! -x "$PROV_PREFIX/bin/$name" ]]; then
      p_drift "bin/$name absent/non exécutable sous $PROV_PREFIX/bin"
    elif [[ "$mode" == "noexec" && ! -e "$PROV_PREFIX/bin/$name" ]]; then
      p_drift "bin/$name absent sous $PROV_PREFIX/bin — l'apply le pose"
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
    p_ok "génération précédente gardée : $PREFIX_REL.prev ($(du -sh "$PREFIX_REL.prev" 2>/dev/null | cut -f1 || echo '?')) — « sudo rm -rf $PREFIX_REL.prev » pour libérer l'espace"
  fi
  verdict_check
}

apply() {
  # la copie posée sert à rejouer, pas à reconstruire : sans mix.exs, la release en place est l'état-cible
  if prov_dans_la_copie && [[ ! -f "$RUNTIME_DIR/mix.exs" ]] && release_present; then
    p_ok "rejeu depuis la copie posée : release en place, aucune source ici ($RUNTIME_DIR) — rien à bâtir"
    clore_la_pose
    verdict_apply
  fi
  [[ -f "$RUNTIME_DIR/mix.exs" ]] || { p_fail "source runtime introuvable: $RUNTIME_DIR"; verdict_apply; }
  [[ -f "$MANIFEST" ]] || { p_fail "manifest introuvable: $MANIFEST (checkout incomplet)"; verdict_apply; }

  local src_sha deployed_sha
  src_sha="$(source_build)"
  deployed_sha="$(build_sha)"
  if meme_build "$src_sha" "$deployed_sha" && release_present; then
    p_ok "build déployé $deployed_sha, celui de la source — rien à bâtir"
    clore_la_pose
    verdict_apply
  fi

  if pgrep -f "$(prov_pgrep_pattern "$PREFIX_REL")" >/dev/null 2>&1; then
    p_warn "une fleet tourne depuis $PROV_PREFIX — le swap est sûr, mais « fleet stop && fleet start » pour prendre le nouveau build"
  fi
  ensure_dir "$PROV_PREFIX" 0750 "$BUILDER_OWNER" || verdict_apply
  chown -R "$BUILDER_OWNER" "$PROV_PREFIX" || { p_fail "déverrouillage du prefix"; verdict_apply; }
  if prov_delivery_is_binary; then
    p_ok "outillage mix non posé — livraison binaire, la release est déjà bâtie"
  else
    p_step "outillage mix (hex + rebar) pour $PROV_HUMAN"
    run_quiet as_human env -C "$RUNTIME_DIR" mix local.hex --force  || verdict_apply
    run_quiet as_human env -C "$RUNTIME_DIR" mix local.rebar --force || verdict_apply
  fi
  local etape="build de la release"
  ! prov_delivery_is_binary || etape="pose de la release depuis le kit"
  run_step "$etape" -- as_human env LCARS_RUNTIME_DIR="$RUNTIME_DIR" bash "$(dirname "$PROVISION_LIB")/deploy-release.sh" \
    || { p_warn "$PROV_PREFIX reste déverrouillé pour inspection"; verdict_apply; }
  release_present || { p_fail "deploy-release.sh a rendu 0 sans release ($PREFIX_REL/bin/lcars_fleet) — $PROV_PREFIX reste déverrouillé pour inspection"; verdict_apply; }
  clore_la_pose
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "runtime déployé : $PROV_PREFIX (build $(build_sha)) + $PROV_LINK_DIR câblé"
  verdict_apply
}

case "${1:-}" in check|apply) "$1" ;; *) p_die "mode inconnu: ${1:-} (check|apply)" ;; esac
