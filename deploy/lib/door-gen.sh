#!/usr/bin/env bash
# SOURCE: deploy/lib/door-gen.sh
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: le generateur de la porte d'une VERSION — le gabarit install.sh, constantes remplies, table des sha256
#
#     deploy/lib/door-gen.sh <tag> <base> <dist-dir>
#
#       <tag>       la version : LCARS_DOOR_VERSION de la porte generee, et le tag de la release
#       <base>      <forge>/<owner>/<repo>/releases/download/<tag> — d'ou la porte telecharge
#       <dist-dir>  le tiroir des artefacts de CETTE version. La table couvre TOUS ses fichiers
#                   (hors la porte elle-meme, les .sha256, les .minisig et minisign.pub) ;
#                   install.sh et install.sh.sha256 y sont ecrits.
#
#     ENV : LCARS_DOOR_TEMPLATE      le gabarit (defaut : install.sh a la racine du depot)
#           LCARS_MINISIGN_PUBKEY    la cle publique minisign des artefacts ; sinon la ligne de
#                                    <dist-dir>/minisign.pub ; sinon AUCUNE — et c'est dit : la porte
#                                    dira « provenance NON verifiee (sha256 seul) »
#     EXIT : 0 la porte est la · 1 gabarit sans ses marqueurs, tiroir vide, ou porte generee muette
#
# ─── POURQUOI UN GENERATEUR, ET PAS UNE PORTE QUI TELECHARGE SA TABLE ──────────────────────────
#
# `curl_bash_2026.md` § 07.1-2 : une URL PAR VERSION, et les sha256 des artefacts EN DUR dans le
# script de la version — jamais recuperes a cote du binaire, « un checksum servi par le meme serveur
# ne vaut rien ». La porte du depot est donc un GABARIT : ce qui tourne dans un checkout (provenance
# source), avec ses constantes vides. Celle d'une release en derive, et ne differe que par ces
# lignes — un temoin le tient (`install_door.bats`, « la porte generee = le gabarit hors constantes »).
#
# ⚠ LES MARQUEURS SONT LE CONTRAT, ET ILS SE COMPTENT. `@@DOOR_VERSION@@`, `@@DOOR_BASE@@`,
# `@@DOOR_PUBKEY@@` marquent UNE ligne chacun ; `@@DOOR_SUMS_BEGIN@@` / `@@DOOR_SUMS_END@@` bornent
# le corps de `sums()`. Un gabarit qui en a perdu un — ou en a deux — ne se genere pas : une porte
# de version dont une constante serait restee vide tendrait la table de personne.
#
# ⚠ AUCUN `sub()` AWK SUR LES VALEURS : `&` et `\` y sont speciaux, et une base ou une cle qui les
# porterait serait recopiee fausse en silence. Les lignes marquees sont REBATIES (valeur + le
# marqueur tel quel), jamais substituees.

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

# ─── LA CLE PUBLIQUE — donnee, ou a cote des artefacts, ou AUCUNE (dit) ─────────────────────────
PUBKEY="${LCARS_MINISIGN_PUBKEY:-}"
if [[ -z "$PUBKEY" && -f "$DIST/minisign.pub" ]]; then
  # un minisign.pub : « untrusted comment: … » puis la cle sur la seconde ligne
  PUBKEY="$(grep -v '^untrusted comment' "$DIST/minisign.pub" | head -1 || true)"
fi
if [[ -n "$PUBKEY" ]]; then
  [[ "$PUBKEY" =~ ^[A-Za-z0-9+/=]+$ ]] || die "cle publique illisible (base64 attendu) : « $PUBKEY »"
else
  say "AUCUNE cle publique (LCARS_MINISIGN_PUBKEY, ou $DIST/minisign.pub) — la porte dira « provenance NON verifiee (sha256 seul) »"
fi

# ─── LA TABLE — tous les artefacts du tiroir, et rien d'autre ──────────────────────────────────
# Une porte de version doit connaitre CHAQUE artefact de sa release : c'est le tiroir qui fait foi,
# pas une liste ecrite ici. Ce qui en est ecarte est derive (les .sha256, les .minisig, la cle) ou
# est la porte elle-meme.
mapfile -t ARTEFACTS < <(
  find "$DIST" -maxdepth 1 -type f \
    ! -name 'install.sh' ! -name '*.sha256' ! -name '*.minisig' ! -name 'minisign.pub' \
    -printf '%f\n' 2>/dev/null | LC_ALL=C sort
)
[[ "${#ARTEFACTS[@]}" -gt 0 ]] || die "aucun artefact dans $DIST — une porte sans table ne tend rien"
TABLE="$(cd "$DIST" && sha256sum "${ARTEFACTS[@]}")"

# ─── LA PORTE — le gabarit, ligne a ligne ; les marquees sont rebaties ───────────────────────────
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

# La porte generee doit se dire — pipee, sans lire son fichier — et dire CE tag. Sinon rien ne sort.
_dit="$(bash "$OUT.tmp" --version 2>/dev/null || true)"
[[ "$_dit" == "$TAG" ]] || { rm -f "$OUT.tmp"; die "la porte generee repond « $_dit » a --version, attendu « $TAG » — rien n'est ecrit"; }
mv "$OUT.tmp" "$OUT"
( cd "$DIST" && sha256sum install.sh > install.sh.sha256 )

# ⚠ L'ETAT SE CALCULE AVANT D'ETRE DIT : `${X:+a}${X:-b}` imprime la VALEUR quand elle existe (la
# cicatrice de pack.sh, ou c'etait un jeton). Ici une cle publique — la forme est fausse quand meme.
_cle="ABSENTE"; [[ -z "$PUBKEY" ]] || _cle="presente"
say "porte $TAG : $OUT — base $BASE, ${#ARTEFACTS[@]} artefact(s) dans la table, cle $_cle"
say "sha256 de la porte : $(cut -d' ' -f1 < "$DIST/install.sh.sha256")  ($DIST/install.sh.sha256)"
