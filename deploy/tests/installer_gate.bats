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
  SHELL_GATE="$BATS_TEST_DIRNAME/../../runtime/test/shell_gate.sh"

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

go7_shape() { # go7_shape <fichier> <fonction> — la FORME d'un predicat : fenetre lue, drapeaux, motifs
  # `echo "$h" | grep`, `grep <<<"$h"` et `[[ -n "$(… | grep …)" ]]` (capture puis test, DI-13)
  # sont une ecriture, pas un sens : on ne garde que ce qui decide — chaque `head -N` et chaque
  # `grep -<drapeaux> <motif>`, drapeaux tries, `q` retire (c est la forme du test, pas le motif).
  local line flags pat
  sed -n "/^$2()/,/^}/p" "$1" \
    | grep -oE "head -[0-9]+|grep -[A-Za-z]+[[:space:]]+('[^']*'|\"[^\"]*\")" \
    | while IFS= read -r line; do
        case "$line" in
          head*) printf '%s\n' "$line" ;;
          *) flags="${line#grep -}"; flags="${flags%%[[:space:]]*}"; flags="${flags//q/}"
             pat="${line#grep -*[[:space:]]}"; pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat:1:${#pat}-2}"
             printf 'grep -%s %s\n' "$(printf '%s' "$flags" | fold -w1 | sort | tr -d '\n')" "$pat" ;;
        esac
      done
}

