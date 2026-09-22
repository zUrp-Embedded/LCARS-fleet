#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/lib/forge_publish.bats
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: forge-publish.sh à blanc, sourcé après provision-lib.sh : une doublure de curl qui note ce qu'on lui demande

load ../refute
load ../support/decor

setup() {
  decor_pose
  LIBS=". '$BATS_TEST_DIRNAME/../../lib/provision-lib.sh'; . '$BATS_TEST_DIRNAME/../../lib/forge-publish.sh'"
  TRACE="$BATS_TEST_TMPDIR/trace"
  cat > "$DECOR_BIN/curl" <<'SH'
#!/usr/bin/env bash
out=""; method=GET; url=""; prev=""; forme=""; ctype=""; corps=""; entete=""
for a in "$@"; do
  case "$prev" in
    -o) out="$a" ;;
    -X) method="$a" ;;
    -H) case "$a" in @-) entete="$(cat)" ;; 'Content-Type: '*) ctype="${a#Content-Type: }" ;; esac ;;
    --data-binary) forme=binaire; corps="${a#@}" ;;
    -F) forme=multipart ;;
  esac
  [[ "$a" == http* ]] && url="$a"
  prev="$a"
done
echo "$method $url${forme:+ corps=$forme}${ctype:+ ctype=$ctype}" >> "$FAKE_TRACE"
printf '%s\n' "$entete" >> "$FAKE_TRACE.entetes"
printf '%s\n' "$*" >> "$FAKE_TRACE.argv"
[[ "$ctype" != application/json ]] || cat "$corps" >> "$FAKE_TRACE.json"
[[ "${FAKE_DOWN:-0}" == 1 ]] && { printf 000; exit 7; }   # le vrai curl rend 000 avec -w quand rien ne répond
case "$method $url" in
  "GET "*/releases/tags/*) printf '{"id":7,"draft":%s}' "${FAKE_TAG_DRAFT:-false}" > "$out"; printf '%s' "${FAKE_TAG:-404}" ;;
  "GET "*/releases?per_page=100\&page=1) if [[ -n "${FAKE_PAGE1_FULL:-}" ]]; then { printf '['; for i in $(seq 1 100); do printf '%s{"tag_name":"v%s"}' "$([[ $i -gt 1 ]] && echo ,)" "$i"; done; printf ']'; } > "$out"; else printf '[%s]' "${FAKE_DRAFT_TAG:+{\"tag_name\":\"$FAKE_DRAFT_TAG\",\"draft\":true\}}" > "$out"; fi; printf '%s' "${FAKE_LIST:-200}" ;;
  "GET "*/releases?per_page=*) printf '[%s]' "${FAKE_DRAFT_TAG:+{\"tag_name\":\"$FAKE_DRAFT_TAG\",\"draft\":true\}}" > "$out"; printf '%s' "${FAKE_LIST:-200}" ;;
  "GET "*/git/commits/*) : > "$out"; printf '%s' "${FAKE_COMMIT:-200}" ;;
  "POST "*/releases) printf '{"id":42}' > "$out"; printf 201 ;;
  "POST "*/assets?name=*) n="${url##*name=}"; if [[ "$n" == "${FAKE_ASSET_KO:-}" ]]; then printf '{"message":"disque plein"}' > "$out"; printf 500; else : > "$out"; printf 201; fi ;;
  "PATCH "*/releases/*) : > "$out"; printf 200 ;;
  *) printf 599 ;;
esac
SH
  chmod +x "$DECOR_BIN/curl"
  DIST="$BATS_TEST_TMPDIR/dist/0.1-abc"; mkdir -p "$DIST"
  printf 'x' > "$DIST/lcars-0.1-abc.tar.gz"; echo "aaaa  lcars-0.1-abc.tar.gz" > "$DIST/lcars-0.1-abc.tar.gz.sha256"
  printf 'p' > "$DIST/install.sh"; echo "bbbb  install.sh" > "$DIST/install.sh.sha256"
  export FP_TOKEN_FILE="$BATS_TEST_TMPDIR/jeton"
  printf 'jeton-secret-0123456789\n' > "$FP_TOKEN_FILE"
  export FAKE_TRACE="$TRACE"
}

_pre()    { run bash -c "$LIBS; fp_precheck http://forge.test fleet lcars 0.1-abc deadbeefcafe"; }
_dist()   { run bash -c "$LIBS; fp_publish_dist http://forge.test fleet lcars 0.1-abc '$DIST' deadbeefcafe"; }
_pub()    { run bash -c "$LIBS; fp_precheck http://forge.test fleet lcars 0.1-abc deadbeefcafe && fp_publish_dist http://forge.test fleet lcars 0.1-abc '$DIST' deadbeefcafe"; }
_pre_gh() { run bash -c "$LIBS; fp_precheck https://github.com zurp-embedded LCARS-fleet 0.1-abc deadbeefcafe"; }
_pub_gh() { run bash -c "$LIBS; fp_precheck https://github.com zurp-embedded LCARS-fleet 0.1-abc deadbeefcafe && fp_publish_dist https://github.com zurp-embedded LCARS-fleet 0.1-abc '$DIST' deadbeefcafe"; }

@test "le corps nomme l'image de la version quand FP_IMAGE la donne" {
  run bash -c "export FP_IMAGE=ghcr.io/fleet/lcars:0.1-abc; $LIBS; fp_publish_dist http://forge.test fleet lcars 0.1-abc '$DIST' deadbeefcafe"
  [ "$status" -eq 0 ]
  [[ "$(sed -n 1p "$TRACE.json" | jq -r '.body')" == *'Image : `ghcr.io/fleet/lcars:0.1-abc`'* ]]
}

@test "le jeton arrive à curl par son entrée, jamais en argv, et chaque appel le porte" {
  _pub
  [ "$status" -eq 0 ]
  [ "$(grep -cx 'Authorization: token jeton-secret-0123456789' "$TRACE.entetes")" -eq "$(wc -l < "$TRACE")" ]
  refute grep -q 'jeton-secret' "$TRACE.argv"
}

@test "un jeton qui porte un guillemet part entier dans l'en-tête" {
  printf '%s\n' "ab\"cd'ef" > "$FP_TOKEN_FILE"
  _pre
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$TRACE.entetes")" = "Authorization: token ab\"cd'ef" ]
}

@test "fp_publish_dist ne rejoue pas la garde : le premier appel crée le brouillon, les assets suivent, la publication ferme" {
  _dist
  [ "$status" -eq 0 ]
  [[ "$(sed -n 1p "$TRACE")" == "POST http://forge.test/api/v1/repos/fleet/lcars/releases "* ]]
  [ "$(grep -c 'POST http://forge.test/api/v1/repos/fleet/lcars/releases/42/assets?name=' "$TRACE")" -eq 4 ]
  grep -qE 'assets\?name=install\.sh( |$)' "$TRACE"
  grep -qE 'assets\?name=lcars-0\.1-abc\.tar\.gz( |$)' "$TRACE"
  [[ "$(tail -1 "$TRACE")" == "PATCH http://forge.test/api/v1/repos/fleet/lcars/releases/42"* ]]
  refute grep -qE '^GET ' "$TRACE"
  [[ "$output" == *"fp: release http://forge.test/fleet/lcars/releases/tag/0.1-abc — 4 assets"* ]]
}

@test "le brouillon est créé draft:true sur target_commitish = le sha, et le corps porte les sommes du tiroir" {
  _dist
  [ "$status" -eq 0 ]
  local j; j="$(sed -n 1p "$TRACE.json")"
  [ "$(jq -r '.draft' <<<"$j")" = "true" ]
  [ "$(jq -r '.tag_name' <<<"$j")" = "0.1-abc" ]
  [ "$(jq -r '.target_commitish' <<<"$j")" = "deadbeefcafe" ]
  local corps; corps="$(jq -r '.body' <<<"$j")"
  [[ "$corps" == *'Source : `deadbeefcafe`'*"bbbb  install.sh"*"aaaa  lcars-0.1-abc.tar.gz"* ]]  # le glob trie : install.sh avant lcars-
  # les commandes à copier portent la vraie adresse de la release, les deux modes, jamais un gabarit
  [[ "$corps" == *"curl -fsSL http://forge.test/fleet/lcars/releases/download/0.1-abc/install.sh | bash -s -- --bench"* ]]
  [[ "$corps" == *"http://forge.test/fleet/lcars/releases/download/0.1-abc/install.sh | bash -s -- --workstation --bench"* ]]
  refute_out '<base>' <<<"$corps"
  refute_out 'Image :' <<<"$corps"
  [ "$(sed -n 2p "$TRACE.json")" = '{"draft":false}' ]
}

@test "une release publiée du tag est un refus nommé, et rien d'autre n'est demandé" {
  FAKE_TAG=200 _pre
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUS"*"existe déjà"*"publiée"*"Un tag publié ne se réécrit jamais"*"la supprimer sur la forge"* ]]
  [ "$(wc -l < "$TRACE")" -eq 1 ]
}

@test "un brouillon du tag vu par Gitea est un refus qui le dit brouillon" {
  FAKE_TAG=200 FAKE_TAG_DRAFT=true _pre
  [ "$status" -ne 0 ]
  [[ "$output" == *"existe déjà"*"brouillon"* ]]
}

@test "une forge injoignable est un refus après un seul appel" {
  FAKE_DOWN=1 _pre
  [ "$status" -ne 0 ]
  [[ "$output" == *"ne répond pas"*"code 000"*"ne laisse pas passer"* ]]
  [ "$(wc -l < "$TRACE")" -eq 1 ]
}

@test "un jeton sans portée est un refus qui nomme la portée" {
  FAKE_TAG=403 _pre
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUS (403)"*"write:repository"* ]]
}

@test "un commit que la forge ne connaît pas est un refus avant le brouillon" {
  FAKE_COMMIT=404 _pub
  [ "$status" -ne 0 ]
  [[ "$output" == *"le commit deadbeefcafe n'est pas sur http://forge.test/fleet/lcars"*"commit poussé"* ]]
  [ "$(wc -l < "$TRACE")" -eq 2 ]
  refute grep -q '^POST' "$TRACE"
}

@test "un asset qui échoue : refus qui nomme l'asset, le message de la forge et le brouillon à supprimer, sans publication" {
  FAKE_ASSET_KO=lcars-0.1-abc.tar.gz _dist
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUS (500) sur l'asset lcars-0.1-abc.tar.gz"*"disque plein"*"brouillon (id 42) : à supprimer sur la forge"* ]]
  refute grep -q '^PATCH' "$TRACE"
}

@test "GITHUB : l'API est api.github.com, la garde précède le brouillon, et les assets partent sur uploads.github.com" {
  _pub_gh
  [ "$status" -eq 0 ]
  [[ "$(sed -n 1p "$TRACE")" == "GET https://api.github.com/repos/zurp-embedded/LCARS-fleet/releases/tags/0.1-abc" ]]
  grep -qx 'GET https://api.github.com/repos/zurp-embedded/LCARS-fleet/git/commits/deadbeefcafe' "$TRACE"
  [ "$(grep -n '/git/commits/' "$TRACE" | cut -d: -f1)" -lt "$(grep -n '^POST https://api.github.com/repos/zurp-embedded/LCARS-fleet/releases ' "$TRACE" | cut -d: -f1)" ]
  [ "$(grep -c '^POST https://uploads.github.com/repos/zurp-embedded/LCARS-fleet/releases/42/assets?name=' "$TRACE")" -eq 4 ]
  refute grep -q 'POST https://api.github.com/.*/assets' "$TRACE"   # GitHub y rend 422
  [[ "$(tail -1 "$TRACE")" == "PATCH https://api.github.com/repos/zurp-embedded/LCARS-fleet/releases/42"* ]]
}

