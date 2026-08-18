#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/projects_reconcile.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for modules.d/75-projects.sh — la forge dit quels projets existent, le disque suit
#
# CE QUE CES TEMOINS TIENNENT. Ce module n'a AUCUNE logique de projet : il relaie une porte du
# release qui parle en mots, et traduit ces mots en verdicts de provisioning. Tout ce qu'il apporte
# est donc cette traduction et les refus qui l'entourent — c'est exactement ce qui est mesure ici.
#
# TROIS PIEGES, UN PAR TEMOIN DE REFUS :
#   * une porte qui MEURT n'ecrit rien sur stdout. Sans garde, le module lit zero ligne et rend
#     « aucun projet » — le mot d'une boite convergee, sur une panne franche.
#   * une porte dont le FORMAT derive (un mot nouveau) doit se voir au premier run. Un `case` sans
#     branche par defaut la lirait comme un silence.
#   * une boite SANS forge n'est pas une boite en derive. Il n'y a pas d'autorite a suivre : on le
#     dit, et on sort conforme.
#
# La porte est simulee par un `lcars` pose dans le PROV_LINK_DIR du test : aucun release n'est
# construit, aucune socket n'est ouverte.

# ⚠ L'IDENTITE DU LANCEUR EST POSEE, JAMAIS HERITEE — ET CE N'EST PAS DE LA PRUDENCE : ce fichier
# a ete VERT sur la machine de dev et ROUGE dans la CI du banc, au premier tour. Le module
# court-circuite pour qui n'est pas un humain de fleet (`is_fleet_human` : uid >= UID_MIN et
# uid != SYSADMIN_UID), le job de CI tourne en ROOT (uid 0), et les neuf temoins de traduction
# recevaient donc « n'est pas un humain de fleet » a la place du verdict qu'ils mesurent.
#
# Un test qui lit l'uid de sa machine mesure la machine. Les deux entrees de la regle sont des
# knobs — `PASSWD_DEFS` pour UID_MIN, `LCARS_SYSADMIN_UID` pour le siege — donc le setup les POSE
# de facon que l'uid courant soit un humain de fleet, quel qu'il soit. Les deux temoins de la garde
# les re-posent a l'envers pour eux-memes : c'est la seule facon d'epingler les DEUX reponses.
setup() {
  # ⚠ L'ENVIRONNEMENT DE LA MACHINE N'A PAS SON MOT A DIRE ICI. Ces temoins mesurent une ABSENCE de
  # forge ; si la variable existe deja dans l'environnement, ils mesurent la machine et passent au
  # rouge sans que rien ne soit casse. Mesure du 2026-08-18 : `provision --env` exporte
  # `FORGE_BASE_URL` (set -a) pour tout le run, gate compris — quatre temoins rouges sur une
  # installation parfaitement saine, et verts joues a la main.
  unset FORGE_BASE_URL FORGE_PUBLIC_URL FORGE_TOKEN_FILE FORGE_ADMIN_TOKEN
  # ⚠ ET LE FICHIER, QUI EST UNE SECONDE PORTE VERS LA MEME VARIABLE. Depuis que `48-forge-host`
  # ecrit `$PROV_TOKENS_DIR/forge.url`, la lib le lit en dernier repli — et l'idiome `:=` traite une
  # chaine VIDE comme « non pose ». Un test qui dit « pas de forge » par `PROV_FORGE_URL=""` se
  # voyait donc rendre celle de la machine. Mesure du 2026-08-18 sur un poste ou la forge venait
  # d'etre montee : rouge la-bas, vert ici, et la seule difference etait un fichier.
  # On pose donc un PROV_TOKENS_DIR a nous : le repli ne trouve rien, comme sur une machine nue.
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/tokens"
  mkdir -p "$PROV_TOKENS_DIR"
  MOD="$BATS_TEST_DIRNAME/../modules.d/75-projects.sh"
  LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  [ -x "$MOD" ]
  export PROVISION_LIB="$LIB"
  export PROV_FORGE_URL="http://forge.invalid"
  export PROV_LINK_DIR="$BATS_TEST_TMPDIR/bin"
  export PROV_HUMAN="$(id -un)"
  mkdir -p "$PROV_LINK_DIR"

  # UID_MIN 0 : tout uid franchit la frontiere systeme/humain, root compris.
  echo "UID_MIN 0" > "$BATS_TEST_TMPDIR/login.defs"
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  # Le siege du sysadmin est un uid que personne ici ne porte.
  export LCARS_SYSADMIN_UID="$(( $(id -u) + 1 ))"
}

