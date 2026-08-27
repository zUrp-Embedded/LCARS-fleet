#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/uninstall.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: bats tests — `provision uninstall` : il lit deux tables et ne contient AUCUNE liste
#
# ─── CE QUE CE VERBE FERME ──────────────────────────────────────────────────────────────────────
#
# Le 2026-08-22, nettoyer une machine de test s'est fait A LA MAIN, avec une liste ecrite dans un
# `for p in …` improvise. Il a fallu s'y reprendre a deux fois, le groupe `fleet` est reste derriere,
# et un `.terraform` appartenant a root a bloque le `rm` du checkout de l'operateur.
#
# ⚠ ET C'EST LE MOMENT OU L'EMPREINTE SE MESURE VRAIMENT. Une install qui reussit ne prouve RIEN de
# ce qu'elle laisse : sur douze defauts trouves cette nuit-la, un seul est apparu en DESINSTALLANT —
# et il etait invisible autrement.
#
# ⚠ AUCUN TEMOIN ICI NE TOUCHE LA MACHINE. Le manifeste et le journal sont des DECORS, dans
# `BATS_TEST_TMPDIR`, et les chemins qu'ils declarent y vivent aussi. Un temoin de desinstalleur qui
# lirait le vrai manifeste retirerait le vrai systeme.

load refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  RUNNER="$BATS_TEST_DIRNAME/../provision"
  [ -f "$RUNNER" ]

  FAKE="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$FAKE"/{opt/lcars/tofu/providers,etc/lcars,usr/local/bin,work,work2}
  : > "$FAKE/etc/lcars/host-consent"
  : > "$FAKE/usr/local/bin/tofu"
  ln -sf "$FAKE/opt/lcars/x" "$FAKE/usr/local/bin/lcars"
  : > "$FAKE/work/precieux.txt"

  export LCARS_SYSTEM_MANIFEST="$BATS_TEST_TMPDIR/system.manifest"
  cat > "$LCARS_SYSTEM_MANIFEST" <<EOF
# SOURCE: decor
# STATUS: data, not code
dir       $FAKE/opt/lcars                    0755  root:root  any
dir       $FAKE/opt/lcars/tofu/providers     0755  root:root  any
dir       $FAKE/etc/lcars                    0755  root:root  any
anchor    $FAKE/etc/lcars/host-consent       0644  root:root  any
anchor    $FAKE/usr/local/bin/tofu           0755  root:root  any
link      $FAKE/usr/local/bin/lcars          -     -          any
group     decor-groupe-absent                2000  -          any
human     /home/<human>/.lcars-decor         0700  <human>:-  any
preserve  $FAKE/work                         2775  root:fleet any
EOF

  export LCARS_JOURNAL_FILE="$BATS_TEST_TMPDIR/install.journal"
}

journal() { printf 'apt_installed %s\n' "$*" > "$LCARS_JOURNAL_FILE"; }
plan()    { run bash "$RUNNER" uninstall; }
code()    { grep -vE '^\s*#' "$RUNNER"; }

@test "AUCUNE LISTE dans le code — il lit les tables, il ne les recopie pas" {
  # La regle de `etc/install.manifest`, etendue a la machine. Une liste en dur ici serait un SECOND
  # inventaire, et celui qui derive est toujours celui qu'on ne relit pas.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  [ -n "$body" ]
  refute grep -qE '/opt/lcars|/usr/share/lcars|/etc/lcars|/home/private|/var/lib/lcars' <<<"$body"
  grep -q 'MANIFEST_FILE' <<<"$body"
  grep -q 'JOURNAL_FILE' <<<"$body"
}

@test "SANS MANIFESTE : refus net, jamais un repli" {
  # « Un desinstalleur qui devine est plus dangereux qu'un qui s'arrete. » Meme contrat que le temoin
  # de `install.manifest` : manifest absent = erreur, PAS un pass silencieux.
  LCARS_SYSTEM_MANIFEST="/nonexistent/system.manifest" plan
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifeste introuvable"* ]]
}

