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
out=""; method=GET; url=""; prev=""; forme=""; ctype=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; -X) method="$a" ;; esac
  # ⚠ LA FORME DU CORPS EST NOTEE, ET ELLE NE L'ETAIT PAS. La divergence GitHub la plus soulignee de
  # `forge-publish.sh` — « uploads.github.com en corps BINAIRE, un multipart y rend 422 » — n'avait
  # aucun temoin : une relecture hostile a remplace `--data-binary` par `-F` et les 16 cas sont
  # restes verts. Une doublure qui ne note que methode et URL ne peut pas mesurer un contrat de corps.
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
  # La liste des releases : c'est LA seule voie qui voit un brouillon sur GitHub. FAKE_DRAFT_TAG
  # nomme le tag d'un brouillon existant ; FAKE_LIST le code de la liste elle-mecircme.
  "GET "*/releases?per_page=*) printf '[%s]' "${FAKE_DRAFT_TAG:+{\"tag_name\":\"$FAKE_DRAFT_TAG\",\"draft\":true\}}" > "$out"; printf '%s' "${FAKE_LIST:-200}" ;;
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
  ARGV="$BATS_TEST_TMPDIR/argv"
  export FAKE_TRACE="$TRACE" FAKE_STDIN="$STDIN" FAKE_ARGV="$ARGV" PATH="$BIN:$PATH" FP_TOKEN="jeton-secret-0123456789"
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
  [[ "$(sed -n 1p "$TRACE")" == "GET http://forge.test/api/v1/repos/fleet/lcars/releases/tags/0.1-abc"* ]]
  [[ "$(sed -n 2p "$TRACE")" == "GET http://forge.test/api/v1/repos/fleet/lcars/git/commits/deadbeefcafe"* ]]
  [[ "$(sed -n 3p "$TRACE")" == "POST http://forge.test/api/v1/repos/fleet/lcars/releases"* ]]
  [ "$(grep -c 'POST http://forge.test/api/v1/repos/fleet/lcars/releases/42/assets?name=' "$TRACE")" -eq 6 ]
  grep -qE 'assets\?name=install\.sh( |$)' "$TRACE"; grep -qE 'assets\?name=lcars_0\.1_amd64\.deb( |$)' "$TRACE"
  [ "$(grep -c 'PUT http://forge.test/api/packages/fleet/debian/pool/resolute/main/upload' "$TRACE")" -eq 2 ]
  [[ "$(tail -1 "$TRACE")" == "PATCH http://forge.test/api/v1/repos/fleet/lcars/releases/42"* ]]
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
  # ⚠ L'ORDRE, PAS LES RANGS. Ce témoin pinnait « ligne 2 = le commit » ; la sonde de brouillon
  # GitHub (témoin plus bas) a inséré un appel avant, et il a rougi pour une raison qui n'était pas
  # la sienne. Un rang de ligne mesure le nombre d'appels d'à côté, pas la propriété visée.
  rang() { grep -n -- "$1" "$TRACE" | head -1 | cut -d: -f1; }
  local r_tag r_commit r_post
  r_tag="$(rang 'GET https://api.github.com/repos/zUrp-Embedded/LCARS-temp/releases/tags/0.1-abc')"
  r_commit="$(rang 'GET https://api.github.com/repos/zUrp-Embedded/LCARS-temp/git/commits/deadbeefcafe')"
  r_post="$(rang 'POST https://api.github.com/repos/zUrp-Embedded/LCARS-temp/releases ')"
  [ -n "$r_tag" ] && [ -n "$r_commit" ] && [ -n "$r_post" ] \
    || { echo "un des trois appels d'API manque — trace :"; cat "$TRACE"; return 1; }
  [ "$r_tag" -lt "$r_commit" ] && [ "$r_commit" -lt "$r_post" ] \
    || { echo "l'ordre est faux (tag=$r_tag commit=$r_commit post=$r_post) — on sonde le tag, on verifie le commit, PUIS on cree"; cat "$TRACE"; return 1; }
  # TOUT le tiroir monte, et par l'hôte d'upload — jamais par api.github.com
  [ "$(grep -c '^POST https://uploads.github.com/repos/zUrp-Embedded/LCARS-temp/releases/42/assets?name=' "$TRACE")" -eq 6 ]
  ! grep -q 'POST https://api.github.com/.*/assets' "$TRACE" \
    || { echo "un asset est parti sur api.github.com : GitHub y rend 422"; return 1; }
  [[ "$(tail -1 "$TRACE")" == "PATCH https://api.github.com/repos/zUrp-Embedded/LCARS-temp/releases/42"* ]]
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
  grep -qE 'assets\?name=lcars_0\.9\.0-20260908\.1310%2Bg48fa4a4b_amd64\.deb( |$)' "$TRACE" \
    || { echo "le + n'est pas encode dans ?name= :"; grep 'g48fa4a4b' "$TRACE"; return 1; }
  ! grep -qE 'assets\?name=[^ ]*1310\+g48' "$TRACE" \
    || { echo "un + brut est parti dans une query string"; return 1; }
}

