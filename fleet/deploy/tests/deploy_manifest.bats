#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/deploy_manifest.bats
# AUTHOR: consultant
# STARDATE: 2026-07-30
# STATUS: bats tests for 60-deploy check — manifest-driven, source-independent
#
# Contract under test: the doctor side of 60-deploy is as BLIND to content as the installer —
# what it probes under $PREFIX/bin comes from etc/install.manifest, and it needs NO source
# checkout beyond etc/ (first real container boot proved the old mix.exs guard broke the probe
# exactly where it matters most). The RO-lock probe (root:fleet) inevitably drifts in an
# unprivileged sandbox — assertions therefore target the bin/link lines, not the exit code,
# except where the exit code is the contract (missing manifest = probe ERROR = rc 2).

setup() {
  SRC="$BATS_TEST_DIRNAME/.."
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/fleet/deploy/lib" "$ROOT/fleet/etc"
  # ⚠ `provision-lib.sh` SOURCE `docker-endpoint.sh` : le decor doit porter les DEUX, sinon
  # toute la suite tombe sur un « No such file » dont la cause est cette ligne de setup.
  cp "$SRC/lib/provision-lib.sh" "$ROOT/fleet/deploy/lib/"
  cp "$SRC/lib/docker-endpoint.sh" "$ROOT/fleet/deploy/lib/"
  cp "$SRC/modules.d/60-deploy.sh" "$BATS_TEST_TMPDIR/60-deploy.sh"

  cat > "$ROOT/fleet/etc/install.manifest" <<'EOF'
# test manifest
fleet_v2         exec   link
bwrap_launch.sh  exec
bridge.py        noexec
EOF

  export PROV_PREFIX="$BATS_TEST_TMPDIR/prefix"
  export PROV_LINK_DIR="$BATS_TEST_TMPDIR/linkdir"
  export PROVISION_LIB="$ROOT/fleet/deploy/lib/provision-lib.sh"
  export PROVISION_MODULE=60-deploy

  # a "deployed" prefix: release marker + every manifest entry posed correctly
  mkdir -p "$PROV_PREFIX/rel/lcars_fleet/bin" "$PROV_PREFIX/bin" "$PROV_LINK_DIR"
  printf '#!/bin/sh\n' > "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  chmod +x "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  printf 'x\n' > "$PROV_PREFIX/bin/fleet_v2";        chmod +x "$PROV_PREFIX/bin/fleet_v2"
  printf 'x\n' > "$PROV_PREFIX/bin/bwrap_launch.sh"; chmod +x "$PROV_PREFIX/bin/bwrap_launch.sh"
  printf 'x\n' > "$PROV_PREFIX/bin/bridge.py"
  ln -s "$PROV_PREFIX/bin/fleet_v2" "$PROV_LINK_DIR/fleet_v2"
}

run_check() { run bash "$BATS_TEST_TMPDIR/60-deploy.sh" check; }

@test "manifest-driven check: fully posed prefix has zero bin/link drift" {
  run_check
  [[ "$output" == *"bin/fleet_v2"* ]]
  [[ "$output" == *"bin/bridge.py"* ]]
  [[ "$output" == *"symlink $PROV_LINK_DIR/fleet_v2"* ]]
  [[ "$output" != *"DRIFT 60-deploy: bin/"* ]]
  [[ "$output" != *"symlink vers"* ]]
}

@test "manifest-driven check: a missing exec entry drifts by name" {
  rm "$PROV_PREFIX/bin/bwrap_launch.sh"
  run_check
  [[ "$output" == *"DRIFT"* ]]
  [[ "$output" == *"bin/bwrap_launch.sh absent"* ]]
}

@test "manifest-driven check: a noexec entry only needs to be readable" {
  chmod -x "$PROV_PREFIX/bin/bridge.py"
  run_check
  [[ "$output" != *"bridge.py absent"* ]]
}

@test "manifest-driven check: a wrong link target drifts" {
  ln -sfn /somewhere/else "$PROV_LINK_DIR/fleet_v2"
  run_check
  [[ "$output" == *"$PROV_LINK_DIR/fleet_v2 ≠ symlink vers"* ]]
}

