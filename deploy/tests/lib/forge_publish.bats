#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/lib/forge_publish.bats
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: PROTO-V2 — forge-publish.sh à blanc : une doublure de curl qui note ce qu'on lui demande
#

setup() {
  LIB="$BATS_TEST_DIRNAME/../../lib/forge-publish.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; TRACE="$BATS_TEST_TMPDIR/trace"; STDIN="$BATS_TEST_TMPDIR/stdin"
  cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
cat > "${FAKE_STDIN:?}.$$" ; cat "${FAKE_STDIN}.$$" >> "$FAKE_STDIN"; rm -f "${FAKE_STDIN}.$$"
out=""; method=GET; url=""; prev=""; forme=""; ctype=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; -X) method="$a" ;; esac
  case "$a" in
    -F) forme=multipart ;;
    --data-binary) forme=binaire ;;
    'Content-Type: '*) ctype="${a#Content-Type: }" ;;
    http*) url="$a" ;;
  esac
  prev="$a"
done
echo "$method $url${forme:+ corps=$forme}${ctype:+ ctype=$ctype}" >> "${FAKE_TRACE:?}"
printf '%s\n' "$*" >> "${FAKE_ARGV:-/dev/null}"   # l'argv ENTIER : les murs de transfert s'y lisent
[[ "${FAKE_DOWN:-0}" == 1 ]] && { printf 000; exit 7; }   # le vrai curl rend 000 avec -w quand rien ne répond
case "$method $url" in
  "GET "*/releases/tags/*) printf '{"id":7,"draft":%s}' "${FAKE_TAG_DRAFT:-false}" > "$out"; printf '%s' "${FAKE_TAG:-404}" ;;
  "GET "*/releases?per_page=*) printf '[%s]' "${FAKE_DRAFT_TAG:+{\"tag_name\":\"$FAKE_DRAFT_TAG\",\"draft\":true\}}" > "$out"; printf '%s' "${FAKE_LIST:-200}" ;;
  "GET "*/git/commits/*) : > "$out"; printf '%s' "${FAKE_COMMIT:-200}" ;;
  "POST "*/releases) printf '{"id":42}' > "$out"; printf 201 ;;
  "POST "*/assets?name=*) n="${url##*name=}"; if [[ "$n" == "${FAKE_ASSET_KO:-}" ]]; then printf '{"message":"disque plein"}' > "$out"; printf 500; else : > "$out"; printf 201; fi ;;
  "PATCH "*/releases/*) : > "$out"; printf 200 ;;
  *) printf 599 ;;
esac
SH
  chmod +x "$BIN/curl"
  DIST="$BATS_TEST_TMPDIR/dist/0.1-abc"; mkdir -p "$DIST"
  printf 'x' > "$DIST/lcars-0.1-abc.tar.gz"; echo "aaaa  lcars-0.1-abc.tar.gz" > "$DIST/lcars-0.1-abc.tar.gz.sha256"
  printf 'p' > "$DIST/install.sh"; echo "bbbb  install.sh" > "$DIST/install.sh.sha256"
  ARGV="$BATS_TEST_TMPDIR/argv"
  export FAKE_TRACE="$TRACE" FAKE_STDIN="$STDIN" FAKE_ARGV="$ARGV" PATH="$BIN:$PATH" FP_TOKEN="jeton-secret-0123456789"
}

load ../refute

_pub() { run bash -c ". '$LIB'; fp_publish_dist http://forge.test/ fleet lcars 0.1-abc '$DIST' deadbeefcafe"; }

@test "le corps nomme l'image de la version quand FP_IMAGE la donne" {
  cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
cat >/dev/null; prev=""; for a in "$@"; do [[ "$prev" == --data-binary ]] && printf '%s\n' "$a" >> "${FAKE_TRACE}.json"; [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
case "$*" in *"-X POST"*"/releases"*) printf '{"id":42}' > "$out"; printf 201 ;; *"-X PATCH"*) printf 200 ;; *"/releases/tags/"*) printf 404 ;; *"/git/commits/"*) printf 200 ;; *) printf 200 ;; esac
SH
  run bash -c "export FP_IMAGE=ghcr.io/fleet/lcars:0.1-abc; . '$LIB'; fp_publish_dist http://forge.test/ fleet lcars 0.1-abc '$DIST' deadbeefcafe"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.body' < <(sed -n 1p "$TRACE.json"))" == *'Image : `ghcr.io/fleet/lcars:0.1-abc`'* ]]
}

@test "le jeton passe par la config -K - sur stdin, JAMAIS en argv — et chaque appel le porte" {
  _pub; [ "$status" -eq 0 ]
  grep -q 'header = "Authorization: token jeton-secret-0123456789"' "$STDIN"
  ! grep -q 'jeton-secret' "$TRACE" || { echo "le jeton est passe en argv de curl"; return 1; }
  [ "$(grep -c 'Authorization' "$STDIN")" -eq "$(wc -l < "$TRACE")" ]
}

@test "l'ordre du geste : immutabilité, le commit est là, brouillon sur LE commit, tous les assets, publication" {
  _pub; [ "$status" -eq 0 ]
  [[ "$(sed -n 1p "$TRACE")" == "GET http://forge.test/api/v1/repos/fleet/lcars/releases/tags/0.1-abc"* ]]
  [[ "$(sed -n 2p "$TRACE")" == "GET http://forge.test/api/v1/repos/fleet/lcars/git/commits/deadbeefcafe"* ]]
  [[ "$(sed -n 3p "$TRACE")" == "POST http://forge.test/api/v1/repos/fleet/lcars/releases"* ]]
  [ "$(grep -c 'POST http://forge.test/api/v1/repos/fleet/lcars/releases/42/assets?name=' "$TRACE")" -eq 4 ]
  grep -qE 'assets\?name=install\.sh( |$)' "$TRACE"; grep -qE 'assets\?name=lcars-0\.1-abc\.tar\.gz( |$)' "$TRACE"
  [[ "$(tail -1 "$TRACE")" == "PATCH http://forge.test/api/v1/repos/fleet/lcars/releases/42"* ]]
  [ "$(grep -n 'assets?name' "$TRACE" | tail -1 | cut -d: -f1)" -lt "$(grep -n '^PATCH' "$TRACE" | head -1 | cut -d: -f1)" ]
  [[ "$output" == *"fp: release http://forge.test/fleet/lcars/releases/tag/0.1-abc — 4 assets"* ]]
}

@test "le brouillon est créé draft:true sur target_commitish = le sha, et le corps porte les sommes du tiroir" {
  cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
cat >/dev/null; prev=""; for a in "$@"; do [[ "$prev" == --data-binary ]] && printf '%s\n' "$a" >> "${FAKE_TRACE}.json"; [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
case "$*" in *"-X POST"*"/releases"*) printf '{"id":42}' > "$out"; printf 201 ;; *"-X PATCH"*) printf 200 ;; *"/releases/tags/"*) printf 404 ;; *"/git/commits/"*) printf 200 ;; *) printf 201 ;; esac
SH
  _pub; [ "$status" -eq 0 ]
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

@test "IMMUTABILITE : une release du tag qui existe (publiée OU brouillon) = refus nommé, et RIEN n'est envoyé" {
  FAKE_TAG=200 _pub; [ "$status" -ne 0 ]
  [[ "$output" == *"REFUS"*"existe déjà"*"publiée"*"Un tag publié ne se réécrit jamais"*"la supprimer sur la forge"* ]]
  [ "$(wc -l < "$TRACE")" -eq 1 ]
  : > "$TRACE"; FAKE_TAG=200 FAKE_TAG_DRAFT=true _pub; [ "$status" -ne 0 ]
  [[ "$output" == *"existe déjà"*"brouillon"* ]]
}

@test "forge injoignable ou jeton sans portée : refus AVANT tout envoi — une garde qui ne peut pas mesurer ne laisse pas passer" {
  FAKE_DOWN=1 _pub; [ "$status" -ne 0 ]
  [[ "$output" == *"ne répond pas"*"code 000"*"ne laisse pas passer"* ]]
  [ "$(wc -l < "$TRACE")" -eq 1 ]
  : > "$TRACE"; FAKE_TAG=403 _pub; [ "$status" -ne 0 ]
  [[ "$output" == *"REFUS (403)"*"write:repository"* ]]
}

@test "un commit que la forge ne connait pas : refus AVANT le brouillon (Gitea creerait le brouillon et casserait a la publication)" {
  FAKE_COMMIT=404 _pub; [ "$status" -ne 0 ]
  [[ "$output" == *"le commit deadbeefcafe n'est pas sur http://forge.test/fleet/lcars"*"commit poussé"* ]]
  [ "$(wc -l < "$TRACE")" -eq 2 ]
  ! grep -q '^POST' "$TRACE"
}

@test "un asset qui échoue : refus qui nomme l'asset, le message de la forge et le BROUILLON à supprimer — pas de publication" {
  FAKE_ASSET_KO=lcars-0.1-abc.tar.gz _pub; [ "$status" -ne 0 ]
  [[ "$output" == *"REFUS (500) sur l'asset lcars-0.1-abc.tar.gz"*"disque plein"*"brouillon (id 42) : à supprimer sur la forge"* ]]
  ! grep -q '^PATCH' "$TRACE" || { echo "publie malgre l'asset KO"; return 1; }
}

@test "sans FP_TOKEN, sans tiroir, sans jq : trois refus nommés, zéro appel" {
  run bash -c "unset FP_TOKEN; . '$LIB'; fp_publish_dist http://forge.test fleet lcars 0.1-abc '$DIST' sha"
  [ "$status" -ne 0 ]; [[ "$output" == *"FP_TOKEN absent"* ]]
  run bash -c ". '$LIB'; fp_publish_dist http://forge.test fleet lcars 0.1-abc '$DIST/absent' sha"
  [ "$status" -ne 0 ]; [[ "$output" == *"le tiroir"*"n'existe pas"* ]]
  [ ! -s "$TRACE" ]
}

_pub_gh() { run bash -c ". '$LIB'; fp_publish_dist https://github.com zurp-embedded LCARS-fleet 0.1-abc '$DIST' deadbeefcafe"; }

@test "GITHUB : le dialecte se lit sur la forge, et lui seul décide" {
  run bash -c ". '$LIB'; fp_dialect https://github.com; fp_dialect https://github.com/; fp_dialect http://10.42.0.118; fp_dialect https://gitea.example.org"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | tr '\n' ' ')" = "github github gitea gitea " ]
}

@test "GITHUB : l'API est api.github.com, et les assets partent sur uploads.github.com" {
  _pub_gh; [ "$status" -eq 0 ]
  rang() { grep -n -- "$1" "$TRACE" | head -1 | cut -d: -f1; }
  local r_tag r_commit r_post
  r_tag="$(rang 'GET https://api.github.com/repos/zurp-embedded/LCARS-fleet/releases/tags/0.1-abc')"
  r_commit="$(rang 'GET https://api.github.com/repos/zurp-embedded/LCARS-fleet/git/commits/deadbeefcafe')"
  r_post="$(rang 'POST https://api.github.com/repos/zurp-embedded/LCARS-fleet/releases ')"
  [ -n "$r_tag" ] && [ -n "$r_commit" ] && [ -n "$r_post" ] \
    || { echo "un des trois appels d'API manque — trace :"; cat "$TRACE"; return 1; }
  [ "$r_tag" -lt "$r_commit" ] && [ "$r_commit" -lt "$r_post" ] \
    || { echo "l'ordre est faux (tag=$r_tag commit=$r_commit post=$r_post) — on sonde le tag, on verifie le commit, PUIS on cree"; cat "$TRACE"; return 1; }
  [ "$(grep -c '^POST https://uploads.github.com/repos/zurp-embedded/LCARS-fleet/releases/42/assets?name=' "$TRACE")" -eq 4 ]
  ! grep -q 'POST https://api.github.com/.*/assets' "$TRACE" \
    || { echo "un asset est parti sur api.github.com : GitHub y rend 422"; return 1; }
  [[ "$(tail -1 "$TRACE")" == "PATCH https://api.github.com/repos/zurp-embedded/LCARS-fleet/releases/42"* ]]
}

