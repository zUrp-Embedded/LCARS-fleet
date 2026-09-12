#!/usr/bin/env bash
# SOURCE: deploy/lib/door-gen.sh
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: le generateur de la porte d'une VERSION — le gabarit install.sh, constantes remplies, table des sha256

set -euo pipefail

TAG="${1:?usage : door-gen.sh <tag> <base> <dist-dir>}"
BASE="${2:?usage : door-gen.sh <tag> <base> <dist-dir>}"
DIST="${3:?usage : door-gen.sh <tag> <base> <dist-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${LCARS_DOOR_TEMPLATE:-$HERE/../../install.sh}"

say() { echo "door-gen: $*" >&2; }
die() { echo "door-gen: ERREUR — $*" >&2; exit 1; }

[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "tag « $TAG » : lettres, chiffres, . _ - seulement"
[[ "$BASE" == https://* || "$BASE" == http://* ]] || die "base « $BASE » : une URL http(s) — la porte n'accepte http que sous LCARS_DOOR_INSECURE_HTTP=1"
[[ -f "$TEMPLATE" ]] || die "gabarit introuvable : $TEMPLATE"
[[ -d "$DIST" ]] || die "tiroir introuvable : $DIST"

for m in DOOR_VERSION DOOR_BASE DOOR_PUBKEY DOOR_SUMS_BEGIN DOOR_SUMS_END; do
  n="$(grep -c "@@$m@@" "$TEMPLATE" || true)"
  [[ "$n" -eq 1 ]] || die "le gabarit porte $n fois @@$m@@ (attendu : 1) — $TEMPLATE n'est pas le gabarit de la porte"
done

PUBKEY="${LCARS_MINISIGN_PUBKEY:-}"
if [[ -z "$PUBKEY" && -f "$DIST/minisign.pub" ]]; then
  PUBKEY="$(grep -v '^untrusted comment' "$DIST/minisign.pub" | head -1 || true)"
fi
if [[ -n "$PUBKEY" ]]; then
  [[ "$PUBKEY" =~ ^[A-Za-z0-9+/=]+$ ]] || die "cle publique illisible (base64 attendu) : « $PUBKEY »"
else
  say "AUCUNE cle publique (LCARS_MINISIGN_PUBKEY, ou $DIST/minisign.pub) — la porte dira « provenance NON verifiee (sha256 seul) »"
fi

mapfile -t ARTEFACTS < <(
  find "$DIST" -maxdepth 1 -type f \
    ! -name 'install.sh' ! -name '*.sha256' ! -name '*.minisig' ! -name 'minisign.pub' \
    -printf '%f\n' 2>/dev/null | LC_ALL=C sort
)
[[ "${#ARTEFACTS[@]}" -gt 0 ]] || die "aucun artefact dans $DIST — une porte sans table ne tend rien"
TABLE="$(cd "$DIST" && sha256sum "${ARTEFACTS[@]}")"

OUT="$DIST/install.sh"
awk -v tag="$TAG" -v base="$BASE" -v pub="$PUBKEY" -v table="$TABLE" '
  function rebuild(prefix, value,   i) {   # <prefix>="<value>" puis le marqueur et sa glose, tels quels
    i = index($0, "# @@")
    printf "%-34s %s\n", prefix "=\"" value "\"", substr($0, i)
  }
  /# @@DOOR_VERSION@@/    { rebuild("LCARS_DOOR_VERSION", tag); next }
  /# @@DOOR_BASE@@/       { rebuild("DOOR_BASE", base); next }
  /# @@DOOR_PUBKEY@@/     { rebuild("MINISIGN_PUBKEY", pub); next }
  /# @@DOOR_SUMS_BEGIN@@/ { print; print table; print "SUMS"; skip = 1; next }
  /# @@DOOR_SUMS_END@@/   { skip = 0 }
  skip { next }
  { print }
' "$TEMPLATE" > "$OUT.tmp"
chmod 0755 "$OUT.tmp"

_dit="$(bash "$OUT.tmp" --version 2>/dev/null || true)"
[[ "$_dit" == "$TAG" ]] || { rm -f "$OUT.tmp"; die "la porte generee repond « $_dit » a --version, attendu « $TAG » — rien n'est ecrit"; }
mv "$OUT.tmp" "$OUT"
( cd "$DIST" && sha256sum install.sh > install.sh.sha256 )

_cle="ABSENTE"; [[ -z "$PUBKEY" ]] || _cle="presente"
say "porte $TAG : $OUT — base $BASE, ${#ARTEFACTS[@]} artefact(s) dans la table, cle $_cle"
say "sha256 de la porte : $(cut -d' ' -f1 < "$DIST/install.sh.sha256")  ($DIST/install.sh.sha256)"
