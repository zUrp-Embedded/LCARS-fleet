#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/60-deploy.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — deploy du runtime : orchestre etc/install.sh (l'autorité build+pose) puis verrouille RO
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

RUNTIME_DIR="$(repo_root)/fleet"
MANIFEST="$RUNTIME_DIR/etc/install.manifest"
mf_entries() { # « <nom> <exec|noexec> <link:0|1> » par entrée, commentaires/vides sautés
  awk 'NF && $1 !~ /^#/ { print $1, $2, ($3 == "link" ? 1 : 0) }' "$MANIFEST"
}

release_present() { [[ -x "$PREFIX_REL/bin/lcars_fleet" ]]; }
PREFIX_REL="$PROV_PREFIX/rel/lcars_fleet"

build_sha() {
  local matches=("$PREFIX_REL"/lib/lcars_fleet-*/priv/api/build_info.txt)
  [[ -f "${matches[0]}" ]] || return 0
  sed -n 's/^sha=//p' "${matches[0]}" 2>/dev/null | head -1 || true
}

check() {
  [[ -f "$MANIFEST" ]] || { p_fail "manifest introuvable: $MANIFEST (checkout incomplet)"; verdict_check; }

  if release_present; then
    p_ok "release posée ($PROV_PREFIX, build $(build_sha))"
  else
    p_drift "release absente sous $PROV_PREFIX"
    verdict_check   # sans release, sonder perms/liens n'apporte que du bruit
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
      p_drift "bin/$name absent/illisible sous $PROV_PREFIX/bin"
    else
      p_ok "bin/$name"
    fi
    if [[ "$is_link" -eq 1 ]]; then
      if [[ "$(readlink "$PROV_LINK_DIR/$name" 2>/dev/null)" == "$PROV_PREFIX/bin/$name" ]]; then
        p_ok "symlink $PROV_LINK_DIR/$name"
      else
        p_drift "$PROV_LINK_DIR/$name ≠ symlink vers $PROV_PREFIX/bin/$name"
      fi
    else
      [[ -f "$PROV_LINK_DIR/$name" ]] && p_warn "copie morte $PROV_LINK_DIR/$name (invention D3, plus aucun lecteur) — nettoyage manuel : sudo rm $PROV_LINK_DIR/$name"
    fi
  done < <(mf_entries)
  verdict_check
}

apply() {
  [[ -f "$RUNTIME_DIR/mix.exs" ]] || { p_fail "source runtime introuvable: $RUNTIME_DIR"; verdict_apply; }
  [[ -f "$MANIFEST" ]] || { p_fail "manifest introuvable: $MANIFEST (checkout incomplet)"; verdict_apply; }
  command -v mix >/dev/null || { p_fail "mix absent — lance d'abord 15-toolchain"; verdict_apply; }
  id "$PROV_HUMAN" >/dev/null 2>&1 || { p_fail "humain-bâtisseur inconnu: $PROV_HUMAN"; verdict_apply; }

  local src_sha deployed_sha
  # B2 : --short NU des deux côtés — le build embarque le short par défaut de git (abbrev auto,
  # 9 hex sur ce repo) ; un --short=8 côté module ne matchait jamais → rebuild à chaque apply.
  src_sha="$(git -C "$(repo_root)" rev-parse --short HEAD 2>/dev/null || true)"
  deployed_sha="$(build_sha)"
  if [[ -n "$src_sha" && "$src_sha" == "$deployed_sha" ]] \
      && git -C "$(repo_root)" diff --quiet HEAD -- fleet 2>/dev/null && release_present; then
    p_ok "build déployé $deployed_sha == HEAD source (fleet propre) — rien à bâtir"
    local name _mode is_link
    while read -r name _mode is_link; do
      [[ "$is_link" -eq 1 ]] || continue
      ensure_symlink "$PROV_LINK_DIR/$name" "$PROV_PREFIX/bin/$name" || verdict_apply
    done < <(mf_entries)
    verdict_apply
  fi

  if pgrep -f "$PREFIX_REL" >/dev/null 2>&1; then
    p_warn "une fleet tourne depuis $PROV_PREFIX — le swap est sûr, mais « fleet_v2 stop && fleet_v2 start » pour prendre le nouveau build"
  fi

  ensure_dir "$PROV_PREFIX" 0750 "$PROV_HUMAN:$PROV_FLEET_GROUP" || verdict_apply
  chown -R "$PROV_HUMAN:$PROV_FLEET_GROUP" "$PROV_PREFIX" || { p_fail "déverrouillage du prefix"; verdict_apply; }

  # 1-bis. L'OUTILLAGE DU GATE, ET C'EST CE MODULE QUI LE DOIT — pas 10-packages.
  #
  # `etc/install.sh` joue `mix gate`, et le gate REFUSE de sauter ses moitiés hors-mix en silence :
  # `shell_gate` exige `pytest` (les lcars_tests de token-saver) et `bats` (BATS_MISSING_FATAL=1
  # posé par mix.exs), et plusieurs sondes lisent `pgrep` (procps). Aucun de ces trois n'est un
  # paquet de RUNTIME : les mettre dans 10-packages alourdirait toute installation pour un besoin
  # qui n'existe qu'ici, à la minute du build.
  GATE_PACKAGES=(python3-pytest bats procps)
  apt_ensure "${GATE_PACKAGES[@]}" || { p_fail "outillage du gate non installé (${GATE_PACKAGES[*]})"; verdict_apply; }

  p_step "outillage mix (hex + rebar) pour $PROV_HUMAN"
  run_quiet as_human env -C "$RUNTIME_DIR" mix local.hex --force  || verdict_apply
  run_quiet as_human env -C "$RUNTIME_DIR" mix local.rebar --force || verdict_apply

  run_step --ok 3 "build de la release" -- \
    as_human env LCARS_INSTALL_PREFIX="$PROV_PREFIX" LCARS_INSTALL_LINK_DIR="$PROV_LINK_DIR" bash "$RUNTIME_DIR/etc/install.sh"
  local install_rc="$PROV_LAST_RC"
  if [[ "$install_rc" -ne 0 && "$install_rc" -ne 3 ]]; then
    p_fail "etc/install.sh en échec (rc=$install_rc — verrou contracts rouge ? warnings-as-errors ?) — le prefix reste déverrouillé pour inspection"
    verdict_apply
  fi
  release_present || { p_fail "install.sh vert mais release absente ($PREFIX_REL) — incohérence, inspecte"; verdict_apply; }

  chown -R "root:$PROV_FLEET_GROUP" "$PROV_PREFIX" || { p_fail "re-verrouillage chown"; verdict_apply; }
  chmod -R u=rwX,g=rX,o= "$PROV_PREFIX"            || { p_fail "re-verrouillage chmod"; verdict_apply; }

  local name _mode is_link
  while read -r name _mode is_link; do
    [[ "$is_link" -eq 1 ]] || continue
    ensure_symlink "$PROV_LINK_DIR/$name" "$PROV_PREFIX/bin/$name" || verdict_apply
  done < <(mf_entries)

  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "runtime déployé : $PROV_PREFIX (build $(build_sha)) + /usr/local/bin câblé"
  verdict_apply
}

case "${1:?usage: 60-deploy.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