@test "GITHUB : l'URL rendue est celle du web, pas celle de l'API" {
  _pub_gh; [ "$status" -eq 0 ]
  [[ "$output" == *"release https://github.com/zurp-embedded/LCARS-fleet/releases/tag/0.1-abc — 4 assets"* ]]
}

@test "un caractere RESERVE dans un nom d'asset part ENCODE — sinon la forge stocke une espace et la porte rend 404" {
  printf 'd' > "$DIST/lcars_0.9.0-20260908.1310+g48fa4a4b_amd64.tar.gz"
  _pub; [ "$status" -eq 0 ]
  grep -qE 'assets\?name=lcars_0\.9\.0-20260908\.1310%2Bg48fa4a4b_amd64\.tar\.gz( |$)' "$TRACE" \
    || { echo "le + n'est pas encode dans ?name= :"; grep 'g48fa4a4b' "$TRACE"; return 1; }
  ! grep -qE 'assets\?name=[^ ]*1310\+g48' "$TRACE" \
    || { echo "un + brut est parti dans une query string"; return 1; }
}

@test "fp_urlenc : le NON-ASCII sort en OCTETS UTF-8, pas en point de code" {
  run bash -c '. '"$LIB"'; printf "%s|%s|%s" "$(fp_urlenc "€")" "$(fp_urlenc "café")" "$(fp_urlenc "日")"'
  [ "$status" -eq 0 ]
  [ "$output" = '%E2%82%AC|caf%C3%A9|%E6%97%A5' ] \
    || { echo "encodage non-ASCII faux : $output (attendu des octets UTF-8, pas un point de code)"; return 1; }
  [[ "$output" != *"%20"* ]] || { echo "une ESPACE est apparue dans un nom encodé : $output"; return 1; }
}