@test "le PLAN s'imprime, et RIEN n'est retire sans --yes" {
  plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"RIEN N'A ÉTÉ RETIRÉ"* ]]
  # les objets du decor sont tous encore la
  [ -f "$FAKE/etc/lcars/host-consent" ]
  [ -d "$FAKE/opt/lcars" ]
}

@test "SANS JOURNAL : aucun paquet, et la raison est DITE" {
  # Le journal est la seule chose qui distingue ce que LCARS a installe de ce que l'operateur avait
  # deja. Sans lui, retirer serait un pari sur le bien d'autrui.
  rm -f "$LCARS_JOURNAL_FILE"
  plan
  [[ "$output" == *"AUCUN"* ]]
  [[ "$output" == *"journal absent"* ]]
  [[ "$output" == *"impossible de distinguer"* ]]
}

@test "AVEC journal : seuls les paquets QUE LCARS A POSES sont nommes" {
  journal socat jq
  plan
  [[ "$output" == *"socat"* ]]
  [[ "$output" == *"jq"* ]]
}

@test "apt_already n'est JAMAIS repris — c'est le fond du journal" {
  printf 'apt_installed socat\napt_already git curl\n' > "$LCARS_JOURNAL_FILE"
  plan
  [[ "$output" == *"socat"* ]]
  [[ "$output" != *"git"* ]]
  [[ "$output" != *"curl"* ]]
}

@test "preserve : nomme dans le plan, et JAMAIS dans ce qui part" {
  plan
  [[ "$output" == *"$FAKE/work"* ]]
  # il n'est compte ni dans les fichiers ni dans les dirs : 3 dirs de decor, pas 4
  [[ "$output" == *"3 répertoire(s)"* ]]
}

@test "les objets du HOME sont laisses par defaut, et il le DIT" {
  # « L'uninstall peut les PROPOSER, jamais les imposer » — ce sont des objets de travail.
  plan
  [[ "$output" == *"LAISSÉS"* ]]
  [[ "$output" == *"--humans"* ]]
}

@test "l'ORDRE est l'inverse de la pose : le plus profond d'abord" {
  # Un `groupdel` avant les fichiers que le groupe possede echoue ; un `rm` de repertoire avant son
  # contenu, non. L'ordre n'est donc pas une elegance.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  grep -q 'sort -rn' <<<"$body"
  local n_files n_dirs n_groups
  n_files="$(grep -n 'for o in "\${files\[@\]}"' <<<"$body" | cut -d: -f1)"
  n_dirs="$(grep -n 'for o in "\${dirs\[@\]}"' <<<"$body" | cut -d: -f1)"
  n_groups="$(grep -n 'for o in "\${groups\[@\]}"' <<<"$body" | cut -d: -f1)"
  [ "$n_files" -lt "$n_dirs" ]
  [ "$n_dirs" -lt "$n_groups" ]
}

@test "un groupe encore porte par un objet PRESERVE se garde, et ce n'est pas une erreur" {
  # ⚠ REGLE APPRISE A LA MAIN. Les trois faces sont en `2775 root:fleet` : retirer `fleet` les
  # laisserait avec un GID orphelin. `groupdel fleet` a echoue au nettoyage de .63, et c'etait la
  # BONNE reponse. Le verbe doit le DIRE au lieu de le compter comme un ratage.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  grep -q 'gardé — encore porté par un objet préservé' <<<"$body"
  grep -q 'kept=\$((kept + 1))' <<<"$body"
}

@test "root n'est exige que pour RETIRER, jamais pour LIRE le plan" {
  # Refuser la lecture sans root obligerait l'operateur a escalader pour SAVOIR ce qui va
  # disparaitre — c'est-a-dire a decider apres avoir escalade.
  plan
  [ "$status" -eq 0 ]
  code | grep -q 'UNINSTALL_YES" -ne 1 || "\$EUID" -eq 0'
}

@test "le verbe est DECLARE dans le dispatch, sinon il n'existe pas" {
  code | grep -qE 'case "\$CMD" in apply\|doctor\|update\|list\|uninstall\)'
}