@test "fp_urlenc : le NON-ASCII sort en OCTETS UTF-8, pas en point de code" {
  # ⚠ SANS `LC_ALL=C` DANS LA FONCTION, ELLE REPRODUIT LE BUG QU'ELLE CORRIGE. En locale UTF-8,
  # `${s:i:1}` rend un CARACTÈRE et `printf '%02X' "'$c"` son point de code : « € » sortait en
  # `%20AC` — une ESPACE suivie du littéral « AC ». C'est la cicatrice `+`→espace, rouverte par le
  # correctif lui-même ; « café » sortait en `caf%E9`, du Latin-1. Trouvé par relecture hostile le
  # 2026-09-08. Ce témoin joue dans la locale du poste : c'est là que le défaut se produit.
  run bash -c '. '"$LIB"'; printf "%s|%s|%s" "$(fp_urlenc "€")" "$(fp_urlenc "café")" "$(fp_urlenc "日")"'
  [ "$status" -eq 0 ]
  [ "$output" = '%E2%82%AC|caf%C3%A9|%E6%97%A5' ] \
    || { echo "encodage non-ASCII faux : $output (attendu des octets UTF-8, pas un point de code)"; return 1; }
  # Et la garde qui NOMME la cause : un « %20 » dans une sortie non-ASCII est une espace inventée.
  [[ "$output" != *"%20"* ]] || { echo "une ESPACE est apparue dans un nom encodé : $output"; return 1; }
}

@test "fp_urlenc : ce qui est sur passe tel quel, le reste est percent-encode" {
  run bash -c ". '$LIB'; fp_urlenc 'lcars_0.9.0-1310+g48_amd64.deb'; echo; fp_urlenc 'a~b-c_d.e'; echo; fp_urlenc 'x y:z'"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p <<< "$output")" = 'lcars_0.9.0-1310%2Bg48_amd64.deb' ]
  [ "$(sed -n 2p <<< "$output")" = 'a~b-c_d.e' ]
  [ "$(sed -n 3p <<< "$output")" = 'x%20y%3Az' ]
}

@test "GITHUB : les assets partent en corps BINAIRE avec son Content-Type — un multipart y rend 422" {
  # ⚠ CE CONTRAT ÉTAIT LE PLUS SOULIGNÉ DE `forge-publish.sh` ET LE SEUL SANS TÉMOIN. Une relecture
  # hostile a remplacé `--data-binary` par `-F` sur la branche github : 16 cas sur 16 sont restés
  # verts. La doublure ne notait que méthode et URL — elle note désormais la forme du corps, et
  # c'est ici qu'on l'exige. Sans ça, la divergence qui justifie tout le dialecte n'est pas mesurée.
  _pub_gh; [ "$status" -eq 0 ]
  [ "$(grep -c 'uploads.github.com.*corps=binaire' "$TRACE")" -eq 6 ]
  [ "$(grep -c 'uploads.github.com.*ctype=application/octet-stream' "$TRACE")" -eq 6 ]
  ! grep -q 'uploads.github.com.*corps=multipart' "$TRACE" \
    || { echo "un asset part en MULTIPART sur uploads.github.com — GitHub y rend 422"; return 1; }
}

@test "GITEA : les assets restent en MULTIPART — le dialecte par défaut n'a pas changé de forme" {
  # La contre-épreuve du témoin ci-dessus : sans elle, il passerait aussi sur un geste qui enverrait
  # TOUT en binaire, y compris à une forge Gitea qui attend un `attachment=@`.
  _pub; [ "$status" -eq 0 ]
  [ "$(grep -c 'forge.test.*assets?name=.*corps=multipart' "$TRACE")" -eq 6 ]
  ! grep -q 'forge.test.*assets?name=.*corps=binaire' "$TRACE" \
    || { echo "un asset part en binaire vers Gitea, qui attend un multipart"; return 1; }
}

