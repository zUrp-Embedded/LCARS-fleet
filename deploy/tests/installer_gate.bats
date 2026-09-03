#!/usr/bin/env bats
# SOURCE: deploy/tests/installer_gate.bats
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: temoins de deploy/gate.sh — la porte de l'installeur se mesure elle-meme
#
# ⚠ CETTE PORTE EST CE QUI REND LE DETACHEMENT SUR, DONC ELLE-MEME DOIT ETRE MESUREE. Les 1294 cas
# de `deploy/tests/` etaient joues par `mix gate` ; ils le sont desormais par `deploy/gate.sh`. Si
# cette porte peut rendre 0 sans avoir joue quoi que ce soit, le detachement a transforme une
# couverture reelle en une couverture DECLAREE — le defaut exact que `@test_corpora` du
# contracts.check raconte : « a corpus nobody runs does not rot loudly — it rots while reporting a
# coverage it does not provide ».
#
# ⚠ LE DECOR NE JOUE PAS LES 1294 CAS. On copie la porte dans un arbre a nous, avec un `tests/`
# fabrique : ce qui se mesure ici est le COMPORTEMENT de la porte, pas le contenu de la suite.

load refute

setup() {
  PORTE_SRC="$BATS_TEST_DIRNAME/../gate.sh"
  [ -f "$PORTE_SRC" ]
  SHELL_GATE="$BATS_TEST_DIRNAME/../../fleet/test/shell_gate.sh"

  DECOR="$BATS_TEST_TMPDIR/decor"
  mkdir -p "$DECOR/tests"
  cp "$PORTE_SRC" "$DECOR/gate.sh"
  chmod 0755 "$DECOR/gate.sh"

  # Une doublure de `bats` : on mesure la porte, pas bats.
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
}

stub_bats() { # stub_bats <rc rendu>
  printf '#!/usr/bin/env bash\necho "BATS APPELE: $*"\nexit %s\n' "$1" > "$BIN/bats"
  chmod 0755 "$BIN/bats"
}

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  grep -q "^# SOURCE:" "$PORTE_SRC"; grep -q "^# AUTHOR:" "$PORTE_SRC"
  grep -q "^# STARDATE:" "$PORTE_SRC"; grep -q "^# STATUS:" "$PORTE_SRC"
}

@test "corpus VIDE = ECHEC — zero test joue ne se lit pas comme zero test rouge" {
  # LE TEMOIN QUI PORTE TOUT LE DETACHEMENT. Une porte qui rend 0 sur un dossier vide transforme
  # 1294 cas en une ligne de prose.
  stub_bats 0
  run bash "$DECOR/gate.sh"
  [ "$status" -ne 0 ] || { echo "la porte est VERTE sur un corpus vide"; echo "$output"; return 1; }
  [[ "$output" == *"ne mesure RIEN"* ]]
  [[ "$output" != *"BATS APPELE"* ]] || { echo "bats a ete lance sans fichier"; return 1; }
}

@test "bats ABSENT = ECHEC nomme — jamais un saut silencieux" {
  # `shell_gate` a `BATS_MISSING_FATAL` pour la meme raison : un outil manquant qui fait sauter un
  # pas rend le gate vert sur ce qu'il n'a pas mesure.
  : > "$DECOR/tests/x.bats"
  # ⚠ UN `PATH` VIDE NE MESURE PAS L'ABSENCE DE bats, IL TUE LE SHELL. Ma premiere ecriture posait
  # `PATH="$BIN:/nonexistent"` : `bash` lui-meme devenait introuvable, la porte sortait en 127 sans
  # avoir tourne, et le temoin lisait ce 127 comme « elle a refuse ». Il aurait ete vert sur une
  # porte qui ne dit rien. On construit donc un PATH qui porte TOUT sauf `bats`.
  #
  # ⚠ ET ON NE LISTE PAS LES BINAIRES A LA MAIN. Ma deuxieme ecriture en nommait huit ; il manquait
  # `dirname`, la porte mourait sur « command not found » et le temoin lisait ENCORE autre chose que
  # ce qu'il croit. Une liste des outils qu'un script utilise derive au premier outil ajoute — donc
  # on reflete le PATH ENTIER, moins la seule chose dont on mesure l'absence.
  local nobats="$BATS_TEST_TMPDIR/nobats"; mkdir -p "$nobats"
  local d f n
  local -a dirs; IFS=: read -ra dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] || continue
      n="$(basename "$f")"
      if [ "$n" = bats ]; then continue; fi
      [ -e "$nobats/$n" ] || ln -sf "$f" "$nobats/$n"
    done
  done
  # TEMOIN DU TEMOIN : le decor doit avoir tue bats, et RIEN d'autre.
  [ ! -e "$nobats/bats" ] || { echo "le decor n'a pas masque bats"; return 1; }
  [ -x "$nobats/bash" ]   || { echo "le decor a masque bash — il ne mesure plus l'absence de bats"; return 1; }
  run env PATH="$nobats" "$nobats/bash" "$DECOR/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bats absent"* ]] || { echo "rc=$status sortie: $output"; return 1; }
  [[ "$output" == *"NON joues"* ]]
}

