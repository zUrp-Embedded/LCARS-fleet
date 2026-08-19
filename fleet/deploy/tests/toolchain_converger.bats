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

setup() {
  SUT="${BATS_TEST_DIRNAME}/../docker/toolchain-converger.sh"
  export LCARS_STORE_ROOT="$BATS_TEST_TMPDIR/store"
  export LCARS_TOOLCHAIN_WORK="$BATS_TEST_TMPDIR/work"
  export LCARS_TOOLCHAIN_LOCK="$BATS_TEST_TMPDIR/lock"
  export FORGE_BASE_URL="http://forge.test"
  export FORGE_TOKEN_FILE="$BATS_TEST_TMPDIR/token"
  mkdir -p "$LCARS_STORE_ROOT/state" "$LCARS_TOOLCHAIN_WORK" "$BATS_TEST_TMPDIR/bin"
  printf 'TOK\n' > "$FORGE_TOKEN_FILE"
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
stub_forge() { # stub_forge <yaml-base64>
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in *contents/ops/toolchains.d*) echo '[{"name":"python.yaml","path":"ops/toolchains.d/python.yaml"}]'; exit 0;; esac; done
for a in "\$@"; do case "\$a" in *contents/ops/toolchains.d/python.yaml*) echo '{"content":"$1"}'; exit 0;; esac; done
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  # `jq` doit rendre le chemin puis le contenu : on le scripte au meme endroit.
  cat > "$BATS_TEST_TMPDIR/bin/jq" <<EOF
#!/usr/bin/env bash
in=\$(cat)
case "\$*" in
  *endswith*) echo "ops/toolchains.d/python.yaml" ;;
  *.content*) echo "$1" ;;
  *) echo "" ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/jq"
}

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  grep -q "^# SOURCE:" "$SUT"; grep -q "^# AUTHOR:" "$SUT"
  grep -q "^# STARDATE:" "$SUT"; grep -q "^# STATUS:" "$SUT"
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

@test "REFUS: jeton illisible" {
  rm -f "$FORGE_TOKEN_FILE"
  run "$SUT" deadbeef
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"jeton"* ]]
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

@test "IDEMPOTENCE: un ecosysteme deja applique AU MEME SHA est saute" {
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: python\n' | base64 -w0)"
  mkdir -p "$LCARS_STORE_ROOT/state/eco.d"
  printf 'deadbeef\n' > "$LCARS_STORE_ROOT/state/eco.d/python.applied"

  run "$SUT" deadbeef
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"deja a deadbeef"* ]]
}

@test "IDEMPOTENCE: un marqueur d'un AUTRE sha ne fait pas sauter" {
  # Le marqueur porte le SHA qui l'a produit, pas un booleen : un manifeste modifie doit se
  # rejouer, sinon un merge approuve resterait non applique en se croyant fait.
  stub_forge "$(printf 'kind: ecosystem_enable\necosystem: python\n' | base64 -w0)"
  mkdir -p "$LCARS_STORE_ROOT/state/eco.d"
  printf 'cafe1234\n' > "$LCARS_STORE_ROOT/state/eco.d/python.applied"

  run "$SUT" deadbeef
  [[ "$output" != *"deja a"* ]]
}

@test "REFUS: un manifeste dont le kind n'est pas celui du rail" {
  # Un fichier pose a la main dans ops/toolchains.d n'est pas passe par le schema de l'outil MCP.
  # La ceinture est ici, et c'est la derniere.
  stub_forge "$(printf 'kind: autre_chose\necosystem: python\n' | base64 -w0)"
  run "$SUT" deadbeef
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"kind inattendu"* ]]
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