# La porte rend ce qu'on lui dit de rendre. $1 = code de sortie, stdin = les lignes de verdict.
# Elle trace son argv dans `$BATS_TEST_TMPDIR/argv` — le mode transmis est un fait mesurable.
fake_door() { # <rc> ; verdicts sur stdin
  local rc="$1"
  cat > "$BATS_TEST_TMPDIR/verdicts"
  cat > "$PROV_LINK_DIR/lcars" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$BATS_TEST_TMPDIR/argv"
cat "$BATS_TEST_TMPDIR/verdicts"
exit $rc
SH
  chmod +x "$PROV_LINK_DIR/lcars"
}

# Une porte qui meurt : rien sur stdout, tout sur stderr — la forme exacte d'un release absent ou
# d'une config incomplete.
fake_dead_door() { # <rc> <message stderr>
  cat > "$PROV_LINK_DIR/lcars" <<SH
#!/usr/bin/env bash
echo "$2" >&2
exit $1
SH
  chmod +x "$PROV_LINK_DIR/lcars"
}

# ─── la traduction des mots ──────────────────────────────────────────────────────────────────────

@test "check: RIEN → conforme, et le module le DIT" {
  fake_door 0 <<< "RIEN aucun projet declare dans les catalogues installes"
  run "$MOD" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"aucun projet declare"* ]]
  # Le mode transmis est celui du module, pas un defaut de la CLI.
  [[ "$(cat "$BATS_TEST_TMPDIR/argv")" == "project reconcile check" ]]
}

@test "check: MANQUE → DRIFT (exit 1) et le geste de reparation est nomme" {
  fake_door 2 <<< "MANQUE  fleet/vitrine"
  run "$MOD" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"fleet/vitrine"* ]]
  # UN DRIFT QUI NE DIT PAS QUOI FAIRE NE SE DISTINGUE PAS D'UNE PANNE.
  [[ "$output" == *"lcars project reconcile apply"* ]]
}

@test "check: DEJA → conforme, aucune ligne de drift" {
  fake_door 0 <<< "DEJA    fleet/vitrine"
  run "$MOD" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet/vitrine"* ]]
  [[ "$output" != *"DRIFT"* ]]
}

@test "apply: un projet en echec N'ARRETE PAS les autres" {
  # LE POINT DU LOT. Une boite a laquelle il manque neuf projets sur dix doit en recuperer neuf.
  # Le module rend un echec (exit 1) ET porte les deux lignes : le verdict global ne mange pas le
  # detail de ce qui a marche.
  fake_door 1 <<'EOF'
IMPORTE fleet/vitrine
ECHEC   fleet/casse — {:branch_unreadable, "ops", :timeout}
EOF
  run "$MOD" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"fleet/vitrine"* ]]
  [[ "$output" == *"fleet/casse"* ]]
  [[ "$output" == *"branch_unreadable"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/argv")" == "project reconcile apply" ]]
}

@test "apply: tout DEJA → convergé, exit 0" {
  fake_door 0 <<'EOF'
DEJA    fleet/vitrine
DEJA    fleet/autre
EOF
  run "$MOD" apply
  [ "$status" -eq 0 ]
}

