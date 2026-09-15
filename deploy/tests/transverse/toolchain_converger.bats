#!/usr/bin/env bats
# bats file_tags=integration


# shellcheck disable=SC2016

@test "le repertoire de travail par defaut ne s'ouvre ni dans l'etat tofu ni dans le magasin" {
  local default
  default="$(sed -n 's/^WORK="\${LCARS_TOOLCHAIN_WORK:-\(.*\)}"$/\1/p' "$SUT")"
  [[ -n "$default" ]]
  [[ "$default" != /var/lib/lcars/tofu* ]]
  # Ni sous la racine du magasin : les volumes externes y sont montes, et un voisin non monte
  # promet une persistance qu'il n'a pas.
  [[ "$default" != /var/lib/lcars/* ]]
  # Ni en tmpfs : une racine apt telecharge des centaines de Mo, `/run` est de la RAM.
  [[ "$default" != /run/* ]]
}

load ../refute

setup() {
  SUT="${BATS_TEST_DIRNAME}/../../../runtime/bin/lcars-toolchain-converge"
  TOKENS_DIR="$(env -i PATH="$PATH" bash -c ". '${BATS_TEST_DIRNAME}/../../lib/provision-lib.sh' >/dev/null 2>&1; printf '%s' \"\$PROV_TOKENS_DIR\"")"
  [[ "$TOKENS_DIR" == /* ]] || { echo "la lib ne rend pas de racine de jetons absolue : « $TOKENS_DIR »" >&2; return 1; }
  export LCARS_STORE_ROOT="$BATS_TEST_TMPDIR/store"
  export LCARS_TOOLCHAIN_WORK="$BATS_TEST_TMPDIR/work"
  export LCARS_TOOLCHAIN_LOCK="$BATS_TEST_TMPDIR/lock"
  export FORGE_BASE_URL="http://forge.test"
  # ⚠ AUCUN JETON POSE : le convergeur lit le depot d'ops en ANONYME. Un temoin qui en poserait
  # un ferait passer au vert un script qui en exige encore.
  mkdir -p "$LCARS_STORE_ROOT/state" "$LCARS_TOOLCHAIN_WORK" "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  stub_deps
}

# Les binaires que le script exige — presents et INERTES : ces temoins ne posent pas de paquets.
stub_deps() {
  for b in apt-get dpkg-deb jq; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/$b"
    chmod +x "$BATS_TEST_TMPDIR/bin/$b"
  done
}

: "${STUB_HEAD:=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef}"
stub_head() { STUB_HEAD="$1"; }

stub_forge() { # stub_forge <yaml-base64>
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in *branches/*) echo '{"commit":{"id":"$STUB_HEAD"}}'; exit 0;; esac; done
for a in "\$@"; do case "\$a" in *contents/ops/toolchains.d*) echo '[{"name":"python.yaml","path":"ops/toolchains.d/python.yaml"}]'; exit 0;; esac; done
for a in "\$@"; do case "\$a" in *contents/ops/toolchains.d/python.yaml*) echo '{"content":"$1"}'; exit 0;; esac; done
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  # `jq` doit rendre la tete, le chemin, puis le contenu : on le scripte au meme endroit.
  cat > "$BATS_TEST_TMPDIR/bin/jq" <<EOF
#!/usr/bin/env bash
in=\$(cat)
case "\$*" in
  *commit.id*) [[ "\$in" == *'"commit"'* ]] && echo "$STUB_HEAD" || echo "" ;;
  *endswith*) echo "ops/toolchains.d/python.yaml" ;;
  *.content*) echo "$1" ;;
  *) echo "" ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/jq"
}

@test "usage: un sha absent est un refus, pas un no-op" {
  run "$SUT"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"usage"* ]]
}

@test "REFUS: un sha qui n'est pas hexadecimal" {
  # La ligne de commande est le SEUL argument que ce script recoit de l'exterieur. Un sha libre y
  # serait le premier endroit ou faire entrer autre chose.
  run "$SUT" 'abc; rm -rf /'
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"sha invalide"* ]]
}

@test "REFUS: pas de FORGE_BASE_URL — on ne conclut RIEN sans manifeste" {
  unset FORGE_BASE_URL
  run "$SUT" deadbeef
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"FORGE_BASE_URL"* ]]
}


@test "AUCUN SECRET: ce script n'OUVRE aucun fichier de la racine des jetons" {
  # ⚠ ON MESURE LE CODE, PAS LA PROSE : la cicatrice de ce fichier NOMME le chemin qu'elle a retire,
  # et c'est son metier. Ce qui est interdit est de le LIRE.
  local n
  n="$(sed 's/#.*//' "$SUT" | grep -cE "$TOKENS_DIR" || true)"
  [ "$n" -eq 0 ] || { sed 's/#.*//' "$SUT" | grep -nE "$TOKENS_DIR" >&2; return 1; }
  n="$(sed 's/#.*//' "$SUT" | grep -cE 'TOKEN_FILE' || true)"
  [ "$n" -eq 0 ]
}

@test "AUCUN SECRET: quand un jeton EST fourni, il ne passe pas en argv de curl" {
  local n
  n="$(sed 's/#.*//' "$SUT" | grep -cE '\-H "Authorization' || true)"
  [ "$n" -eq 0 ]
  sed 's/#.*//' "$SUT" | grep -qE 'curl -sS -m 30 -K -'
}

@test "VERROU: une seconde convergence pendant la premiere sort 4 sans rien poser — tenu n'est pas applique" {
  # Un 0 ferait repondre `OK:<sha>` a l'executeur, et le reconciliateur noterait un SHA que la
  # convergence en vol peut encore ne pas appliquer.
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: python\n' | base64 -w0)"
  exec 8>"$LCARS_TOOLCHAIN_LOCK"
  flock -n 8
  run "$SUT" deadbeef
  exec 8>&-
  [[ "$status" -eq 4 ]]
  [[ "$output" == *"tourne déjà"* ]]
  [[ ! -e "$LCARS_STORE_ROOT/state/eco.d/python.applied" ]]
  [[ ! -e "$LCARS_STORE_ROOT/state/egress.d/.applied" ]]
}

@test "IDEMPOTENCE: marqueur au MEME SHA — les verbes MAGASIN sont sautes, APT REJOUE" {
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: python\napt:\n  packages:\n  - python3-venv\n' | base64 -w0)"
  mkdir -p "$LCARS_STORE_ROOT/state/eco.d"
  printf 'deadbeef\n' > "$LCARS_STORE_ROOT/state/eco.d/python.applied"
  # apt-get TEMOIN : enregistre son passage.
  cat > "$BATS_TEST_TMPDIR/bin/apt-get" <<EOS
#!/usr/bin/env bash
touch "$BATS_TEST_TMPDIR/apt-was-called"
exit 0
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/apt-get"

  run "$SUT" deadbeef
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"magasin deja a deadbeef"* ]]
  [[ -e "$BATS_TEST_TMPDIR/apt-was-called" ]]
}

