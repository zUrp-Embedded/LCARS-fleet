#!/usr/bin/env bash
# SOURCE: deploy/lib/door-gen.sh
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: l'installeur d'une version — le gabarit install.sh avec sa version, sa base, sa clé, son image et la table des sha256 du tiroir
# USAGE : door-gen.sh <tag> <base> <tiroir>   (LCARS_DOOR_IMAGE, LCARS_MINISIGN_PUBKEY ou <tiroir>/minisign.pub ; une clé fait vérifier la signature de chaque kit, minisign requis)
# EXIT  : 0 install.sh et install.sh.sha256 écrits dans le tiroir · 1 refus, l'installeur n'est pas écrit

set -euo pipefail

TAG="${1:?usage : door-gen.sh <tag> <base> <dist-dir>}"
BASE="${2:?usage : door-gen.sh <tag> <base> <dist-dir>}"
DIST="${3:?usage : door-gen.sh <tag> <base> <dist-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${LCARS_DOOR_TEMPLATE:-$HERE/../../install.sh}"

say() { echo "door-gen: $*" >&2; }
die() { echo "door-gen: ERREUR — $*" >&2; exit 1; }

[[ "$EUID" -ne 0 ]] || die "door-gen ne se lance pas en root : son auto-test lance l'installeur généré, qui refuse root"
[[ "$BASE" == https://* || "$BASE" == http://* ]] || die "base « $BASE » : une URL http(s) — install.sh n'accepte http que sous LCARS_DOOR_INSECURE_HTTP=1"
[[ -f "$TEMPLATE" ]] || die "gabarit introuvable : $TEMPLATE"

for m in DOOR_VERSION DOOR_BASE DOOR_PUBKEY DOOR_IMAGE DOOR_SUMS_BEGIN DOOR_SUMS_END; do
  n="$(grep -c "@@$m@@" "$TEMPLATE" || true)"
  [[ "$n" -eq 1 ]] || die "le gabarit porte $n fois @@$m@@ (attendu : 1) — $TEMPLATE n'est pas le gabarit d'install.sh"
done

PUBKEY="${LCARS_MINISIGN_PUBKEY:-}"
if [[ -z "$PUBKEY" && -f "$DIST/minisign.pub" ]]; then
  PUBKEY="$(grep -v '^untrusted comment' "$DIST/minisign.pub" | head -1 || true)"
fi
# une clé inscrite fait exiger une signature à l'installeur : un kit sans .minisig, ou signé d'une autre clé, il le refuserait
if [[ -n "$PUBKEY" ]]; then
  [[ "$PUBKEY" =~ ^[A-Za-z0-9+/=]+$ ]] || die "clé publique illisible (base64 attendu) : « $PUBKEY »"
  command -v minisign >/dev/null 2>&1 \
    || die "une clé publique est fournie et minisign est absent : la signature des kits ne se vérifie pas ici — installer minisign, ou retirer la clé"
  for _k in "$DIST"/*.tar.gz; do
    [[ -e "$_k" ]] || continue
    [[ -f "$_k.minisig" ]] || die "une clé publique est fournie, mais $(basename "$_k").minisig manque : l'installeur refuserait ce kit — signer, ou retirer la clé"
    minisign -Vq -P "$PUBKEY" -m "$_k" >/dev/null 2>&1 \
      || die "la signature de $(basename "$_k") ne se vérifie pas avec la clé publique fournie : l'installeur refuserait ce kit — le signer avec la clé secrète de cette clé"
  done
else
  say "aucune clé publique (LCARS_MINISIGN_PUBKEY, ou $DIST/minisign.pub) — l'installeur dira « provenance NON vérifiée (sha256 seul) »"
fi

mapfile -t ARTEFACTS < <(
  find "$DIST" -maxdepth 1 -type f \
    ! -name 'install.sh' ! -name '*.sha256' ! -name '*.minisig' ! -name 'minisign.pub' \
    -printf '%f\n' 2>/dev/null | LC_ALL=C sort
)
[[ "${#ARTEFACTS[@]}" -gt 0 ]] || die "aucun artefact dans $DIST — rien à inscrire dans la table de sommes"
TABLE="$(cd "$DIST" && sha256sum "${ARTEFACTS[@]}")"

OUT="$DIST/install.sh"
IMAGE="${LCARS_DOOR_IMAGE:-}"
[[ -z "$IMAGE" || "$IMAGE" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ ]] || die "image « $IMAGE » : un nom registre/image:tag"
DG_TAG="$TAG" DG_BASE="$BASE" DG_PUB="$PUBKEY" DG_IMAGE="$IMAGE" DG_TABLE="$TABLE" awk '
  function rebuild(prefix, value,   i) {   # <prefix>="<value>" puis le marqueur et sa glose, tels quels
    i = index($0, "# @@")
    printf "%-34s %s\n", prefix "=\"" value "\"", substr($0, i)
  }
  /# @@DOOR_VERSION@@/    { rebuild("LCARS_DOOR_VERSION", ENVIRON["DG_TAG"]); next }
  /# @@DOOR_BASE@@/       { rebuild("DOOR_BASE", ENVIRON["DG_BASE"]); next }
  /# @@DOOR_PUBKEY@@/     { rebuild("MINISIGN_PUBKEY", ENVIRON["DG_PUB"]); next }
  /# @@DOOR_IMAGE@@/      { rebuild("DOOR_IMAGE", ENVIRON["DG_IMAGE"]); next }
  /# @@DOOR_SUMS_BEGIN@@/ { print; print ENVIRON["DG_TABLE"]; print "SUMS"; skip = 1; next }
  /# @@DOOR_SUMS_END@@/   { skip = 0 }
  skip { next }
  { print }
' "$TEMPLATE" > "$OUT.tmp"
chmod 0755 "$OUT.tmp"

_dit="$(bash "$OUT.tmp" --version 2>/dev/null || true)"
[[ "$_dit" == "$TAG" ]] || { rm -f "$OUT.tmp"; die "l'installeur généré répond « $_dit » à --version, attendu « $TAG » — rien n'est écrit"; }
mv "$OUT.tmp" "$OUT"
( cd "$DIST" && sha256sum install.sh > install.sh.sha256 )

_cle="ABSENTE"; [[ -z "$PUBKEY" ]] || _cle="presente"
say "install.sh $TAG : $OUT — base $BASE, ${#ARTEFACTS[@]} artefact(s) dans la table, clé $_cle"
say "sha256 de l'installeur : $(cut -d' ' -f1 < "$DIST/install.sh.sha256")  ($DIST/install.sh.sha256)"
