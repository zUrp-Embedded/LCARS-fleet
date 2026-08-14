#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/human_converger.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for docker/human-converger.sh — l'ADMISSION, et elle seule
#
# CE QUI EST EPINGLE, ET POURQUOI CE N'EST PAS DE LA PARANOIA. Ce convergeur cree des users Linux a
# partir de noms choisis par des inconnus sur une page d'inscription ouverte. Les deux alphabets ne
# coincident pas, et c'est MESURE le 2026-08-12 sur l'image et sur Gitea 1.26.1 :
#
#   · `useradd` est BEAUCOUP plus permissif qu'on ne l'imagine — `Bob`, `1bob`, `bob@x`, `bob.`,
#     `bob$` passent tous. Il ne refuse que : > 32 caracteres, un espace, et un `-` initial — et ce
#     dernier ne part meme pas en refus de nom mais en PARSING D'OPTION (`useradd -bob` a rendu
#     « invalid base directory 'ob' »). C'est une injection d'argument, pas une coquille.
#   · Gitea refuse `_bob`, `bob$`, `bob@x`, `-bob`, `bob.`, `bob..x` — mais ACCEPTE `admin`, `b`,
#     `1bob`, et un nom de 33 caracteres que `useradd` refusera.
#
# Le danger n'est donc pas que Linux soit etroit : c'est que la forge laisse passer des noms qui
# COLLISIONNENT avec des comptes systeme, et des noms trop longs pour aboutir. Ces tests sont le
# verrou de cette frontiere. Ils sourcent le script (garde de sourcing) : aucune boucle, aucun
# reseau, aucun user cree.

setup() {
  SUT="$BATS_TEST_DIRNAME/../docker/human-converger.sh"
  export SUT
  [ -f "$SUT" ]
  PASSWD_FILE="$BATS_TEST_TMPDIR/passwd"
  PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  cat > "$PASSWD_FILE" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
sshd:x:100:65534::/run/sshd:/usr/sbin/nologin
lcars:x:1000:1000::/home/lcars:/bin/bash
EOF
  echo "UID_MIN			 1000" > "$PASSWD_DEFS"
  export PASSWD_FILE PASSWD_DEFS
}

# Helper: source the SUT in a fresh shell and run a predicate on <login>.
admits() { # admits <login>  -> exit 0 if the converger would create that user
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS'
    source '$SUT'
    reserved '$1' && exit 1
    valid_login '$1' || exit 1
    exit 0"
}

# ─── le garde de sourcing ───────────────────────────────────────────────────────────────────────

@test "sourcer le convergeur ne lance NI preflight NI boucle (sinon ces tests pendraient)" {
  run bash -c "set -euo pipefail; source '$SUT'; type -t valid_login; type -t reserved"
  [ "$status" -eq 0 ]
  [[ "$output" == *function*function* ]]
}

# ─── ce qui passe ───────────────────────────────────────────────────────────────────────────────

@test "les logins ordinaires passent" {
  for n in bob zoe bob-x bob_x bob.dupont 1bob b Z9; do
    admits "$n"
    [ "$status" -eq 0 ] || { echo "refuse a tort: $n"; return 1; }
  done
}

@test "la casse est conservee VERBATIM — le deck compare preferred_username a /etc/passwd" {
  # Minusculiser ici casserait la jointure : Gitea rend le login tel qu'il a ete saisi, et
  # `Bob` cote forge doit trouver `Bob` cote passwd. (Gitea etant insensible a la casse a
  # l'inscription, deux comptes ne peuvent pas differer que par elle.)
  admits "Bob"
  [ "$status" -eq 0 ]
}

# ─── ce qui est REFUSE, et chaque refus a sa raison mesuree ──────────────────────────────────────

@test "un `-` initial est refuse : useradd le lirait comme une OPTION, pas comme un nom" {
  admits -- "-bob"
  [ "$status" -eq 1 ]
}

@test "les caracteres hors alphabet Gitea sont refuses (useradd, lui, les accepterait)" {
  for n in 'bob$' 'bob@x' '_bob' 'bo b' 'bob;rm' 'bob/x' 'bob*'; do
    admits "$n"
    [ "$status" -eq 1 ] || { echo "accepte a tort: $n"; return 1; }
  done
}

@test "un point final ou double est refuse (Gitea les refuse deja, useradd non)" {
  admits "bob."
  [ "$status" -eq 1 ]
  admits "bob..x"
  [ "$status" -eq 1 ]
}