@test "le verdict SUIT bats — un corpus rouge rend rouge" {
  printf '@test "faux" { true; }\n' > "$DECOR/tests/x.bats"
  stub_bats 1
  run bash "$DECOR/gate.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ECHEC"* ]]
}

@test "le chemin NOMINAL passe — sans lui les trois refus sont satisfaits par une porte qui refuse tout" {
  printf '@test "faux" { true; }\n' > "$DECOR/tests/x.bats"
  stub_bats 0
  run bash "$DECOR/gate.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"BATS APPELE"* ]]
  [[ "$output" == *"OK"* ]]
}

@test "le compte de cas est REEL, pas le nombre de fichiers" {
  printf '@test "a" { true; }\n@test "b" { true; }\n' > "$DECOR/tests/x.bats"
  printf '@test "c" { true; }\n'                       > "$DECOR/tests/y.bats"
  stub_bats 0
  run bash "$DECOR/gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 fichier(s), 3 cas"* ]] || { echo "compte faux : $output"; return 1; }
}

@test "l'environnement du lanceur est NEUTRALISE, et le dire fait partie du geste" {
  printf '@test "faux" { true; }\n' > "$DECOR/tests/x.bats"
  stub_bats 0
  run env PROV_FLEET_GROUP=piege LCARS_SEAT_UID_FILE=/x bash "$DECOR/gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NEUTRALISEE"* ]]
  [[ "$output" == *"PROV_FLEET_GROUP"* ]]
  [[ "$output" == *"LCARS_SEAT_UID_FILE"* ]]
}

@test "LA SECONDE COPIE S'ACCORDE avec celle de shell_gate.sh — deux copies derivent" {
  # ⚠ CE BLOC EST DUPLIQUE, ASSUME, ET DONC GARDE. La porte de l'installeur doit etre autonome — elle
  # part avec `deploy/` — mais la neutralisation d'environnement est un contrat, pas un detail : trois
  # pannes datees vivent dans le commentaire de `shell_gate.sh` (`FORGE_BASE_URL` exporte par
  # `provision --env`, un `LCARS_SEAT_UID_FILE` pose a la main, `PROV_FLEET_GROUP` qui VOYAGE par
  # `services.env`). Si l'une des deux copies apprend une quatrieme variable et pas l'autre, la porte
  # qu'on ne relit pas mesure sous un environnement que l'autre refuse.
  #
  # Meme motif que `tests.refute_copies_agree`, qui tient deja les deux copies de `refute.bash`.
  [ -f "$SHELL_GATE" ] || skip "shell_gate.sh absent de cet arbre (contexte installeur seul)"
  local a b
  a="$(grep -oE "\\^\\(LCARS_\\|PROV_\\|FORGE_\\)" "$PORTE_SRC" | head -1)"
  b="$(grep -oE "\\^\\(LCARS_\\|PROV_\\|FORGE_\\)" "$SHELL_GATE" | head -1)"
  [ -n "$a" ] || { echo "motif de neutralisation introuvable dans la porte"; return 1; }
  [ -n "$b" ] || { echo "motif de neutralisation introuvable dans shell_gate.sh"; return 1; }
  [ "$a" = "$b" ] || { echo "les deux copies ont DERIVE : porte=$a  shell_gate=$b"; return 1; }
}
