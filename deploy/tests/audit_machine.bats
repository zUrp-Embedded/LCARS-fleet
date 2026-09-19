#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/audit_machine.bats
# AUTHOR: alice
# STARDATE: 2026-08-28
# STATUS: bats tests — `provision audit` : la TABLE opposee a la MACHINE

# shellcheck disable=SC2016

load refute
load support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  decor_pose
  # la table se lit à côté de la lib : un corpus à part porte la sienne
  local src="$BATS_TEST_DIRNAME/.." sbx="$BATS_TEST_TMPDIR/prov"
  mkdir -p "$sbx/lib" "$sbx/modules.d"
  cp "$src/provision" "$src/installer-constants.env" "$sbx/"
  cp "$src/lib/provision-lib.sh" "$src/lib/provision-audit.sh" "$src/lib/docker-endpoint.sh" "$sbx/lib/"
  # ⚖ décision 3 : les faits du produit ne sont pas dans ce bac à sable — on les lui NOMME.
  export PROV_PRODUCT_FACTS_FILE="$src/../runtime/etc/facts.env"
  printf '#!/usr/bin/env bash\n# APPLY-ON: any\n# CHECK-ON: any\n# NEEDS: human\nexit 0\n' > "$sbx/modules.d/10-x.sh"
  RUNNER="$sbx/provision"
  MANIFEST="$sbx/system.manifest"
  JOURNAL="$LCARS_DECOR_ROOT/opt/lcars/var/install.journal"
  mkdir -p "$(dirname "$JOURNAL")"
  cat > "$MANIFEST" <<EOF
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

@test "rien d'apparu : rien n'est apparu entre les deux instantanés que la table ne déclare" {
  : > "$APRES"
  audit
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rien n'est apparu"* ]]
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
  [[ "$output" == *"1 non couvert"* ]]
  [[ "$output" == *"Chacun est un défaut"* ]]
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


@test "APT : ce qu'un paquet JOURNALISE possede n'est pas un objet non declare" {
  printf 'apt_installed decorpkg\n' > "$JOURNAL"
  cat > "$DECOR_BIN/dpkg" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "-L" && "$2" == "decorpkg" ]] && { printf '/usr/lib/decor.so
/usr/share/decor/x
'; exit 0; }
exit 1
STUB
  chmod +x "$DECOR_BIN/dpkg"
  snap /usr/lib/decor.so /usr/share/decor/x
  audit
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 appartenant à un paquet apt"* ]]
}

@test "APT : un paquet NON journalise ne couvre rien — le journal decide, pas dpkg" {
  # `dpkg` sait ce qu'un paquet possede ; il ne sait pas si c'est LCARS qui l'a pose. Seul le
  # journal porte cette distinction, et c'est sa raison d'etre.
  : > "$JOURNAL"
  cat > "$DECOR_BIN/dpkg" <<'STUB'
#!/usr/bin/env bash
printf '/usr/lib/decor.so
'; exit 0
STUB
  chmod +x "$DECOR_BIN/dpkg"
  snap /usr/lib/decor.so
  audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"/usr/lib/decor.so"* ]]
}

@test "APT : sans journal lisible, l'audit DIT que son compte ne veut pas dire ce qu'il semble" {
  snap /var/surprise
  audit
  [[ "$output" == *"journal illisible ($JOURNAL)"* ]]
}

@test "GARDE D'INSTRUMENT : deux instantanes sont EXIGES, on ne devine pas" {
  # Un audit qui accepterait un fichier manquant rendrait vert sur du vide — la forme d'echec la
  # plus chere, celle qui certifie.
  run bash "$RUNNER" audit --before "$AVANT" --after /nexistepas
  [ "$status" -ne 0 ]
  [[ "$output" == *"deux instantanés"* ]]
}

@test "un verbe inconnu est refusé avant toute lecture" {
  run bash "$RUNNER" inconnu --before "$AVANT" --after "$APRES"
  [ "$status" -eq 1 ]
  [[ "$output" == *"commande inconnue"* ]]
}

@test "un joker en TETE (person <human>) ne couvre PAS l'univers — deux chemins bidon sortent" {
  printf 'person    <human>   -   -   any\n' >> "$MANIFEST"
  snap /etc/pwned-by-lcars /srv/nimportequoi
  audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"/etc/pwned-by-lcars"* ]]
  [[ "$output" == *"/srv/nimportequoi"* ]]
  [[ "$output" != *"Rien n'est apparu"* ]]
}

@test "un chmod sur un chemin préexistant ne fait pas un objet apparu" {
  printf 'f -rw-r--r-- 0:0 /etc/pas-a-nous.conf\n' > "$AVANT"
  printf 'f -rw-rw-r-- 0:0 /etc/pas-a-nous.conf\n' > "$APRES"
  audit
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 objet(s) apparu(s)"* ]]
  refute grep -q '/etc/pas-a-nous.conf' <<<"$output"
}

@test "le même chemin, absent de l'instantané d'avant, est un objet apparu et non couvert" {
  : > "$AVANT"
  printf 'f -rw-rw-r-- 0:0 /etc/pas-a-nous.conf\n' > "$APRES"
  audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 objet(s) apparu(s)"* ]]
  [[ "$output" == *"/etc/pas-a-nous.conf"* ]]
}
