#!/usr/bin/env bats
#
# LE SEUL GESTE PRIVILEGIE DU RAIL, et ce que ces temoins defendent tient en une phrase : ce script
# ne doit RIEN interpreter. Son entree est un manifeste qu'un humain a signe ; sa sortie est
# l'application EXACTE de ce document, ou un refus bruyant.
#
# Trois familles de cas :
#   - les REFUS (un manifeste qui ne peut pas venir du rail ne s'applique pas) ;
#   - le VERROU (deux convergences concurrentes se battraient sur /var/lib/dpkg/lock) ;
#   - l'IDEMPOTENCE par le SHA (rejouer ne refait rien, et un echec ne pose pas de marqueur).
#
# La forge est simulee par un `curl` en tete de PATH. Ce qui est mesure est la DECISION, jamais le
# reseau.

# ⚠ LE DEFAUT DE `LCARS_TOOLCHAIN_WORK` N'EST EXERCE PAR AUCUN AUTRE TEMOIN DE CE FICHIER : le
# `setup` le surcharge vers le tmpdir, comme il faut — un temoin qui poserait un aptroot au chemin
# de production serait un temoin qui provisionne la machine. Le prix de cette surcharge est qu'un
# defaut faux passe INVISIBLE ici, et il l'a ete : il pointait dans l'etat tofu. Le temoin qui suit
# est le seul a regarder la valeur elle-meme.

@test "le repertoire de travail par defaut ne s'ouvre ni dans l'etat tofu ni dans le magasin" {
  local default
  default="$(sed -n 's/^WORK="\${LCARS_TOOLCHAIN_WORK:-\(.*\)}"$/\1/p' "$SUT")"
  [[ -n "$default" ]]
  # `/var/lib/lcars/tofu` porte l'etat terraform des catalogues, mot de passe de seed compris. Son
  # mode et son proprietaire vivent dans `deploy/system.manifest`, pas ici : ce qui se verifie
  # ci-dessous est qu'un arbre `rm -rf` a chaque passe ne s'imbrique pas dans l'etat sensible d'un
  # autre proprietaire.
  [[ "$default" != /var/lib/lcars/tofu* ]]
  # Ni sous la racine du magasin : les volumes externes y sont montes, et un voisin non monte
  # promet une persistance qu'il n'a pas.
  [[ "$default" != /var/lib/lcars/* ]]
  # Ni en tmpfs : une racine apt telecharge des centaines de Mo, `/run` est de la RAM.
  [[ "$default" != /run/* ]]
}

setup() {
  SUT="${BATS_TEST_DIRNAME}/../../services/toolchain-converger.sh"
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

# `curl` rend la liste des manifestes puis leur contenu, selon l'URL demandee.
#
# ⚠ ET LA TETE DE LA BRANCHE PROTEGEE, parce que le convergeur la DEMANDE AVANT TOUT. Un decor qui
# ne la sert pas fait refuser toutes les passes nominales — c'est le comportement voulu du garde,
# et c'est pourquoi le defaut du decor decrit une forge SAINE dont la tete vaut le sha des temoins.
# Les temoins qui veulent une tete AUTRE la posent eux-memes via `stub_head`.
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

# ─── AUCUN SECRET DANS LE PROCESS LE PLUS PRIVILEGIE ────────────────────────────────────────────
#
# ⚠ CE TEMOIN GARDAIT UNE EXIGENCE QUI EST DEVENUE SON CONTRAIRE. Il epinglait « pas de jeton
# lisible -> refus ». Or ce script porte le SEUL geste root de la machine, et la regle qui donne sa
# forme au rail est que celui qui a le PRIVILEGE ne DETIENT aucun secret. Exiger un jeton, c'etait
# exiger que le process le plus privilegie en tienne un — donc qu'un defaut chez lui puisse
# escalader ce qu'il vole.
#
# Le depot d'ops est PUBLIC par construction — mesure du 2026-08-25 sur forge vivante :
# `/repos/fleet/lcars/branches/tool_request` et `/contents/ops` repondent 200 SANS aucun en-tete
# d'autorisation. La lecture part donc en anonyme, et ce temoin garde la propriete INVERSE.

@test "AUCUN SECRET: ce script n'OUVRE aucun fichier de /home/private" {
  # ⚠ ON MESURE LE CODE, PAS LA PROSE : la cicatrice de ce fichier NOMME le chemin qu'elle a retire,
  # et c'est son metier. Ce qui est interdit est de le LIRE.
  local n
  n="$(sed 's/#.*//' "$SUT" | grep -cE '/home/private' || true)"
  [ "$n" -eq 0 ] || { sed 's/#.*//' "$SUT" | grep -nE '/home/private' >&2; return 1; }
  n="$(sed 's/#.*//' "$SUT" | grep -cE 'TOKEN_FILE' || true)"
  [ "$n" -eq 0 ]
}

@test "AUCUN SECRET: quand un jeton EST fourni, il ne passe pas en argv de curl" {
  # La contrepartie du precedent. `FORGE_TOKEN` reste accepte pour une boite dont la forge exige une
  # session en lecture — mais un en-tete construit en `-H` se lit dans `/proc/<pid>/cmdline`, par
  # tout le monde, pendant toute la duree de l'appel, dans le process le plus privilegie qui soit.
  local n
  n="$(sed 's/#.*//' "$SUT" | grep -cE '\-H "Authorization' || true)"
  [ "$n" -eq 0 ]
  sed 's/#.*//' "$SUT" | grep -qE 'curl -sS -m 30 -K -'
}

@test "VERROU: une seconde convergence pendant la premiere sort 0 sans rien faire" {
  # `apt-get` n'est PAS reentrant : deux processus root en parallele se battent sur
  # /var/lib/dpkg/lock et l'un des deux meurt en laissant dpkg a moitie configure. Sortir 0 est
  # correct — il n'y a rien a faire, ce n'est pas un echec — et le dire l'est aussi.
  exec 8>"$LCARS_TOOLCHAIN_LOCK"
  flock -n 8
  run "$SUT" deadbeef
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"tourne deja"* ]]
  exec 8>&-
}

