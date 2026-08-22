#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/46-tofu.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: PROTO-V2 — OpenTofu et son miroir de providers, SUR LA MACHINE : la structure de forge n'a plus besoin d'une image
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
#
# ─── 124 Mo D'OUTIL TRANSPORTÉS DANS 1,18 Go D'IMAGE ────────────────────────────────────────────
#
# ⚖ USER 2026-08-22 : « tu build une image complète de 1,2 Go juste pour exécuter 100 ko de recette
# tofu ? » — et : « pourquoi tofu ne peut pas tourner directement ? »
#
# Mesuré dans l'image : `tofu` pèse 110 Mo, son miroir de providers 14 Mo. Le rail poste bâtissait
# donc une image de 1,18 Go — dix minutes — qu'il ne DÉMARRE jamais, uniquement pour exécuter ces
# 124 Mo dans un conteneur jetable.
#
# LA CAUSE ÉTAIT HISTORIQUE, PAS ARCHITECTURALE. Le Dockerfile le dit lui-même : « tofu n'était
# installé NULLE PART : ni dans cette image, ni par un module de provision, ni par install.sh ». Il a
# été mis là parce que c'était le seul endroit qui existait alors.
#
# ⚠ ET LE CONTOURNEMENT ÉTAIT DEVENU SA PROPRE JUSTIFICATION. Le conteneur transitoire recevait ses
# fichiers d'autorité par un volume nommé et trois `docker cp`, sous un commentaire qui explique
# — justement — qu'un bind de chemin d'hôte serait INVISIBLE si le daemon vit dans une autre VM.
# C'est vrai, et ce problème n'existe QUE parce qu'on avait choisi de tourner dans un conteneur.
# Sur la machine, les fichiers sont déjà là.
#
# ─── POURQUOI 46, ET PAS AVEC LES AUTRES AUXILIAIRES ────────────────────────────────────────────
#
# `48-forge-host` pose la structure de la forge et a besoin de tofu POUR ÇA. `62-runtime-helpers`,
# qui pose le reste des auxiliaires, tourne quatorze crans plus tard : y mettre tofu l'aurait rendu
# indisponible au moment exact où la forge en a besoin. L'ordre est le préfixe, et le préfixe porte
# le sens — même leçon que `22-fleet-human`, renommé de 65 à 22 pour la même raison.
#
# ─── CE QUI EST GARDÉ : L'HERMÉTISME ────────────────────────────────────────────────────────────
#
# Le conteneur n'apportait qu'une chose de valeur — une version figée et des providers qui ne
# dépendent pas du réseau. Les deux sont rendues par le pin sha256 et le miroir local, exactement le
# mécanisme que ce dépôt utilise déjà pour `ttyd` et le précompilé Elixir. Les pins sont ceux du
# Dockerfile, et un témoin épingle leur égalité : deux rails, deux mécanismes, UNE version.

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
TOFU_DIR="${LCARS_TOFU_DIR:-/opt/lcars/tofu}"
TOFU_OWNER="${LCARS_TOFU_OWNER:-root:root}"

tofu_rc() { echo "$TOFU_DIR/tofurc"; }

# LES DEUX MODULES DE LA RECETTE : la racine et `instance/`. La liste se dérive de l'arbre, pas d'un
# tableau en dur — c'est la recette que la machine jouera qui décide quels providers il lui faut.
tofu_modules() { printf '%s\n%s\n' "$(repo_root)/fleet/deploy/deps" "$(repo_root)/fleet/deploy/deps/instance"; }

# L'arch au vocabulaire d'OpenTofu, jamais `uname -m` — qui répond `x86_64` là où les releases
# disent `amd64`, et qui répondrait pour la machine de build en cross-compilation.
tofu_arch() {
  case "$(dpkg --print-architecture 2>/dev/null)" in
    amd64) echo amd64 ;; arm64) echo arm64 ;; *) echo "" ;;
  esac
}

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
    [[ "$v" == "$TOFU_VERSION" ]] \
      && p_ok "tofu $v posé ($TOFU_BIN)" \
      || p_drift "tofu $v ≠ version épinglée $TOFU_VERSION ($TOFU_BIN) — la recette tournerait avec d'autres providers"
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
    *) p_fail "arch non épinglée pour tofu : « $(dpkg --print-architecture 2>/dev/null) » (attendu amd64 ou arm64)"; verdict_apply ;;
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
  #
  # La règle : on ne sonde pas avec un outil qui juge. `run_quiet` sert aux gestes qui doivent
  # réussir ; une question dont « non » est une réponse valide s'écrit nue.
  local m offline=1
  for m in $(tofu_modules); do
    [[ -d "$m" ]] || { p_fail "recette absente : $m"; verdict_apply; }
    TF_CLI_CONFIG_FILE="$(tofu_rc)" env -C "$m" "$TOFU_BIN" init -input=false -no-color >/dev/null 2>&1 \
      || offline=0
  done
  if [[ "$offline" -eq 1 ]]; then
    p_ok "miroir de providers complet (init hors-ligne OK)"
    verdict_apply
  fi

  for m in $(tofu_modules); do
    TF_CLI_CONFIG_FILE="$(tofu_rc)" run_quiet env -C "$m" "$TOFU_BIN" providers mirror -platform="linux_${arch}" "$TOFU_DIR/providers" \
      || { p_fail "miroir de providers : échec sur $m"; verdict_apply; }
  done
  chmod -R a+rX "$TOFU_DIR" 2>/dev/null || true
  for m in $(tofu_modules); do
    TF_CLI_CONFIG_FILE="$(tofu_rc)" run_quiet env -C "$m" "$TOFU_BIN" init -input=false -no-color \
      || { p_fail "tofu : init hors-ligne en échec dans $m APRÈS miroir — le miroir ne couvre pas la recette"; verdict_apply; }
  done
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "miroir de providers hors-ligne ($TOFU_DIR/providers)"
  verdict_apply
}

case "${1:?usage: 46-tofu.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