@test "manifest-driven check: a dead copy of a non-link entry warns (D3)" {
  printf 'x\n' > "$PROV_LINK_DIR/bwrap_launch.sh"
  run_check
  [[ "$output" == *"copie morte $PROV_LINK_DIR/bwrap_launch.sh"* ]]
}

@test "source-independence: check runs WITHOUT mix.exs (only etc/ ships in the image)" {
  # setup() never created mix.exs — a green-path check proves no source-tree dependency
  run_check
  [[ "$output" != *"introuvable"* ]]
}

@test "missing manifest is a probe ERROR (rc 2), not a silent pass" {
  rm "$BATS_TEST_TMPDIR/repo/fleet/etc/install.manifest"
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"manifest introuvable"* ]]
}

# ─── L'OUTILLAGE DU GATE : UNE EGALITE DE LISTES, TENUE PAR UN TEMOIN ───────────────────────────
#
# Le Dockerfile porte en commentaire « Liste = celle de 10-packages + les 2 du gate ». C'etait une
# affirmation que rien ne verifiait, et elle avait deja derive : le stage build installe TROIS
# paquets de plus (python3-pytest, bats, procps), et le rail natif n'en installait aucun.
#
# Mesure du 2026-08-18, Ubuntu 26.04 LTS neuve : « ECHEC: pytest absent — les lcars_tests de
# token-saver ne peuvent pas tourner (pas de skip silencieux) ». Gate rouge, release non posee,
# install natif mort. La liste vivait a un seul endroit, et c'etait le Dockerfile.

@test "tout paquet exige par le gate est installe DES DEUX COTES (image et rail natif)" {
  DOCKERFILE="$BATS_TEST_DIRNAME/../docker/Dockerfile"
  MOD="$BATS_TEST_DIRNAME/../modules.d/60-deploy.sh"
  PKG="$BATS_TEST_DIRNAME/../modules.d/10-packages.sh"
  [ -f "$DOCKERFILE" ] && [ -f "$MOD" ] && [ -f "$PKG" ]

  # ce que le rail natif installe : les paquets runtime + l'outillage du gate.
  # ⚠ L'EXTRACTION SUIT LE TABLEAU SUR PLUSIEURS LIGNES. Elle lisait `^PACKAGES=(…)$` — donc une
  # seule ligne — et rendait du VIDE des que la liste s'aerait. Un temoin qui rend du vide ne
  # compare rien, et `[ -n ]` etait la seule chose qui l'empechait de passer sur une liste absente.
  runtime="$(native_list 'PACKAGES' "$PKG")"
  gate="$(native_list 'GATE_PACKAGES' "$MOD")"
  [ -n "$runtime" ]
  [ -n "$gate" ]

  # le stage build de l'image DOIT contenir chacun d'eux
  for p in $runtime $gate; do
    grep -q -- " $p " "$DOCKERFILE" || grep -q -- " $p\\\\" "$DOCKERFILE" || {
      echo "paquet '$p' absent du stage build du Dockerfile" >&2; false; }
  done
}

# ─── ET DANS L'AUTRE SENS, QUI EST CELUI QUI A COUTE ────────────────────────────────────────────
#
# Le temoin ci-dessus ne verifie qu'une direction : tout paquet natif est dans l'image. L'inverse —
# tout paquet du RUNTIME de l'image est sur le rail natif — n'etait verifie par personne, et c'est
# par la que sont passes `socat` et TOUT le socle d'outillage des pods.
#
# MESURE DU 2026-08-21, poste natif installe a froid : `socat` absent, donc
# `bwrap_launch.sh:478` refuse (exit 2), donc le warden respawne le pod permanent cinq fois puis
# abandonne — AUCUN pod ne peut naitre. Sur une installation dont les 23 modules etaient verts.
# Et derriere : ni gcc, ni make, ni pip, ni venv. Le produit livrait des pods infirmes.
#
# ⚠ LES EXEMPTIONS SE NOMMENT UNE PAR UNE, AVEC LEUR RAISON. Une liste d'exclusion sans motif
# devient l'endroit ou l'on range ce qu'on n'a pas envie de traiter.