@test "fp_dialect reconnaît l'HÔTE, pas une chaîne exacte — chemin, casse, identifiants, port" {
  # ⚠ LA LISTE DE MOTIFS LITTÉRAUX RENDAIT `gitea` SUR `https://github.com/owner/repo`. Un faux
  # négatif n'échoue pas franchement : la publication part sur `https://github.com/api/v1/repos/…`,
  # prend 404 à l'étape 1 (lu « absente, on continue »), puis 404 à l'étape 1b — et le refus accuse
  # LE MAUVAIS OBJET (« le commit n'est pas sur la forge, git push puis rejoue ») sur un commit déjà
  # poussé. `pack.sh:327` dérive la forge d'`origin` : un remote authentifié porte `user@`.
  # Trouvé par relecture hostile le 2026-09-08.
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
  # ⚠ 404 NE VEUT PAS DIRE « RIEN » SUR GITHUB, et c'est le mode de panne NOMINAL du workflow : un
  # envoi coupé laisse un brouillon, et l'en-tête de forge-publish promet qu'un tag existant
  # « brouillon compris » est un refus. Sans la sonde de liste, le rejeu créait un SECOND brouillon,
  # remontait tout, publiait, et laissait un orphelin. Trouvé par relecture hostile le 2026-09-08.
  FAKE_DRAFT_TAG=0.1-abc _pub_gh
  [ "$status" -ne 0 ]
  [[ "$output" == *"BROUILLON"* ]]
  [[ "$output" == *"0.1-abc"* ]]
  # et RIEN n'a été envoyé après la sonde : pas de brouillon créé, pas d'asset
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

# ─── LE JETON EST UNE ENTRÉE, ET `-K -` EST UN FORMAT ────────────────────────────────────────────
#
# Mesuré le 2026-09-08 avec `curl --libcurl`, hors de ce corpus : un jeton portant un `"` fait
# partir un en-tête TRONQUÉ (un préfixe du secret sur le réseau, et un 401 inexplicable) ; un jeton
# portant un saut de ligne fait EXÉCUTER la suite comme des options — `user-agent = "INJECTE"` est
# arrivé jusqu'à `CURLOPT_USERAGENT`. Ces quatre témoins tiennent les deux bords : ce qui est refusé,
# et ce qui doit continuer de passer.

@test "JETON : un guillemet est un REFUS NOMME, et RIEN ne part sur le reseau" {
  export FP_TOKEN='ab"cd'
  run bash -c ". '$LIB'; fp_curl '$BATS_TEST_TMPDIR/corps' http://forge.test/x"
  [ "$status" -ne 0 ] || { echo "un jeton porteur d un guillemet a ete accepte : l en-tete part tronque"; return 1; }
  [[ "$output" == *"config curl"* ]] || { echo "le refus ne dit pas POURQUOI : $output"; return 1; }
  # ⚠ ET IL NE REIMPRIME PAS LE SECRET. Un refus qui recopie le jeton dans le journal du runner
  # transforme une entree malformee en fuite.
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
  # Gitea sert 40 hex ; GitHub sert `ghp_`/`ghs_` + alphanumerique, et `github_pat_` avec des `_`.
  # Un mur qui refuserait l un des trois rendrait la publication impossible sur sa forge.
  local t
  for t in dd13a93a814e449b59da3a68a27fdf9c7abd487e \
           ghp_16CharsOfNonsense0123456789ABCDefgh \
           github_pat_11ABCDEFG0abcdefghij_KLMNOPqrstuvwx; do
    FP_TOKEN="$t" run bash -c ". '$LIB'; fp_token_sain"
    [ "$status" -eq 0 ] || { echo "un jeton de forge legitime a ete refuse : ${t:0:8}… — $output"; return 1; }
  done
}

@test "TRANSFERT : le mur porte sur l INACTIVITE, pas sur la duree — 47 Mo sur un lien lent est un succes" {
  # ⚠ `-m 300` SEUL COUPAIT UNE MONTEE SAINE. Le plus gros asset pese 47 Mo (`lcars-tofu`, mesure du
  # 2026-09-08) : 300 s exigent 1,25 Mbit/s montants soutenus, au-dessus d un lien domestique. Ce
  # qu on veut refuser est un serveur MUET. Le temoin verifie les deux : le mur d inactivite EXISTE,
  # et le plafond total n est plus a 300.
  _pub; [ "$status" -eq 0 ]
  local a; a="$(cat "$ARGV")"
  [[ "$a" == *"--speed-limit"* && "$a" == *"--speed-time"* ]] \
    || { echo "aucun mur d inactivite dans l argv de curl : $a"; return 1; }
  [[ "$a" == *"--connect-timeout"* ]] || { echo "aucun plafond de CONNEXION : $a"; return 1; }
  [[ "$a" != *"-m 300 "* ]] || { echo "le plafond total est reste a 300 s — il coupe une montee de 47 Mo"; return 1; }
  # et le filet large est bien la, sur CHAQUE appel
  local n_appels n_filets
  n_appels="$(grep -c . "$ARGV")"; n_filets="$(grep -c -- '-m 1800' "$ARGV")"
  [ "$n_appels" -eq "$n_filets" ] || { echo "$n_filets appels sur $n_appels portent le filet -m"; return 1; }
}