# ─── les trois refus ─────────────────────────────────────────────────────────────────────────────

@test "une porte qui MEURT est un echec, et son cri est repris — jamais « aucun projet »" {
  fake_dead_door 127 "binaire de release introuvable"
  run "$MOD" check
  [ "$status" -eq 2 ]
  [[ "$output" == *"binaire de release introuvable"* ]]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" != *"aucun projet declare"* ]]
}

@test "une porte qui meurt DANS la fourchette normale (rc 1) rend quand meme son cri" {
  # LE CAS QUI A ECHAPPE A LA PREMIERE VERSION, et c'est celui qui est arrive au banc : la porte
  # est morte en plein import, avec un rc de 1 — un code que le module traite comme « au moins un
  # ECHEC », donc normal — et ZERO ligne sur stdout. La condition de reprise n'est donc pas le code
  # de sortie mais l'ABSENCE de verdict : sans ca, le module jette la seule chose qui dit pourquoi.
  fake_dead_door 1 "** (EXIT) no process: Fleet.Spawner.Supervisor"
  run "$MOD" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"no process"* ]]
  [[ "$output" == *"n'a rien rendu"* ]]
}

@test "un mot inconnu de la porte est un echec, pas un silence" {
  fake_door 0 <<< "PEUTETRE fleet/vitrine"
  run "$MOD" check
  [ "$status" -eq 2 ]
  [[ "$output" == *"verdict illisible"* ]]
}

@test "sans forge : ce n'est pas une derive, c'est une absence d'autorite" {
  # Une boite hors ligne rend conforme. La compter en drift ferait crier le doctor sur toutes les
  # boites qui n'ont jamais recu « docker.sh config ».
  export PROV_FORGE_URL=""
  fake_door 0 <<< "RIEN rien"
  run "$MOD" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"pas d'autorite a suivre"* ]]
}

@test "sans release : on ne redit pas l'alarme de 60-deploy" {
  rm -f "$PROV_LINK_DIR/lcars"
  run "$MOD" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"60-deploy"* ]]
  [[ "$output" != *"FAIL"* ]]
}

# ─── la garde qui manquait : tous les `# NEEDS: human` ne parlent pas du meme humain ─────────────

@test "le sysadmin n'est pas un humain de fleet : le module passe son tour, conforme" {
  # LE PIEGE MESURE. L'entrypoint conteneur joue le cycle de boot avec `--human <sysadmin>` (uid
  # 1000). Sans cette garde, les faces des projets seraient posees sous le seul compte qui ne peut
  # pas lancer de fleet — et le git de l'humain qui les utilise ensuite les refuserait, proprietaire
  # different. Ce n'est pas une derive : les humains, eux, les convergent.
  export LCARS_SYSADMIN_UID="$(id -u)"
  fake_door 0 <<< "MANQUE  fleet/vitrine"
  run "$MOD" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"n'est pas un humain de fleet"* ]]
  # ET LA PORTE N'EST PAS JOUEE DU TOUT — pas un import silencieux sous le mauvais uid.
  [ ! -f "$BATS_TEST_TMPDIR/argv" ]
}

@test "un compte SYSTEME (uid < UID_MIN) est ecarte par la meme garde" {
  # La garde a deux conditions parce qu'il y a deux regles : la frontiere systeme/humain, declaree
  # par login.defs, et la reservation du siege du sysadmin, que login.defs ne peut PAS exprimer.
  # Un UID_MIN au-dessus de l'uid courant simule le compte systeme sans en creer un — il ECRASE le
  # `UID_MIN 0` du setup, qui existe pour que les autres temoins ne dependent pas de l'uid reel.
  echo "UID_MIN $(( $(id -u) + 1 ))" > "$BATS_TEST_TMPDIR/login.defs"
  fake_door 0 <<< "MANQUE  fleet/vitrine"
  run "$MOD" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"n'est pas un humain de fleet"* ]]
}
