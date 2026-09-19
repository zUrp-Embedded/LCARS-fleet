#!/usr/bin/env bats
# SOURCE: runtime/test/services/human.d/claude_bin.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-17
# STATUS: bats tests for 40-claude-bin — UNE seule source, l'installeur officiel
#
# ⚠ CE FICHIER REMPLACE `claude_bin_seed.bats`, ET IL EPINGLE L'INVERSE DE CE QUE CELUI-LA PROUVAIT.
# L'ancien tenait qu'une GRAINE (`$LCARS_CLAUDE_SEED`, un binaire pose sur la machine par un geste
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
  # UNE SEULE RACINE (Q3, 2026-09-04) : le module ET son protocole sont du runtime — le temoin ne
  # lit plus rien dans `deploy/`. Il en lisait la lib, que le module sourcait et que son hote
  # reel ne posait pas.
  MOD="$BATS_TEST_DIRNAME/../../../services/human.d/40-claude-bin.sh"
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  HOMEDIR="$SANDBOX/home"
  BINDIR="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$SANDBOX/lib" "$HOMEDIR/.local/bin" "$BINDIR"

  # The real lib, plus the single override. Appended rather than edited: what the module calls is
  # the shipped code, and the diff between it and what runs here is these three lines.
  # Le decor recopie le protocole pour y surcharger `human_home`.
  cp "$BATS_TEST_DIRNAME/../../../services/lib/human-protocol.sh" "$SANDBOX/lib/human-protocol.sh"
  cp "$BATS_TEST_DIRNAME/../../../services/lib/module-protocol.sh" "$SANDBOX/lib/module-protocol.sh"
  # ⚖ decision 3 : le protocole SOURCE le lecteur des faits. Le decor n'emporte pas l'arbre du
  # produit : on lui NOMME le vrai lecteur, qui resout les vrais faits depuis son propre chemin.
  export LCARS_FACTS_SH="$BATS_TEST_DIRNAME/../../../services/lib/facts.sh"
  cat >> "$SANDBOX/lib/human-protocol.sh" <<EOF

human_home() { echo "$HOMEDIR"; }
EOF

  CURL_LOG="$BATS_TEST_TMPDIR/curl.calls"
  : > "$CURL_LOG"

  export LCARS_HUMAN_PROTOCOL="$SANDBOX/lib/human-protocol.sh"
  export LCARS_LOGIN
  LCARS_LOGIN="$(id -un)"
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
  run bash "$MOD" apply
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

# ⚠ LA CAUSE LA PLUS FREQUENTE DE CET ECHEC NE SE VOIT PAS DANS SA PLAINTE. L'installeur officiel
# prend l'artefact COMPRESSE quand `zstd` est la, et le binaire NU sinon — 230 Mo. Sur un lien
# ordinaire il n'aboutit pas, et il le dit en « somme de controle » sur un fichier qui n'existe meme
# pas. Mesure du 2026-09-17 sur LCARS-beta : aucun humain n'avait `claude`, et rien ne le disait.
@test "installeur en echec avec zstd ABSENT : le refus NOMME zstd, sa consequence et le geste" {
  # ⚠ L'ABSENCE SE CONSTRUIT, ELLE NE SE SUPPOSE PAS. Compter sur le fait que la machine du testeur
  # n'a pas zstd, c'est mesurer cette machine : le jour ou elle l'aura, ce temoin tombera en
  # accusant le module. Un PATH de liens vers TOUT sauf zstd rend l'absence deterministe.
  local sans="$BATS_TEST_TMPDIR/sans-zstd" d f n; mkdir -p "$sans"
  for d in /usr/bin /bin /usr/sbin /sbin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      n="${f##*/}"
      [[ -x "$f" && "$n" != zstd && ! -e "$sans/$n" ]] || continue
      ln -s "$f" "$sans/$n"
    done
  done
  # l'installeur telecharge, puis echoue
  # ⚠ LA CIBLE EST CELLE DE `-o`, PAS `$3`. Le geste appelle `curl -fsSL --proto '=https' -m N -o
  # <fichier> <url>` : prendre `$3` ecrivait un fichier nomme « =https » dans le repertoire courant —
  # et deux d'entre eux ont fini commites (2026-09-18).
  cat > "$BINDIR/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] || exit 1
printf '#!/usr/bin/env bash\nexit 1\n' > "$out"
exit 0
EOF
  chmod 0755 "$BINDIR/curl"
  run env PATH="$BINDIR:$sans" bash "$MOD" apply

  [[ "$output" == *"zstd"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"230 Mo"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"10-packages"* ]] || { echo "$output"; return 1; }
}

@test "installeur en echec avec zstd PRESENT : le refus reste court — on n'accuse pas un innocent" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/zstd"; chmod 0755 "$BINDIR/zstd"
  # ⚠ LA CIBLE EST CELLE DE `-o`, PAS `$3`. Le geste appelle `curl -fsSL --proto '=https' -m N -o
  # <fichier> <url>` : prendre `$3` ecrivait un fichier nomme « =https » dans le repertoire courant —
  # et deux d'entre eux ont fini commites (2026-09-18).
  cat > "$BINDIR/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] || exit 1
printf '#!/usr/bin/env bash\nexit 1\n' > "$out"
exit 0
EOF
  chmod 0755 "$BINDIR/curl"
  run_apply

  [[ "$output" == *"installeur officiel en échec"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"zstd"* ]] || { echo "$output"; return 1; }
}

@test "aucune SOURCE alternative ne subsiste dans le module" {
  # Epingle la FORME, pas le comportement : ce qui a produit le defaut est une seconde source
  # preferee au reseau. Qu'elle ne puisse pas revenir par une variable oubliee se verifie ici.
  run grep -c "LCARS_CLAUDE_SEED" "$MOD"
  [ "$output" -eq 1 ]   # la seule occurrence restante est l'avertissement « ne pas la remettre »
}