@test "LES DEUX PREDICATS GO-7 S'ACCORDENT avec leurs originaux du pre-commit — deux copies derivent (bis)" {
  # `go7_md_header` et `go7_source_header` sont des copies de `check_md_header` et
  # `check_source_header` (`runtime/git-hooks/pre-commit`), commentees comme telles et gardees par
  # rien (relecture hostile 2026-09-04, S4). Meme motif que le bloc BATS_ENV juste au-dessus : ce
  # qui doit rester egal est la fenetre lue (`head -15`, `head -20`), les drapeaux (`-F`, `-E`, `-i`)
  # et chaque motif. Un motif appris d'un seul cote ferait passer au pre-commit un fichier que la
  # porte refuse, ou l'inverse.
  local hook="$BATS_TEST_DIRNAME/../../runtime/git-hooks/pre-commit"
  [ -f "$hook" ] || skip "pre-commit absent de cet arbre (contexte installeur seul)"
  local pair a b
  for pair in go7_md_header:check_md_header go7_source_header:check_source_header; do
    a="$(go7_shape "$PORTE_SRC" "${pair%%:*}")"
    b="$(go7_shape "$hook" "${pair##*:}")"
    [ -n "$a" ] || { echo "${pair%%:*} : aucun motif lu dans la porte"; return 1; }
    [ -n "$b" ] || { echo "${pair##*:} : aucun motif lu dans le hook"; return 1; }
    [ "$a" = "$b" ] || { echo "les deux copies ont DERIVE (${pair%%:*} / ${pair##*:}) :"; echo "porte: $a"; echo "hook : $b"; return 1; }
  done
  # TEMOIN DU TEMOIN : le lecteur voit bien les quatre motifs et les deux fenetres — une extraction
  # morte des deux cotes rendrait deux vides egaux.
  a="$(go7_shape "$PORTE_SRC" go7_md_header)"
  [[ "$a" == *'head -15'* && "$a" == *'**Date**'* && "$a" == *'^\s+date:'* && "$a" == *'<!--\s*Date\s*:'* ]] || { echo "md : $a"; return 1; }
  a="$(go7_shape "$PORTE_SRC" go7_source_header)"
  [[ "$a" == *'head -20'* && "$a" == *'SOURCE:|AUTHOR:|STARDATE:'* ]] || { echo "source : $a"; return 1; }
}

# ─── LES DEUX MOITIES AJOUTEES PAR Q4 (plancher shellcheck, en-tetes GO-7) — relecture 2026-09-04 ──
# La porte de l'installeur est le SEUL porteur de ces deux proprietes pour deploy/ (shell_gate.sh
# exclut deploy/). Sans ces temoins, les neutraliser laissait ce fichier vert sur ses huit cas.
@test "shellcheck ABSENT = ECHEC nomme — la porte ne joue pas un plancher qu'elle ne peut pas mesurer" {
  stub_bats 0; printf '@test "un" { true; }\n' > "$DECOR/tests/un.bats"
  local nosc="$BATS_TEST_TMPDIR/nosc"; mkdir -p "$nosc"
  local d f n; local -a dirs; IFS=: read -ra dirs <<< "$PATH"
  for d in "${dirs[@]}"; do [ -d "$d" ] || continue; for f in "$d"/*; do [ -x "$f" ] || continue; n="$(basename "$f")"; [ "$n" = shellcheck ] && continue; [ -e "$nosc/$n" ] || ln -sf "$f" "$nosc/$n"; done; done
  [ ! -e "$nosc/shellcheck" ]
  run env PATH="$nosc" "$nosc/bash" "$DECOR/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shellcheck absent"* ]] || { echo "rc=$status : $output"; return 1; }
}

@test "decor sans AUCUN fichier shell = ECHEC nomme — la decouverte est cassee, pas l'installeur (B1, quatrieme cas)" {
  # Les trois autres refus (shellcheck absent, plancher, GO-7) supposent qu'il y a quelque chose a
  # auditer. Zero fichier shell sous la porte n'est pas « rien a redire » : c'est le `find`, ou la
  # reconnaissance par shebang, qui ne rend plus rien — et un plancher joue sur une liste vide
  # rendrait un verdict (shellcheck sans fichier sort en usage) qui parlerait d'autre chose.
  # ⚠ LA COPIE DE LA PORTE EST ELLE-MEME UN FICHIER SHELL par les regles de sa decouverte (`.sh`, ou
  # un shebang bash) : pour un decor SANS fichier shell, la copie perd les deux. Elle se joue par
  # `bash <fichier>`, le shebang ne decide de rien ici — on mesure la garde, pas le shebang.
  stub_bats 0
  printf '@test "un" { true; }\n' > "$DECOR/tests/un.bats"   # un cas sans shebang : un corpus, pas un shell
  tail -n +2 "$PORTE_SRC" > "$DECOR/porte"; chmod 0755 "$DECOR/porte"
  rm -f "$DECOR/gate.sh"
  # TEMOIN DU TEMOIN : le decor ne porte bien AUCUN fichier shell au sens de la porte
  refute grep -qE '^#!' "$DECOR/porte"
  run bash "$DECOR/porte"
  [ "$status" -ne 0 ]
  [[ "$output" == *"aucun fichier shell"* ]] || { echo "rc=$status : $output"; return 1; }
  [[ "$output" == *"decouverte est cassee"* ]]
  [[ "$output" != *"BATS APPELE"* ]] || { echo "bats a ete lance sur un corpus que la porte n'a pas pu auditer"; return 1; }
  [[ "$output" != *"shellcheck plancher"* ]] || { echo "le plancher a ete joue sur une liste vide"; return 1; }
}

@test "le plancher shellcheck REFUSE un avertissement dans un script du corpus" {
  stub_bats 0; printf '@test "un" { true; }\n' > "$DECOR/tests/un.bats"
  printf '%s\n' '#!/usr/bin/env bash' '# SOURCE: deploy/tests/warn.sh' 'echo $(ls)' > "$DECOR/tests/warn.sh"
  run bash "$DECOR/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shellcheck plancher"* ]] || { echo "rc=$status : $output"; return 1; }
  [[ "$output" == *"warn.sh"* ]]
}

@test "GO-7 REFUSE un script sans en-tete declaratif, et le nomme" {
  stub_bats 0; printf '@test "un" { true; }\n' > "$DECOR/tests/un.bats"
  printf '%s\n' '#!/usr/bin/env bash' 'echo ok' > "$DECOR/tests/nohead.sh"
  run bash "$DECOR/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GO-7"* ]] || { echo "rc=$status : $output"; return 1; }
  [[ "$output" == *"nohead.sh"* ]]
}