@test "fp_urlenc : ce qui est sur passe tel quel, le reste est percent-encode" {
  run bash -c ". '$LIB'; fp_urlenc 'lcars_0.9.0-1310+g48_amd64.tar.gz'; echo; fp_urlenc 'a~b-c_d.e'; echo; fp_urlenc 'x y:z'"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p <<< "$output")" = 'lcars_0.9.0-1310%2Bg48_amd64.tar.gz' ]
  [ "$(sed -n 2p <<< "$output")" = 'a~b-c_d.e' ]
  [ "$(sed -n 3p <<< "$output")" = 'x%20y%3Az' ]
}

@test "GITHUB : les assets partent en corps BINAIRE avec son Content-Type — un multipart y rend 422" {
  _pub_gh; [ "$status" -eq 0 ]
  [ "$(grep -c 'uploads.github.com.*corps=binaire' "$TRACE")" -eq 4 ]
  [ "$(grep -c 'uploads.github.com.*ctype=application/octet-stream' "$TRACE")" -eq 4 ]
  ! grep -q 'uploads.github.com.*corps=multipart' "$TRACE" \
    || { echo "un asset part en MULTIPART sur uploads.github.com — GitHub y rend 422"; return 1; }
}

@test "GITEA : les assets restent en MULTIPART — le dialecte par défaut n'a pas changé de forme" {
  _pub; [ "$status" -eq 0 ]
  [ "$(grep -c 'forge.test.*assets?name=.*corps=multipart' "$TRACE")" -eq 4 ]
  ! grep -q 'forge.test.*assets?name=.*corps=binaire' "$TRACE" \
    || { echo "un asset part en binaire vers Gitea, qui attend un multipart"; return 1; }
}