@test "IDEMPOTENCE: marqueur au MEME SHA — l'installeur (verbe magasin) N'EST PAS rejoue" {
  # sha256sum saboteur : si l'installeur tournait, la passe echouerait (rc 3). Elle sort 0 :
  # la preuve que le verbe magasin est saute quand le marqueur est courant.
  cat > "$BATS_TEST_TMPDIR/bin/sha256sum" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/sha256sum"
  local sha; sha="$(printf 'a%.0s' {1..64})"
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: rust\ninstaller:\n  name: rustup\n  sha256: %s\n  url: https://sh.rustup.rs\n  version: "1.27"\n' "$sha" | base64 -w0)"
  mkdir -p "$LCARS_STORE_ROOT/state/eco.d"
  # ⚠ le marqueur porte l'eco du CHEMIN (python.yaml via stub_forge), pas celui du contenu.
  printf 'deadbeef\n' > "$LCARS_STORE_ROOT/state/eco.d/python.applied"

  run "$SUT" deadbeef
  [[ "$status" -eq 0 ]]
}

@test "IDEMPOTENCE: un marqueur d'un AUTRE sha ne fait pas sauter" {
  # Le marqueur porte le SHA qui l'a produit, pas un booleen : un manifeste modifie doit se
  # rejouer, sinon un merge approuve resterait non applique en se croyant fait.
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: python\n' | base64 -w0)"
  mkdir -p "$LCARS_STORE_ROOT/state/eco.d"
  printf 'cafe1234\n' > "$LCARS_STORE_ROOT/state/eco.d/python.applied"

  run "$SUT" deadbeef
  [[ "$output" != *"magasin deja a"* ]]
  [[ "$output" == *"applique a deadbeef"* ]]
}

