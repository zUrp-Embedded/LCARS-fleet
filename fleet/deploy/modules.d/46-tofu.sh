#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/46-tofu.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: PROTO-V2 — OpenTofu et son miroir de providers, SUR LA MACHINE : la structure de forge n'a plus besoin d'une image
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
#
# `48-forge-host` pose la structure de la forge et a besoin de tofu POUR ÇA. `62-runtime-helpers`,
# qui pose le reste des auxiliaires, tourne quatorze crans plus tard : y mettre tofu l'aurait rendu
# indisponible au moment exact où la forge en a besoin. L'ordre est le préfixe, et le préfixe porte
# le sens — même leçon que `22-fleet-human`, renommé de 65 à 22 pour la même raison.
#

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

TOFU_VERSION="${LCARS_TOFU_VERSION:-1.12.3}"
TOFU_SHA256_AMD64=46b48c3438c65cf479fc076c9281422ffa2f493548d1e813d154c835c5986a08
TOFU_SHA256_ARM64=b2110d1ce46e366ce861b7f53d293dad99080075629aed7fb50d7328916d91c2
# Seams de test — le binaire et la racine du miroir. Le premier existe parce qu'un poste de dev peut
# déjà porter un `tofu` posé à la main (mesuré le 2026-08-22 : un symlink de juillet sur cette
# machine), et un témoin qui ne le nomme pas mesure la machine au lieu de la règle.
TOFU_BIN="${LCARS_TOFU_BIN:-/usr/local/bin/tofu}"
# La racine vient de la lib — un second defaut ici serait un second decideur.
TOFU_DIR="${LCARS_TOFU_DIR:-$PROV_ROOT/tofu}"
TOFU_OWNER="${LCARS_TOFU_OWNER:-root:root}"

tofu_rc() { echo "$TOFU_DIR/tofurc"; }

tofu_arch() { arch_tag debian; }

tofu_installed_version() {
  "$TOFU_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

check() {
  # ⚠ LA VERSION SE SONDE, PAS LA PRÉSENCE. Un tofu du système, posé par quelqu'un d'autre et d'une
  # autre version, jouerait la recette avec d'autres providers — et la structure de la forge est son
  # territoire exclusif. Un pin ne vaut que si l'on vérifie ce qu'on a.
  if [[ ! -x "$TOFU_BIN" ]]; then
    p_drift "$TOFU_BIN absent — la structure de la forge est le territoire de tofu, et rien ne peut la poser sans lui"
  else
    local v; v="$(tofu_installed_version)"
    if [[ "$v" == "$TOFU_VERSION" ]]; then
      p_ok "tofu $v posé ($TOFU_BIN)"
    else
      p_drift "tofu $v ≠ version épinglée $TOFU_VERSION ($TOFU_BIN) — la recette tournerait avec d'autres providers"
    fi
  fi

  if [[ -s "$(tofu_rc)" && -d "$TOFU_DIR/providers" ]]; then
    p_ok "miroir de providers hors-ligne posé ($TOFU_DIR/providers)"
  else
    p_drift "miroir de providers absent ($TOFU_DIR) — tofu irait les chercher sur le réseau, ou échouerait"
  fi

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
    install -m 0755 -o "${TOFU_OWNER%%:*}" -g "${TOFU_OWNER##*:}" "$tmpd/x/tofu" "$TOFU_BIN" \
      || { p_fail "tofu : pose ratée ($TOFU_BIN)"; rm -rf "$tmpd"; verdict_apply; }
    rm -rf "$tmpd"
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "tofu $TOFU_VERSION ($TOFU_BIN)"
  fi

  ensure_dir "$TOFU_DIR/providers" 0755 "$TOFU_OWNER" || verdict_apply
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
  # mesure. Mesuré à froid le 2026-08-22 : deux FAIL et un verdict rouge sur un module dont le
  # miroir venait d'être posé correctement.
  # ⚠ ET L'INIT NE SE JOUE PAS DANS L'ARBRE DE L'OPÉRATEUR. `tofu init` ÉCRIT — il pose un
  # `.terraform/` à côté de la recette — et ce module tourne en root. Mesuré au nettoyage de .63 le
  # 2026-08-22 : l'opérateur ne pouvait plus effacer son propre checkout, `Permission denied` sur
  # chaque provider. `60-deploy` porte déjà la règle pour l'autre outil (« un build root polluerait
  # le `_build` du checkout ») ; elle vaut pour tout ce qui écrit, pas pour mix seul.
  #
  # On travaille donc sur une COPIE jetable. Ce qui sort d'ici est le miroir, pas l'état : le
  # `.terraform/` de la copie meurt avec elle, et c'est ce qu'on veut — un état tofu décrit un
  # répertoire à SON chemin, il ne se transporte pas.
  local src work
  src="$(repo_root)/fleet/deploy/deps"
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
