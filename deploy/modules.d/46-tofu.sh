#!/usr/bin/env bash
# SOURCE: deploy/modules.d/46-tofu.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: OpenTofu épinglé et son miroir de providers hors-ligne — la structure de la forge se pose sans réseau
# APPLY-ON: wsl linux docker
# CHECK-ON: any
# NEEDS: root

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

TOFU_VERSION=1.12.3
TOFU_SHA256_AMD64=46b48c3438c65cf479fc076c9281422ffa2f493548d1e813d154c835c5986a08
TOFU_SHA256_ARM64=b2110d1ce46e366ce861b7f53d293dad99080075629aed7fb50d7328916d91c2
TOFU_BIN="$PROV_TOFU_BIN"
TOFU_DIR="$PROV_TOFU_DIR"
TOFU_OWNER="$(prov_owner "$(prov_manifest_owner "$TOFU_DIR")")"

tofu_mode() { prov_manifest_mode "$1"; }   # tofu_mode <chemin> → le mode que system.manifest déclare

tofu_check_perms() { # tofu_check_perms <chemin posé>
  local path="$1" cur want
  [[ -e "$path" ]] || return 0
  cur="$(stat -c '%a %U:%G' "$path")"
  want="$(tofu_mode "$path") $TOFU_OWNER"; want="${want#0}"
  if [[ "$cur" == "$want" ]]; then
    p_ok "$path $cur (table)"
  else
    p_drift "$path : $cur ≠ $want (deploy/system.manifest) — l'apply le repose"
  fi
}

tofu_rc() { echo "$TOFU_DIR/tofurc"; }

tofu_installed_version() { # tofu_installed_version → la version que rend le binaire posé, vide s'il n'en rend aucune
  "$TOFU_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

# tofu init écrit un .terraform/ à côté de la recette : elle se joue sur une copie jetable, jamais dans l'arbre
recette_copie() { # recette_copie → pose WORK, la copie de la recette
  local src
  src="${LCARS_FORGE_RECIPE:-$(product_tree)/services/forge-recipe}"
  [[ -d "$src" ]] || { p_fail "recette absente : $src"; return 1; }
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/lcars-tofu-recipe.XXXXXX")" || { p_fail "tofu : tmp impossible"; return 1; }
  cp -a "$src/." "$WORK/" || { p_fail "recette non copiable ($src)"; rm -rf "$WORK"; return 1; }
  rm -rf "$WORK/.terraform" "$WORK/instance/.terraform"
}

# un init hors-ligne qui passe dans les deux modules de la copie prouve que le miroir couvre la recette ;
# chaque init recopie les providers sous TMPDIR, souvent en mémoire : la copie d'un module part avant l'init du suivant
init_hors_ligne() {
  local m
  for m in "$WORK/instance" "$WORK"; do
    TF_CLI_CONFIG_FILE="$(tofu_rc)" env -C "$m" "$TOFU_BIN" init -input=false -no-color >/dev/null 2>&1 || return 1
    rm -rf "$m/.terraform"
  done
}

check() {
  if [[ ! -x "$TOFU_BIN" ]]; then
    p_drift "$TOFU_BIN absent — la structure de la forge se pose avec tofu"
  else
    local v; v="$(tofu_installed_version)"
    if [[ "$v" == "$TOFU_VERSION" ]]; then
      p_ok "tofu $v posé ($TOFU_BIN)"
    else
      p_drift "tofu ${v:-sans version lisible} ≠ version épinglée $TOFU_VERSION ($TOFU_BIN) — la recette tournerait avec d'autres providers"
    fi
    tofu_check_perms "$TOFU_BIN"
  fi
  local WORK=""
  if [[ ! -s "$(tofu_rc)" || ! -x "$TOFU_BIN" ]]; then
    p_drift "miroir de providers absent ($TOFU_DIR) — tofu irait les chercher sur le réseau, ou échouerait"
  elif ! recette_copie; then
    :   # recette_copie a dit l'échec : le miroir n'est pas mesurable sans recette
  elif init_hors_ligne; then
    p_ok "miroir de providers hors-ligne posé ($TOFU_DIR/providers) — il couvre la recette (init hors-ligne OK)"
  else
    p_drift "miroir de providers incomplet ($TOFU_DIR/providers) — l'init hors-ligne de la recette échoue ; l'apply le refait"
  fi
  [[ -z "$WORK" ]] || rm -rf "$WORK"
  tofu_check_perms "$TOFU_DIR"
  tofu_check_perms "$TOFU_DIR/providers"
  verdict_check
}

sha_epingle() { # sha_epingle <arch debian> → le sha256 du binaire, ou 1 si l'arch n'est pas épinglée
  case "$1" in
    amd64) echo "$TOFU_SHA256_AMD64" ;;
    arm64) echo "$TOFU_SHA256_ARM64" ;;
    *) return 1 ;;
  esac
}