@test "REFUS: un manifeste dont le kind n'est pas celui du rail" {
  # Un fichier pose a la main dans ops/toolchains.d n'est pas passe par le schema de l'outil MCP.
  # La ceinture est ici, et c'est la derniere.
  stub_forge "$(printf 'kind: autre_chose\necosystem: python\n' | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"kind inattendu"* ]]
}

@test "GRAMMAIRE: la forme REELLE du render (entrees a 4 espaces) — apt recoit les paquets" {
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: python\napt:\n  packages:\n    - python3-yaml\n' | base64 -w0)"
  cat > "$BATS_TEST_TMPDIR/bin/apt-get" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$BATS_TEST_TMPDIR/apt-args"
exit 0
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/apt-get"

  run "$SUT" deadbeef
  [[ "$status" -eq 0 ]]
  grep -qx 'python3-yaml' "$BATS_TEST_TMPDIR/apt-args"
}

@test "GRAMMAIRE: manifeste COMBINE apt+sysroot — la cible ne s'installe JAMAIS sur l'hote" {
  local sr; sr="$BATS_TEST_TMPDIR/keyring.gpg"; : > "$sr"
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: cross\napt:\n  packages:\n    - crossbuild-essential-arm64\nsysroot:\n  arch: arm64\n  keyring: %s\n  sources:\n    - "deb http://deb.debian.org/debian bookworm main"\n  packages:\n    - libssl-dev\n' "$sr" | base64 -w0)"
  cat > "$BATS_TEST_TMPDIR/bin/apt-get" <<EOS
#!/usr/bin/env bash
{ printf '%s\n' "\$@"; echo; } >> "$BATS_TEST_TMPDIR/apt-args"
exit 0
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/apt-get"
  # curl du sysroot : rien a telecharger (print-uris vide via stub apt-get) — on ne teste que le TRI.

  run "$SUT" deadbeef
  [[ "$status" -eq 0 ]]
  grep -qx 'crossbuild-essential-arm64' "$BATS_TEST_TMPDIR/apt-args"
  refute awk 'BEGIN{RS=""} !/Dir::/ && /libssl-dev/ {found=1} END{exit !found}' "$BATS_TEST_TMPDIR/apt-args"
}

@test "EGRESS: les hotes approuves sont poses sur le volume d'etat" {
  # Sans ce verbe, tout le prealable A ouvre un registry que RIEN ne pose : les deux autres sources
  # vivent dans l'image et un rebuild les efface.
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: python\negress_hosts:\n  - pypi.org\n  - files.pythonhosted.org\n' | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$status" -eq 0 ]]
  [[ -r "$LCARS_STORE_ROOT/state/egress.d/engineer.hosts" ]]
  grep -q '^pypi.org$' "$LCARS_STORE_ROOT/state/egress.d/engineer.hosts"
  grep -q '^files.pythonhosted.org$' "$LCARS_STORE_ROOT/state/egress.d/engineer.hosts"
}

