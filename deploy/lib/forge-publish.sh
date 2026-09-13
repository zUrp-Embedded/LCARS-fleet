#!/usr/bin/env bash
# SOURCE: deploy/lib/forge-publish.sh
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: publier UNE version sur la forge : la Release (tout le tiroir)

fp_token_sain() {
  local t="${FP_TOKEN:?FP_TOKEN absent (le jeton, attendu en variable)}" i c
  if [[ "$t" =~ ^[A-Za-z0-9._-]+$ ]]; then return 0; fi
  for (( i = 0; i < ${#t}; i++ )); do
    c="${t:i:1}"
    [[ "$c" =~ [A-Za-z0-9._-] ]] || break
  done
  echo "ÉCHEC : FP_TOKEN porte un caractère que la config curl interprète (rang $((i + 1)) sur ${#t})." >&2
  echo "       Un jeton de forge est alphanumérique (. _ - admis) ; un guillemet tronque l'en-tête," >&2
  echo "       un saut de ligne fait exécuter la suite comme des options curl. Le jeton n'est pas réimprimé." >&2
  return 1
}

fp_curl() {
  local out="$1"; shift
  fp_token_sain || return 1
  printf 'header = "Authorization: token %s"\n' "$FP_TOKEN" \
    | "${FP_CURL:-curl}" -sS -K - -o "$out" -w '%{http_code}' \
        --connect-timeout "${FP_CONNECT_TIMEOUT:-20}" \
        --speed-limit "${FP_SPEED_LIMIT:-1024}" --speed-time "${FP_SPEED_TIME:-60}" \
        -m "${FP_TIMEOUT:-1800}" "$@" 2>/dev/null || true
}

fp_err() { jq -r '.message // empty' "$1" 2>/dev/null | head -c 200; }

fp_urlenc() {
  local LC_ALL=C
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

fp_release_body() { # fp_release_body <tiroir> <sha du commit> <base des assets> [<image>] — le corps de la release, en Markdown : les commandes à copier, avec leur vraie adresse
  local dist="$1" target="$2" base="$3" image="${4:-}" f
  printf 'Source : `%s`\n' "$target"
  [[ -z "$image" ]] || printf 'Image : `%s`\n' "$image"
  printf '\n**En conteneur** (docker), avec la forge et le runner montés par l'"'"'installeur :\n\n```bash\ncurl -fsSL %s/install.sh | bash -s -- --bench\n```\n\n' "$base"
  printf '**Dans ce système** (WSL 2, ou Linux dédié avec `LCARS_ALLOW_ANY_HOST=1`) :\n\n```bash\ncurl -fsSL %s/install.sh | bash -s -- --workstation --bench\n```\n\n' "$base"
  printf 'Sans `--bench`, une forge existante est requise (`FORGE_BASE_URL`). `--check` mesure sans rien poser, `--dry-run` dit la commande.\n\nsha256 :\n\n```\n'
  for f in "$dist"/*.sha256; do [[ -f "$f" ]] || continue; printf '%s\n' "$(head -1 "$f")"; done
  printf '```\n'
}

fp_dialect() {
  local u="${1%/}" hote
  u="${u,,}"                       # l'hôte est insensible à la casse (RFC 3986 § 3.2.2)
  u="${u#*://}"                    # le schéma s'il y en a un
  u="${u%%/*}"                     # tout ce qui suit l'hôte : chemin, requête, fragment
  hote="${u##*@}"                  # les identifiants d'un remote authentifié
  hote="${hote%%:*}"               # le port
  case "$hote" in
    github.com|www.github.com|api.github.com|uploads.github.com) echo github ;;
    *) echo gitea ;;
  esac
}

fp_publish_dist() {
  local forge="${1%/}" owner="$2" repo="$3" tag="$4" dist="$5" target="$6"
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

  code="$(fp_curl "$body" "$api/releases/tags/$tag")"
  case "$code" in
    404)
      if [[ "$dialect" == github ]]; then
        code="$(fp_curl "$body" "$api/releases?per_page=100")"
        if [[ "$code" == 200 ]] && jq -e --arg t "$tag" 'any(.[]; .tag_name == $t)' "$body" >/dev/null 2>&1; then
          echo "fp: REFUS — un BROUILLON du tag « $tag » existe déjà sur $web/$owner/$repo (invisible à GET /releases/tags/, qui ne voit que les publiées) — à supprimer sur la forge avant de rejouer, ce script ne le fait pas." >&2
          return 1
        fi
        [[ "$code" == 200 ]] || { echo "fp: REFUS (${code:-vide}) — impossible de lister les releases de $owner/$repo pour chercher un brouillon : une garde qui ne peut pas mesurer ne laisse pas passer" >&2; return 1; }
      fi
      ;;
    200) echo "fp: REFUS — la release « $tag » existe déjà sur $forge/$owner/$repo ($(jq -r 'if .draft then "brouillon" else "publiée" end' "$body" 2>/dev/null)). Un tag publié ne se réécrit jamais — pour la refaire, la supprimer sur la forge, ce script ne le fait pas." >&2; return 1 ;;
    401|403) echo "fp: REFUS ($code) — le jeton ne lit pas $owner/$repo (portée write:repository requise)" >&2; return 1 ;;
    *) echo "fp: REFUS — la forge ne répond pas sur $api/releases/tags/$tag (code ${code:-vide}) : une garde qui ne peut pas mesurer ne laisse pas passer" >&2; return 1 ;;
  esac

  code="$(fp_curl "$body" "$api/git/commits/$target")"
  case "$code" in
    200) ;;
    404) echo "fp: REFUS — le commit $target n'est pas sur $forge/$owner/$repo : on publie un commit poussé, pas un arbre local (git push, puis rejouer)" >&2; return 1 ;;
    *) echo "fp: REFUS (${code:-vide}) — la forge ne dit pas si le commit $target est là ($(fp_err "$body"))" >&2; return 1 ;;
  esac

  local json; json="$(jq -cn --arg t "$tag" --arg n "lcars $tag" --arg b "$(fp_release_body "$dist" "$target" "$forge/$owner/$repo/releases/download/$tag" "${FP_IMAGE:-}")" --arg c "$target" \
                      '{tag_name:$t, name:$n, body:$b, draft:true, prerelease:false, target_commitish:$c}')"
  code="$(fp_curl "$body" -X POST -H 'Content-Type: application/json' --data-binary "$json" "$api/releases")"
  case "$code" in
    201) ;;
    404|422) echo "fp: REFUS ($code) à la création de la release — $(fp_err "$body"). Le commit $target est-il sur la forge ? On publie un commit POUSSÉ." >&2; return 1 ;;
    *) echo "fp: REFUS (${code:-vide}) à la création de la release — $(fp_err "$body")" >&2; return 1 ;;
  esac
  id="$(jq -r '.id // empty' "$body" 2>/dev/null)"
  [[ "$id" =~ ^[0-9]+$ ]] || { echo "fp: la forge n'a pas rendu l'id de la release « $tag » (brouillon créé ? à vérifier sur la forge)" >&2; return 1; }

  local nq
  for f in "$dist"/*; do
    [[ -f "$f" ]] || continue; n="$(basename "$f")"; nq="$(fp_urlenc "$n")"
    if [[ "$dialect" == github ]]; then
      code="$(fp_curl "$body" -X POST -H 'Content-Type: application/octet-stream' \
                --data-binary "@$f" "https://uploads.github.com/repos/$owner/$repo/releases/$id/assets?name=$nq")"
    else
      code="$(fp_curl "$body" -X POST -F "attachment=@$f" "$api/releases/$id/assets?name=$nq")"
    fi
    [[ "$code" == 201 ]] || { echo "fp: REFUS (${code:-vide}) sur l'asset $n — $(fp_err "$body"). La release « $tag » reste en brouillon (id $id) : à supprimer sur la forge avant de rejouer." >&2; return 1; }
    echo "fp: asset ← $n"
  done

  code="$(fp_curl "$body" -X PATCH -H 'Content-Type: application/json' --data-binary '{"draft":false}' "$api/releases/$id")"
  [[ "$code" == 200 ]] || { echo "fp: REFUS (${code:-vide}) à la publication du brouillon $id — $(fp_err "$body")" >&2; return 1; }
  echo "fp: release $web/$owner/$repo/releases/tag/$tag — $(find "$dist" -maxdepth 1 -type f | wc -l) assets"
}
