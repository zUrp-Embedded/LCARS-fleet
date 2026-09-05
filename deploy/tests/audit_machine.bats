#!/usr/bin/env bats
# SOURCE: deploy/tests/audit_machine.bats
# AUTHOR: alice
# STARDATE: (posee par /push-github)
# STATUS: bats tests — `provision audit` : la TABLE opposee a la MACHINE
#
# POURQUOI CE VERBE EXISTE, ET POURQUOI AUCUN TEMOIN DE CODE NE LE REMPLACE.
#
# Les deux murs ISO de `system_manifest.bats` extraient des LITTERAUX d'un source. Ils sont donc
# aveugles a trois choses, et les trois ont mordu ce chantier :
#   · un nom compose a l'execution — `unit_path() { "$1.service" }` : quatre liens d'activation
#     morts, invisibles aux deux sens du contrat
#   · un objet pose par un TIERS — `/root/.terraform.d`, ecrit par le binaire `tofu`
#   · un objet neuf qu'aucun mur n'attendait — `lcars-system`, second compte de service, ne apres
#     le releve sans que rien ne le signale
#
# Un instrument qui lit le CODE herite des angles morts du code. Celui-ci lit la MACHINE : il voit
# ce QUI EST, pas ce qui est ecrit. C'est la definition de fin de `cible.md` §12.
#
# CE FICHIER TESTE LE COMPARATEUR, PAS LA MACHINE. Le balayage est le geste de l'operateur ; ce qui
# se verifie ici est que l'opposition table/diff rend le bon verdict — y compris ses deux cas
# tordus : la couverture par un ANCETRE, et le joker.

# shellcheck disable=SC2016

load refute

setup() {
  RUNNER="$BATS_TEST_DIRNAME/../provision"
  [ -f "$RUNNER" ]
  export LCARS_SYSTEM_MANIFEST="$BATS_TEST_TMPDIR/system.manifest"
  cat > "$LCARS_SYSTEM_MANIFEST" <<EOF
dir       /opt/decor                 0755  root:root  any
anchor    /etc/decor/pose.conf       0644  root:root  any
dir       /opt/vers-<version>        0755  root:root  any
human     /home/<human>/.decor       0700  -:-        any
EOF
  AVANT="$BATS_TEST_TMPDIR/avant"; APRES="$BATS_TEST_TMPDIR/apres"
  : > "$AVANT"
}
# Un instantane au format du releve : « <type> <mode> <uid>:<gid> <chemin> ».
snap() { printf 'f -rw-r--r-- 0:0 %s\n' "$@" > "$APRES"; }
audit() { run bash "$RUNNER" audit --before "$AVANT" --after "$APRES"; }

@test "rien d'apparu : la machine ne porte rien que la table ne declare" {
  : > "$APRES"
  audit
  [ "$status" -eq 0 ]
  [[ "$output" == *"ne porte rien"* ]]
}

@test "un objet DECLARE ne sort pas" {
  snap /etc/decor/pose.conf
  audit
  [ "$status" -eq 0 ]
}

@test "un objet NON declare sort, et il est NOMME" {
  snap /etc/decor/pose.conf /var/surprise
  audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"/var/surprise"* ]]
  [[ "$output" == *"1 NON couvert"* ]]
  [[ "$output" == *"DEFAUT"* ]]
}

@test "COUVERT PAR UN ANCETRE : declarer le repertoire couvre ce qu'il porte" {
  # Exiger une ligne par fichier ferait une table de dix mille lignes que personne ne relirait —
  # et une table qu'on ne relit pas ne declare rien.
  snap /opt/decor /opt/decor/bin /opt/decor/bin/outil
  audit
  [ "$status" -eq 0 ]
}

@test "COUVERT PAR UN ANCETRE : le voisin de meme prefixe n'est PAS couvert" {
  # Contre-temoin du precedent, et il porte tout son poids : sans lui, `/opt/decor` couvrirait
  # `/opt/decor-autre`, et un objet voisin passerait pour declare a cause d'un prefixe commun.
  snap /opt/decor-autre
  audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"/opt/decor-autre"* ]]
}

@test "JOKER : \`<version>\` et \`<human>\` couvrent ce qu'ils resolvent" {
  snap /opt/vers-1.2.3 /opt/vers-1.2.3/bin /home/zoe/.decor
  audit
  [ "$status" -eq 0 ]
}

# ─── CE QU'APT POSSEDE N'EST PAS A NOUS ─────────────────────────────────────────────────────────
#
# MESURE DU 2026-08-28, banc vierge : 35 143 objets apparus, dont ~10 000 sous `/usr/lib`,
# `/usr/include` et `/usr/share` — le CONTENU des seize paquets que le rail a installes. La table ne
# les declare pas DELIBEREMENT : ils ont leur propre inventaire et leur temoin bidirectionnel, et le
# journal sait lesquels ce rail a poses.
#
# Un instrument qui signale dix mille objets legitimes apprend a etre ignore. C'est le mode d'echec
# que ce chantier nomme partout ailleurs ; le fabriquer ici serait absurde.

