#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/claude_bin.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-17
# STATUS: bats tests for 40-claude-bin — UNE seule source, l'installeur officiel
#
# ⚠ CE FICHIER REMPLACE `claude_bin_seed.bats`, ET IL EPINGLE L'INVERSE DE CE QUE CELUI-LA PROUVAIT.
# L'ancien tenait qu'une GRAINE (`$PROV_CLAUDE_SEED`, un binaire pose sur la machine par un geste
# exterieur) court-circuitait le reseau ; son stub `curl` echouait si le reseau etait appele.
#
# ⚖ ARBITRAGE USER 2026-08-17 : « on ne cache pas un binaire anthropic, on fait UNIQUEMENT l'install
# officielle », et pour le banc « il DOIT derouler le compose entierement, et re-dl a chaque tour ».
# Le motif n'est pas l'economie : un banc seme rend VERT un chemin qu'il n'a pas parcouru — le
# telechargement EST une etape du deploiement reel, la sauter fait mesurer autre chose.
#
# L'appel reseau est donc le comportement EXIGE, et c'est lui que ces temoins tiennent. Avec les
# deux proprietes qui comptent autour :
#
#   · un binaire deja bon COURT-CIRCUITE tout — l'auto-update est le rail vendor, pas le notre.
#     Sans ce temoin, « on telecharge toujours » passerait pour correct.
#   · un download RATE laisse l'ancien binaire INTACT. La v1 faisait `rm` AVANT le download : un
#     echec reseau coutait l'outil entier. C'est la seule propriete de ce module dont la perte se
#     paie en travail, et elle n'avait de temoin que par la bande.

setup() {
  SRC="$BATS_TEST_DIRNAME/../.."
  SANDBOX="$BATS_TEST_TMPDIR/box"
  HOMEDIR="$SANDBOX/home"
  BINDIR="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$SANDBOX/lib" "$HOMEDIR/.local/bin" "$BINDIR"

  # The real lib, plus the single override. Appended rather than edited: what the module calls is
  # the shipped code, and the diff between it and what runs here is these three lines.
  # ⚠ `provision-lib.sh` SOURCE `docker-endpoint.sh` : le decor doit porter les DEUX, sinon
  # toute la suite tombe sur un « No such file » dont la cause est cette ligne de setup.
  cp "$SRC/lib/provision-lib.sh" "$SANDBOX/lib/provision-lib.sh"
  cp "$SRC/lib/docker-endpoint.sh" "$SANDBOX/lib/docker-endpoint.sh"
  cat >> "$SANDBOX/lib/provision-lib.sh" <<EOF

human_home() { echo "$HOMEDIR"; }
EOF

  CURL_LOG="$BATS_TEST_TMPDIR/curl.calls"
  : > "$CURL_LOG"

  export PROVISION_LIB="$SANDBOX/lib/provision-lib.sh"
  export PROV_HUMAN
  PROV_HUMAN="$(id -un)"
  export PATH="$BINDIR:$PATH"

  # ⚠ `HOME` EST DU DECOR ICI, ET SON ABSENCE COUTE LE BINAIRE DU DEVELOPPEUR. Le module ne
  # detourne plus le HOME de l'installeur — le rail vendor installe POUR l'utilisateur courant —
  # donc la doublure d'installeur ecrit dans `$HOME`, et `~/.local/bin/claude` est un SYMLINK :
  # une ecriture le suit et tronque la cible reelle. Le bac a sable doit porter le home.
  export HOME="$HOMEDIR"
}

# A binary is a thing that answers --version. The fake is a script, which `cp -a`, `chmod` and the
# functional probe all treat exactly like the real static ELF.
fake_claude() {
  local path="$1" version="$2"
  cat > "$path" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "--version" ]] && echo "$version" && exit 0
exit 3
EOF
  chmod 0755 "$path"
}

# `curl` is the network. The stub logs the call so a test can assert it never happened, and still
# behaves like the installer download so the fallback path stays exercisable.
stub_curl() {
  cat > "$BINDIR/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CURL_LOG"
out=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "\$out" ]] || exit 0
# The vendor installer, reduced to its contract: it puts .local/bin/claude in \$HOME.
cat > "\$out" <<'INNER'
#!/usr/bin/env bash
mkdir -p "\$HOME/.local/bin"
printf '#!/usr/bin/env bash\n[[ "\$1" == "--version" ]] && echo "from-installer" && exit 0\nexit 3\n' \
  > "\$HOME/.local/bin/claude"
chmod 0755 "\$HOME/.local/bin/claude"
INNER
exit 0
EOF
  chmod 0755 "$BINDIR/curl"
}

run_apply() {
  run bash "$SRC/modules.d/40-claude-bin.sh" apply
}

@test "l'installeur officiel EST appele — c'est le comportement exige, pas un repli" {
  stub_curl
  run_apply

  [ -s "$CURL_LOG" ]
  grep -q "claude.ai/install.sh" "$CURL_LOG"
  run "$HOMEDIR/.local/bin/claude" --version
  [[ "$output" == "from-installer" ]]
}

@test "un binaire DEJA bon court-circuite tout — aucun appel reseau" {
  fake_claude "$HOMEDIR/.local/bin/claude" "deja-la"
  stub_curl
  run_apply

  # LE TEMOIN NEGATIF DU PRECEDENT : sans lui, un module qui telecharge a chaque boot passerait.
  [ ! -s "$CURL_LOG" ]
  run "$HOMEDIR/.local/bin/claude" --version
  [[ "$output" == "deja-la" ]]
}

@test "un download RATE laisse l'ancien binaire INTACT, et le DIT" {
  fake_claude "$HOMEDIR/.local/bin/claude" "ancien"
  # Le binaire est bon, donc le module sortirait tot : on le casse pour forcer le chemin reseau,
  # puis le reseau echoue.
  printf '#!/usr/bin/env bash\nexit 3\n' > "$HOMEDIR/.local/bin/claude"
  chmod 0755 "$HOMEDIR/.local/bin/claude"
  cat > "$BINDIR/curl" <<'EOF'
#!/usr/bin/env bash
exit 6
EOF
  chmod 0755 "$BINDIR/curl"
  run_apply

  # La FORME, pas la phrase : le module DIT que le download a echoue. Epingler la formulation
  # exacte fait tomber ce temoin sur une reecriture de message, ce qui ne prouve rien.
  [[ "$output" == *"download"* && "$output" == *"échec"* ]]
  # La v1 faisait `rm` AVANT le download : un echec reseau coutait l'outil. Le fichier est toujours la.
  [ -f "$HOMEDIR/.local/bin/claude" ]
}

@test "aucune SOURCE alternative ne subsiste dans le module" {
  # Epingle la FORME, pas le comportement : ce qui a produit le defaut est une seconde source
  # preferee au reseau. Qu'elle ne puisse pas revenir par une variable oubliee se verifie ici.
  run grep -c "PROV_CLAUDE_SEED" "$SRC/modules.d/40-claude-bin.sh"
  [ "$output" -eq 1 ]   # la seule occurrence restante est l'avertissement « ne pas la remettre »
}
