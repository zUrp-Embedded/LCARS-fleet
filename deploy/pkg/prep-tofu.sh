#!/usr/bin/env bash
# SOURCE: deploy/pkg/prep-tofu.sh
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: prepare le contenu de `lcars-tofu` dans le tiroir des outils du pack : le binaire
#         OpenTofu (la version et les sha256 de 46-tofu, LUS dans le module — une source), le
#         tofurc du poste, et le miroir de providers de la recette (reseau, une fois, ici)
#
# USAGE : prep-tofu.sh --tools <dir> --stage <lcars_install/> [--arch amd64|arm64]
#         pose <dir>/tofu/{tofu,tofurc,providers/} ; imprime le dossier sur stdout
# ENV   : LCARS_CURL_BIN   la CLI curl (defaut : curl)
# EXIT  : 0 · 1 pins illisibles, telechargement, sha256, archive, ou miroir en defaut
#
# ⚠ LE MIROIR SE BATIT COMME 46-tofu LE BATIT : `tofu providers mirror` sur une COPIE de la recette
# (`runtime/services/forge-recipe`, puis `instance/`), et un `init` hors-ligne PROUVE qu'il couvre
# la recette. Ce que 46 fait sur la cible avec le reseau, le pack le fait UNE fois, et le paquet le
# porte. Le chemin du miroir dans le tofurc est celui de la TABLE (`dir …/tofu/providers`), pas un
# litteral : c'est la meme raison qui tient 46 hors des chemins en dur (lot 15).
set -euo pipefail

CURL="${LCARS_CURL_BIN:-curl}"
TOOLS="" STAGE="" ARCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tools) TOOLS="${2:?--tools attend un dossier}"; shift 2 ;;
    --stage) STAGE="${2:?--stage attend un dossier}"; shift 2 ;;
    --arch)  ARCH="${2:?--arch attend amd64 ou arm64}"; shift 2 ;;
    -h|--help) sed -n '/^# USAGE/,/^# EXIT/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "prep-tofu: option inconnue: $1" >&2; exit 1 ;;
  esac
done
say() { echo "prep-tofu: $*" >&2; }
die() { echo "prep-tofu: ERREUR — $*" >&2; exit 1; }
[[ -n "$TOOLS" ]] || die "--tools manquant"
[[ -n "$STAGE" && -d "$STAGE" ]] || die "--stage : dossier introuvable (${STAGE:-vide})"
if [[ -z "$ARCH" ]]; then
  case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) die "architecture inconnue : $(uname -m)" ;; esac
fi

# ─── LES PINS, LUS DANS 46-tofu.sh DU STAGE — jamais recopies ───────────────────────────────────
MOD46="$STAGE/deploy/modules.d/46-tofu.sh"
[[ -r "$MOD46" ]] || die "46-tofu.sh absent du stage ($MOD46)"
pin() { sed -n "s/^$1=\"\{0,1\}\([^\"}]*\)\"\{0,1\}\$/\1/p" "$MOD46" | head -1; }
TOFU_VERSION="$(sed -n 's/^TOFU_VERSION="${LCARS_TOFU_VERSION:-\(.*\)}"$/\1/p' "$MOD46" | head -1)"
case "$ARCH" in
  amd64) WANT="$(pin TOFU_SHA256_AMD64)" ;;
  arm64) WANT="$(pin TOFU_SHA256_ARM64)" ;;
  *) die "arch non epinglee : $ARCH (amd64 ou arm64)" ;;
esac
[[ -n "$TOFU_VERSION" && "$WANT" =~ ^[0-9a-f]{64}$ ]] \
  || die "pins illisibles dans $MOD46 (version « ${TOFU_VERSION:-?} », sha « ${WANT:-?} ») — la forme du module a change ?"

# ─── LE CHEMIN DU MIROIR SUR LE POSTE : la table ────────────────────────────────────────────────
MANIFEST="$STAGE/deploy/system.manifest"
[[ -r "$MANIFEST" ]] || die "system.manifest absent du stage"
PROVIDERS_DST="$(awk '$1 !~ /^#/ && $1=="dir" && $2 ~ /\/tofu\/providers$/ && !v {v=$2} END {print v}' "$MANIFEST")"
[[ -n "$PROVIDERS_DST" ]] || die "la table ne declare pas de repertoire …/tofu/providers"

