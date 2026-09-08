#!/usr/bin/env bash
# SOURCE: deploy/lib/forge-publish.sh
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: PROTO-V2 — publier UNE version sur la forge : la Release (tout le tiroir) et le registre Debian (les .deb)
#
# Sourcée par pack.sh (--publish) — et par la CI sur tag, qui joue LE MÊME pack.sh. Zéro état : la
# forge, l'owner, le dépôt, le tag et le tiroir sont des ARGUMENTS ; le jeton est FP_TOKEN, dans
# l'environnement, et il ne passe JAMAIS en argv (`curl -K -` : lisible dans /proc de tout l'hôte,
# cicatrice 6-141) ni sur une sortie.
#
# LA RELEASE NAÎT EN BROUILLON. Les assets montent dessus, les .deb vont au registre, PUIS elle est
# publiée d'un coup. Un envoi coupé laisse un brouillon — visible, nommé dans le refus, que l'opérateur
# supprime sur la forge avant de rejouer — jamais une release publiée à moitié pleine, et jamais un
# tag « réparé » : une release du tag qui existe (brouillon compris) est un REFUS (ADR 012).
#
# Forme d'URL commune à Gitea et GitHub : <forge>/<owner>/<repo>/releases/download/<tag>/<asset> —
# c'est CETTE base que la porte de la version porte en dur (door-gen.sh), donc le tiroir doit
# monter ENTIER : tar, .deb, .sha256, install.sh, install.sh.sha256, .minisig quand la clé est là.

# fp_curl <fichier-corps> <args curl…> → le code HTTP sur stdout (VIDE si curl n'a pas répondu),
# le corps dans <fichier-corps>. FP_CURL est la doublure des témoins.
fp_curl() {
  local out="$1"; shift
  printf 'header = "Authorization: token %s"\n' "${FP_TOKEN:?FP_TOKEN absent (le jeton, dans l environnement)}" \
    | "${FP_CURL:-curl}" -sS -K - -o "$out" -w '%{http_code}' -m "${FP_TIMEOUT:-300}" "$@" 2>/dev/null || true
}

# fp_err <fichier-corps> → le `message` de la forge, court — ou rien
fp_err() { jq -r '.message // empty' "$1" 2>/dev/null | head -c 200; }