# ⚠ LES COMMENTAIRES SE RETIRENT AVANT DE CHERCHER LA BORNE, ET C'EST TOUT LE PIEGE. Le depot porte
# les DEUX formes — un tableau sur une ligne (`GATE_PACKAGES=(a b c)`) et un tableau aere avec des
# commentaires entre les noms. Avec `/^)/` comme borne, la forme d'une ligne ne fermait jamais la
# plage et sed rapportait du CODE comme des paquets (« paquet 'apt_ensure' absent du Dockerfile ») ;
# avec `/)/`, un commentaire contenant « (lot 1 du rail toolchain) » la fermait trop tot. Une
# machine a etats sur les lignes DECOMMENTEES repond juste sur les deux.
native_list() { # native_list <NOM_DU_TABLEAU> <fichier> — le contenu, commentaires retires
  awk -v n="$1" '
    !inside && $0 ~ "^[[:space:]]*" n "=\\(" { inside = 1; sub("^[[:space:]]*" n "=\\(", "") }
    inside {
      line = $0
      sub(/#.*/, "", line)
      if (line ~ /\)[[:space:]]*$/) { sub(/\)[[:space:]]*$/, "", line); print line; exit }
      print line
    }
  ' "$2" | tr '\n' ' '
}

@test "tout paquet du RUNTIME de l'image est sur le rail natif — l'autre sens, celui qui a coute" {
  DOCKERFILE="$BATS_TEST_DIRNAME/../docker/Dockerfile"
  PKG="$BATS_TEST_DIRNAME/../modules.d/10-packages.sh"
  MOD="$BATS_TEST_DIRNAME/../modules.d/60-deploy.sh"

  # Le stage RUNTIME seul : celui qui decrit la boite livree, pas l'atelier de build.
  local image
  image="$(sed -n '/^FROM ${RUNTIME_IMAGE} AS runtime/,/^COPY --from=build/p' "$DOCKERFILE" \
    | sed -n '/apt-get install/,/rm -rf \/var\/lib\/apt/p' \
    | grep -vE '^\s*`#' \
    | tr ' \\' '\n\n' \
    | grep -vE '^$|apt-get|install|-y|--no-install-recommends|DEBIAN_FRONTEND|&&|^rm$|-rf|/var/lib/apt' \
    | sort -u)"
  [ -n "$image" ]

  local native; native=" $(native_list 'PACKAGES' "$PKG") $(native_list 'LINUX_PACKAGES' "$PKG") $(native_list 'GATE_PACKAGES' "$MOD") "

  # Ce que l'image seule a le droit de porter, et POURQUOI :
  #   tini            — PID 1 d'un conteneur. Sur une machine, c'est systemd, et il est deja la.
  #   openssh-server  — la porte d'admin de la BOITE. Sur un poste, l'acces reseau appartient a son
  #                     proprietaire : l'operateur est deja connecte quand ce rail tourne, et lui
  #                     ouvrir un sshd serait decider de son exposition a sa place.
  local exempt=" tini openssh-server "

  local miss=""
  for p in $image; do
    [[ "$exempt" == *" $p "* ]] && continue
    [[ "$native" == *" $p "* ]] || miss="$miss $p"
  done
  [ -z "$miss" ] || { echo "paquets du runtime de l'image ABSENTS du rail natif :$miss" >&2; false; }
}

@test "les exemptions sont NOMMEES dans le temoin, pas glissees dans une liste" {
  # Une exclusion sans motif ecrit devient l'endroit ou l'on range ce qu'on ne veut pas traiter.
  local f="$BATS_TEST_DIRNAME/deploy_manifest.bats"
  grep -q 'tini *— PID 1' "$f"
  grep -q 'openssh-server *— la porte' "$f"
}

