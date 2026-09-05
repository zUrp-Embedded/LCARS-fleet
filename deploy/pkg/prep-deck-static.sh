#!/usr/bin/env bash
# SOURCE: deploy/pkg/prep-deck-static.sh
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: prepare le client de la console web (xterm.js, addon-fit) dans le tiroir des outils du pack,
#         aux versions et sha256 que 62-runtime-helpers EPINGLE — le paquet `lcars` l'embarque sous
#         <racine>/deck-static, la ou 62 le telechargeait a l'apply (sous paquet, 62 mesure sans poser)
#
# USAGE : prep-deck-static.sh --tools <dir>
# ENV   : LCARS_CURL_BIN   la CLI curl (defaut : curl)
# EXIT  : 0 les trois fichiers sont la et verifies · 1 telechargement ou sha256 en echec
set -euo pipefail
CURL="${LCARS_CURL_BIN:-curl}"
TOOLS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tools) TOOLS="${2:?--tools attend un dossier}"; shift 2 ;;
    *) echo "prep-deck-static: option inconnue: $1" >&2; exit 1 ;;
  esac
done
say() { echo "prep-deck-static: $*" >&2; }
die() { echo "prep-deck-static: ERREUR — $*" >&2; exit 1; }
[[ -n "$TOOLS" ]] || die "--tools manquant"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD62="$HERE/../modules.d/62-runtime-helpers.sh"
[[ -r "$MOD62" ]] || die "62-runtime-helpers.sh introuvable ($MOD62)"

# LES PINS SONT CEUX DE 62, LUS DANS 62 — une source. On evalue ses affectations XTERM_* et le corps
# de `deck_static_table` (nom, url, sha256 par ligne), rien d'autre du module.
eval "$(grep -E '^XTERM_[A-Z0-9_]+=' "$MOD62")"
eval "$(sed -n '/^deck_static_table()/,/^}/p' "$MOD62")"
DIR="$TOOLS/deck-static"
mkdir -p "$DIR"
n=0
while IFS=$'\t' read -r name url want; do
  [[ -n "$name" ]] || continue
  if [[ -f "$DIR/$name" ]] && [[ "$(sha256sum "$DIR/$name" | awk '{print $1}')" == "$want" ]]; then
    n=$((n + 1)); continue
  fi
  tmp="$(mktemp "$DIR/.$name.XXXXXX")"
  "$CURL" --proto '=https' --tlsv1.2 -fsSL -m 120 -o "$tmp" "$url" || { rm -f "$tmp"; die "$name : telechargement en echec ($url)"; }
  got="$(sha256sum "$tmp" | awk '{print $1}')"
  [[ "$got" == "$want" ]] || { rm -f "$tmp"; die "$name : sha256 $got ≠ $want (pin de 62) — rien n'est garde"; }
  chmod 0644 "$tmp"; mv -f "$tmp" "$DIR/$name"; n=$((n + 1))
done < <(deck_static_table)
[[ "$n" -ge 3 ]] || die "la table de 62 rend $n fichier(s), trois attendus"
say "$n fichier(s) du client de console verifies dans $DIR"