# fp_urlenc <nom> → le nom, sûr dans une QUERY STRING
#
# ⚠ LE « + » D'UNE RÉVISION DEBIAN DEVIENT UNE ESPACE, ET LA RELEASE DEVIENT INUTILISABLE. Les huit
# `.deb` portent `0.9.0-20260908.1310+g48fa4a4b` : envoyés bruts dans `?name=`, le serveur décode le
# `+` en espace (règle `application/x-www-form-urlencoded`) et STOCKE l'asset sous
# `…1310 g48fa4a4b…`. Mesuré le 2026-09-08 sur une vraie publication :
#     …1310+g48fa4a4b_all.deb    → 404      ← le nom que la porte a gravé en dur
#     …1310%20g48fa4a4b_all.deb  → 200      ← ce que la forge a stocké
# La porte d'une version ne pouvait donc pas tirer SES PROPRES paquets, et rien ne le disait : les
# assets montaient tous en 201. C'est le genre de panne qu'aucune doublure n'attrape — il a fallu
# publier pour de bon, puis tirer.
#
# Percent-encodage complet plutôt qu'un `+`→`%2B` ciblé : le prochain caractère réservé dans un nom
# de paquet (`~` d'une pré-version, `:` d'un epoch Debian) tomberait dans le même trou.
fp_urlenc() {
  local s="$1" i c out=''
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# fp_release_body <tiroir> <sha-source> → le texte de la release : d'où elle vient, comment on la pose,
# et les sommes (celles que le tiroir porte déjà — on ne recalcule pas ce que la porte a en dur)
fp_release_body() {
  local dist="$1" target="$2" f
  printf 'Source : %s\n\nPoser (poste, Debian/Ubuntu) :\n\n    curl --proto '"'"'=https'"'"' --tlsv1.2 -fsSL <base>/install.sh | bash -s -- --workstation\n\nsha256 :\n\n' "$target"
  for f in "$dist"/*.sha256; do [[ -f "$f" ]] || continue; printf '    %s\n' "$(head -1 "$f")"; done
}

# fp_dialect <forge> → `github` | `gitea`
#
# ⚠ DEUX FORGES, UN SEUL GESTE — ET LA DIFFÉRENCE N'EST PAS COSMÉTIQUE. La forme d'URL de
# TÉLÉCHARGEMENT est commune (c'est ce que la porte grave, cf. en-tête), mais l'API de PUBLICATION
# diverge sur trois points, et sur trois seulement :
#   · la base       : `<forge>/api/v1/repos/o/r`   contre  `https://api.github.com/repos/o/r`
#   · les assets    : `POST …/assets?name=` en multipart  contre  un HÔTE À PART
#                     (`uploads.github.com`) en corps binaire — un multipart y rend 422
#   · le registre Debian : GitHub N'EN A PAS. On ne le simule pas, on le DIT.
# Tout le reste — l'immutabilité, la sonde de commit, le brouillon, la publication d'un coup — est
# identique, donc n'est écrit qu'une fois.
fp_dialect() {
  case "${1%/}" in
    https://github.com|http://github.com|https://api.github.com|https://www.github.com) echo github ;;
    *) echo gitea ;;
  esac
}

# fp_publish_dist <forge> <owner> <repo> <tag> <tiroir> <sha-source> <distribution-debian> [component]
fp_publish_dist() {
  local forge="${1%/}" owner="$2" repo="$3" tag="$4" dist="$5" target="$6" ddist="$7" comp="${8:-main}"
  local body code id f n
  local dialect; dialect="$(fp_dialect "$forge")"
  local api web
  if [[ "$dialect" == github ]]; then
    api="https://api.github.com/repos/$owner/$repo"; web="https://github.com"
  else
    api="$forge/api/v1/repos/$owner/$repo"; web="$forge"
  fi
  [[ -n "${FP_TOKEN:-}" ]] || { echo "fp: REFUS — FP_TOKEN absent (le jeton, dans l'environnement — jamais en argv)" >&2; return 1; }
  [[ -d "$dist" ]] || { echo "fp: REFUS — le tiroir $dist n'existe pas" >&2; return 1; }
  command -v jq >/dev/null || { echo "fp: REFUS — jq absent (la release se décrit en JSON)" >&2; return 1; }
  body="$(mktemp)"
  # shellcheck disable=SC2064  # $body est résolu maintenant, c'est voulu
  trap "rm -f '$body'" RETURN

  # 1. l'immutabilité, AVANT tout envoi : absent (on continue), présent (refus), injoignable (refus —
  #    une garde qui ne peut pas mesurer ne laisse pas passer)
  code="$(fp_curl "$body" "$api/releases/tags/$tag")"
  case "$code" in
    404) ;;
    200) echo "fp: REFUS — la release « $tag » existe déjà sur $forge/$owner/$repo ($(jq -r 'if .draft then "brouillon" else "publiée" end' "$body" 2>/dev/null)). ADR 012 : un tag publié ne se réécrit jamais — pour la refaire, supprime-la sur la forge, ce script ne le fait pas." >&2; return 1 ;;
    401|403) echo "fp: REFUS ($code) — le jeton ne lit pas $owner/$repo (portée write:repository requise, en plus de write:package)" >&2; return 1 ;;
    *) echo "fp: REFUS — la forge ne répond pas sur $api/releases/tags/$tag (code ${code:-vide}) : une garde qui ne peut pas mesurer ne laisse pas passer" >&2; return 1 ;;
  esac

  # 1b. LE COMMIT EST-IL SUR LA FORGE ? Mesuré sur Gitea 1.26 (banc bob_1, 2026-09-05) : un brouillon
  #     sur un commit inconnu est CRÉÉ (201) et c'est sa publication qui casse (500 « object does not
  #     exist ») — le brouillon reste. On demande donc le commit AVANT d'écrire quoi que ce soit : on
  #     publie un commit poussé, pas un arbre local.
  code="$(fp_curl "$body" "$api/git/commits/$target")"
  case "$code" in
    200) ;;
    404) echo "fp: REFUS — le commit $target n'est pas sur $forge/$owner/$repo : on publie un commit POUSSÉ, pas un arbre local (git push, puis rejoue)" >&2; return 1 ;;
    *) echo "fp: REFUS (${code:-vide}) — la forge ne dit pas si le commit $target est là ($(fp_err "$body"))" >&2; return 1 ;;
  esac

  # 2. la release, en brouillon, sur LE commit du pack (target_commitish)
  local json; json="$(jq -cn --arg t "$tag" --arg n "lcars $tag" --arg b "$(fp_release_body "$dist" "$target")" --arg c "$target" \
                      '{tag_name:$t, name:$n, body:$b, draft:true, prerelease:false, target_commitish:$c}')"
  code="$(fp_curl "$body" -X POST -H 'Content-Type: application/json' --data-binary "$json" "$api/releases")"
  case "$code" in
    201) ;;
    404|422) echo "fp: REFUS ($code) à la création de la release — $(fp_err "$body"). Le commit $target est-il sur la forge ? On publie un commit POUSSÉ." >&2; return 1 ;;
    *) echo "fp: REFUS (${code:-vide}) à la création de la release — $(fp_err "$body")" >&2; return 1 ;;
  esac
  id="$(jq -r '.id // empty' "$body" 2>/dev/null)"
  [[ "$id" =~ ^[0-9]+$ ]] || { echo "fp: la forge n'a pas rendu l'id de la release « $tag » (brouillon créé ? vérifie sur la forge)" >&2; return 1; }

  # 3. les assets — TOUT le tiroir. L'HÔTE DIFFÈRE CHEZ GITHUB, et la forme du corps aussi :
  #    `uploads.github.com`, corps binaire, `Content-Type` explicite. Un multipart (`-F`) y rend 422.
  local nq
  for f in "$dist"/*; do
    [[ -f "$f" ]] || continue; n="$(basename "$f")"; nq="$(fp_urlenc "$n")"
    if [[ "$dialect" == github ]]; then
      code="$(fp_curl "$body" -X POST -H 'Content-Type: application/octet-stream' \
                --data-binary "@$f" "https://uploads.github.com/repos/$owner/$repo/releases/$id/assets?name=$nq")"
    else
      code="$(fp_curl "$body" -X POST -F "attachment=@$f" "$api/releases/$id/assets?name=$nq")"
    fi
    [[ "$code" == 201 ]] || { echo "fp: REFUS (${code:-vide}) sur l'asset $n — $(fp_err "$body"). La release « $tag » reste en BROUILLON (id $id) : supprime-la sur la forge avant de rejouer." >&2; return 1; }
    echo "fp: asset ← $n"
  done

  # 4. les .deb au registre Debian de l'owner. 409 = déjà là : un paquet publié ne se réécrit pas.
  #
  # ⚠ GITHUB N'A PAS DE REGISTRE DEBIAN, ET ON NE LE SIMULE PAS. Les `.deb` sont montés à l'étape 3
  # comme assets — donc téléchargeables, et `apt install ./lcars_*.deb` marche — mais il n'y a pas
  # de source `apt` à déclarer. Le taire ferait croire à une voie qui n'existe pas ; inventer une
  # URL en ferait une qui rend 404 à la première install venue.
  if [[ "$dialect" == github ]]; then
    echo "fp: registre Debian — GitHub n'en a pas. Les .deb sont dans la release (assets) : « sudo apt install ./lcars_*.deb » après téléchargement. Pas de source apt sur cette forge."
  else
  for f in "$dist"/*.deb; do
    [[ -f "$f" ]] || continue; n="$(basename "$f")"
    code="$(fp_curl "$body" -X PUT --upload-file "$f" "$forge/api/packages/$owner/debian/pool/$ddist/$comp/upload")"
    case "$code" in
      201) echo "fp: debian $ddist/$comp ← $n" ;;
      409) echo "fp: REFUS — $n existe déjà dans le registre Debian de $owner ($ddist/$comp) : un paquet publié ne se réécrit pas. La release « $tag » reste en brouillon (id $id)." >&2; return 1 ;;
      *) echo "fp: REFUS (${code:-vide}) au registre Debian pour $n — $(fp_err "$body"). La release « $tag » reste en brouillon (id $id)." >&2; return 1 ;;
    esac
  done
  fi

  # 5. publiée d'un coup
  code="$(fp_curl "$body" -X PATCH -H 'Content-Type: application/json' --data-binary '{"draft":false}' "$api/releases/$id")"
  [[ "$code" == 200 ]] || { echo "fp: REFUS (${code:-vide}) à la publication du brouillon $id — $(fp_err "$body")" >&2; return 1; }
  echo "fp: release $web/$owner/$repo/releases/tag/$tag — $(find "$dist" -maxdepth 1 -type f | wc -l) assets"
  # La source apt ne se dit QUE là où elle existe : une ligne `deb …` pour une forge qui n'a pas de
  # registre serait une commande qui rend 404 à celui qui la copie.
  if [[ "$dialect" != github ]]; then
    echo "fp: source apt : deb [signed-by=/etc/apt/keyrings/lcars-$owner.asc] $forge/api/packages/$owner/debian $ddist $comp"
    echo "fp:   clé     : $forge/api/packages/$owner/debian/repository.key"
  fi
}
