#!/usr/bin/env bash
# SOURCE: deploy/lib/forge-publish.sh
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: publier UNE version sur la forge : la Release (tout le tiroir)
#
# Sourcée après provision-lib.sh (forge_api). Le jeton se lit dans FP_TOKEN_FILE, l'image de la
# version dans FP_IMAGE ; pack.sh pose les deux.

# un asset de plusieurs dizaines de Mo sur un lien lent : le mur porte sur l'inactivité, pas sur la durée
FP_TRANSFERT=(--connect-timeout 20 --speed-limit 1024 --speed-time 60 -m 1800)

fp_err() { jq -r '.message // empty' "$1" 2>/dev/null | head -c 200; }

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

fp_api() { # fp_api <forge> <owner> <repo> → « <api> <web> » selon le dialecte
  local forge="$1" owner="$2" repo="$3"
  if [[ "$(fp_dialect "$forge")" == github ]]; then
    printf '%s %s\n' "https://api.github.com/repos/$owner/$repo" "https://github.com"
  else
    printf '%s %s\n' "$forge/api/v1/repos/$owner/$repo" "$forge"
  fi
}

fp_precheck() { # fp_precheck <forge> <owner> <repo> <tag> <sha> — la release du tag n'existe pas, brouillon compris, et le commit est sur la forge
  local forge="$1" owner="$2" repo="$3" tag="$4" target="$5"
  local body code api web page n
  read -r api web < <(fp_api "$forge" "$owner" "$repo")
  command -v jq >/dev/null || { echo "fp: REFUS — jq absent (la release se décrit en JSON)" >&2; return 1; }
  body="$(mktemp)"
  # shellcheck disable=SC2064  # $body est résolu maintenant, c'est voulu
  trap "rm -f '$body'" RETURN

  code="$(forge_api GET "$api/releases/tags/$tag" "$body" --token-file "$FP_TOKEN_FILE" "${FP_TRANSFERT[@]}")" || true
  case "$code" in
    404)
      if [[ "$(fp_dialect "$forge")" == github ]]; then
        page=1
        while :; do
          code="$(forge_api GET "$api/releases?per_page=100&page=$page" "$body" --token-file "$FP_TOKEN_FILE" "${FP_TRANSFERT[@]}")" \
            || { echo "fp: REFUS ($code) — impossible de lister les releases de $owner/$repo pour chercher un brouillon : une garde qui ne peut pas mesurer ne laisse pas passer" >&2; return 1; }
          if jq -e --arg t "$tag" 'any(.[]; .tag_name == $t)' "$body" >/dev/null 2>&1; then
            echo "fp: REFUS — un BROUILLON du tag « $tag » existe déjà sur $web/$owner/$repo (invisible à GET /releases/tags/, qui ne voit que les publiées) — à supprimer sur la forge avant de rejouer, ce script ne le fait pas." >&2
            return 1
          fi
          n="$(jq 'length' "$body" 2>/dev/null || echo 0)"
          [[ "$n" -eq 100 ]] || break
          page=$((page + 1))
        done
      fi
      ;;
    200) echo "fp: REFUS — la release « $tag » existe déjà sur $forge/$owner/$repo ($(jq -r 'if .draft then "brouillon" else "publiée" end' "$body" 2>/dev/null)). Un tag publié ne se réécrit jamais — pour la refaire, la supprimer sur la forge, ce script ne le fait pas." >&2; return 1 ;;
    401|403) echo "fp: REFUS ($code) — le jeton ne lit pas $owner/$repo (portée write:repository requise)" >&2; return 1 ;;
    *) echo "fp: REFUS — la forge ne répond pas sur $api/releases/tags/$tag (code $code) : une garde qui ne peut pas mesurer ne laisse pas passer" >&2; return 1 ;;
  esac

  code="$(forge_api GET "$api/git/commits/$target" "$body" --token-file "$FP_TOKEN_FILE" "${FP_TRANSFERT[@]}")" || true
  case "$code" in
    200) ;;
    404) echo "fp: REFUS — le commit $target n'est pas sur $forge/$owner/$repo : on publie un commit poussé, pas un arbre local (git push, puis rejouer)" >&2; return 1 ;;
    *) echo "fp: REFUS ($code) — la forge ne dit pas si le commit $target est là ($(fp_err "$body"))" >&2; return 1 ;;
  esac
}

fp_publish_dist() { # fp_publish_dist <forge> <owner> <repo> <tag> <tiroir> <sha> — après fp_precheck : brouillon, assets, publication
  local forge="$1" owner="$2" repo="$3" tag="$4" dist="$5" target="$6"
  local body code id f n api web nq
  local dialect; dialect="$(fp_dialect "$forge")"
  read -r api web < <(fp_api "$forge" "$owner" "$repo")
  body="$(mktemp)"
  # shellcheck disable=SC2064  # $body est résolu maintenant, c'est voulu
  trap "rm -f '$body'" RETURN

  code="$(forge_api POST "$api/releases" "$body" --token-file "$FP_TOKEN_FILE" "${FP_TRANSFERT[@]}" \
            --json '{tag_name: $t, name: $n, body: $b, draft: true, prerelease: false, target_commitish: $c}' \
            --arg t "$tag" --arg n "lcars $tag" --arg c "$target" \
            --arg b "$(fp_release_body "$dist" "$target" "$forge/$owner/$repo/releases/download/$tag" "${FP_IMAGE:-}")")" || true
  case "$code" in
    201) ;;
    404|422) echo "fp: REFUS ($code) à la création de la release — $(fp_err "$body"). Le commit $target est-il sur la forge ? On publie un commit POUSSÉ." >&2; return 1 ;;
    *) echo "fp: REFUS ($code) à la création de la release — $(fp_err "$body")" >&2; return 1 ;;
  esac
  id="$(jq -r '.id // empty' "$body" 2>/dev/null)"
  [[ "$id" =~ ^[0-9]+$ ]] || { echo "fp: la forge n'a pas rendu l'id de la release « $tag » (brouillon créé ? à vérifier sur la forge)" >&2; return 1; }

  for f in "$dist"/*; do
    [[ -f "$f" ]] || continue; n="$(basename "$f")"; nq="$(jq -rn --arg s "$n" '$s|@uri')"
    if [[ "$dialect" == github ]]; then
      code="$(forge_api POST "https://uploads.github.com/repos/$owner/$repo/releases/$id/assets?name=$nq" "$body" \
                --token-file "$FP_TOKEN_FILE" "${FP_TRANSFERT[@]}" -H 'Content-Type: application/octet-stream' --data-binary "@$f")" || true
    else
      code="$(forge_api POST "$api/releases/$id/assets?name=$nq" "$body" --token-file "$FP_TOKEN_FILE" "${FP_TRANSFERT[@]}" -F "attachment=@$f")" || true
    fi
    [[ "$code" == 201 ]] || { echo "fp: REFUS ($code) sur l'asset $n — $(fp_err "$body"). La release « $tag » reste en brouillon (id $id) : à supprimer sur la forge avant de rejouer." >&2; return 1; }
    echo "fp: asset ← $n"
  done

  code="$(forge_api PATCH "$api/releases/$id" "$body" --token-file "$FP_TOKEN_FILE" "${FP_TRANSFERT[@]}" --json '{draft: false}')" || true
  [[ "$code" == 200 ]] || { echo "fp: REFUS ($code) à la publication du brouillon $id — $(fp_err "$body")" >&2; return 1; }
  echo "fp: release $web/$owner/$repo/releases/tag/$tag — $(find "$dist" -maxdepth 1 -type f | wc -l) assets"
}