DIR="$TOOLS/tofu"
mkdir -p "$DIR/providers" || die "tiroir inaccessible : $DIR"

# ─── LE BINAIRE ─────────────────────────────────────────────────────────────────────────────────
installed() { "$DIR/tofu" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }
if [[ -x "$DIR/tofu" && "$(installed)" == "$TOFU_VERSION" ]]; then
  say "tofu $TOFU_VERSION deja la ($DIR/tofu)"
else
  tmp="$(mktemp -d "$TOOLS/.tofu.XXXXXX")" || die "tmp impossible dans $TOOLS"
  trap 'rm -rf "$tmp"' EXIT
  asset="tofu_${TOFU_VERSION}_linux_${ARCH}.zip"
  url="https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/${asset}"
  say "telechargement de $asset…"
  "$CURL" -fsSL --proto '=https' --tlsv1.2 -m 300 -o "$tmp/$asset" "$url" || die "telechargement rate : $url"
  actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
  [[ "$actual" == "$WANT" ]] || { say "  attendu : $WANT"; say "  trouve  : $actual"; die "sha256 MISMATCH pour $asset — rien n'est pose"; }
  unzip -q -o -d "$tmp/x" "$tmp/$asset" || die "archive illisible ($asset)"
  install -m 0755 "$tmp/x/tofu" "$DIR/tofu" || die "pose ratee ($DIR/tofu)"
  [[ "$(installed)" == "$TOFU_VERSION" ]] || die "le binaire pose ne dit pas $TOFU_VERSION"
  say "tofu $TOFU_VERSION pose ($DIR/tofu, sha256 verifie)"
fi

# ─── LE TOFURC DU POSTE — la meme forme que 46-tofu ecrit, le miroir au chemin de la table ──────
cat > "$DIR/tofurc" <<EOF_RC
provider_installation {
  filesystem_mirror {
    path    = "$PROVIDERS_DST"
    include = ["*/*"]
  }
  direct {
    exclude = ["*/*"]
  }
}
EOF_RC

# ─── LE MIROIR — sur une copie de la recette, comme 46 ─────────────────────────────────────────
SRC="$STAGE/runtime/services/forge-recipe"
[[ -d "$SRC" ]] || die "recette absente du stage : $SRC"
work="$(mktemp -d "${TMPDIR:-/tmp}/lcars-pack-recipe.XXXXXX")" || die "tmp impossible"
cp -a "$SRC/." "$work/" || { rm -rf "$work"; die "recette non copiable"; }
rm -rf "$work/.terraform" "$work/instance/.terraform"
# Un tofurc de BUILD : le miroir vise le tiroir, pas le chemin du poste — c'est le seul endroit
# ou les deux different, et il ne sort pas du pack.
printf 'provider_installation {\n  filesystem_mirror {\n    path    = "%s"\n    include = ["*/*"]\n  }\n  direct {\n    exclude = ["*/*"]\n  }\n}\n' "$DIR/providers" > "$work/.tofurc-build"
for m in instance .; do
  [[ -d "$work/$m" ]] || { rm -rf "$work"; die "recette incomplete : $m"; }
  ( cd "$work/$m" && "$DIR/tofu" providers mirror -platform="linux_${ARCH}" "$DIR/providers" >/dev/null ) \
    || { rm -rf "$work"; die "miroir de providers : echec sur $m (reseau ?)"; }
done
for m in instance .; do
  ( cd "$work/$m" && TF_CLI_CONFIG_FILE="$work/.tofurc-build" "$DIR/tofu" init -input=false -no-color >/dev/null ) \
    || { rm -rf "$work"; die "init hors-ligne en echec dans $m APRES miroir — le miroir ne couvre pas la recette"; }
done
rm -rf "$work"
chmod -R a+rX "$DIR" 2>/dev/null || true
say "miroir de providers complet ($DIR/providers, linux_${ARCH}) — init hors-ligne OK"
printf '%s\n' "$DIR"