@test "le gate a bien ses trois outils nommes — un ajout silencieux ne passe pas" {
  MOD="$BATS_TEST_DIRNAME/../modules.d/60-deploy.sh"
  gate="$(sed -n 's/^  GATE_PACKAGES=(\(.*\))$/\1/p' "$MOD")"
  [[ "$gate" == *"python3-pytest"* ]]   # shell_gate: les lcars_tests de token-saver
  [[ "$gate" == *"bats"* ]]             # BATS_MISSING_FATAL=1 pose par mix.exs
  [[ "$gate" == *"procps"* ]]           # les sondes qui lisent pgrep
}

@test "install.sh fait TRAVERSER ses reglages a l'escalade sudo" {
  # `sudo` remet l'environnement a zero. Un reglage pose avant l'escalade (PROV_COLOR, PROV_VERBOSE)
  # meurt en la traversant : mesure du 2026-08-18, `PROV_COLOR=1 bash install.sh` colorisait le
  # preflight puis rendait un provisionnement blanc, sans un mot pour dire pourquoi. Troisieme
  # incarnation de ce piege dans la meme journee (le shim docker, le temp root de bench-swap).
  SH="$BATS_TEST_DIRNAME/../../../install.sh"
  [ -f "$SH" ]
  grep -q 'REEXEC_ENV+=' "$SH"
  grep -q 'exec sudo "${REEXEC_ENV\[@\]}"' "$SH"
  for v in PROV_COLOR NO_COLOR PROV_VERBOSE; do
    grep -q "$v" "$SH" || { echo "reglage $v non transmis a travers sudo" >&2; false; }
  done
}

# ─── DOCKER : DEPENDANCE DURE DU RAIL POSTE, ET DE LUI SEUL ─────────────────────────────────────
#
# ⚖ USER 2026-08-21 : « docker, ça me choque pas que ça soit un pré-requis […] tu peux toujours
# l'installer si tu trouves pas. »
#
# Sur une machine dediee, LCARS MONTE sa forge lui-meme (`48-forge-host` : `compose up -d` sur un
# Gitea) et refuse sans docker. Aucun module ne le posait : sur une Ubuntu vierge l'install mourait
# au module 48, et tout ce qui suit sortait en derive pour une cause qui n'etait pas la sienne.

pkg_mod() { echo "$BATS_TEST_DIRNAME/../modules.d/10-packages.sh"; }

@test "docker n'est PAS dans la liste des deux rails — il n'a rien a faire dans l'image" {
  # `PACKAGES` est la liste que les DEUX rails obtiennent par apt, et le temoin d'egalite ci-dessus
  # exige que chacun de ses membres soit dans le Dockerfile. Y mettre docker ferait mentir ce
  # temoin ou installerait un daemon dans une image qui tourne DANS un daemon.
  # ⚠ CE TEMOIN NE MESURAIT RIEN, ET IL EST VERT DEPUIS QU'IL EXISTE. Sa `sed` exigeait
  # `^PACKAGES=(…)$` sur UNE ligne ; le tableau reel en fait vingt-huit, donc elle rendait la chaine
  # VIDE et `[[ "" != *"docker"* ]]` passait a vide. Mesure du 2026-08-23 : 0 octet en sortie.
  # Ajouter `docker` a `PACKAGES` n'aurait rien fait rougir.
  #
  # `native_list` existe dans ce fichier POUR CA — son propre commentaire decrit le piege — et il
  # etait deja utilise deux tests plus bas. Une extraction correcte a cote d'une extraction fausse,
  # c'est celle qui ne mord pas qui survit le plus longtemps : personne ne relit un test vert.
  run native_list 'PACKAGES' "$(pkg_mod)"
  [ -n "$output" ]
  [[ "$output" != *"docker"* ]]
}

