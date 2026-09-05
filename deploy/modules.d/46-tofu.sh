#!/usr/bin/env bash
# SOURCE: deploy/modules.d/46-tofu.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: PROTO-V2 — OpenTofu et son miroir de providers, SUR LA MACHINE : la structure de forge n'a plus besoin d'une image
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

TOFU_VERSION="${LCARS_TOFU_VERSION:-1.12.3}"
TOFU_SHA256_AMD64=46b48c3438c65cf479fc076c9281422ffa2f493548d1e813d154c835c5986a08
TOFU_SHA256_ARM64=b2110d1ce46e366ce861b7f53d293dad99080075629aed7fb50d7328916d91c2
TOFU_BIN_CANON=/usr/local/bin/tofu    # le chemin que deploy/system.manifest declare (anchor)
TOFU_BIN="${LCARS_TOFU_BIN:-$TOFU_BIN_CANON}"
TOFU_DIR_CANON="$PROV_ROOT/tofu"      # idem (dir tofu, dir tofu/providers)
TOFU_DIR="${LCARS_TOFU_DIR:-$TOFU_DIR_CANON}"
# ⚠ LE MODE ET LE PROPRIETAIRE VIENNENT DE LA TABLE, PLUS D'UN LITTERAL (lot 15). Ce module POSE
# `tofu`, `tofu/providers` et l'ancre : il est le seul a pouvoir relire leur mode — les ajouter a
# la table de `25-directories` en ferait un second poseur (mur POSEUR). La table les declarait
# `0755 root:root` et aucun module ne les mesurait. Couture de decor sur le proprietaire (un
# temoin ne chown pas vers root), repli historique si la table ne dit rien.
TOFU_OWNER="${LCARS_TOFU_OWNER:-$(prov_manifest_owner "$TOFU_DIR_CANON")}"
: "${TOFU_OWNER:=root:root}"
tofu_mode() { # tofu_mode <objet canonique> -> le mode que la table declare, sinon 0755
  local m; m="$(prov_manifest_mode "$1")"; printf '%s\n' "${m:-0755}"
}
# tofu_check_perms <chemin pose> <objet canonique> — mode et proprietaire RELUS (stat), contre la
# table. Un objet absent n'est pas juge ici : son absence se dit une fois, avec sa consequence.
tofu_check_perms() {
  local path="$1" cur want
  [[ -e "$path" ]] || return 0
  cur="$(stat -c '%a %U:%G' "$path")"
  want="$(tofu_mode "$2") $TOFU_OWNER"; want="${want#0}"
  if [[ "$cur" == "$want" ]]; then
    p_ok "$path $cur (table)"
  else
    p_drift "$path : $cur ≠ $want (deploy/system.manifest) — l'apply le repose"
  fi
}

tofu_rc() { echo "$TOFU_DIR/tofurc"; }

tofu_arch() { arch_tag debian; }