@test "fp_dialect reconnaît l'HÔTE, pas une chaîne exacte — chemin, casse, identifiants, port" {
  run bash -c '. '"$LIB"'
    for u in "https://github.com" "https://github.com/o/r" "HTTPS://GITHUB.COM" "https://GitHub.com" \
             "github.com" "https://user@github.com/o/r.git" "https://x:tok@github.com/o/r" \
             "https://github.com//" "https://api.github.com/" "https://github.com:443" \
             "https://github.example.com" "http://10.42.0.118" "https://gitea.example.org/o/r"; do
      printf "%s " "$(fp_dialect "$u")"
    done'
  [ "$status" -eq 0 ]
  [ "$output" = "github github github github github github github github github github gitea gitea gitea " ]
}

@test "GITHUB : un BROUILLON du tag est vu — GET /releases/tags/ ne voit que les publiées" {
  FAKE_DRAFT_TAG=0.1-abc _pub_gh
  [ "$status" -ne 0 ]
  [[ "$output" == *"BROUILLON"* ]]
  [[ "$output" == *"0.1-abc"* ]]
  ! grep -q '^POST' "$TRACE" || { echo "un POST est parti malgre le brouillon existant"; return 1; }
}

@test "GITHUB : une liste de releases injoignable est un REFUS — une garde qui ne mesure pas ne passe pas" {
  FAKE_LIST=500 _pub_gh
  [ "$status" -ne 0 ]
  [[ "$output" == *"chercher un brouillon"* ]]
  ! grep -q '^POST' "$TRACE"
}