@test "docker : pose sur linux SEULEMENT, et SEULEMENT si aucun daemon ne repond" {
  # ⚠ CETTE REGLE EST DEVENUE CONDITIONNELLE, DONC LE TEMOIN TESTE LES DEUX BRANCHES. Il n'en
  # testait qu'une, et ma condition l'a rendu dependant de la MACHINE : sur un poste ou docker
  # repond, `eff linux` ne contient plus `docker.io` et le temoin tombait — en mesurant l'hote au
  # lieu de la regle. Sixieme occurrence de ce piege en deux jours.
  #
  # LE FOND : la majorite des postes Linux ont docker par le depot upstream, et le rail y pose
  # DESORMAIS le meme empaquetage (⚖ user 2026-08-23). Ce qui protege l'operateur n'est donc plus le
  # choix du paquet mais la CONDITION : aucun daemon ne repond. Poser une source apt tierce sur une
  # machine qui a deja docker serait ajouter un depot dont elle n'a pas besoin — la branche « 0 »
  # ci-dessous est ce qui l'interdit, et c'est elle qu'il faut garder verte.
  local head="$BATS_TEST_TMPDIR/pkg-head.sh"
  sed '/^check() {/,$d' "$(pkg_mod)" > "$head"

  # La sonde est DOUBLEE, dans les deux sens. C'est la seule facon de mesurer une condition sans
  # mesurer la machine qui joue le test.
  eff() { # eff <substrat> <0 si un daemon repond | 1 sinon>
    PROV_SUBSTRATE="$1" DOCKER_ANSWERS="$2" \
    PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh" \
      bash -c 'source "$1" >/dev/null 2>&1
               docker_endpoint() { return "$DOCKER_ANSWERS"; }
               effective_packages' _ "$head" 2>/dev/null | tr '\n' ' '
  }

  # aucun daemon : le rail POSE docker, c'est sa raison d'etre sur ce substrat
  [[ "$(eff linux 1)" == *"docker-ce"* ]]
  [[ "$(eff linux 1)" == *"docker-compose-plugin"* ]]
  # un daemon repond : on ne pose RIEN, et on ne retire rien non plus
  [[ "$(eff linux 0)" != *"docker-ce"* ]]
  [[ "$(eff linux 0)" != *"docker-compose-plugin"* ]]
  # les autres substrats ne le posent JAMAIS, quelle que soit la sonde
  [[ "$(eff wsl 1)"    != *"docker-ce"* ]]
  [[ "$(eff docker 1)" != *"docker-ce"* ]]
  # et la liste commune reste la, dans tous les cas
  [[ "$(eff docker 1)" == *"bubblewrap"* ]]
  [[ "$(eff linux 0)"  == *"bubblewrap"* ]]
}

@test "check et apply lisent la MEME liste — deux derivations repondraient differemment" {
  # `check` iterait sur `PACKAGES`, `apply` aussi : ajouter une liste conditionnelle a un seul des
  # deux ferait sonder autre chose que ce qu'on installe.
  grep -q 'done < <(effective_packages)' "$(pkg_mod)"
  grep -q 'mapfile -t pkgs < <(effective_packages)' "$(pkg_mod)"
}

@test "UN FAIT, DEUX RENDUS : le prefixe de la lib EGALE celui de l'installeur de release" {
  # ⚠ CE COUPLAGE ETAIT ECRIT ET NON TENU. `provision-lib.sh` le dit en toutes lettres — « DOIT
  # egaler le defaut d'etc/install.sh (SSoT du layout) […] Un fait, deux rendus : sync a la main » —
  # et RIEN ne le verifiait. Une prose qui demande une synchronisation manuelle est une derive
  # programmee : celui qui deplace l'un des deux ne lit pas forcement le commentaire de l'autre.
  #
  # Ce temoin existe pour le chantier EMPREINTE, qui va precisement deplacer ce prefixe. Sans lui,
  # la phase B pouvait bouger la lib, laisser `etc/install.sh` derriere, et produire une machine ou
  # le provisionnement cherche la release a un endroit ou l'installeur ne l'a pas posee.
  local lib="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  local inst="$BATS_TEST_DIRNAME/../../etc/install.sh"
  local from_lib from_inst
  from_lib="$(grep -oE '\$\{PROV_PREFIX:=[^}]+\}' "$lib" | head -1 | sed 's/.*:=//')"
  from_inst="$(grep -oE '\$\{LCARS_INSTALL_PREFIX:-[^}]+\}' "$inst" | head -1 | sed 's/.*:-//')"
  [ -n "$from_lib" ]
  [ -n "$from_inst" ]
  [ "$from_lib" = "$from_inst" ]
}