tofu_installed_version() {
  "$TOFU_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

check() {
  if [[ ! -x "$TOFU_BIN" ]]; then
    p_drift "$TOFU_BIN absent — la structure de la forge est le territoire de tofu, et rien ne peut la poser sans lui"
  else
    local v; v="$(tofu_installed_version)"
    if [[ "$v" == "$TOFU_VERSION" ]]; then
      p_ok "tofu $v posé ($TOFU_BIN)"
    else
      p_drift "tofu $v ≠ version épinglée $TOFU_VERSION ($TOFU_BIN) — la recette tournerait avec d'autres providers"
    fi
    tofu_check_perms "$TOFU_BIN" "$TOFU_BIN_CANON"
  fi

  if [[ -s "$(tofu_rc)" && -d "$TOFU_DIR/providers" ]]; then
    p_ok "miroir de providers hors-ligne posé ($TOFU_DIR/providers)"
  else
    p_drift "miroir de providers absent ($TOFU_DIR) — tofu irait les chercher sur le réseau, ou échouerait"
  fi
  tofu_check_perms "$TOFU_DIR" "$TOFU_DIR_CANON"
  tofu_check_perms "$TOFU_DIR/providers" "$TOFU_DIR_CANON/providers"

  verdict_check
}

apply() {
  local arch want_sha
  arch="$(tofu_arch)"
  case "$arch" in
    amd64) want_sha="$TOFU_SHA256_AMD64" ;;
    arm64) want_sha="$TOFU_SHA256_ARM64" ;;
    *) p_fail "arch non épinglée pour tofu : « $(arch_tag raw) » (attendu amd64 ou arm64)"; verdict_apply ;;
  esac

  if [[ "$(tofu_installed_version)" != "$TOFU_VERSION" ]]; then
    local tmpd; tmpd="$(mktemp -d "${TMPDIR:-/tmp}/lcars-tofu.XXXXXX")" || { p_fail "tofu : tmp impossible"; verdict_apply; }
    fetch_verify "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${arch}.zip" \
      "$want_sha" "$tmpd/tofu.zip" 0644 || { rm -rf "$tmpd"; verdict_apply; }
    unzip -q -o -d "$tmpd/x" "$tmpd/tofu.zip" \
      || { p_fail "tofu : archive illisible"; rm -rf "$tmpd"; verdict_apply; }
    ensure_dir "$(dirname "$TOFU_BIN")" 0755 "$TOFU_OWNER" || { rm -rf "$tmpd"; verdict_apply; }
    install -m "$(tofu_mode "$TOFU_BIN_CANON")" -o "${TOFU_OWNER%%:*}" -g "${TOFU_OWNER##*:}" "$tmpd/x/tofu" "$TOFU_BIN" \
      || { p_fail "tofu : pose ratée ($TOFU_BIN)"; rm -rf "$tmpd"; verdict_apply; }
    rm -rf "$tmpd"
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "tofu $TOFU_VERSION ($TOFU_BIN)"
  fi
  # Un binaire deja a la bonne version n'est pas re-pose : son mode converge a part, comme le reste.
  ensure_mode "$TOFU_BIN" "$(tofu_mode "$TOFU_BIN_CANON")" "$TOFU_OWNER" || verdict_apply

  ensure_dir "$TOFU_DIR" "$(tofu_mode "$TOFU_DIR_CANON")" "$TOFU_OWNER" || verdict_apply
  ensure_dir "$TOFU_DIR/providers" "$(tofu_mode "$TOFU_DIR_CANON/providers")" "$TOFU_OWNER" || verdict_apply
  write_atomic "$(tofu_rc)" 0644 "$TOFU_OWNER" <<EOF || { p_fail "tofurc non posé ($(tofu_rc))"; verdict_apply; }
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

  # ⚠ LE MIROIR SE REFAIT SUR UN VERDICT, PAS À CHAQUE PASSAGE. `providers mirror` va sur le réseau ;
  # `init` hors-ligne, non. Ce dernier est donc le discriminant : s'il passe, le miroir couvre la
  # recette telle qu'elle est AUJOURD'HUI ; s'il échoue, elle a bougé sous lui et on le refait.
  # C'est aussi la seule chose qui PROUVE que le miroir est complet — le Dockerfile le joue pour la
  # même raison, et il coûte une seconde.
  # ⚠ CETTE SONDE N'EST PAS `run_quiet`, ET LA CONFONDRE REND UN FAUX ROUGE. `run_quiet` a pour
  # contrat que l'échec COMPTE : il appelle `p_fail` et incrémente `PROV_FAILED`. Or l'échec est
  # ATTENDU ici — au premier passage le miroir n'existe pas encore, c'est tout ce que cet init
  # mesure. Vu à froid : deux FAIL et un verdict rouge sur un module dont le
  # miroir venait d'être posé correctement.
  # ⚠ ET L'INIT NE SE JOUE PAS DANS L'ARBRE DE L'OPÉRATEUR. `tofu init` ÉCRIT — il pose un
  # `.terraform/` à côté de la recette — et ce module tourne en root. Vu au nettoyage d'un banc : l'opérateur ne pouvait plus effacer son propre checkout, `Permission denied` sur
  # chaque provider. `60-deploy` porte déjà la règle pour l'autre outil (« un build root polluerait
  # le `_build` du checkout ») ; elle vaut pour tout ce qui écrit, pas pour mix seul.
  local src work
  src="$(product_tree)/services/forge-recipe"
  [[ -d "$src" ]] || { p_fail "recette absente : $src"; verdict_apply; }
  work="$(mktemp -d "${TMPDIR:-/tmp}/lcars-tofu-recipe.XXXXXX")" \
    || { p_fail "tofu : tmp impossible"; verdict_apply; }
  cp -a "$src/." "$work/" || { p_fail "recette non copiable ($src)"; rm -rf "$work"; verdict_apply; }
  rm -rf "$work/.terraform" "$work/instance/.terraform"
  local mods=("$work/instance" "$work")

  local m offline=1
  for m in "${mods[@]}"; do
    [[ -d "$m" ]] || { p_fail "recette incomplète : $m"; rm -rf "$work"; verdict_apply; }
    TF_CLI_CONFIG_FILE="$(tofu_rc)" env -C "$m" "$TOFU_BIN" init -input=false -no-color >/dev/null 2>&1 \
      || offline=0
  done
  if [[ "$offline" -eq 1 ]]; then
    rm -rf "$work"
    p_ok "miroir de providers complet (init hors-ligne OK)"
    verdict_apply
  fi

  for m in "${mods[@]}"; do
    TF_CLI_CONFIG_FILE="$(tofu_rc)" run_quiet env -C "$m" "$TOFU_BIN" providers mirror -platform="linux_${arch}" "$TOFU_DIR/providers" \
      || { p_fail "miroir de providers : échec sur $m"; rm -rf "$work"; verdict_apply; }
  done
  chmod -R a+rX "$TOFU_DIR" 2>/dev/null || true
  for m in "${mods[@]}"; do
    TF_CLI_CONFIG_FILE="$(tofu_rc)" run_quiet env -C "$m" "$TOFU_BIN" init -input=false -no-color \
      || { p_fail "tofu : init hors-ligne en échec dans $m APRÈS miroir — le miroir ne couvre pas la recette"; rm -rf "$work"; verdict_apply; }
  done
  rm -rf "$work"
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "miroir de providers hors-ligne ($TOFU_DIR/providers)"
  verdict_apply
}

case "${1:?usage: 46-tofu.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
