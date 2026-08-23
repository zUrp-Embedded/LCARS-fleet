#!/usr/bin/env bash
# SOURCE: pack.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-23
# STATUS: le paquet — gate, release, tar, et pousse sur la forge
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
#
# Le gate tournait DEUX FOIS sur le même commit : une fois ici (ou en CI), une fois chez celui qui
# installe — `etc/install.sh` le rejoue avant `mix release`. Sept minutes payées deux fois, et la
# première ne produisait rien : `gate.yml` n'a aucun `upload`, ses produits de build sont jetés.
#
# ⚖ USER 2026-08-23 : « on fait le minimum pour pas jeter le boulot fait ici à chaque fois. »
#
# Ce script est ce minimum. Il ne réimplémente rien — `mix gate`, `mix release`, `tar` — et l'install
# ne change que d'un cran : `build_release()` voit la release déjà là et ne compile pas. Tout le
# reste du rail est identique, y compris la pose, les symlinks et les perms.
#
# LE TAR EST LE MÊME KIT QU'AUJOURD'HUI, la release en plus : on untar, on lance `install.sh`, ça
# part. Il n'y a pas de second chemin à connaître.
#
# ⚠ L'ARTEFACT PORTE SON OTP ET SON ARCH DANS SON NOM. Une release embarque son ERTS : elle est
# compilée pour un OTP et une architecture, et rien ne la rend portable. Le nom le dit, c'est tout —
# personne ne vérifie à ta place.
#
# USAGE : ./pack.sh            gate + release + tar (+ push si une forge est configurée)
#         ./pack.sh --no-push  s'arrête au tar
# EXIT  : 0 le paquet est là · 1 gate rouge, build KO, ou push refusé

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

PUSH=1
[[ "${1:-}" == "--no-push" ]] && PUSH=0

say() { echo "pack: $*" >&2; }
die() { echo "pack: ERREUR — $*" >&2; exit 1; }

# ─── LA VERSION ─────────────────────────────────────────────────────────────────────────────────
# ⚖ USER : un timestamp `MM-DD_HH-MM`. Il ordonne, il se lit, et il ne prétend rien sur le contenu —
# le sha du commit est là pour ça. Deux paquets de la même minute écrasent : c'est voulu, on refait.
VERSION="$(date +%m-%d_%H-%M)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
ARCH="$(uname -m)"
OTP="$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null || echo 0)"
NAME="lcars-fleet-${VERSION}-${SHA}-otp${OTP}-${ARCH}"
OUT="dist/${NAME}.tar.gz"

# ─── LE GATE, PUIS LA RELEASE — dans cet ordre et sans échappatoire ──────────────────────────────
# C'est ce qui fait qu'un tar VAUT quelque chose : les bits empaquetés sont les bits que le gate a
# passés. Le sauter ici rendrait le paquet indistinguable d'un `mix release` à la main.
say "gate (compile strict + suite + bats + contrats + topologie + dialyzer)…"
( cd fleet && MIX_ENV=prod mix deps.get >/dev/null && MIX_ENV=test mix gate ) || die "gate rouge — rien n'est empaqueté"

say "release prod…"
( cd fleet && MIX_ENV=prod mix release --overwrite >/dev/null ) || die "mix release KO"

# ─── LE TAR — le kit d'install, release comprise ─────────────────────────────────────────────────
# `git archive` donne l'arbre suivi (ce que la forge sert déjà en `main.tar.gz`), et on y ajoute le
# `_build/prod/rel/` que le gate vient d'attester. Deux morceaux, une seule racine : untar, et
# `install.sh` est là où il a toujours été.
say "tar → $OUT"
mkdir -p dist
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT INT TERM
git archive --format=tar HEAD | tar -x -C "$STAGE" || die "git archive KO"
mkdir -p "$STAGE/fleet/_build/prod/rel"
cp -a fleet/_build/prod/rel/lcars_fleet "$STAGE/fleet/_build/prod/rel/" || die "release introuvable après le build"
tar -czf "$OUT" -C "$STAGE" . || die "tar KO"
( cd dist && sha256sum "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256" )


say "paquet : $OUT ($(du -h "$OUT" | cut -f1))"
say "sha256 : $(cut -d' ' -f1 < "${OUT}.sha256")"

# ─── LA POUSSE ──────────────────────────────────────────────────────────────────────────────────
# API paquets `generic` de Gitea — la même que `publish.yml` emploie pour les images `container`.
# Le jeton vient de l'environnement ou du fichier que le rail pose ; sans forge configurée on
# s'arrête sur le tar, qui est déjà utilisable.
[[ "$PUSH" -eq 1 ]] || { say "--no-push : le tar reste ici"; exit 0; }

# LA FORGE EST CELLE D'`origin` — c'est déjà d'elle qu'on tire `main.tar.gz`, donc le paquet doit
# atterrir au même endroit. Elle se DÉRIVE du remote plutôt que d'être écrite : deux adresses pour
# une forge, c'est celle qu'on ne lit pas qui finit par être la bonne.
FORGE="${LCARS_PACK_FORGE:-$(git remote get-url origin 2>/dev/null | sed -n 's|^\(https\?://[^/]*\)/.*|\1|p')}"
OWNER="${LCARS_PACK_OWNER:-$(git remote get-url origin 2>/dev/null | sed -n 's|^https\?://[^/]*/\([^/]*\)/.*|\1|p')}"

# ⚠ LE JETON N'EST PAS ÉCRIT ICI, ET CE N'EST PAS UN OUBLI DE CONFORT. Ce fichier est suivi par git :
# un littéral partirait sur la forge, sur le remote github, ET dans chaque tar que ce script produit
# — le paquet livrerait la clé de la forge qui le sert. On lit donc celui qui authentifie déjà les
# `git push` de ce dépôt (`http.<forge>.extraheader`), posé une fois par l'opérateur. Même machine,
# même credential, aucune configuration à faire : le script « tourne tout seul » sans qu'un secret
# entre dans l'arbre.
TOKEN="${LCARS_PACK_TOKEN:-}"
if [[ -z "$TOKEN" && -n "$FORGE" ]]; then
  TOKEN="$(git config --get "http.${FORGE}/.extraheader" 2>/dev/null | sed -n 's/^Authorization: *token *//p')"
fi
[[ -n "$TOKEN" ]] || TOKEN="$(cat "${LCARS_MASTER_TOKEN_FILE:-/home/private/forge-master.token}" 2>/dev/null || true)"

if [[ -z "$FORGE" || -z "$TOKEN" ]]; then
  say "forge ou jeton indéterminables — le tar est dans dist/, pousse-le à la main si tu veux"
  say "  forge : ${FORGE:-<aucun remote origin http>} · jeton : ${TOKEN:+trouvé}${TOKEN:-absent}"
  exit 0
fi

# `-K -` : le jeton ne passe pas par argv, lisible dans /proc de tout l'hôte (cicatrice 6-141).
url="${FORGE%/}/api/v1/packages/${OWNER}/generic/lcars-fleet/${VERSION}-${SHA}"
for f in "$OUT" "${OUT}.sha256"; do
  code="$(printf 'header = "Authorization: token %s"\n' "$TOKEN" \
          | curl -sS -K - -X PUT --upload-file "$f" -o /dev/null -w '%{http_code}' \
                 "${url}/$(basename "$f")" 2>/dev/null || true)"
  case "$code" in
    201|200) say "poussé : $(basename "$f")" ;;
    *) die "push refusé ($code) pour $(basename "$f") — $url" ;;
  esac
done

say "→ ${FORGE%/}/${OWNER}/-/packages/generic/lcars-fleet/${VERSION}-${SHA}"
