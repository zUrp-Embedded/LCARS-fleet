#!/usr/bin/env bats
# SOURCE: fleet/test/claude_probe/claude_probe.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-03
# STATUS: tests de la sonde de contrat vendor
#
# Ce qui est epingle : la sonde REFUSE quand un drapeau load-bearing manque, distingue un vendor
# ABSENT d'un vendor QUI A CHANGE (deux codes de sortie, deux gestes de reparation differents), et
# ne se laisse pas tromper par un prefixe — `--settings` est une sous-chaine de `--setting-sources`,
# et une recherche naive rendrait un vert menteur sur le drapeau le plus load-bearing des deux.

setup() {
  PROBE="${BATS_TEST_DIRNAME}/../../bin/claude_probe.sh"
  FAKEBIN="$(mktemp -d)"
}

teardown() { rm -rf "$FAKEBIN"; }

# Fabrique un faux `claude` dont `--help` rend exactement ce qu'on lui donne.
fake_claude() {
  cat > "$FAKEBIN/claude" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version) echo "2.1.183 (fake)" ;;
  --help) cat <<'HELP'
$1
HELP
  ;;
esac
EOF
  chmod +x "$FAKEBIN/claude"
}

ALL_FLAGS='  --system-prompt-file <path>
  --setting-sources <list>
  --settings <json>
  --mcp-config <path>
  --strict-mcp-config
  --permission-mode <mode>
  --allowedTools <list>
  --disallowedTools <list>
  --model <name>
  --session-id <uuid>
  --resume
  --effort <level>
  --remote-control
  --disable-slash-commands'

@test "contrat tenu : tous les drapeaux presents -> exit 0" {
  fake_claude "$ALL_FLAGS"
  run env CLAUDE_BIN="$FAKEBIN/claude" bash "$PROBE"
  # Le statut est asserte AVANT la sortie, donc un rouge n'apprenait rien : la sonde a trois codes
  # distincts (0 contrat tenu, 1 contrat rompu, 2 vendor absent ou muet) et savoir LEQUEL est tombe
  # trancherait entre une fuite d'environnement et une fabrication de faux ratee. Vu une fois en
  # suite complete le 2026-08-10, vert en isolation et sur tous les rejeux depuis — cause inconnue,
  # occurrence suivante desormais lisible.
  [ "$status" -eq 0 ] || { echo "claude_probe exit=$status output: $output" >&3; false; }
  [[ "$output" == *"contrat vendor OK"* ]]
}

@test "un drapeau retire par une mise a jour -> exit 1, et il est NOMME" {
  fake_claude "$(printf '%s' "$ALL_FLAGS" | grep -v 'system-prompt-file')"
  run env CLAUDE_BIN="$FAKEBIN/claude" bash "$PROBE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONTRAT VENDOR ROMPU"* ]]
  [[ "$output" == *"--system-prompt-file"* ]]
  # La version du vendor est dans le message : sans elle, l'operateur ne sait pas QUOI a change.
  [[ "$output" == *"2.1.183"* ]]
}

@test "un PREFIXE ne compte pas pour le drapeau : --setting-sources ne couvre pas --settings" {
  # Le piege exact qu'une recherche en sous-chaine ferait passer — et sur les deux drapeaux dont
  # la confusion est la plus couteuse (les settings du pod contre ceux qui fuiraient de l'humain).
  fake_claude "$(printf '%s' "$ALL_FLAGS" | grep -v -- '--settings <json>')"
  run env CLAUDE_BIN="$FAKEBIN/claude" bash "$PROBE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--settings"* ]]
}

@test "vendor ABSENT -> exit 2, distinct du contrat rompu (autre geste de reparation)" {
  run env CLAUDE_BIN="$FAKEBIN/inexistant" bash "$PROBE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"introuvable"* ]]
}

@test "vendor present mais --help muet -> exit 2, jamais un vert par defaut" {
  # Un --help vide ferait echouer TOUS les greps : sans ce garde la sonde rendrait « 11 drapeaux
  # manquants » et enverrait reparer un launcher qui va tres bien.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/claude"
  chmod +x "$FAKEBIN/claude"
  run env CLAUDE_BIN="$FAKEBIN/claude" bash "$PROBE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"n'a rien rendu"* ]]
}

@test "notation a CROCHETS du vendor : --system-prompt[-file] compte pour --system-prompt-file" {
  # Le faux positif paye au premier tir contre le vrai binaire (2.1.220) : son --help factorise
  # deux drapeaux en `--system-prompt[-file]`, et une recherche du token exact declarait le contrat
  # rompu sur le drapeau LE PLUS load-bearing de la liste — un vert transforme en alarme, qui
  # aurait envoye reparer un launcher intact.
  fake_claude "$(printf '%s' "$ALL_FLAGS" | sed 's/--system-prompt-file <path>/--system-prompt[-file] <path>/')"
  run env CLAUDE_BIN="$FAKEBIN/claude" bash "$PROBE"
  [ "$status" -eq 0 ]
}

@test "VERROU : la liste REQUIRED couvre tout drapeau que le launcher passe en argv" {
  # Sans ce verrou, ajouter un drapeau au launcher sans l'ajouter a la sonde la rend menteuse PAR
  # OMISSION : elle attesterait un contrat plus petit que celui dont on depend, et son vert
  # couvrirait un drapeau que personne ne verifie. Meme forme que le verrou des quatre listes.
  LAUNCHER="${BATS_TEST_DIRNAME}/../../bin/claude_launch.sh"

  # argv SEULEMENT : les commentaires du launcher nomment des drapeaux qu'il ne passe pas
  # (`--print-like`, une note d'histoire) — les compter ferait echouer la sonde sur de la prose.
  # C'est l'erreur exacte du premier inventaire de cette liste.
  for flag in $(grep -vE '^\s*#' "$LAUNCHER" | grep -oE '\-\-[a-zA-Z-]+' | sort -u); do
    [ "$flag" = "--version" ] && continue
    grep -qE "^\s+${flag}([[:space:]]|$)" "$PROBE" \
      || { echo "drapeau passe par le launcher mais absent de REQUIRED : $flag"; false; }
  done
}