@test "APT : ce qu'un paquet JOURNALISE possede n'est pas un objet non declare" {
  printf 'apt_installed decorpkg\n' > "$BATS_TEST_TMPDIR/journal"
  cat > "$BATS_TEST_TMPDIR/dpkg" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "-L" && "$2" == "decorpkg" ]] && { printf '/usr/lib/decor.so
/usr/share/decor/x
'; exit 0; }
exit 1
STUB
  chmod +x "$BATS_TEST_TMPDIR/dpkg"
  snap /usr/lib/decor.so /usr/share/decor/x
  LCARS_JOURNAL_FILE="$BATS_TEST_TMPDIR/journal" LCARS_DPKG="$BATS_TEST_TMPDIR/dpkg" \
    run bash "$RUNNER" audit --before "$AVANT" --after "$APRES"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 appartenant a un paquet apt"* ]]
}

@test "APT : un paquet NON journalise ne couvre rien — le journal decide, pas dpkg" {
  # `dpkg` sait ce qu'un paquet possede ; il ne sait pas si c'est LCARS qui l'a pose. Seul le
  # journal porte cette distinction, et c'est sa raison d'etre.
  : > "$BATS_TEST_TMPDIR/journal"
  cat > "$BATS_TEST_TMPDIR/dpkg" <<'STUB'
#!/usr/bin/env bash
printf '/usr/lib/decor.so
'; exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/dpkg"
  snap /usr/lib/decor.so
  LCARS_JOURNAL_FILE="$BATS_TEST_TMPDIR/journal" LCARS_DPKG="$BATS_TEST_TMPDIR/dpkg" \
    run bash "$RUNNER" audit --before "$AVANT" --after "$APRES"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/usr/lib/decor.so"* ]]
}

@test "APT : sans journal lisible, l'audit DIT que son compte ne veut pas dire ce qu'il semble" {
  # ⚠ MESURE DU 2026-08-28 : audit rejoue APRES un uninstall — `dpkg -L` ne rend plus rien, zero
  # exclusion, 10 190 faux positifs. Un instrument dont la reponse depend de QUAND on le lance doit
  # le dire, sinon c'est le lecteur qui paie.
  snap /var/surprise
  LCARS_JOURNAL_FILE=/nexistepas run bash "$RUNNER" audit --before "$AVANT" --after "$APRES"
  [[ "$output" == *"journal illisible"* ]]
}

@test "GARDE D'INSTRUMENT : deux instantanes sont EXIGES, on ne devine pas" {
  # Un audit qui accepterait un fichier manquant rendrait vert sur du vide — la forme d'echec la
  # plus chere, celle qui certifie.
  run bash "$RUNNER" audit --before "$AVANT" --after /nexistepas
  [ "$status" -ne 0 ]
  [[ "$output" == *"deux instantanes"* ]]
}

@test "le verbe est DECLARE dans le dispatch, sinon il n'existe pas" {
  grep -qE 'case "\$CMD" in apply\|doctor\|update\|list\|uninstall\|audit\)' "$RUNNER"
}

# ─── relecture hostile 2026-09-04 : un joker EN TETE couvrait l'univers ─────────────────────────
# `person <human>` est une ligne de la vraie table ; son objet commence par `<`, son prefixe est
# vide, et `[[ "$p" == ""* ]]` est vrai de tout chemin : l'audit rendait « ne porte rien » sur
# n'importe quoi. Ce temoin joue la table AVEC cette ligne, et deux chemins bidon.
@test "un joker en TETE (person <human>) ne couvre PAS l'univers — deux chemins bidon sortent" {
  printf 'person    <human>   -   -   any\n' >> "$LCARS_SYSTEM_MANIFEST"
  snap /etc/pwned-by-lcars /srv/nimportequoi
  audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"/etc/pwned-by-lcars"* ]]
  [[ "$output" == *"/srv/nimportequoi"* ]]
  [[ "$output" != *"ne porte rien"* ]]
}

# ─── M5 : UN CHEMIN DEJA LA DONT SEUL LE MODE CHANGE N'EST PAS « APPARU » ───────────────────────
#
# Relecture hostile du 2026-09-04 : le `comm` comparait la LIGNE entiere (`<type> <mode> <uid:gid>
# <chemin>`). Un chmod sur un objet preexistant — ce que `ensure_mode` fait a chaque apply sur des
# arbres qui ne sont pas a nous — ressortait comme un objet apparu, donc NON couvert, donc un DEFAUT.
@test "M5 : un chmod sur un chemin preexistant ne fait pas un objet apparu" {
  printf 'f -rw-r--r-- 0:0 /etc/pas-a-nous.conf\n' > "$AVANT"
  printf 'f -rw-rw-r-- 0:0 /etc/pas-a-nous.conf\n' > "$APRES"
  audit
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 objet(s) apparu(s)"* ]]
  refute grep -q '/etc/pas-a-nous.conf' <<<"$output"
}

@test "M5 : TEMOIN DU TEMOIN — le meme chemin ABSENT de l'avant est bien apparu (et non couvert)" {
  : > "$AVANT"
  printf 'f -rw-rw-r-- 0:0 /etc/pas-a-nous.conf\n' > "$APRES"
  audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 objet(s) apparu(s)"* ]]
  [[ "$output" == *"/etc/pas-a-nous.conf"* ]]
}
