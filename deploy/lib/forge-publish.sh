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

# fp_release_body <tiroir> <sha-source> → le texte de la release : d'où elle vient, comment on la pose,
# et les sommes (celles que le tiroir porte déjà — on ne recalcule pas ce que la porte a en dur)
fp_release_body() {
  local dist="$1" target="$2" f
  printf 'Source : %s\n\nPoser (poste, Debian/Ubuntu) :\n\n    curl --proto '"'"'=https'"'"' --tlsv1.2 -fsSL <base>/install.sh | bash -s -- --workstation\n\nsha256 :\n\n' "$target"
  for f in "$dist"/*.sha256; do [[ -f "$f" ]] || continue; printf '    %s\n' "$(head -1 "$f")"; done
}

# fp_publish_dist <forge> <owner> <repo> <tag> <tiroir> <sha-source> <distribution-debian> [component]
fp_publish_dist() {
  local forge="${1%/}" owner="$2" repo="$3" tag="$4" dist="$5" target="$6" ddist="$7" comp="${8:-main}"
  local api="$forge/api/v1/repos/$owner/$repo" body code id f n
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

  # 2. la release, en brouillon, sur LE commit du pack (target_commitish) — s'il n'est pas sur la forge,
  #    elle le dit : on publie un commit poussé, pas un arbre local
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

  # 3. les assets — TOUT le tiroir
  for f in "$dist"/*; do
    [[ -f "$f" ]] || continue; n="$(basename "$f")"
    code="$(fp_curl "$body" -X POST -F "attachment=@$f" "$api/releases/$id/assets?name=$n")"
    [[ "$code" == 201 ]] || { echo "fp: REFUS (${code:-vide}) sur l'asset $n — $(fp_err "$body"). La release « $tag » reste en BROUILLON (id $id) : supprime-la sur la forge avant de rejouer." >&2; return 1; }
    echo "fp: asset ← $n"
  done

  # 4. les .deb au registre Debian de l'owner. 409 = déjà là : un paquet publié ne se réécrit pas.
  for f in "$dist"/*.deb; do
    [[ -f "$f" ]] || continue; n="$(basename "$f")"
    code="$(fp_curl "$body" -X PUT --upload-file "$f" "$forge/api/packages/$owner/debian/pool/$ddist/$comp/upload")"
    case "$code" in
      201) echo "fp: debian $ddist/$comp ← $n" ;;
      409) echo "fp: REFUS — $n existe déjà dans le registre Debian de $owner ($ddist/$comp) : un paquet publié ne se réécrit pas. La release « $tag » reste en brouillon (id $id)." >&2; return 1 ;;
      *) echo "fp: REFUS (${code:-vide}) au registre Debian pour $n — $(fp_err "$body"). La release « $tag » reste en brouillon (id $id)." >&2; return 1 ;;
    esac
  done

  # 5. publiée d'un coup
  code="$(fp_curl "$body" -X PATCH -H 'Content-Type: application/json' --data-binary '{"draft":false}' "$api/releases/$id")"
  [[ "$code" == 200 ]] || { echo "fp: REFUS (${code:-vide}) à la publication du brouillon $id — $(fp_err "$body")" >&2; return 1; }
  echo "fp: release $forge/$owner/$repo/releases/tag/$tag — $(find "$dist" -maxdepth 1 -type f | wc -l) assets"
  echo "fp: source apt : deb [signed-by=/etc/apt/keyrings/lcars-$owner.asc] $forge/api/packages/$owner/debian $ddist $comp"
  echo "fp:   clé     : $forge/api/packages/$owner/debian/repository.key"
}