@test "UN FAIT, DEUX RENDUS : le repertoire de liens aussi" {
  # Meme classe, meme piege : `PROV_LINK_DIR` se dit « miroir de LCARS_INSTALL_LINK_DIR ».
  local lib="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  local inst="$BATS_TEST_DIRNAME/../../etc/install.sh"
  local from_lib from_inst
  from_lib="$(grep -oE '\$\{PROV_LINK_DIR:=[^}]+\}' "$lib" | head -1 | sed 's/.*:=//')"
  from_inst="$(grep -oE '\$\{LCARS_INSTALL_LINK_DIR:-[^}]+\}' "$inst" | head -1 | sed 's/.*:-//')"
  [ -n "$from_lib" ]
  [ -n "$from_inst" ]
  [ "$from_lib" = "$from_inst" ]
}

# ─── LE DEPOT UPSTREAM — ce qu'il pose, et surtout ce qu'il NE pose PAS ──────────────────────────
#
# ⚖ USER 2026-08-23 : le rail prend `docker-ce` chez Docker plutot que `docker.io` chez Canonical.
# C'est le SEUL depot tiers que ce rail ajoute a une machine, donc les trois proprietes qui comptent
# sont : il se derive (jamais de codename cable), il refuse en NOMMANT la cause, et un refus ne
# laisse RIEN derriere lui.
#
# ⚠ LA TROISIEME EST LA MOINS EVIDENTE ET LA PLUS CHERE. Une source apt posee vers une suite qui
# n'existe pas ne casse pas ici : elle casse au prochain `apt-get update` de l'operateur, des mois
# plus tard, sur un message de depot introuvable que personne ne rattachera a LCARS.
repo_sh() { # repo_sh <corps a jouer apres la source> — decor complet, machine jamais mesuree
  local head="$BATS_TEST_TMPDIR/repo-head.sh"
  sed '/^check() {/,$d' "$(pkg_mod)" > "$head"
  run env PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh" \
          LCARS_DOCKER_KEYRING="$BATS_TEST_TMPDIR/keyrings/docker.asc" \
          LCARS_DOCKER_LIST="$BATS_TEST_TMPDIR/docker.list" \
      bash -c 'source "$1" >/dev/null 2>&1; shift; eval "$@"' _ "$head" "$1"
}