@test "EGRESS: le marqueur .applied est pose MEME SANS egress_hosts — le silence nominal est estampille" {
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: python\n' | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$LCARS_STORE_ROOT/state/egress.d/.applied")" == "deadbeef" ]]
}

@test "EGRESS: une passe en ECHEC ne pose PAS le marqueur — estampiller mentirait" {
  cat > "$BATS_TEST_TMPDIR/bin/sha256sum" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/sha256sum"
  local sha; sha="$(printf 'a%.0s' {1..64})"
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: rust\ninstaller:\n  name: rustup\n  sha256: %s\n  url: https://sh.rustup.rs\n  version: "1.27"\n' "$sha" | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$status" -eq 3 ]]
  [[ ! -r "$LCARS_STORE_ROOT/state/egress.d/.applied" ]]
}

@test "EGRESS: le marqueur .applied porte le SHA — c'est lui qui distingue le silence nominal" {
  # Sans marqueur, « aucun hote » recouvre quatre etats dont trois sont des pannes : convergeur
  # jamais passe, volume non monte, volume purge. Tous rendent le meme rien.
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: python\negress_hosts:\n  - pypi.org\n' | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$(cat "$LCARS_STORE_ROOT/state/egress.d/.applied")" == "deadbeef" ]]
}

@test "EGRESS: REFUS d'un hote qui n'est pas un nom d'hote" {
  # Le proxy ne decide que du HOTE d'un CONNECT : un schema ou un chemin ici serait une declaration
  # qui ne veut rien dire, posee comme si elle en voulait une.
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: python\negress_hosts:\n  - "https://pypi.org/simple"\n' | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"hote refuse"* ]]
}

@test "INSTALLER: sha256 qui ne correspond pas — RIEN n'est execute, et c'est un echec d'APPLICATION" {
  cat > "$BATS_TEST_TMPDIR/bin/sha256sum" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/sha256sum"
  local sha; sha="$(printf 'a%.0s' {1..64})"
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: rust\ninstaller:\n  name: rustup\n  sha256: %s\n  url: https://sh.rustup.rs\n  version: "1.27"\n' "$sha" | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$status" -eq 3 ]]
  [[ "$output" == *"NE CORRESPOND PAS"* ]]
  # Le marqueur n'est PAS pose : rien ne fera croire au prochain tick que c'est fait.
  [[ ! -r "$LCARS_STORE_ROOT/state/eco.d/python.applied" ]]
}

@test "INSTALLER: REFUS d'une url non-https" {
  local sha; sha="$(printf 'a%.0s' {1..64})"
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: rust\ninstaller:\n  name: rustup\n  sha256: %s\n  url: http://sh.rustup.rs\n  version: "1.27"\n' "$sha" | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"https requis"* ]]
}

@test "le marqueur n'est pose QU'APRES un succes" {
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: python\n' | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$status" -eq 0 ]]
  [[ -r "$LCARS_STORE_ROOT/state/eco.d/python.applied" ]]
  [[ "$(cat "$LCARS_STORE_ROOT/state/eco.d/python.applied")" == "deadbeef" ]]
}

