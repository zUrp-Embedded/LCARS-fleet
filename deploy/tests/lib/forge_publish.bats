#!/usr/bin/env bats
# SOURCE: deploy/tests/lib/forge_publish.bats
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: PROTO-V2 — forge-publish.sh à blanc : une doublure de curl qui note ce qu'on lui demande
#
# La doublure lit la config `-K -` sur stdin (c'est LÀ que le jeton passe) et note argv ; elle répond
# par route : GET releases/tags → FAKE_TAG (404), POST releases → 201 {"id":42}, POST assets → 201
# (FAKE_ASSET_KO nomme celui qui rend 500), PUT debian → 201 (FAKE_DEB_409 nomme celui qui existe),
# PATCH → 200, GET git/commits → FAKE_COMMIT (200). FAKE_DOWN=1 : curl « ne répond pas » (000 sur stdout comme le vrai, rc 7).

setup() {
  LIB="$BATS_TEST_DIRNAME/../../lib/forge-publish.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; TRACE="$BATS_TEST_TMPDIR/trace"; STDIN="$BATS_TEST_TMPDIR/stdin"
  cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
cat > "${FAKE_STDIN:?}.$$" ; cat "${FAKE_STDIN}.$$" >> "$FAKE_STDIN"; rm -f "${FAKE_STDIN}.$$"
out=""; method=GET; url=""; prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; -X) method="$a" ;; esac
  case "$a" in http*) url="$a" ;; esac; prev="$a"