@test "au-dela de 32 caracteres : Gitea accepte, useradd refuse — on refuse AVANT" {
  admits "$(printf 'a%.0s' $(seq 1 32))"
  [ "$status" -eq 0 ]
  admits "$(printf 'a%.0s' $(seq 1 33))"
  [ "$status" -eq 1 ]
}

@test "un login vide est refuse" {
  admits ""
  [ "$status" -eq 1 ]
}

# ─── les noms reserves : la denylist se CALCULE ──────────────────────────────────────────────────

@test "un compte systeme (uid < UID_MIN) n'est JAMAIS adopte" {
  # `admin` est accepte par Gitea (mesure) ; si un jour l'image porte un compte `admin`, l'adopter
  # lui donnerait un home et un shell fleet. La liste vient de /etc/passwd, pas d'un tableau en dur.
  for n in root daemon sshd; do
    admits "$n"
    [ "$status" -eq 1 ] || { echo "adopte a tort: $n"; return 1; }
  done
}

@test "un humain deja present (uid >= UID_MIN) n'est PAS reserve — il est juste deja converge" {
  admits "lcars"
  [ "$status" -eq 0 ]
}

@test "le compte SYSTEME de la fleet est refuse — il EST membre de la team humans (mesure)" {
  admits "lcars-system"
  [ "$status" -eq 1 ]
}

@test "les comptes de ROLE sont refuses, quelle que soit la casse" {
  for n in fleet_qualifier system_architect FLEET_SCRIBE; do
    admits "$n"
    [ "$status" -eq 1 ] || { echo "adopte a tort: $n"; return 1; }
  done
}

# ─── L'UID EST DURABLE, ET RIEN NE LE GARANTISSAIT ──────────────────────────────────────────────
# Mesure du 2026-08-12, premier boot a froid : `/etc/passwd` meurt avec le conteneur, `/home` survit
# dans un volume. Les users etaient donc recrees dans l'ordre ou la team les rend — pas l'ordre de
# creation initial — et `useradd` redistribuait les uid libres. Resultat : zoe 1001 -> 1002, guest1
# 1002 -> 1001, et chacune proprietaire du home de l'AUTRE. Pas un desagrement : un `~/.lcars` 0700
# et un `.claude/.credentials.json` lisibles par la mauvaise personne.