@test "RC 2 vs RC 3: un delta HORS MAGASIN (freeze_env) sort en 2 — document faux, pas retryable" {
  local sha; sha="$(printf 'a%.0s' {1..64})"
  local B64; B64="$(printf 'kind: ecosystem_enable\necosystem: rust\ninstaller:\n  name: rustup\n  sha256: %s\n  url: https://sh.rustup.rs\n  version: "1.27"\n  env_script: env.sh\n' "$sha" | base64 -w0)"
  stub_forge "$B64"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/sha256sum"; chmod +x "$BATS_TEST_TMPDIR/bin/sha256sum"

  # Le faux installeur : il pose l'env_script, qui exporte un chemin HORS magasin.
  cat > "$BATS_TEST_TMPDIR/fake-installer.sh" <<'EOS'
#!/bin/sh
cat > env.sh <<'EOF2'
export EVIL_TOOL_HOME=/usr/lib/evil
EOF2
exit 0
EOS

  # curl : les DEUX roles — servir la forge (delegue aux reponses de stub_forge via fichiers) et
  # « telecharger » l'installeur (-o <fichier>).
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<EOS
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  if [[ "\$prev" == "-o" ]]; then cp "$BATS_TEST_TMPDIR/fake-installer.sh" "\$a"; exit 0; fi
  prev="\$a"
  case "\$a" in
    *branches/*) echo '{"commit":{"id":"'"$STUB_HEAD"'"}}'; exit 0;;
    *contents/ops/toolchains.d/python.yaml*) echo '{"content":"$B64"}'; exit 0;;
    *contents/ops/toolchains.d*) echo '[{"name":"python.yaml","path":"ops/toolchains.d/python.yaml"}]'; exit 0;;
  esac
done
exit 0
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"

  run "$SUT" deadbeef
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"REFUSE en application"* ]]
  [[ ! -e "$LCARS_STORE_ROOT/state/env.d/python.env" ]]
}


@test "GARDE: un sha qui n'est PAS la tete de la branche protegee est REFUSE" {
  stub_head "cafe1234cafe1234cafe1234cafe1234cafe1234"
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: python\napt:\n    packages:\n    - jq\n' | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"n'est PAS la tete"* ]]
  [[ "$output" == *"tool_request"* ]]
  # La tete REELLE est nommee : sans elle, l'operateur ne sait pas contre quoi il a ete compare.
  [[ "$output" == *"cafe1234cafe1234cafe1234cafe1234cafe1234"* ]]
}

@test "GARDE: une forge MUETTE sur la tete fait REFUSER — un garde qui s'efface ne garde rien" {
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  run "$SUT" deadbeef
  # 4 et pas 1 : une forge muette est un echec passager, pas un appel mal forme.
  [[ "$status" -eq 4 ]]
  [[ "$output" == *"tête de"* ]]
  [[ "$output" == *"introuvable"* ]]
}

@test "GARDE: un sha ABREGE qui prefixe la tete passe — la comparaison porte sur sa longueur" {
  # Le reconciliateur passe un sha complet, mais le contrat d'entree accepte 7-40 hex depuis
  # toujours. Comparer les chaines entieres refuserait un appel legitime abrege.
  stub_head "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: python\napt:\n    packages:\n    - jq\n' | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$output" != *"n'est PAS la tete"* ]]
}

@test "GARDE: la branche est un LITTERAL GELE — une borne ne se regle pas" {
  grep -qx 'BRANCH="tool_request"' "$SUT"
  refute grep -qE '\$\{[A-Za-z_]*BRANCH[A-Za-z_]*[}:]' "$SUT"
  # Et l'autorite dit bien ce nom-la : sans cette ligne, le temoin epinglerait un litteral que le
  # runtime aurait pu changer sans lui.
  grep -q 'def branch, do: "tool_request"' "$BATS_TEST_DIRNAME/../../../runtime/lib/fleet/toolchain.ex"
}

# Une forge en erreur, telle que `curl` la rend : avec `-f`, rien sur stdout et le code 22 ; sans
# `-f`, le corps d'erreur JSON et le code 0. `jq` suit sa semantique reelle sur ce corps : `.content`
# absent rend `null`, et `-e` en fait un code 1.
stub_forge_en_erreur() { # stub_forge_en_erreur <motif d'url en erreur> <yaml-base64 des autres>
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<EOF
#!/usr/bin/env bash
fail=0
for a in "\$@"; do case "\$a" in --fail) fail=1;; --*|http*) ;; -*f*) fail=1;; esac; done
for a in "\$@"; do
  case "\$a" in
    $1)
      if [[ "\$fail" -eq 1 ]]; then echo "curl: (22) The requested URL returned error: 500" >&2; exit 22; fi
      echo '{"message":"Internal Server Error"}'; exit 0;;
  esac
done
for a in "\$@"; do case "\$a" in *branches/*) echo '{"commit":{"id":"$STUB_HEAD"}}'; exit 0;; esac; done
for a in "\$@"; do case "\$a" in *contents/ops/toolchains.d/python.yaml*) echo '{"content":"$2"}'; exit 0;; esac; done
for a in "\$@"; do case "\$a" in *contents/ops/toolchains.d*) echo '[{"name":"python.yaml","path":"ops/toolchains.d/python.yaml"}]'; exit 0;; esac; done
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  cat > "$BATS_TEST_TMPDIR/bin/jq" <<'EOF'
#!/usr/bin/env bash
in=$(cat)
e=0
for a in "$@"; do case "$a" in -e|-er|-re) e=1;; esac; done
case "$*" in
  *commit.id*) if [[ "$in" == *'"commit"'* ]]; then sed 's/.*"id":"\([^"]*\)".*/\1/' <<<"$in"; fi ;;
  *endswith*)
    if [[ "$in" == '['* ]]; then
      echo "ops/toolchains.d/python.yaml"
    elif [[ "$*" == *'error('* ]]; then
      echo "jq: error (at <stdin>:1): pas une liste" >&2
      exit 5
    fi ;;
  *.content*)
    if [[ "$in" == *'"content"'* ]]; then
      sed 's/.*"content":"\([^"]*\)".*/\1/' <<<"$in"
    else
      echo null
      if [[ "$e" -eq 1 ]]; then exit 1; fi
    fi ;;