@test "GITHUB : l'URL rendue est celle du web, pas celle de l'API" {
  _pub_gh
  [ "$status" -eq 0 ]
  [[ "$output" == *"release https://github.com/zurp-embedded/LCARS-fleet/releases/tag/0.1-abc — 4 assets"* ]]
}

@test "un nom d'asset réservé ou non ASCII part encodé en octets UTF-8 — sinon la forge stocke une espace et la porte rend 404" {
  printf 'd' > "$DIST/lcars_0.9.0-20260908.1310+g48fa4a4b_amd64.tar.gz"
  printf 'e' > "$DIST/café€ x~y.bin"
  _dist
  [ "$status" -eq 0 ]
  grep -qE 'assets\?name=lcars_0\.9\.0-20260908\.1310%2Bg48fa4a4b_amd64\.tar\.gz( |$)' "$TRACE"
  refute grep -qE 'assets\?name=[^ ]*1310\+g48' "$TRACE"
  grep -qE 'assets\?name=caf%C3%A9%E2%82%AC%20x~y\.bin( |$)' "$TRACE"
}

@test "GITHUB : les assets partent en corps binaire avec son Content-Type — un multipart y rend 422" {
  _pub_gh
  [ "$status" -eq 0 ]
  [ "$(grep -c 'uploads.github.com.*corps=binaire' "$TRACE")" -eq 4 ]
  [ "$(grep -c 'uploads.github.com.*ctype=application/octet-stream' "$TRACE")" -eq 4 ]
  refute grep -q 'uploads.github.com.*corps=multipart' "$TRACE"
}

