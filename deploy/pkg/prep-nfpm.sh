#!/usr/bin/env bash
# SOURCE: deploy/pkg/prep-nfpm.sh
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: pose nFPM dans le tiroir des outils du pack — telechargement EPINGLE par sha256, refus
#         sur tout ecart. Ni un paquet apt (il n'en existe pas), ni un binaire dans l'arbre.
#
# USAGE : prep-nfpm.sh --tools <dir>        pose <dir>/nfpm s'il manque ou n'est pas la version
#                                           epinglee ; imprime son chemin sur stdout
# ENV   : LCARS_CURL_BIN   la CLI curl (defaut : curl) — une couture pour les temoins
# EXIT  : 0 nfpm est la, a la bonne version · 1 telechargement, sha256 ou archive en defaut
#
# ⚠ LES PINS VIVENT ICI, PAS DANS pack.sh : le temoin de pack.sh refuse toute suite de 40 hexa
# dans son code (pack_secrets.bats — un jeton Gitea a cette forme), et un sha256 en contient une.
# Deux sommes, une par architecture, prises dans checksums.txt de la release v2.47.0 (2026-09-05).
set -euo pipefail

NFPM_VERSION=2.47.0
NFPM_SHA256_X86_64=0660ca602b2d2d2ae4781a06c692b3eeb9d437ffea05b831d76e41f4a3188783
NFPM_SHA256_ARM64=1c0f5f2999b9a974bfb04fdb0cc3306096de530ac5dbb25d739cc5f5219c919c
CURL="${LCARS_CURL_BIN:-curl}"

TOOLS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tools) TOOLS="${2:?--tools attend un dossier}"; shift 2 ;;
    -h|--help) sed -n '/^# USAGE/,/^# EXIT/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "prep-nfpm: option inconnue: $1" >&2; exit 1 ;;
  esac
done
say() { echo "prep-nfpm: $*" >&2; }
die() { echo "prep-nfpm: ERREUR — $*" >&2; exit 1; }
[[ -n "$TOOLS" ]] || die "--tools manquant"
mkdir -p "$TOOLS" || die "tiroir inaccessible : $TOOLS"
BIN="$TOOLS/nfpm"

nfpm_version() { "$BIN" --version 2>/dev/null | sed -n 's/^GitVersion:[[:space:]]*//p' | head -1; }
if [[ -x "$BIN" && "$(nfpm_version)" == "$NFPM_VERSION" ]]; then
  say "nfpm $NFPM_VERSION deja la ($BIN)"
  printf '%s\n' "$BIN"; exit 0
fi

case "$(uname -m)" in
  x86_64)        asset="nfpm_${NFPM_VERSION}_Linux_x86_64.tar.gz"; want="$NFPM_SHA256_X86_64" ;;
  aarch64|arm64) asset="nfpm_${NFPM_VERSION}_Linux_arm64.tar.gz";  want="$NFPM_SHA256_ARM64" ;;
  *) die "architecture non epinglee pour nfpm : $(uname -m) (x86_64 ou arm64)" ;;
esac
url="https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/${asset}"

tmp="$(mktemp -d "$TOOLS/.nfpm.XXXXXX")" || die "tmp impossible dans $TOOLS"
trap 'rm -rf "$tmp"' EXIT
say "telechargement de $asset…"
"$CURL" -fsSL --proto '=https' --tlsv1.2 -m 300 -o "$tmp/$asset" "$url" || die "telechargement rate : $url"
actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
[[ "$actual" == "$want" ]] || { say "  attendu : $want"; say "  trouve  : $actual"; die "sha256 MISMATCH pour $asset — rien n'est pose"; }
tar -xzf "$tmp/$asset" -C "$tmp" nfpm || die "archive illisible ($asset)"
[[ -f "$tmp/nfpm" ]] || die "l'archive ne porte pas de binaire nfpm"
install -m 0755 "$tmp/nfpm" "$BIN" || die "pose ratee ($BIN)"
[[ "$(nfpm_version)" == "$NFPM_VERSION" ]] || die "le binaire pose ne dit pas $NFPM_VERSION ($(nfpm_version || echo '?'))"
say "nfpm $NFPM_VERSION pose ($BIN, sha256 verifie)"
printf '%s\n' "$BIN"