@test "IDEMPOTENCE: marqueur au MEME SHA — les verbes MAGASIN sont sautes, APT REJOUE" {
  # LE CAS DU REBUILD : le marqueur (magasin, volume externe) survit au conteneur, /usr non. Une
  # v1 sautait le manifeste ENTIER sur marqueur courant — apres rebuild, la boite se disait
  # convergee avec un /usr nu. Deux temoins en un : apt est INVOQUE malgre le marqueur courant,
  # et l'installeur (verbe magasin) ne l'est PAS.
  # ⚠ l'eco vient du CHEMIN servi par stub_forge (python.yaml), et list_under attend des entrees
  # indentees a DEUX espaces (`  - `).
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
  # Le temoin qui a paye : une v1 de list_under exigeait `^  - ` pendant que le render emet a 4
  # espaces — apply_apt lisait ZERO paquet sur un manifeste reellement rendu, en silence, et
  # chaque cote etait vert avec ses propres fixtures. Cette fixture est la forme du RENDER.
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
  # Le cas cross legitime : apt.packages = paquets HOTE, sysroot.packages = paquets CIBLE. Sans le
  # scope par bloc (block_under), `  packages` aspirait les deux et apt installait la cible sur
  # l'hote. Piege latent depuis la v1, mesure en reparant la grammaire.
  local sr; sr="$BATS_TEST_TMPDIR/keyring.gpg"; : > "$sr"
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: cross\napt:\n  packages:\n    - crossbuild-essential-arm64\nsysroot:\n  arch: arm64\n  keyring: %s\n  sources:\n    - "deb http://deb.debian.org/debian bookworm main"\n  packages:\n    - libssl-dev\n' "$sr" | base64 -w0)"
  # UNE LIGNE VIDE entre les invocations : c'est elle qui fait de chaque appel un paragraphe
  # (RS="") — sans elle le fichier est UN bloc et le temoin serait creux (le Dir:: du sysroot
  # couvrirait un libssl-dev arrive dans l'appel hote).
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
  # La preuve du tri — nuance : le sysroot appelle AUSSI apt-get (racine privee, `-o Dir::Etc`).
  # Ce qui est interdit est libssl-dev dans un appel SANS `Dir::` (l'appel HOTE) : on refuse tout
  # PARAGRAPHE (= une invocation, separee par la ligne vide du stub) hote portant le paquet cible.
  ! awk 'BEGIN{RS=""} !/Dir::/ && /libssl-dev/ {found=1} END{exit !found}' "$BATS_TEST_TMPDIR/apt-args"
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
  # Une v1 posait le marqueur dans apply_egress : une boite qui n'a jamais rien ouvert (le cas
  # NOMINAL) ne l'avait donc jamais, et « aucun hote » recouvrait de nouveau les pannes que le
  # marqueur separe. Ce temoin epingle : convergence verte SANS hotes => marqueur pose quand meme.
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
  # Un telechargement coupe produit un script TRONQUE que `sh` executerait quand meme, et l'etat
  # partiel passerait ensuite pour « deja fait ».
  #
  # EXIT 3 ET PAS 2, ET LA NUANCE EST LE SUJET : le manifeste est BIEN FORME — c'est l'artefact qui
  # ne correspond pas. Un pin perime et un telechargement corrompu se ressemblent ici, et l'un des
  # deux se repare tout seul au tick suivant. Un `2` dirait « ce document ne marchera jamais », ce
  # qui est faux et ferait attendre une correction humaine qui n'a pas lieu d'etre.
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
  # Le refus nait pendant l'EXECUTION (invisible a validate_manifest) : l'env_script pose un chemin
  # hors magasin. Une v1 le laissait mourir dans le sous-shell du pipe : freeze_env CONTINUAIT
  # (env.d tronque possible) et le rc sortait en 3 « retryable » — le rail rebouclait toutes les
  # 60 s en RE-TELECHARGEANT l'installeur. Deux proprietes : rc=2, et AUCUN env.d pose.
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

# ─── LE SHA EST BORNE A LA BRANCHE PROTEGEE ─────────────────────────────────────────────────────
#
# ⚠ MESURE DU 2026-08-24, CHAINE COMPLETE. `45-sudoers-toolchain` accorde
# `%fleet ALL=(root) NOPASSWD:` sur ce binaire ; le controle de `$1` ne portait que la FORME
# hexadecimale ; le manifeste etait ensuite lu `?ref=$SHA` et ses paquets installes EN ROOT. Or le
# rail existe pour que des pods ouvrent des PR vers `tool_request` : des commits NON SIGNES vivent
# dans ce depot PAR CONCEPTION. Et `fleet` n'est pas l'operateur — `human-converger.sh` y verse
# toute la team `humans` de la forge, toutes les 30 s.
#
# Ces temoins tiennent le garde. Sans eux, il se retire au premier refactor qui trouve l'appel
# reseau couteux.

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
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"tete de"* ]]
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
  # ⚠ CE TEMOIN A CONSACRE UN DEFAUT. Sa premiere forme exigeait
  # `LCARS_TOOLCHAIN_BRANCH:-tool_request` : elle rendait la borne REGLABLE et le verifiait, donc
  # elle aurait empeche de la geler. Un temoin qui epingle l'implementation qu'on vient d'ecrire ne
  # mesure rien — il fige.
  #
  # Ce qui se tient : `Fleet.Toolchain.branch/0` gele le nom, chaque lecteur shell en porte la COPIE,
  # et AUCUN ne la derive d'une expansion. Le contrat `toolchain.branch_single_source` le dit dans
  # sa remediation : « a name half of the rail can retune is a rail that splits in silence ».
  # Ici ce n'est meme pas un nom de confort : c'est ce qui empeche d'installer en root un manifeste
  # que personne n'a signe.
  grep -qx 'BRANCH="tool_request"' "$SUT"
  ! grep -qE '\$\{[A-Za-z_]*BRANCH[A-Za-z_]*[}:]' "$SUT"
  # Et l'autorite dit bien ce nom-la : sans cette ligne, le temoin epinglerait un litteral que le
  # runtime aurait pu changer sans lui.
  grep -q 'def branch, do: "tool_request"' "$BATS_TEST_DIRNAME/../../lib/fleet/toolchain.ex"
}