@test "un home existant IMPOSE son uid — le chemin fait foi, pas l'ordre d'iteration" {
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes'
    mkdir -p \"\$LCARS_HOME_ROOT/zoe\"
    source '$SUT'
    uid_of_home zoe"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ⚠ TITRE CORRIGE LE 2026-08-14. Il disait « pas de home = pas de contrainte : l'OS choisit ». Son
# ASSERTION est restee vraie — `uid_of_home` rend bien le vide sur un home absent — mais sa
# CONCLUSION est devenue fausse : l'appelant ne laisse plus l'OS choisir, il demande a la forge.
# Un test dont le titre decrit une consequence disparue se lit comme un contrat, et c'est le titre
# qu'on lit dans une sortie de suite, pas le corps.
@test "sans home, uid_of_home ne rend RIEN — il ne devine pas" {
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes'
    mkdir -p \"\$LCARS_HOME_ROOT\"
    source '$SUT'
    echo \"[\$(uid_of_home jamaisvue)]\""
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# ─── L'UID VIENT DE LA FORGE SUR UNE BOITE NEUVE ──────────────────────
# `uid_of_home` repare APRES COUP : il relit l'uid sur un home qui a survecu. Sur une boite neuve il
# n'y a aucun home, et `useradd` distribuait alors les uid libres dans l'ordre ou la team les rend —
# un ordre qui n'a aucune raison d'etre stable d'un boot a l'autre. L'identifiant de la forge, lui,
# est un auto-increment SQL : lineaire, dense, JAMAIS reutilise apres suppression.

@test "6-surface: sans home, l'uid vient de la FORGE (id + offset)" {
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes'
    mkdir -p \"\$LCARS_HOME_ROOT\"
    source '$SUT'
    uid_wanted nouvelle 3"
  [ "$status" -eq 0 ]
  [ "$output" = "1003" ]
}

@test "6-surface: un home existant GAGNE sur la forge — le disque fait foi sur ce qui est ecrit" {
  # LA PRIORITE QUI COMPTE. Si la forge dit 1003 et que le home appartient a un autre uid, prendre
  # celui de la forge rend la personne incapable d'ecrire chez elle : c'est le defaut du 2026-08-12,
  # remis a l'endroit. La forge fait autorite sur QUI EST LA ; le disque sur ce qui est deja ecrit.
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes'
    mkdir -p \"\$LCARS_HOME_ROOT/zoe\"
    source '$SUT'
    home_uid=\$(uid_of_home zoe)
    got=\$(uid_wanted zoe 999)
    [ \"\$got\" = \"\$home_uid\" ] || { echo \"forge a gagne: \$got != \$home_uid\"; exit 1; }
    echo ok"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "6-surface: sans home ET sans id de forge, on ne pose RIEN — l'OS choisit, et c'est dit" {
  # Le mode degrade existe : une forge qui ne rend pas d'`id` (charge tronquee, version future).
  # On ne fabrique pas un uid a partir de rien — on laisse `useradd` faire, comme avant, plutot que
  # d'inventer un numero qui aurait l'air autoritaire.
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes'
    mkdir -p \"\$LCARS_HOME_ROOT\"
    source '$SUT'
    echo \"[\$(uid_wanted sansid '')][\$(uid_wanted sansid 'abc')]\""
  [ "$status" -eq 0 ]
  [ "$output" = "[][]" ]
}

@test "6-surface: l'offset n'est pas cosmetique — un id de forge brut serait un compte SYSTEME" {
  # UID_MIN vaut 1000 : l'id 3 de la forge, pose tel quel, tomberait sur `sync` ou `lp`. L'offset
  # est ce qui fait d'un identifiant de forge un siege d'humain.
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes'
    mkdir -p \"\$LCARS_HOME_ROOT\"
    source '$SUT'
    got=\$(uid_wanted quiconque 3)
    min=\$(uid_min)
    [ \"\$got\" -ge \"\$min\" ] || { echo \"uid \$got sous UID_MIN \$min\"; exit 1; }
    echo ok"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "l'uid revendique est-il deja pris par QUELQU'UN D'AUTRE ?" {
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE'
    source '$SUT'
    echo \"lcars-sur-1000=[\$(uid_taken_by 1000 autre)]\"
    echo \"lui-meme=[\$(uid_taken_by 1000 lcars)]\"
    echo \"libre=[\$(uid_taken_by 4242 qui)]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"lcars-sur-1000=[lcars]"* ]]
  # Un uid porte par le login LUI-MEME n'est pas un conflit : c'est la convergence deja faite.
  [[ "$output" == *"lui-meme=[]"* ]]
  [[ "$output" == *"libre=[]"* ]]
}

# ─── fail-closed a l'execution ──────────────────────────────────────────────────────────────────

@test "sans FORGE_BASE_URL : exit 2 et un message, jamais une boucle muette" {
  run env -u FORGE_BASE_URL bash "$SUT" --once
  [ "$status" -eq 2 ]
  [[ "$output" == *"FORGE_BASE_URL"* ]]
}

@test "token systeme illisible : exit 2, et le message nomme le fichier" {
  run env FORGE_BASE_URL=http://forge:3000 FORGE_TOKEN_FILE=/nope/nothing bash "$SUT" --once
  [ "$status" -eq 2 ]
  [[ "$output" == *"/nope/nothing"* ]]
}

# ─── la revocation : QUI, jamais COMMENT ────────────────────────────────────────────────────────
#
# Seule la DECISION est epinglee ici (`converged_humans`, `absent_humans`). Le geste
# (`revoke_human`) touche gpasswd/pkill/usermod : il n'a rien a faire dans une suite de tests, et
# c'est precisement pour ca que la selection en est separee. Ce qui coupe l'acces de quelqu'un doit
# etre lisible sans lancer quoi que ce soit.

# Un groupe fleet injectable, meme idiome que PASSWD_FILE.
group_fixture() { # group_fixture <membres,separes,par,virgule>
  GROUP_FILE="$BATS_TEST_TMPDIR/group"
  printf 'fleet:x:2000:%s\n' "$1" > "$GROUP_FILE"
  printf 'sudo:x:27:root\n' >> "$GROUP_FILE"
  export GROUP_FILE
}

# Un passwd ou tout le monde existe, avec des uid d'humains sauf `svc` (compte systeme infiltre).
passwd_fixture() {
  cat > "$PASSWD_FILE" <<'EOF'
root:x:0:0:root:/root:/bin/bash
svc:x:120:120::/nonexistent:/usr/sbin/nologin
lcars:x:1000:1000::/home/lcars:/bin/bash
alice:x:1001:1001::/home/alice:/bin/bash
bob:x:1002:1002::/home/bob:/bin/bash
carol:x:1003:1003::/home/carol:/usr/sbin/nologin
EOF
}

converged() { # converged -> la liste calculee
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' GROUP_FILE='$GROUP_FILE'
    source '$SUT'
    converged_humans"
}

absent() { # absent <membres de la team…>
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' GROUP_FILE='$GROUP_FILE'
    source '$SUT'
    absent_humans $*"
}

@test "l'humain de BOOTSTRAP n'est jamais un converge — l'entrypoint le cree, pas la team" {
  passwd_fixture; group_fixture "lcars,alice,bob"
  converged
  [ "$status" -eq 0 ]
  [[ "$output" != *"lcars"* ]]
  [[ "$output" == *"alice"* ]]
  [[ "$output" == *"bob"* ]]
}

@test "un compte SYSTEME infiltre dans le groupe n'est pas un humain converge (uid < UID_MIN)" {
  passwd_fixture; group_fixture "alice,svc"
  converged
  [ "$status" -eq 0 ]
  [[ "$output" != *"svc"* ]]
  [[ "$output" == *"alice"* ]]
}

@test "SANS ARGUMENT, absent_humans ne designe PERSONNE — une liste vide n'est pas une purge" {
  passwd_fixture; group_fixture "alice,bob,carol"
  absent
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "seuls les sortis de la team sont designes — ceux qui y sont restent intouches" {
  passwd_fixture; group_fixture "alice,bob,carol"
  absent alice
  [ "$status" -eq 0 ]
  [[ "$output" != *"alice"* ]]
  [[ "$output" == *"bob"* ]]
  [[ "$output" == *"carol"* ]]
}

@test "toute la team encore la : rien a revoquer" {
  passwd_fixture; group_fixture "alice,bob"
  absent alice bob lcars-system
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ⚠ CES DEUX-LA COUVRENT LE RACCORD, PAS LA FONCTION. Tous les tests ci-dessus appellent
# `absent_humans` avec des logins deja nus — ils restaient verts pendant qu'un humain etait revoque
# puis reintegre toutes les 30 s sur le banc, parce que l'APPELANT lui passait la charge brute de la
# forge. Un test qui fabrique lui-meme la bonne forme d'entree ne peut pas voir une entree mal
# formee. Ce qui se mesure ici est donc la conversion REELLE, `roster_of`, et ce qu'elle donne a
# manger a la decision.

@test "6-surface: roster_of ne rend que les logins — la charge de la forge porte l'id devant" {
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' GROUP_FILE='$GROUP_FILE'
    source '$SUT'
    printf '15\talice\n3\tbob\n' | roster_of"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "alice" ]
  [ "${lines[1]}" = "bob" ]
}

@test "6-surface: la charge de la forge traverse jusqu'a la revocation SANS designer personne" {
  passwd_fixture; group_fixture "alice,bob"
  # alice et bob sont dans le groupe ET dans la team. Personne ne doit etre coupe. Avec la charge
  # brute en roster, `absent_humans` ne retrouvait aucun login et les designait TOUS LES DEUX.
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' GROUP_FILE='$GROUP_FILE'
    source '$SUT'
    mapfile -t roster < <(printf '1001\talice\n1002\tbob\n' | roster_of)
    absent_humans \"\${roster[@]}\""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "6-surface: et un sorti de la team reste designe — le raccord n'aveugle pas la revocation" {
  passwd_fixture; group_fixture "alice,bob,carol"
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' GROUP_FILE='$GROUP_FILE'
    source '$SUT'
    mapfile -t roster < <(printf '1001\talice\n' | roster_of)
    absent_humans \"\${roster[@]}\""
  [ "$status" -eq 0 ]
  [[ "$output" != *"alice"* ]]
  [[ "$output" == *"bob"* ]]
  [[ "$output" == *"carol"* ]]
}

@test "un membre de la team qui n'est PAS sur cette boite ne fait rien revoquer" {
  passwd_fixture; group_fixture "alice"
  absent alice dave erin
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