esac
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/jq"
}

@test "FORGE: une erreur sur le CONTENU d'un manifeste sort en 4, jamais en 2 — une panne ne gele pas la tete" {
  # En 2, le reconciliateur gele la tete jusqu'au merge suivant : une forge qui hoquette une fois
  # bloquerait un manifeste juste. Sans `-f` ni `-e`, le `null` du corps d'erreur passait par
  # `base64 -d` et devenait « kind inattendu ».
  stub_forge_en_erreur '*contents/ops/toolchains.d/python.yaml*' \
    "$(printf 'kind: ecosystem_enable\necosystem: python\n' | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$status" -eq 4 ]]
  [[ "$output" == *"illisible"* ]]
  printf '%s\n' "$output" | refute_out 'kind inattendu'
  [[ ! -e "$LCARS_STORE_ROOT/state/eco.d/python.applied" ]]
  [[ ! -e "$LCARS_STORE_ROOT/state/egress.d/.applied" ]]
}

@test "FORGE: un contenu qui n'est pas du base64 sort en 4 — illisible n'est pas refuse" {
  stub_forge '@@@ pas du base64 @@@'
  run "$SUT" deadbeef
  [[ "$status" -eq 4 ]]
  [[ "$output" == *"illisible"* ]]
  [[ ! -e "$LCARS_STORE_ROOT/state/eco.d/python.applied" ]]
}

@test "FORGE: une erreur sur la LISTE des manifestes sort en 4 — illisible n'est pas vide" {
  # Lue comme vide, la liste faisait sortir 0 et estampiller `.applied` : le SHA etait note sans
  # qu'un seul manifeste ait ete lu.
  stub_forge_en_erreur '*contents/ops/toolchains.d\?ref=*' \
    "$(printf 'kind: ecosystem_enable\necosystem: python\n' | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$status" -eq 4 ]]
  [[ "$output" == *"liste des manifestes illisible"* ]]
  [[ ! -e "$LCARS_STORE_ROOT/state/egress.d/.applied" ]]
}

