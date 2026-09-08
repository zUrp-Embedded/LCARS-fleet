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
# ⚠ LE JETON EST VALIDÉ AVANT D'ENTRER DANS LA CONFIG, PARCE QU'UNE CONFIG CURL S'INJECTE.
# `-K -` protège le jeton de `/proc` — et ouvre une autre porte : la config est un FORMAT, pas une
# chaîne opaque. Mesuré le 2026-09-08 avec `curl --libcurl` :
#   · un jeton portant un `"` fait envoyer un en-tête TRONQUÉ — « token ab » pour `ab"cd` : un
#     préfixe du jeton part sur le réseau et la forge rend un 401 que rien n'explique ;
#   · un jeton portant un SAUT DE LIGNE fait exécuter les lignes suivantes COMME DES OPTIONS —
#     `user-agent = "INJECTE"` est arrivé jusqu'à `CURLOPT_USERAGENT`. `output = …` écrirait un
#     fichier arbitraire, `--config` en lirait un autre. Le geste qui existe pour protéger le jeton
#     devient le geste qui exécute ce qu'il contient.
# Le jeu accepté est celui des jetons réels des deux forges — 40 hex chez Gitea, `ghp_`/`ghs_`/
# `github_pat_` + alphanumérique et `_` chez GitHub. Tout le reste est un REFUS NOMMÉ, et le refus
# ne réimprime pas le jeton : il dit sa longueur et le rang du premier caractère fautif.
fp_token_sain() {
  local t="${FP_TOKEN:?FP_TOKEN absent (le jeton, dans l environnement)}" i c
  if [[ "$t" =~ ^[A-Za-z0-9._-]+$ ]]; then return 0; fi
  for (( i = 0; i < ${#t}; i++ )); do
    c="${t:i:1}"
    [[ "$c" =~ [A-Za-z0-9._-] ]] || break
  done
  echo "ECHEC: FP_TOKEN porte un caractere que la config curl interprete (rang $((i + 1)) sur ${#t})." >&2
  echo "       Un jeton de forge est alphanumerique (. _ - admis) ; un guillemet tronque l en-tete," >&2
  echo "       un saut de ligne fait executer la suite comme des options curl. Le jeton n est pas reimprime." >&2
  return 1
}

fp_curl() {
  local out="$1"; shift
  fp_token_sain || return 1
  # ⚠ UN MUR SUR L'INACTIVITÉ, PAS SUR LA DURÉE TOTALE. `-m 300` seul coupe une montée SAINE : le
  # plus gros asset pèse 47 Mo (`lcars-tofu`, mesuré le 2026-09-08), soit 1,25 Mbit/s montants
  # exigés — au-dessus de ce qu'un lien domestique fournit. Ce qu'on veut refuser est un serveur
  # MUET, pas un lien lent : moins d'1 ko/s pendant 60 s est une mort, 47 Mo en dix minutes est un
  # succès. `-m` reste, en filet très large, pour le cas où le flux goutte indéfiniment.
  printf 'header = "Authorization: token %s"\n' "$FP_TOKEN" \
    | "${FP_CURL:-curl}" -sS -K - -o "$out" -w '%{http_code}' \
        --connect-timeout "${FP_CONNECT_TIMEOUT:-20}" \
        --speed-limit "${FP_SPEED_LIMIT:-1024}" --speed-time "${FP_SPEED_TIME:-60}" \
        -m "${FP_TIMEOUT:-1800}" "$@" 2>/dev/null || true
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
  # ⚠ `LC_ALL=C` OU LA FONCTION REPRODUIT LE BUG QU'ELLE CORRIGE. En locale UTF-8, `${s:i:1}` rend un
  # CARACTÈRE et `printf '%02X' "'$c"` son POINT DE CODE, pas ses octets : « € » sortait en `%20AC`,
  # c'est-à-dire une ESPACE suivie du littéral « AC » — exactement la cicatrice `+`→espace que cette
  # fonction existe pour fermer. « café » sortait en `caf%E9` (du Latin-1, pas de l'UTF-8 valide).
  # Mesuré le 2026-09-08 par une relecture hostile. En C, `${s:i:1}` itère les OCTETS et le
  # percent-encodage est correct : `café` -> `caf%C3%A9`, `€` -> `%E2%82%AC`.
  # La déclaration est LOCALE à la fonction : elle ne touche pas l'appelant.
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
# ⚠ ON RECONNAÎT UN HÔTE, PAS UNE CHAÎNE EXACTE — la liste de motifs littéraux d'avant rendait
# `gitea` sur `https://github.com/owner/repo` (une URL avec un chemin), sur `HTTPS://GITHUB.COM`, et
# sur `https://user@github.com/…` que `pack.sh:327` peut dériver d'un remote authentifié. Un faux
# négatif n'échoue pas franchement : la publication part sur `https://github.com/api/v1/repos/…`,
# reçoit 404 à l'étape 1 (lu comme « absente, on continue »), puis 404 à l'étape 1b — et le refus
# accuse alors LE MAUVAIS OBJET : « le commit n'est pas sur la forge, git push puis rejoue », sur un
# commit déjà poussé. Trouvé par relecture hostile le 2026-09-08.
#
# `github.example.com` reste `gitea` : GitHub Enterprise a la même API que github.com sur un autre
# hôte, mais nous n'en avons aucun et deviner serait pire — le jour où il y en a un, il se déclare.
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
    404)
      # ⚠ 404 NE VEUT PAS DIRE « RIEN » SUR GITHUB. `GET /releases/tags/{tag}` n'adresse que les
      # releases PUBLIÉES : un BROUILLON du même tag rend 404 et passerait ici. Or l'en-tête de ce
      # fichier promet « une release du tag qui existe (brouillon compris) est un REFUS », et le
      # mode de panne nominal du workflow est justement un envoi coupé qui laisse un brouillon —
      # « une image poussée dont la release manque se rattrape en rejouant ». Sans cette sonde, le
      # rejeu crée un SECOND brouillon, remonte tout, publie, et laisse un orphelin sans un mot.
      # Trouvé par relecture hostile le 2026-09-08. Sur Gitea, `GET .../tags/` voit les brouillons :
      # la sonde y est redondante, pas fausse — on la joue pour les deux, une garde ne se dédouble pas.
      if [[ "$dialect" == github ]]; then
        code="$(fp_curl "$body" "$api/releases?per_page=100")"
        if [[ "$code" == 200 ]] && jq -e --arg t "$tag" 'any(.[]; .tag_name == $t)' "$body" >/dev/null 2>&1; then
          echo "fp: REFUS — un BROUILLON du tag « $tag » existe déjà sur $web/$owner/$repo (invisible à GET /releases/tags/, qui ne voit que les publiées). ADR 012 : supprime-le sur la forge avant de rejouer, ce script ne le fait pas." >&2
          return 1
        fi
        [[ "$code" == 200 ]] || { echo "fp: REFUS (${code:-vide}) — impossible de lister les releases de $owner/$repo pour chercher un brouillon : une garde qui ne peut pas mesurer ne laisse pas passer" >&2; return 1; }
      fi
      ;;
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