@test "GITEA : la sonde de brouillon ne s'y joue pas — GET /releases/tags/ y voit deja les brouillons" {
  _pub; [ "$status" -eq 0 ]
  ! grep -q 'releases?per_page' "$TRACE" \
    || { echo "la sonde github est jouee sur gitea : un appel de plus, pour rien"; return 1; }
}

@test "JETON : un guillemet est un REFUS NOMME, et RIEN ne part sur le reseau" {
  export FP_TOKEN='ab"cd'
  run bash -c ". '$LIB'; fp_curl '$BATS_TEST_TMPDIR/corps' http://forge.test/x"
  [ "$status" -ne 0 ] || { echo "un jeton porteur d un guillemet a ete accepte : l en-tete part tronque"; return 1; }
  [[ "$output" == *"config curl"* ]] || { echo "le refus ne dit pas POURQUOI : $output"; return 1; }
  [[ "$output" != *'ab"cd'* ]] || { echo "le refus a reimprime le jeton"; return 1; }
  [[ "$output" == *"rang 3"* ]] || { echo "le refus ne situe pas le caractere fautif : $output"; return 1; }
  [ ! -s "$TRACE" ] || { echo "curl a ete appele malgre le refus : $(cat "$TRACE")"; return 1; }
}

@test "JETON : un saut de ligne est un REFUS — sinon la suite devient des OPTIONS curl" {
  export FP_TOKEN='abcd
user-agent = "INJECTE"'
  run bash -c ". '$LIB'; fp_curl '$BATS_TEST_TMPDIR/corps' http://forge.test/x"
  [ "$status" -ne 0 ] || { echo "un jeton multiligne a ete accepte : la config curl s injecte"; return 1; }
  [ ! -s "$TRACE" ] || { echo "curl a ete appele malgre le refus"; return 1; }
  [[ "$(cat "$ARGV" 2>/dev/null)" != *INJECTE* ]] || { echo "l option injectee a atteint curl"; return 1; }
}

@test "JETON : les formes REELLES des deux forges passent — le mur ne ferme pas la porte" {
  local t
  for t in dd13a93a814e449b59da3a68a27fdf9c7abd487e \
           ghp_16CharsOfNonsense0123456789ABCDefgh \
           github_pat_11ABCDEFG0abcdefghij_KLMNOPqrstuvwx; do
    FP_TOKEN="$t" run bash -c ". '$LIB'; fp_token_sain"
    [ "$status" -eq 0 ] || { echo "un jeton de forge legitime a ete refuse : ${t:0:8}… — $output"; return 1; }
  done
}

@test "TRANSFERT : le mur porte sur l INACTIVITE, pas sur la duree — 47 Mo sur un lien lent est un succes" {
  _pub; [ "$status" -eq 0 ]
  local a; a="$(cat "$ARGV")"
  [[ "$a" == *"--speed-limit"* && "$a" == *"--speed-time"* ]] \
    || { echo "aucun mur d inactivite dans l argv de curl : $a"; return 1; }
  [[ "$a" == *"--connect-timeout"* ]] || { echo "aucun plafond de CONNEXION : $a"; return 1; }
  [[ "$a" != *"-m 300 "* ]] || { echo "le plafond total est reste a 300 s — il coupe une montee de 47 Mo"; return 1; }
  local n_appels n_filets
  n_appels="$(grep -c . "$ARGV")"; n_filets="$(grep -c -- '-m 1800' "$ARGV")"
  [ "$n_appels" -eq "$n_filets" ] || { echo "$n_filets appels sur $n_appels portent le filet -m"; return 1; }
}