@test "APPLICATION: un apt-get en echec (100) fait echouer la passe en 3, sans aucun marqueur" {
  # Le sous-shell d'application etait en condition d'un `if` : bash y ignore `set -e`, la passe
  # continuait apres l'echec et posait les marqueurs. L'executeur repondait `OK:<sha>`.
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: python\napt:\n  packages:\n    - python3-yaml\negress_hosts:\n  - pypi.org\n' | base64 -w0)"
  cat > "$BATS_TEST_TMPDIR/bin/apt-get" <<'EOS'
#!/usr/bin/env bash
echo "E: Unable to locate package python3-yaml" >&2
exit 100
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/apt-get"
  run "$SUT" deadbeef
  [[ "$status" -eq 3 ]]
  [[ "$output" == *"A ECHOUE"* ]]
  printf '%s\n' "$output" | refute_out 'applique a deadbeef'
  # La suite de la passe ne s'est pas jouee : l'egress, qui vient apres apt, n'est pas pose.
  [[ ! -e "$LCARS_STORE_ROOT/state/egress.d/engineer.hosts" ]]
  [[ ! -e "$LCARS_STORE_ROOT/state/eco.d/python.applied" ]]
  [[ ! -e "$LCARS_STORE_ROOT/state/egress.d/.applied" ]]
}

@test "SYSROOT: un keyring DECLARE mais absent de l'hote sort en 1 — un fichier a poser n'est pas un document faux" {
  # En 2, la tete resterait gelee apres que l'operateur a pose le fichier : seul un merge sans objet
  # la degelerait.
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: cross\nsysroot:\n  arch: arm64\n  keyring: %s\n  sources:\n    - "deb http://deb.debian.org/debian bookworm main"\n  packages:\n    - libssl-dev\n' "$BATS_TEST_TMPDIR/absent.gpg" | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"keyring de la cible absent ou illisible sur l'hôte"* ]]
  [[ ! -e "$LCARS_STORE_ROOT/state/egress.d/.applied" ]]
}

@test "SYSROOT: un keyring NON DECLARE reste un manifeste refuse (2)" {
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: cross\nsysroot:\n  arch: arm64\n  sources:\n    - "deb http://deb.debian.org/debian bookworm main"\n  packages:\n    - libssl-dev\n' | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"non declare"* ]]
}

# ─── LA FORGE EN HTTP, TELLE QUE `curl` LA REND, ET LE VRAI `jq` ─────────────────────────────────
#
# La doublure suit la semantique de curl sur les options que le convergeur passe : `-f` supprime le
# corps d'une reponse >= 400 et rend 22 en disant le code sur stderr ; sans `-f`, le corps sort et
# le code est 0 ; `-w` ecrit son format (`%{stderr}` bascule sur stderr, `%{http_code}` rend le code)
# dans les deux cas ; `-K -` consomme stdin. Les routes sont une table « motif<TAB>code<TAB>corps ».
# `jq` est le VRAI : un corps HTML ou un message d'erreur JSON y rencontre sa semantique reelle, et
# aucun temoin ne decide sur le texte d'un filtre.
stub_forge_http() { # stub_forge_http <fichier de routes>
  rm -f "$BATS_TEST_TMPDIR/bin/jq"
  command -v jq >/dev/null || skip "jq absent de la machine : ces temoins exigent le vrai"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<EOF
#!/usr/bin/env bash
fail=0 fmt="" url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -f|--fail) fail=1 ;;
    -w) fmt="\$2"; shift ;;
    -K) [[ "\$2" == - ]] && cat >/dev/null; shift ;;
    -m) shift ;;
    http*) url="\$1" ;;
  esac
  shift
done
code=404 body='<!DOCTYPE html><html><body>404 Not Found</body></html>'
while IFS=\$'\t' read -r motif c b; do
  if [[ "\$url" == \$motif ]]; then code="\$c"; body="\$b"; break; fi
done < '$1'
ecrire_format() {
  [[ -n "\$fmt" ]] || return 0
  local out="\${fmt//%\{http_code\}/\$code}"
  if [[ "\$out" == *'%{stderr}'* ]]; then printf '%b' "\${out//%\{stderr\}/}" >&2; else printf '%b' "\$out"; fi
}
if [[ "\$code" -ge 400 && "\$fail" -eq 1 ]]; then
  echo "curl: (22) The requested URL returned error: \$code" >&2
  ecrire_format
  exit 22