poser_binaire() { # poser_binaire <arch> <sha256>
  local arch="$1" want_sha="$2" tmpd
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/lcars-tofu.XXXXXX")" || { p_fail "tofu : tmp impossible"; verdict_apply; }
  fetch_verify "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${arch}.zip" \
    "$want_sha" "$tmpd/tofu.zip" 0644 || { rm -rf "$tmpd"; verdict_apply; }
  unzip -q -o -d "$tmpd/x" "$tmpd/tofu.zip" \
    || { p_fail "tofu : archive illisible"; rm -rf "$tmpd"; verdict_apply; }
  ensure_dir "$(dirname "$TOFU_BIN")" 0755 "$TOFU_OWNER" || { rm -rf "$tmpd"; verdict_apply; }
  install -m "$(tofu_mode "$TOFU_BIN")" -o "${TOFU_OWNER%%:*}" -g "${TOFU_OWNER##*:}" "$tmpd/x/tofu" "$TOFU_BIN" \
    || { p_fail "tofu : pose ratée ($TOFU_BIN)"; rm -rf "$tmpd"; verdict_apply; }
  rm -rf "$tmpd"
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "tofu $TOFU_VERSION ($TOFU_BIN)"
}

apply() {
  local arch sha; arch="$(arch_tag debian)"
  sha="$(sha_epingle "$arch")" \
    || { p_fail "arch non épinglée pour tofu : « $(arch_tag raw) » (attendu amd64 ou arm64)"; verdict_apply; }
  [[ "$(tofu_installed_version)" == "$TOFU_VERSION" ]] || poser_binaire "$arch" "$sha"
  ensure_mode "$TOFU_BIN" "$(tofu_mode "$TOFU_BIN")" "$TOFU_OWNER" || verdict_apply

  ensure_dir "$TOFU_DIR" "$(tofu_mode "$TOFU_DIR")" "$TOFU_OWNER" || verdict_apply
  ensure_dir "$TOFU_DIR/providers" "$(tofu_mode "$TOFU_DIR/providers")" "$TOFU_OWNER" || verdict_apply
  write_atomic "$(tofu_rc)" 0644 "$TOFU_OWNER" <<EOF || verdict_apply
provider_installation {
  filesystem_mirror {
    path    = "$TOFU_DIR/providers"
    include = ["*/*"]
  }
  direct {
    exclude = ["*/*"]
  }
}
EOF

  local WORK m; recette_copie || verdict_apply
  # l'échec de ce premier init est attendu au premier passage
  if init_hors_ligne; then
    rm -rf "$WORK"
    p_ok "miroir de providers complet (init hors-ligne OK)"
    verdict_apply
  fi

  for m in "$WORK/instance" "$WORK"; do
    TF_CLI_CONFIG_FILE="$(tofu_rc)" run_capture env -C "$m" "$TOFU_BIN" providers mirror -platform="linux_${arch}" "$TOFU_DIR/providers" \
      || { p_fail "miroir de providers : échec sur $m"; prov_dump_last; rm -rf "$WORK"; verdict_apply; }
  done
  chmod -R a+rX "$TOFU_DIR" 2>/dev/null || true
  for m in "$WORK/instance" "$WORK"; do
    TF_CLI_CONFIG_FILE="$(tofu_rc)" run_capture env -C "$m" "$TOFU_BIN" init -input=false -no-color \
      || { p_fail "tofu : init hors-ligne en échec dans $m après miroir — le miroir ne couvre pas la recette"; prov_dump_last; rm -rf "$WORK"; verdict_apply; }
  done
  rm -rf "$WORK"
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "miroir de providers hors-ligne ($TOFU_DIR/providers)"
  verdict_apply
}

case "${1:?usage: 46-tofu.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