@test "depot docker : une distro que l'upstream ne publie pas est REFUSEE, et rien n'est pose" {
  repo_sh 'os_field() { case "$1" in ID) echo arch ;; VERSION_CODENAME) echo rolling ;; esac; }
           ensure_docker_repo'
  [ "$status" -ne 0 ]
  [[ "$output" == *"arch"* ]]
  [[ "$output" == *"ubuntu et debian"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/docker.list" ]
  [ ! -e "$BATS_TEST_TMPDIR/keyrings/docker.asc" ]
}

@test "depot docker : sans VERSION_CODENAME la suite est INDERIVABLE — on le dit, on ne devine pas" {
  repo_sh 'os_field() { case "$1" in ID) echo ubuntu ;; VERSION_CODENAME) echo "" ;; esac; }
           ensure_docker_repo'
  [ "$status" -ne 0 ]
  [[ "$output" == *"VERSION_CODENAME"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/docker.list" ]
}

@test "depot docker : une suite ABSENTE chez Docker refuse AVANT de poser quoi que ce soit" {
  # Le coeur du temoin : la sonde reseau passe AVANT la cle et la source. Un refus qui laisserait la
  # source derriere lui armerait la panne differee decrite en tete de section.
  repo_sh 'os_field() { case "$1" in ID) echo ubuntu ;; VERSION_CODENAME) echo suite-qui-nexiste-pas ;; esac; }
           curl() { return 22; }
           fetch_verify() { echo "FETCH NE DOIT PAS ETRE APPELE"; return 0; }
           ensure_docker_repo'
  [ "$status" -ne 0 ]
  [[ "$output" == *"suite-qui-nexiste-pas"* ]]
  [[ "$output" != *"FETCH NE DOIT PAS ETRE APPELE"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/docker.list" ]
  [ ! -e "$BATS_TEST_TMPDIR/keyrings/docker.asc" ]
}

@test "depot docker : la source est DERIVEE — id, codename et architecture, aucun litteral" {
  # ⚠ LES DEUX POSEURS SONT DOUBLES SUR LEUR CHOWN, et ce n'est pas du confort. Le keyring et la
  # source appartiennent a root en production — c'est juste — mais un temoin joue par un humain ne
  # peut pas chowner : il tomberait donc sur l'IDENTITE de qui le lance au lieu de la regle qu'il
  # garde. Meme piege que les deux d'aujourd'hui, troisieme forme.
  #
  # La propriete n'est pas perdue, elle est DEPLACEE la ou elle se verifie : `system.manifest`
  # declare les deux fichiers en `0644 root:root`, et le temoin d'ISO de ce fichier l'exige.
  # Ce test-ci ne garde qu'une chose, celle qui n'est verifiable qu'ici : la source est DERIVEE.
  repo_sh 'os_field() { case "$1" in ID) echo debian ;; VERSION_CODENAME) echo trixie ;; esac; }
           curl() { return 0; }
           ensure_dir() { mkdir -p "$1"; }
           write_atomic() { mkdir -p "$(dirname "$1")"; cat > "$1"; }
           fetch_verify() { : > "$3"; }
           dpkg() { echo arm64; }
           run_quiet() { return 0; }
           ensure_docker_repo'
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/docker.list"
  [[ "$output" == *"https://download.docker.com/linux/debian trixie stable"* ]]
  [[ "$output" == *"arch=arm64"* ]]
  [[ "$output" == *"signed-by=$BATS_TEST_TMPDIR/keyrings/docker.asc"* ]]
}

@test "depot docker : REJOUER ne repose rien — la cle n'est pas re-telechargee" {
  # ⚠ LE TEMOIN QUE LES QUATRE PREMIERS N'AVAIENT PAS, et c'est celui qui a attrape un vrai defaut.
  # `fetch_verify` telecharge, pose et COMPTE un changement a chaque appel — c'est son contrat, et
  # l'idempotence appartient a l'appelant. Sans garde, une machine ou docker est installe mais dont
  # le daemon ne repond pas (service coupe) re-telecharge la cle a chaque passe et sort `POSE`.
  #
  # On compte les appels a `fetch_verify` : deux passes, UN seul appel. La sonde reseau, elle, a le
  # droit de rejouer — c'est une lecture, elle ne pose rien.
  local head="$BATS_TEST_TMPDIR/repo-head.sh"
  sed '/^check() {/,$d' "$(pkg_mod)" > "$head"
  run env PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh" \
          LCARS_DOCKER_KEYRING="$BATS_TEST_TMPDIR/keyrings/docker.asc" \
          LCARS_DOCKER_LIST="$BATS_TEST_TMPDIR/docker.list" \
          LCARS_DOCKER_GPG_SHA256="$(printf '' | sha256sum | awk '{print $1}')" \
      bash -c 'source "$1" >/dev/null 2>&1
        os_field() { case "$1" in ID) echo ubuntu ;; VERSION_CODENAME) echo resolute ;; esac; }
        curl() { return 0; }
        ensure_dir() { mkdir -p "$1"; }
        write_atomic() { mkdir -p "$(dirname "$1")"; cat > "$1"; }
        # La cle posee est VIDE, et le pin ci-dessus est le sha256 du vide : la garde doit donc
        # reconnaitre au second tour que ce qui est en place EST ce qui etait attendu.
        fetch_verify() { echo "FETCH"; : > "$3"; }
        dpkg() { echo amd64; }
        run_quiet() { return 0; }
        ensure_docker_repo
        ensure_docker_repo' _ "$head"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^FETCH$' <<< "$output")" -eq 1 ]
}