@test "GITEA : les assets partent en multipart" {
  _dist
  [ "$status" -eq 0 ]
  [ "$(grep -c 'forge.test.*assets?name=.*corps=multipart' "$TRACE")" -eq 4 ]
  refute grep -q 'forge.test.*assets?name=.*corps=binaire' "$TRACE"
}

@test "fp_dialect reconnaît l'hôte, pas une chaîne exacte — barre finale, chemin, casse, identifiants, port" {
  run bash -c "$LIBS"'
    for u in "https://github.com" "https://github.com/" "https://github.com/o/r" "HTTPS://GITHUB.COM" "https://GitHub.com" \
             "github.com" "https://user@github.com/o/r.git" "https://x:tok@github.com/o/r" \
             "https://github.com//" "https://api.github.com/" "https://github.com:443" \
             "https://github.example.com" "http://10.42.0.118" "https://gitea.example.org/o/r"; do
      printf "%s " "$(fp_dialect "$u")"
    done'
  [ "$status" -eq 0 ]
  [ "$output" = "github github github github github github github github github github github gitea gitea gitea " ]
}

@test "GITHUB : un brouillon du tag est vu — GET /releases/tags/ ne voit que les publiées" {
  FAKE_DRAFT_TAG=0.1-abc _pre_gh
  [ "$status" -ne 0 ]
  [[ "$output" == *"BROUILLON"*"0.1-abc"* ]]
}