done
echo "$method $url" >> "${FAKE_TRACE:?}"
[[ "${FAKE_DOWN:-0}" == 1 ]] && { printf 000; exit 7; }   # le vrai curl rend 000 avec -w quand rien ne répond
case "$method $url" in
  "GET "*/releases/tags/*) printf '{"id":7,"draft":%s}' "${FAKE_TAG_DRAFT:-false}" > "$out"; printf '%s' "${FAKE_TAG:-404}" ;;
  "GET "*/git/commits/*) : > "$out"; printf '%s' "${FAKE_COMMIT:-200}" ;;
  "POST "*/releases) printf '{"id":42}' > "$out"; printf 201 ;;
  "POST "*/assets?name=*) n="${url##*name=}"; if [[ "$n" == "${FAKE_ASSET_KO:-}" ]]; then printf '{"message":"disque plein"}' > "$out"; printf 500; else : > "$out"; printf 201; fi ;;
  "PUT "*/debian/pool/*) f=""; prev=""; for a in "$@"; do [[ "$prev" == --upload-file ]] && f="$(basename "$a")"; prev="$a"; done
      if [[ "$f" == "${FAKE_DEB_409:-}" ]]; then printf 409; else : > "$out"; printf 201; fi ;;
  "PATCH "*/releases/*) : > "$out"; printf 200 ;;
  *) printf 599 ;;
esac
SH
  chmod +x "$BIN/curl"
  DIST="$BATS_TEST_TMPDIR/dist/0.1-abc"; mkdir -p "$DIST"
  printf 'x' > "$DIST/lcars-0.1-abc.tar.gz"; echo "aaaa  lcars-0.1-abc.tar.gz" > "$DIST/lcars-0.1-abc.tar.gz.sha256"
  printf 'd' > "$DIST/lcars_0.1_amd64.deb"; printf 'd' > "$DIST/lcars-workstation_0.1_all.deb"
  printf 'p' > "$DIST/install.sh"; echo "bbbb  install.sh" > "$DIST/install.sh.sha256"
  export FAKE_TRACE="$TRACE" FAKE_STDIN="$STDIN" PATH="$BIN:$PATH" FP_TOKEN="jeton-secret-0123456789"
}

_pub() { run bash -c ". '$LIB'; fp_publish_dist http://forge.test/ fleet lcars 0.1-abc '$DIST' deadbeefcafe resolute main"; }

@test "le jeton passe par la config -K - sur stdin, JAMAIS en argv — et chaque appel le porte" {
  _pub; [ "$status" -eq 0 ]
  grep -q 'header = "Authorization: token jeton-secret-0123456789"' "$STDIN"
  ! grep -q 'jeton-secret' "$TRACE" || { echo "le jeton est passe en argv de curl"; return 1; }
  [ "$(grep -c 'Authorization' "$STDIN")" -eq "$(wc -l < "$TRACE")" ]
}

@test "l'ordre du geste : immutabilité, le commit est là, brouillon sur LE commit, tous les assets, les .deb au registre, publication" {
  _pub; [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$TRACE")" = "GET http://forge.test/api/v1/repos/fleet/lcars/releases/tags/0.1-abc" ]
  [ "$(sed -n 2p "$TRACE")" = "GET http://forge.test/api/v1/repos/fleet/lcars/git/commits/deadbeefcafe" ]
  [ "$(sed -n 3p "$TRACE")" = "POST http://forge.test/api/v1/repos/fleet/lcars/releases" ]
  [ "$(grep -c 'POST http://forge.test/api/v1/repos/fleet/lcars/releases/42/assets?name=' "$TRACE")" -eq 6 ]
  grep -q 'assets?name=install.sh$' "$TRACE"; grep -q 'assets?name=lcars_0.1_amd64.deb$' "$TRACE"
  [ "$(grep -c 'PUT http://forge.test/api/packages/fleet/debian/pool/resolute/main/upload' "$TRACE")" -eq 2 ]
  [ "$(tail -1 "$TRACE")" = "PATCH http://forge.test/api/v1/repos/fleet/lcars/releases/42" ]
  # les assets AVANT les .deb, les .deb AVANT la publication
  [ "$(grep -n 'assets?name' "$TRACE" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'debian/pool' "$TRACE" | head -1 | cut -d: -f1)" ]
  [[ "$output" == *"fp: release http://forge.test/fleet/lcars/releases/tag/0.1-abc — 6 assets"* ]]
  [[ "$output" == *"deb [signed-by=/etc/apt/keyrings/lcars-fleet.asc] http://forge.test/api/packages/fleet/debian resolute main"* ]]
}

@test "le brouillon est créé draft:true sur target_commitish = le sha, et le corps porte les sommes du tiroir" {
  # la doublure ne voit pas --data-binary… on le lit dans argv : la trace ne suffit pas, on rejoue curl en le notant
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
  [[ "$(jq -r '.body' <<<"$j")" == *"Source : deadbeefcafe"*"bbbb  install.sh"*"aaaa  lcars-0.1-abc.tar.gz"* ]]  # le glob trie : install.sh avant lcars-
  [ "$(sed -n 2p "$TRACE.json")" = '{"draft":false}' ]
}

@test "IMMUTABILITE : une release du tag qui existe (publiée OU brouillon) = refus nommé, et RIEN n'est envoyé" {
  FAKE_TAG=200 _pub; [ "$status" -ne 0 ]
  [[ "$output" == *"REFUS"*"existe déjà"*"publiée"*"ADR 012"*"supprime-la sur la forge"* ]]
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
  [[ "$output" == *"le commit deadbeefcafe n'est pas sur http://forge.test/fleet/lcars"*"commit POUSSÉ"* ]]
  [ "$(wc -l < "$TRACE")" -eq 2 ]
  ! grep -q '^POST' "$TRACE"
}

@test "un asset qui échoue : refus qui nomme l'asset, le message de la forge et le BROUILLON à supprimer — pas de publication" {
  FAKE_ASSET_KO=lcars_0.1_amd64.deb _pub; [ "$status" -ne 0 ]
  [[ "$output" == *"REFUS (500) sur l'asset lcars_0.1_amd64.deb"*"disque plein"*"BROUILLON (id 42)"* ]]
  ! grep -q '^PATCH' "$TRACE" || { echo "publie malgre l'asset KO"; return 1; }
  ! grep -q 'debian/pool' "$TRACE"
}

@test "un .deb déjà au registre (409) : refus nommé, le brouillon reste, pas de publication" {
  FAKE_DEB_409=lcars-workstation_0.1_all.deb _pub; [ "$status" -ne 0 ]
  [[ "$output" == *"lcars-workstation_0.1_all.deb existe déjà dans le registre Debian de fleet (resolute/main)"*"brouillon (id 42)"* ]]
  ! grep -q '^PATCH' "$TRACE"
}

@test "sans FP_TOKEN, sans tiroir, sans jq : trois refus nommés, zéro appel" {
  run bash -c "unset FP_TOKEN; . '$LIB'; fp_publish_dist http://forge.test fleet lcars 0.1-abc '$DIST' sha resolute"
  [ "$status" -ne 0 ]; [[ "$output" == *"FP_TOKEN absent"* ]]
  run bash -c ". '$LIB'; fp_publish_dist http://forge.test fleet lcars 0.1-abc '$DIST/absent' sha resolute"
  [ "$status" -ne 0 ]; [[ "$output" == *"le tiroir"*"n'existe pas"* ]]
  [ ! -s "$TRACE" ]
}

# ─── LE DIALECTE GITHUB (lot GHCR, 2026-09-08) ──────────────────────────────────────────────────
#
# La forme d'URL de TÉLÉCHARGEMENT est commune aux deux forges — c'est ce que la porte grave. C'est
# l'API de PUBLICATION qui diverge, sur trois points et trois seulement. Ces témoins les tiennent :
# une base différente, un HÔTE À PART pour les assets, et l'absence de registre Debian qu'on DIT au
# lieu de la simuler.

_pub_gh() { run bash -c ". '$LIB'; fp_publish_dist https://github.com zUrp-Embedded LCARS-temp 0.1-abc '$DIST' deadbeefcafe resolute main"; }

@test "GITHUB : le dialecte se lit sur la forge, et lui seul décide" {
  run bash -c ". '$LIB'; fp_dialect https://github.com; fp_dialect https://github.com/; fp_dialect http://10.42.0.118; fp_dialect https://gitea.example.org"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | tr '\n' ' ')" = "github github gitea gitea " ]
}

@test "GITHUB : l'API est api.github.com, et les assets partent sur uploads.github.com" {
  _pub_gh; [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$TRACE")" = "GET https://api.github.com/repos/zUrp-Embedded/LCARS-temp/releases/tags/0.1-abc" ]
  [ "$(sed -n 2p "$TRACE")" = "GET https://api.github.com/repos/zUrp-Embedded/LCARS-temp/git/commits/deadbeefcafe" ]
  [ "$(sed -n 3p "$TRACE")" = "POST https://api.github.com/repos/zUrp-Embedded/LCARS-temp/releases" ]
  # TOUT le tiroir monte, et par l'hôte d'upload — jamais par api.github.com
  [ "$(grep -c '^POST https://uploads.github.com/repos/zUrp-Embedded/LCARS-temp/releases/42/assets?name=' "$TRACE")" -eq 6 ]
  ! grep -q 'POST https://api.github.com/.*/assets' "$TRACE" \
    || { echo "un asset est parti sur api.github.com : GitHub y rend 422"; return 1; }
  [ "$(tail -1 "$TRACE")" = "PATCH https://api.github.com/repos/zUrp-Embedded/LCARS-temp/releases/42" ]
}