fi
printf '%s\n' "\$body"
ecrire_format
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
}

routes() { # routes <motif|code|corps>… -> le chemin du fichier de routes
  local f="$BATS_TEST_TMPDIR/routes" l
  : > "$f"
  for l in "$@"; do printf '%s\n' "$l" | tr '|' '\t' >> "$f"; done
  printf '%s' "$f"
}

TETE='*/branches/tool_request|200|{"commit":{"id":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}}'

@test "LISTE: ops/toolchains.d absent au SHA (404 HTML) — liste vide, sortie 0, SHA note" {
  # Le dernier manifeste et son `.gitkeep` retires : il ne reste rien a appliquer, et une sortie 4
  # a chaque tick ne noterait jamais ce SHA. Sans `-f`, le corps HTML part dans `jq` et sort en 4.
  stub_forge_http "$(routes "$TETE" '*/contents/ops/toolchains.d\?ref=*|404|<!DOCTYPE html><html><body>404 Not Found</body></html>')"
  run "$SUT" deadbeef
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"aucun dossier ops/toolchains.d sur fleet/lcars au sha deadbeef — aucun manifeste à appliquer"* ]]
  [[ "$(cat "$LCARS_STORE_ROOT/state/egress.d/.applied")" == "deadbeef" ]]
  printf '%s\n' "$output" | refute_out 'parse error|illisible'
}

@test "JETON: un 401 sur la tete sort en 1 et nomme FORGE_TOKEN — un refus n'est pas une panne passagere" {
  # Sans `-f`, le message d'erreur JSON part dans `jq`, la tete est vide, et la sortie est 4.
  export FORGE_TOKEN=jeton-refuse
  stub_forge_http "$(routes '*/branches/tool_request|401|{"message":"user does not exist [uid: 0, name: ]"}')"
  run "$SUT" deadbeef
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"la forge refuse le jeton du convergeur (HTTP 401) en lisant la tête de « tool_request » sur fleet/lcars — rien n'est appliqué. FORGE_TOKEN est invalide ou ne donne pas la lecture de ce dépôt"* ]]
  printf '%s\n' "$output" | refute_out 'jeton-refuse'
  [[ ! -e "$LCARS_STORE_ROOT/state/egress.d/.applied" ]]
}

@test "JETON: un 403 anonyme sur la liste sort en 1 et dit que FORGE_TOKEN manque" {
  stub_forge_http "$(routes "$TETE" '*/contents/ops/toolchains.d\?ref=*|403|{"message":"forbidden"}')"
  run "$SUT" deadbeef
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"la forge refuse la lecture anonyme (HTTP 403) de la liste des manifestes sur fleet/lcars"*"poser FORGE_TOKEN"* ]]
  [[ ! -e "$LCARS_STORE_ROOT/state/egress.d/.applied" ]]
}

@test "LISTE: une autre erreur de lecture (500) garde 4 — ni vide ni refus" {
  stub_forge_http "$(routes "$TETE" '*/contents/ops/toolchains.d\?ref=*|500|<html>500</html>')"
  run "$SUT" deadbeef
  [[ "$status" -eq 4 ]]
  [[ "$output" == *"liste des manifestes illisible"* ]]
  [[ ! -e "$LCARS_STORE_ROOT/state/egress.d/.applied" ]]
}

@test "LISTE: un corps 200 qui n'est pas une liste garde 4" {
  stub_forge_http "$(routes "$TETE" '*/contents/ops/toolchains.d\?ref=*|200|{"message":"pas une liste"}')"
  run "$SUT" deadbeef
  [[ "$status" -eq 4 ]]
  [[ "$output" == *"liste des manifestes illisible"* ]]
  [[ ! -e "$LCARS_STORE_ROOT/state/egress.d/.applied" ]]
}