@test "GITHUB : un brouillon au-delà des cent premières releases est vu, la liste est lue page après page" {
  FAKE_PAGE1_FULL=1 FAKE_DRAFT_TAG=0.1-abc _pre_gh
  [ "$status" -ne 0 ]
  [[ "$output" == *"BROUILLON"* ]]
  grep -q 'releases?per_page=100&page=2' "$TRACE"
}

@test "fp_precheck seul : mesure le tag et le commit, n'envoie rien" {
  _pre
  [ "$status" -eq 0 ]
  grep -qx 'GET http://forge.test/api/v1/repos/fleet/lcars/releases/tags/0.1-abc' "$TRACE"
  grep -qx 'GET http://forge.test/api/v1/repos/fleet/lcars/git/commits/deadbeefcafe' "$TRACE"
  refute grep -qE '^(POST|PATCH)' "$TRACE"
}

@test "GITHUB : une liste de releases injoignable est un refus — une garde qui ne mesure pas ne passe pas" {
  FAKE_LIST=500 _pre_gh
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUS (500)"*"chercher un brouillon"* ]]
}

@test "GITEA : la sonde de brouillon ne s'y joue pas — GET /releases/tags/ y voit déjà les brouillons" {
  _pre
  [ "$status" -eq 0 ]
  refute grep -q 'releases?per_page' "$TRACE"
}

@test "chaque appel porte le mur d'inactivité et le plafond de connexion — une montée longue sur un lien lent passe" {
  _pub
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--connect-timeout 20 --speed-limit 1024 --speed-time 60 -m 1800' "$TRACE.argv")" -eq "$(wc -l < "$TRACE")" ]
}