@test "GITHUB : aucun registre Debian n'est appelé, et l'absence se DIT" {
  _pub_gh; [ "$status" -eq 0 ]
  ! grep -q 'debian/pool' "$TRACE" || { echo "un PUT est parti vers un registre Debian que GitHub n'a pas"; return 1; }
  [[ "$output" == *"GitHub n'en a pas"* ]]
  [[ "$output" == *"apt install ./lcars_*.deb"* ]]
  # ET AUCUNE LIGNE `deb …` : une source apt pour une forge sans registre rend 404 à qui la copie.
  ! [[ "$output" == *"source apt :"* ]] || { echo "une source apt est annoncee sur une forge qui n'en a pas"; return 1; }
}

@test "GITHUB : l'URL rendue est celle du web, pas celle de l'API" {
  _pub_gh; [ "$status" -eq 0 ]
  [[ "$output" == *"release https://github.com/zUrp-Embedded/LCARS-temp/releases/tag/0.1-abc — 6 assets"* ]]
}

@test "GITEA : le dialecte par défaut n'a rien perdu — registre Debian et source apt sont toujours là" {
  _pub; [ "$status" -eq 0 ]
  [ "$(grep -c 'PUT http://forge.test/api/packages/fleet/debian/pool/resolute/main/upload' "$TRACE")" -eq 2 ]
  [[ "$output" == *"source apt : deb [signed-by=/etc/apt/keyrings/lcars-fleet.asc] http://forge.test/api/packages/fleet/debian resolute main"* ]]
  ! grep -q 'uploads.github.com' "$TRACE"
}

@test "le « + » d'une revision Debian part ENCODE — sinon la forge stocke une espace et la porte rend 404" {
  # ⚠ MESURE DU 2026-09-08, SUR UNE VRAIE PUBLICATION. Les .deb portent `…1310+g48fa4a4b`. Envoye
  # brut dans `?name=`, le serveur decode le `+` en espace et stocke `…1310 g48fa4a4b…`. L'asset
  # monte en 201, tout parait vert — et la porte de la version, qui a le nom AVEC le `+` grave en
  # dur, rend 404 sur son propre paquet. Aucune doublure n'attrape ca : il faut publier puis tirer.
  printf 'd' > "$DIST/lcars_0.9.0-20260908.1310+g48fa4a4b_amd64.deb"
  _pub; [ "$status" -eq 0 ]
  grep -q 'assets?name=lcars_0.9.0-20260908.1310%2Bg48fa4a4b_amd64.deb$' "$TRACE" \
    || { echo "le + n'est pas encode dans ?name= :"; grep 'g48fa4a4b' "$TRACE"; return 1; }
  ! grep -qE 'assets\?name=[^ ]*1310\+g48' "$TRACE" \
    || { echo "un + brut est parti dans une query string"; return 1; }
}

@test "fp_urlenc : ce qui est sur passe tel quel, le reste est percent-encode" {
  run bash -c ". '$LIB'; fp_urlenc 'lcars_0.9.0-1310+g48_amd64.deb'; echo; fp_urlenc 'a~b-c_d.e'; echo; fp_urlenc 'x y:z'"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p <<< "$output")" = 'lcars_0.9.0-1310%2Bg48_amd64.deb' ]
  [ "$(sed -n 2p <<< "$output")" = 'a~b-c_d.e' ]
  [ "$(sed -n 3p <<< "$output")" = 'x%20y%3Az' ]
}
