#!/usr/bin/env bats
# SOURCE: runtime/test/services/human.d/human_converger.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for services/human-converger.sh — l'ADMISSION, et elle seule
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

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

load ../../support/refute

setup() {
  SUT="$BATS_TEST_DIRNAME/../../../services/human-converger.sh"
  export SUT
  [ -f "$SUT" ]
  PASSWD_FILE="$BATS_TEST_TMPDIR/passwd"
  PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  cat > "$PASSWD_FILE" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
sshd:x:100:65534::/run/sshd:/usr/sbin/nologin
lcars:x:1000:1000::/home/lcars:/bin/bash
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF
  # Les DEUX bornes, comme tout login.defs reel : la regle du protocole les exige toutes deux
  # (2026-09-05), et un fichier qui n'en porte qu'une n'etablit pas la frontiere — rien n'est admis.
  printf 'UID_MIN\t\t\t 1000\nUID_MAX\t\t\t 60000\n' > "$PASSWD_DEFS"
  export PASSWD_FILE PASSWD_DEFS
  # Le protocole de module (source par le protocole des humains) lit `forge.url` sous
  # LCARS_PRIVATE_DIR : celui du decor, jamais celui de la machine.
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/tokens"

  # ⚠ LE TROISIEME SEAM, ET SANS LUI LA PREMISSE DE CE FICHIER APPARTIENT A LA MACHINE. Le SUT
  # resout le siege par FICHIER D'ABORD (`/etc/lcars/seat.uid`), `LCARS_SYSADMIN_UID` seulement en
  # second — c'est voulu, c'est GUARD B : la variable appartient au processus garde, donc elle ne
  # decide pas de sa borne. Consequence pour un temoin : sur une machine PROVISIONNEE, le fichier
  # existe, il gagne, et les `LCARS_SYSADMIN_UID=…` que ces tests posent ne sont plus lus du tout.
  #
  # MESURE DU 2026-08-27 : avec un siege etabli a 1001, SEPT temoins de ce fichier rougissent sur du
  # code juste — les deux GUARD A, l'ecart des comptes systeme, et le plancher d'uid. Ils sont verts
  # sur ce poste de dev pour une seule raison : `/etc/lcars/seat.uid` n'y existe pas. Un temoin dont
  # le verdict depend de qui le lance n'atteste rien.
  #
  # On pointe le seam vers un chemin QUI N'EXISTE PAS, et c'est le geste juste plutot que d'y ecrire
  # 1000 : chaque test declare SON siege via `LCARS_SYSADMIN_UID` (1000, 1237, et deux valeurs
  # malformees pour le garde d'arithmetique). Fermer le canal fichier rend leur declaration
  # effective ; y poser une valeur les ecraserait toutes par une seule.
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/aucun-siege-pose/seat.uid"

  # ⚠ LE QUATRIEME SEAM : LE ROSTER DE ROLES VIENT DU PRODUIT (⚖ decision 2). Le SUT ne porte plus
  # de liste ecrite a la main — il la demande au release (`lcars tool roles`) — et un roster
  # ILLISIBLE lui fait reserver TOUT nom, par la meme doctrine que les bornes d'uid. Sans cette
  # CLI de banc, ce fichier ne mesurerait plus l'admission mais le refus global : tous ses temoins
  # « passe » rougiraient sur du code juste. La liste est celle que ses propres cas attendent.
  cat > "$BATS_TEST_TMPDIR/lcars" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == tool && "$2" == roles ]] || exit 64
printf '%s\n' system_architect system_chief system_gatekeeper fleet_engineer fleet_scribe \
              fleet_qualifier fleet_reviewer fleet_scoper fleet_vulcan
EOF
  chmod +x "$BATS_TEST_TMPDIR/lcars"
  export LCARS_CLI="$BATS_TEST_TMPDIR/lcars"
}

# Helper: source the SUT in a fresh shell and run a predicate on <login>.
admits() { # admits <login>  -> exit 0 if the converger would create that user
  # ⚠ `cmd; echo $?` NE MARCHE PAS SOUS `set -e` : un rc non-nul tue le shell AVANT l'echo, donc
  # les cas « prouve non-admin » et « pas su lire » — c'est-a-dire tout ce qui compte — ne
  # rendaient rien. `|| rc=$?` fait de l'appel une condition, l'exception que `set -e` prevoit.
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI'
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

@test "un \`-\` initial est refuse : useradd le lirait comme une OPTION, pas comme un nom" {
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

@test "nobody (uid 65534, AU-DESSUS de UID_MAX) est reserve — la regle a deux bornes, pas une" {
  # Il est sur toute machine, superieur a UID_MIN et different du siege : la regle basse seule
  # l'adopterait, et un `nobody` inscrit sur la forge recevrait un home et un shell fleet.
  admits "nobody"
  [ "$status" -eq 1 ]
}

@test "bornes ILLISIBLES : TOUT nom est reserve — on ne cree personne sur une frontiere devinee" {
  # Fail-closed (⚖ user 2026-09-05) : le convergeur devinait 1000 (`uid_min() … || echo 1000`), a
  # contre-sens du BEAM qui refuse de booter dans ce cas. Le remede est dit, et il nomme le fichier.
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/nulle-part/login.defs"
  admits "zoe"
  [ "$status" -eq 1 ]
  [[ "$output" == *"n'est pas etablie"* ]]
  [[ "$output" == *"repare $PASSWD_DEFS"* ]]
}

@test "le compte SYSTEME de la fleet est refuse — il EST membre de la team humans (mesure)" {
  admits "system_starfleet"
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
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes'
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
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes'
    mkdir -p \"\$LCARS_HOME_ROOT\"
    source '$SUT'
    echo \"[\$(uid_of_home jamaisvue)]\""
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# ─── L'UID VIENT DE LA FORGE SUR UN CONTENEUR NEUF ──────────────────────
# `uid_of_home` repare APRES COUP : il relit l'uid sur un home qui a survecu. Sur un conteneur neuf il
# n'y a aucun home, et `useradd` distribuait alors les uid libres dans l'ordre ou la team les rend —
# un ordre qui n'a aucune raison d'etre stable d'un boot a l'autre. L'identifiant de la forge, lui,
# est un auto-increment SQL : lineaire, dense, JAMAIS reutilise apres suppression.

@test "D8: sans home ET sans table, RIEN n'est derive de l'id de forge — le premier libre, pas un calcul" {
  # ⚖ USER 2026-08-21 (D8). La derivation `id_forge + 1000` tenait sur une hypothese vraie dans un
  # conteneur fabrique pour LCARS et fausse ailleurs : que l'espace d'uid soit libre. Mesure du meme
  # jour, poste natif : `admiral` (id 1) revendiquait 1001, deja porte par `lcars` — refus sans
  # recours sur une machine ou rien n'etait casse.
  #
  # ⚠ CE TEMOIN EXIGEAIT LE VIDE, ET LE VIDE EST DEVENU LE DEFAUT. Il epinglait « on ne revendique
  # rien, `useradd` prend le premier libre » — vrai tant que le SEUL createur d'humains etait
  # `22-fleet-human`, qui portait le plancher. Depuis que ce module a cesse de creer (2026-08-25), le
  # « premier libre » de `useradd` part de `UID_MIN` et peut donc rendre l'uid RESERVE du siege.
  #
  # CE QUE D8 A DECIDE RESTE INTACT : aucune ARITHMETIQUE sur l'id de forge. Ce qui change est QUI
  # cherche le premier uid libre — nous, avec le plancher, au lieu de `useradd`, sans. Le temoin
  # epingle donc les deux moities : pas de derivation, et jamais l'uid du siege.
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes'
    export LCARS_UID_MAP_FILE='$BATS_TEST_TMPDIR/uid.map' LCARS_SYSADMIN_UID=1000
    mkdir -p \"\$LCARS_HOME_ROOT\"
    # \`getent\` double : sans ca ce temoin rend un uid libre de la MACHINE qui le joue.
    mkdir -p \"$BATS_TEST_TMPDIR/b8\"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 2' > \"$BATS_TEST_TMPDIR/b8/getent\"
    chmod 0755 \"$BATS_TEST_TMPDIR/b8/getent\"
    PATH=\"$BATS_TEST_TMPDIR/b8:\$PATH\"
    source '$SUT'
    echo \"[\$(uid_wanted nouvelle 3)]\""
  [ "$status" -eq 0 ]
  # Le premier libre au-dessus du siege (1000), et surtout PAS 3 + 1000 : la formule est morte.
  [ "$output" = "[1001]" ]
}

@test "D8: la TABLE remplace la formule — un id deja vu rend SON uid, pas un calcul" {
  # Ce que la derivation achetait — « deux conteneurs reconstruits donnent le meme uid a la meme
  # personne » — n'a jamais eu besoin d'etre une formule. La table le rend, et elle est keyee sur
  # l'ID de forge, pas sur le nom : Gitea conserve l'id au renommage.
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes'
    export LCARS_UID_MAP_FILE='$BATS_TEST_TMPDIR/uid.map'
    mkdir -p \"\$LCARS_HOME_ROOT\"
    printf '7\t1042\tancien_nom\n' > \"\$LCARS_UID_MAP_FILE\"
    source '$SUT'
    echo \"[\$(uid_wanted nouveau_nom 7)]\""
  [ "$status" -eq 0 ]
  [ "$output" = "[1042]" ]
}

@test "D8: la table s'ecrit APRES coup, et le PREMIER enregistrement fait foi" {
  # Ecrire d'avance reconstruirait une formule avec une etape de plus ; re-ecrire ferait perdre le
  # couple qui correspond au home REELLEMENT pose sur le disque.
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes'
    export LCARS_UID_MAP_FILE='$BATS_TEST_TMPDIR/uid2.map' GROUP='$(id -gn)'
    source '$SUT'
    uid_map_record 12 1012 zoe
    uid_map_record 12 9999 zoe_renommee
    cat \"\$LCARS_UID_MAP_FILE\""
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | wc -l)" -eq 0 ]
  [[ "$output" == "12	1012	zoe" ]]
}

@test "6-surface: un home existant GAGNE sur la forge — le disque fait foi sur ce qui est ecrit" {
  # LA PRIORITE QUI COMPTE. Si la forge dit 1003 et que le home appartient a un autre uid, prendre
  # celui de la forge rend la personne incapable d'ecrire chez elle : c'est le defaut du 2026-08-12,
  # remis a l'endroit. La forge fait autorite sur QUI EST LA ; le disque sur ce qui est deja ecrit.
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes'
    mkdir -p \"\$LCARS_HOME_ROOT/zoe\"
    source '$SUT'
    home_uid=\$(uid_of_home zoe)
    got=\$(uid_wanted zoe 999)
    [ \"\$got\" = \"\$home_uid\" ] || { echo \"forge a gagne: \$got != \$home_uid\"; exit 1; }
    echo ok"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "6-surface: un id de forge ILLISIBLE ne fabrique rien — meme reponse que pas d'id du tout" {
  # Le mode degrade existe : une forge qui ne rend pas d'`id` (charge tronquee, version future). On
  # n'invente pas un numero qui aurait l'air autoritaire — mais on ne renvoie plus le vide non plus,
  # parce que le vide rendait la main a `useradd`, qui n'a pas le plancher du siege (cf. D8 ci-dessus).
  #
  # LES DEUX FORMES DEGRADEES DOIVENT DONNER LA MEME REPONSE. Un `id` vide et un `id` non numerique
  # sont le meme etat — « la forge n'a rien dit d'exploitable » — et deux chemins pour un etat sont
  # un chemin de trop.
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes'
    export LCARS_SYSADMIN_UID=1000
    mkdir -p \"\$LCARS_HOME_ROOT\"
    mkdir -p \"$BATS_TEST_TMPDIR/b6\"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 2' > \"$BATS_TEST_TMPDIR/b6/getent\"
    chmod 0755 \"$BATS_TEST_TMPDIR/b6/getent\"
    PATH=\"$BATS_TEST_TMPDIR/b6:\$PATH\"
    source '$SUT'
    echo \"[\$(uid_wanted sansid '')][\$(uid_wanted sansid 'abc')]\""
  [ "$status" -eq 0 ]
  [ "$output" = "[1001][1001]" ]
}

@test "D8: plus AUCUNE arithmetique d'uid dans le convergeur — la formule est morte, pas commentee" {
  # Le motif de la disparition doit rester lisible, mais un `UID_OFFSET` encore CALCULE quelque part
  # serait une seconde regle silencieuse. On epingle l'absence du calcul, pas celle du mot.
  # ⚠ CETTE PREMIERE ASSERTION ETAIT INERTE, ET UNE MUTATION L'A DEMASQUEE : en reinjectant
  # `$(( UID_OFFSET + 1000 ))` dans le convergeur, ce test restait VERT. Bash exempte de `set -e`
  # toute commande niee par `!` ; une `! grep` qui n'est pas la DERNIERE instruction s'execute,
  # echoue, et rien ne le remarque. Les deux conditions sont distinctes, donc les deux doivent
  # mordre — d'ou la forme `run` + test nu, qui ne peut pas mentir quel que soit son rang.
  run bash -c "sed 's/#.*//' '$SUT' | grep -cE '[\$]\(\(.*(UID_OFFSET|forge_id).*\)\)' || true"
  [ "$output" -eq 0 ]
  run bash -c "sed 's/#.*//' '$SUT' | grep -cE '^UID_OFFSET=' || true"
  [ "$output" -eq 0 ]
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

# ─── le tour entier, sur une frontiere illisible ────────────────────────────────────────────────
#
# `converge_once` est definie APRES le garde de sourcing : on l'EXTRAIT (meme idiome que
# `converge_with`), avec une team {zoe} et des doublures pour tout ce qui touche la machine. Ce qui
# se mesure est la DECISION du tour : cree-t-il, et que dit-il.
once_with() { # once_with <script> — source le convergeur + converge_once extrait, joue <script>
  local fn="$BATS_TEST_TMPDIR/once.sh"
  sed -n '/^converge_once() {/,/^}/p' "$SUT" > "$fn"
  [ -s "$fn" ] || { echo "converge_once introuvable dans $SUT" >&2; return 1; }
  GESTES="$BATS_TEST_TMPDIR/gestes.log"; : > "$GESTES"
  mkdir -p "$BATS_TEST_TMPDIR/homes"
  run bash -c "
    set -uo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' LCARS_SYSADMIN_UID=1000
    export LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes' LCARS_UID_MAP_FILE='$BATS_TEST_TMPDIR/uid.map'
    export LCARS_CONVERGER_REFUSED='$BATS_TEST_TMPDIR/refused' LCARS_CONSOLE=0
    source '$SUT'
    team_id() { echo 7; }
    api() { printf '[{\"id\":3,\"login\":\"zoe\"}]'; }
    id() { return 1; }
    getent() { case \"\$1\" in passwd) [[ \"\$2\" == 1000 ]] ;; group) echo 'fleet:x:2000:' ;; esac; }
    useradd() { echo \"USERADD \$*\" >> '$GESTES'; }
    usermod() { :; }
    converge_human() { echo \"CONVERGE \$1\" >> '$GESTES'; }
    revoke_absent() { :; }; reconcile_humans() { :; }; ensure_all_consoles() { :; }
    source '$fn'
    $1"
}

@test "TEMOIN : un tour nominal CREE zoe au premier uid libre au-dessus du siege — le harnais atteint useradd" {
  # Sans ce temoin, celui d'a cote pourrait etre vert parce que le decor n'atteint jamais useradd.
  once_with 'converge_once'
  [ "$status" -eq 0 ]
  grep -q '^USERADD -u 1001 -m -s /bin/bash -- zoe$' "$GESTES"
  grep -q '^CONVERGE zoe$' "$GESTES"
}

@test "bornes ILLISIBLES : le tour ne converge PERSONNE, et le dit UNE FOIS PAR TOUR — pas une fois par membre, pas en silence" {
  # ⚖ user 2026-09-05 : le convergeur « s'en tamponnait » — trois replis sur 1000 dans sa copie
  # privee de la regle. Il applique maintenant celle du protocole : sans frontiere etablie, rien
  # n'est cree, restaure ni revoque, et chaque tour le dit une fois, avec le remede.
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/nulle-part/login.defs"
  once_with 'converge_once; converge_once'
  [ "$status" -eq 0 ]
  [ ! -s "$GESTES" ]
  [ "$(grep -c 'rien converge ce tour' <<<"$output")" -eq 2 ]
  [[ "$output" == *"n'est pas etablie"* ]]
  [[ "$output" == *"repare $PASSWD_DEFS"* ]]
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
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' GROUP_FILE='$GROUP_FILE'
    # ⚠ 1000 EN DUR, ET C'ETAIT '\${LCARS_SYSADMIN_UID:-1000}'. Le repli lisait l'environnement du
    # LANCEUR : un operateur qui exporte cette variable pour tout autre motif retunait la premisse
    # des deux GUARD A sans le savoir. Mesure : \`LCARS_SYSADMIN_UID=1001\` a l'appel de la suite,
    # trois temoins rouges. Un temoin declare sa premisse, il ne la recoit pas.
    export LCARS_SYSADMIN_UID=1000
    source '$SUT'
    converged_humans"
}

absent() { # absent <membres de la team…>
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' GROUP_FILE='$GROUP_FILE'
    source '$SUT'
    absent_humans $*"
}

@test "GUARD A : l'uid 1000 (admiral/sysadmin) n'est jamais un converge — garde dur keye sur l'UID, pas le login" {
  # lcars est a l'uid 1000 dans la fixture -> exclu par le garde uid (jamais candidat a revocation).
  passwd_fixture; group_fixture "lcars,alice,bob"
  converged
  [ "$status" -eq 0 ]
  [[ "$output" != *"lcars"* ]]
  [[ "$output" == *"alice"* ]]
  [[ "$output" == *"bob"* ]]
}

@test "GUARD A : le garde protege l'UID 1000 quel que soit le login, et n'epargne plus un login par son nom" {
  # uid 1000 = admiral (PAS lcars) -> exclu (le garde keye sur l'uid). Un login 'lcars' a l'uid 1005
  # n'est PLUS specialement protege : il converge comme un worker ordinaire. Preuve : uid-based, pas login-based.
  cat > "$PASSWD_FILE" <<'EOF'
root:x:0:0:root:/root:/bin/bash
admiral:x:1000:1000::/home/admiral:/bin/bash
lcars:x:1005:1005::/home/lcars:/bin/bash
alice:x:1001:1001::/home/alice:/bin/bash
EOF
  group_fixture "admiral,lcars,alice"
  converged
  [ "$status" -eq 0 ]
  [[ "$output" != *"admiral"* ]]
  [[ "$output" == *"lcars"* ]]
  [[ "$output" == *"alice"* ]]
}

@test "un compte SYSTEME infiltre dans le groupe n'est pas un humain converge (uid < UID_MIN)" {
  passwd_fixture; group_fixture "alice,svc"
  converged
  [ "$status" -eq 0 ]
  [[ "$output" != *"svc"* ]]
  [[ "$output" == *"alice"* ]]
}

@test "un compte AU-DESSUS de UID_MAX infiltre dans le groupe n'est pas un humain converge non plus" {
  passwd_fixture
  printf 'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n' >> "$PASSWD_FILE"
  group_fixture "alice,nobody"
  converged
  [ "$status" -eq 0 ]
  [[ "$output" != *"nobody"* ]]
  [[ "$output" == *"alice"* ]]
}

@test "bornes ILLISIBLES : converged_humans ne designe PERSONNE — une liste devinee serait une purge" {
  # `absent_humans` revoque ce que `converged_humans` designe et que la team ne nomme plus. Sur une
  # frontiere devinee, la liste serait une purge de comptes qu'on ne sait pas classer.
  passwd_fixture; group_fixture "alice,bob"
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/nulle-part/login.defs"
  converged
  [ "$status" -eq 0 ]
  [[ "$output" != *"alice"* ]]
  [[ "$output" != *"bob"* ]]
  [[ "$output" == *"n'est pas etablie"* ]]
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
  absent alice bob system_starfleet
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
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' GROUP_FILE='$GROUP_FILE'
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
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' GROUP_FILE='$GROUP_FILE'
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
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' GROUP_FILE='$GROUP_FILE'
    source '$SUT'
    mapfile -t roster < <(printf '1001\talice\n' | roster_of)
    absent_humans \"\${roster[@]}\""
  [ "$status" -eq 0 ]
  [[ "$output" != *"alice"* ]]
  [[ "$output" == *"bob"* ]]
  [[ "$output" == *"carol"* ]]
}

@test "un membre de la team qui n'est PAS sur ce conteneur ne fait rien revoquer" {
  passwd_fixture; group_fixture "alice"
  absent alice dave erin
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ─── LE GESTE REFUSE SUR UN COMPTE D'ADMINISTRATION DE LA MACHINE ───────────────────────────────
#
# Mesure sur banc (2026-09-14) : un compte de test membre de `sudo`, absent de la forge, mis dans
# fleet par une passe de l'installeur, a ete revoque par le convergeur — shell nologin. La selection
# ci-dessus le designe, et c'est juste : il est dans fleet et pas dans la team. C'est le GESTE qui
# refuse. `revoke_absent` est extrait (il vit apres le garde de sourcing) et `revoke_human`, qui
# touche gpasswd/pkill/usermod, est double : ce qui se mesure est QUI serait revoque et ce qui est dit.
#
# Le `sudo` du decor n'accepte qu'UNE forme, `-n -l -U <login> /bin/sh` sous `LC_ALL=C` : toute autre
# est consignee dans SUDO_FORMES et rend 64, et chaque temoin exige ce journal vide. Il repond
# ensuite selon SUDO_TABLE (`login:rc`, rc du vrai sudo mesure dans l'image, sudo 1.9.17p2 : groupe
# sudo et `ALL=(ALL) ALL` rendent 0 ; regle etroite, regle vers un autre compte que root, membre de
# wheel et aucune regle rendent 1). Un login hors de la table rend 1. Il ne lit jamais le seul
# dernier argument : ce serait `/bin/sh` pour tout le monde.
sudo_stub() {
  cat > "$BATS_TEST_TMPDIR/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" -ne 5 || "$1" != -n || "$2" != -l || "$3" != -U || -z "$4" || "$5" != /bin/sh || "${LC_ALL:-}" != C ]]; then
  printf 'LC_ALL=%s %s\n' "${LC_ALL:-}" "$*" >> "$SUDO_FORMES"
  exit 64
fi
for entree in ${SUDO_TABLE:-}; do
  if [[ "${entree%%:*}" == "$4" ]]; then
    [[ "${entree#*:}" == 0 ]] && { echo /bin/sh; exit 0; }
    exit 1
  fi
done
exit 1
EOF
  chmod 0755 "$BATS_TEST_TMPDIR/sudo"
}

revoke_with() { # revoke_with <script> — source le convergeur + revoke_absent extrait, revoke_human double
  local fn="$BATS_TEST_TMPDIR/revoke.sh"
  sed -n '/^revoke_absent() {/,/^}/p' "$SUT" > "$fn"
  [ -s "$fn" ] || { echo "revoke_absent introuvable dans $SUT" >&2; return 1; }
  sudo_stub
  REVOQUES="$BATS_TEST_TMPDIR/revoques.log"; : > "$REVOQUES"
  SUDO_FORMES="$BATS_TEST_TMPDIR/sudo-formes.log"; : > "$SUDO_FORMES"
  run bash -c "
    set -uo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' GROUP_FILE='$GROUP_FILE'
    export LCARS_SYSADMIN_UID=1000 LCARS_SUDO_BIN=\"\${LCARS_SUDO_BIN:-$BATS_TEST_TMPDIR/sudo}\"
    export SUDO_FORMES='$SUDO_FORMES' SUDO_TABLE='${SUDO_TABLE:-}'
    source '$SUT'
    revoke_human() { echo \"REVOKE \$1\" >> '$REVOQUES'; }
    source '$fn'
    $1"
}

@test "revocation: la doublure de sudo refuse toute autre forme que -n -l -U <login> /bin/sh, et repond selon sa table" {
  sudo_stub
  export SUDO_FORMES="$BATS_TEST_TMPDIR/sudo-formes.log" SUDO_TABLE="bob:0 carol:1"; : > "$SUDO_FORMES"
  run env LC_ALL=C "$BATS_TEST_TMPDIR/sudo" -n -l -U bob /bin/sh
  [ "$status" -eq 0 ]
  run env LC_ALL=C "$BATS_TEST_TMPDIR/sudo" -n -l -U carol /bin/sh
  [ "$status" -eq 1 ]
  run env LC_ALL=C "$BATS_TEST_TMPDIR/sudo" -n -l -U dave /bin/sh
  [ "$status" -eq 1 ]
  [ ! -s "$SUDO_FORMES" ]
  run env LC_ALL=C "$BATS_TEST_TMPDIR/sudo" -n -l -U bob
  [ "$status" -eq 64 ]
  run env LC_ALL=C "$BATS_TEST_TMPDIR/sudo" -l -U bob /bin/sh
  [ "$status" -eq 64 ]
  run env LC_ALL=fr_FR.UTF-8 "$BATS_TEST_TMPDIR/sudo" -n -l -U bob /bin/sh
  [ "$status" -eq 64 ]
  [ "$(wc -l < "$SUDO_FORMES")" -eq 3 ]
}

@test "revocation: un compte a qui sudo ouvre un shell root, absent de la team, n'est PAS revoque — refus nomme, une fois par processus" {
  # Le siege d'aujourd'hui est 1000 (GUARD A) ; `bob` (1002) administre la machine, par le groupe
  # sudo ou par une regle a son nom : pour sudo, c'est la meme reponse.
  passwd_fixture; group_fixture "alice,bob,carol"
  SUDO_TABLE="bob:0 carol:1" revoke_with 'revoke_absent alice; revoke_absent alice'
  [ "$status" -eq 0 ]
  [ ! -s "$SUDO_FORMES" ]
  refute grep -qx 'REVOKE bob' "$REVOQUES"
  grep -qx 'REVOKE carol' "$REVOQUES"
  [ "$(grep -c 'REFUS de révoquer bob' <<<"$output")" -eq 1 ]
  [[ "$output" == *"REFUS de révoquer bob — compte d'administration de la machine (sudo lui ouvre un shell root) : absent de lcars/humans, il garde son groupe fleet, son shell et ses processus."*"« sudo gpasswd -d bob fleet » (sur un poste ; dans un conteneur, depuis « deploy/container shell »)"* ]]
}

@test "revocation: une regle sudoers etroite ne sauve pas — le compte est revoque, meme membre de wheel ou d'admin" {
  # carol : `ALL=(root) NOPASSWD: /usr/bin/systemctl …` et membre de wheel ; dave : une regle vers
  # `lcars-authority` et membre d'admin. Aucun des deux n'ouvre de shell root.
  passwd_fixture
  printf 'dave:x:1004:1004::/home/dave:/bin/bash\n' >> "$PASSWD_FILE"
  GROUP_FILE="$BATS_TEST_TMPDIR/group"
  printf 'fleet:x:2000:alice,carol,dave\nwheel:x:10:carol\nadmin:x:11:dave\n' > "$GROUP_FILE"
  SUDO_TABLE="carol:1 dave:1" revoke_with 'revoke_absent alice'
  [ "$status" -eq 0 ]
  [ ! -s "$SUDO_FORMES" ]
  grep -qx 'REVOKE carol' "$REVOQUES"
  grep -qx 'REVOKE dave' "$REVOQUES"
  refute grep -q 'REFUS de' <<<"$output"
}

@test "revocation: sans sudo sur la machine, aucun compte n'est epargne — un membre du groupe sudo est revoque" {
  passwd_fixture
  GROUP_FILE="$BATS_TEST_TMPDIR/group"
  printf 'fleet:x:2000:alice,bob,carol\nsudo:x:27:bob\n' > "$GROUP_FILE"
  LCARS_SUDO_BIN="$BATS_TEST_TMPDIR/aucun-sudo" revoke_with 'revoke_absent alice'
  [ "$status" -eq 0 ]
  grep -qx 'REVOKE bob' "$REVOQUES"
  grep -qx 'REVOKE carol' "$REVOQUES"
  refute grep -q 'REFUS de' <<<"$output"
}

# ─── LE RATTRAPAGE : LE CONVERGEUR SEUL REMET UN HUMAIN DE LA FORGE DANS FLEET ──────────────────
#
# Seul juge de l'appartenance a fleet : il cree, ajoute et revoque d'apres la team. Un humain de la
# team dont le compte existe mais qui a perdu le groupe (ou porte le shell d'un revoque) y est remis
# a chaque tour ; un humain en bonne sante n'est pas touche ; le siege ne l'est jamais (GUARD A).
@test "rattrapage: un humain de la team hors de fleet, ou revoque, est remis dans fleet ; ni un humain sain ni le siege ne sont touches" {
  passwd_fixture; group_fixture "bob,carol"
  local fn="$BATS_TEST_TMPDIR/once.sh"
  sed -n '/^converge_once() {/,/^}/p' "$SUT" > "$fn"
  GESTES="$BATS_TEST_TMPDIR/gestes.log"; : > "$GESTES"
  mkdir -p "$BATS_TEST_TMPDIR/homes"
  run bash -c "
    set -uo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' GROUP_FILE='$GROUP_FILE' LCARS_SYSADMIN_UID=1000
    export LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes' LCARS_UID_MAP_FILE='$BATS_TEST_TMPDIR/uid.map'
    export LCARS_CONVERGER_REFUSED='$BATS_TEST_TMPDIR/refused' LCARS_CONSOLE=0
    source '$SUT'
    team_id() { echo 7; }
    api() { printf '[{\"id\":1,\"login\":\"lcars\"},{\"id\":2,\"login\":\"alice\"},{\"id\":3,\"login\":\"bob\"},{\"id\":4,\"login\":\"carol\"}]'; }
    id() { return 0; }
    useradd() { echo \"USERADD \$*\" >> '$GESTES'; }
    restore_human() { echo \"RESTORE \$1\" >> '$GESTES'; }
    ensure_console() { :; }
    revoke_absent() { :; }; reconcile_humans() { :; }; ensure_all_consoles() { :; }
    source '$fn'
    converge_once"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'RESTORE alice' "$GESTES"
  grep -qx 'RESTORE carol' "$GESTES"
  refute grep -qx 'RESTORE bob' "$GESTES"
  refute grep -qx 'RESTORE lcars' "$GESTES"
  refute grep -q '^USERADD' "$GESTES"
}

# ─── L'ADMINITE N'EST PLUS PROJETEE — SEPT TEMOINS SONT PARTIS AVEC LEUR SUJET ─────────────────
#
# Il y avait ici une sonde `forge_is_admin` et sa passe `converge_admins` : elles lisaient
# `is_admin` sur la forge avec le jeton MASTER et le recopiaient en adhesion a un groupe unix. Sept
# temoins les tenaient, dont la mesure qui avait dicte le design (Gitea 1.26.1 rend `is_admin`
# PRESENT ET FAUX a un lecteur non site-admin, donc un convergeur branche sur le jeton systeme
# aurait demote tout le monde a chaque tour).
#
# ⚠ CETTE MESURE N'EST PAS PERDUE, ELLE A CHANGE DE MAISON. C'est elle qui oblige le credential a
# vivre dans un process qui n'est pas celui de l'humain, et elle est desormais epinglee la ou la
# question se pose : `runtime/test/services/catalogue-executor_test.py`, temoin « interrogee avec le jeton
# master ». Un temoin qui perd son sujet se retire ; une mesure qui garde sa valeur se deplace.
#
# CE QUI RESTE VERIFIE ICI, et c'est le contrat de ce fichier : ce convergeur ne connait plus
# l'adminite du tout.
@test "adminite: le convergeur n'en sait plus RIEN — ni sonde, ni groupe, ni jeton master" {
  # Le fond du chantier : ce fichier fait du PROVISIONNEMENT (un compte unix ne se cree pas au
  # moment ou quelqu'un tape), jamais de l'AUTORISATION (qui se demande a l'instant ou elle compte).
  # Melanger les deux transformait un booleen d'autorisation en cache, et un cache appelle un poll,
  # puis un rattrapage pour les sessions nees avant lui.
  # ⚠ PAS DE `! grep` ICI, ET C'EST UNE CORRECTION MESUREE. Bash EXEMPTE de `set -e` toute commande
  # dont le statut est inverse par `!` : une negation qui n'est pas la DERNIERE instruction du test
  # est donc INERTE — elle s'execute, elle echoue, et rien ne le remarque. Ces cinq assertions
  # etaient inertes a leur premiere ecriture, et une mutation l'a montre. `run` + un test nu est la
  # forme qui ne peut pas mentir.
  # ⚠ ET ON MESURE LE CODE, PAS LA PROSE. La cicatrice qui explique ce retrait NOMME ce qu'elle a
  # retire — c'est son metier, et c'est ce qui evite qu'une prochaine session refasse le geste faute
  # de savoir pourquoi il etait faux. Un instrument qui attrape l'explication interdit d'expliquer.
  local motif
  for motif in forge_is_admin converge_admins ADMIN_GROUP lcars-admin MASTER_TOKEN; do
    run bash -c "sed 's/#.*//' '$SUT' | grep -c -- '$motif' || true"
    [ "$output" -eq 0 ] || { echo "le convergeur nomme encore « $motif » dans son CODE ($output fois)" >&2; return 1; }
  done
  # Le garde d'instrument : une extraction cassee rendrait ces cinq assertions vraies sur du vide.
  grep -q 'TOKEN_FILE=' "$SUT"
}

# ─── UN SEUL JEU DE NOMS POUR LES TROIS FAITS PARTAGES ──────────────────────────────────────────
#
# ⚠ CE TEMOIN EXISTE PARCE QU'IL Y AVAIT DEUX FAMILLES DE VARIABLES. Ce script lisait
# `LCARS_FORGE_ORG` / `LCARS_HUMANS_TEAM` / `LCARS_FLEET_GROUP` pendant que `provision-lib.sh`
# declarait `PROV_*` pour les memes faits — mesure du 2026-08-17 : 59 occurrences
# `PROV_*` sur 13 fichiers contre 5 definitions `LCARS_*` sur 2. Personne ne posait ni l'un ni
# l'autre, donc les DEFAUTS portaient seuls l'accord : poser `LCARS_FORGE_ORG=starfleet` provisionnait
# une org que ce convergeur n'interrogeait jamais, en silence.
#
# CE QUE CE TEMOIN NE PEUT PAS FAIRE, et il faut le dire : ce script ne source pas
# `provision-lib.sh` (il tourne en boucle permanente, pas dans un cycle de provisionnement), donc le
# defaut litteral reste ecrit DEUX FOIS. C'est cette egalite-la qu'on epingle, faute de pouvoir la
# deriver — un test qui compare deux litteraux vaut mieux que deux litteraux que rien ne compare.
@test "les defauts du convergeur sont EXACTEMENT ceux que provision-lib declare" {
  lib="$BATS_TEST_DIRNAME/../../../../deploy/lib/provision-lib.sh"
  # la lib de l'INSTALLEUR declare en PROV_* ; le convergeur (produit) lit en LCARS_* — meme valeur
  for v in PROV_FORGE_ORG:ORG PROV_HUMANS_TEAM:TEAM PROV_FLEET_GROUP:GROUP; do
    prov="${v%%:*}"; local_var="${v##*:}"
    # Meme garde qu'ailleurs : `env -i` pour lire le DEFAUT et pas une surcharge de temoin.
    declared="$(env -i PATH="$PATH" bash -c ". '$lib' >/dev/null 2>&1; printf '%s' \"\${$prov}\"")"
    used="$(bash -c "source '$SUT' 2>/dev/null; printf '%s' \"\${$local_var}\"")"
    [ -n "$declared" ]
    [ "$declared" = "$used" ] || {
      echo "divergence sur $prov : provision-lib='$declared' convergeur='$used'" >&2
      return 1
    }
  done
}

# ─── LA CONSOLE D'UN HUMAIN QUI EXISTE DEJA ─────────────────────────────────────────────────────
#
# ⚠ CES TEMOINS EXISTENT PARCE QUE LE GESTE ETAIT ECRIT DEUX FOIS ET MANQUAIT AU TROISIEME CHEMIN.
# Le convergeur voit un humain de la team dans trois etats : compte Unix absent (`useradd`), compte
# present mais revoque (`restore_human`), compte present et EN BONNE SANTE. Les deux premiers
# demarraient sa console ; le troisieme faisait `continue`.
#
# Mesure du 2026-08-17 sur le banc `lcars-l6` : un compte cree A LA MAIN (uid 1042, groupe `fleet`,
# shell `/bin/bash`) puis ajoute a `lcars:humans` traverse un tour complet EN SILENCE — pas de ligne
# dans le log, pas de repertoire dans `/run/lcars/console/`. Le deck lui affiche alors l'adresse d'un
# terminal qui n'existe pas et le navigateur ecrit « [connexion impossible] ».
#
# ⚠ ET UN REDEMARRAGE LE MASQUE : `console.sh --all` tourne a l'entrypoint, donc au boot suivant tout
# le monde a sa console. Le defaut ne se voit que sur un conteneur VIVANT — c'est-a-dire exactement au
# moment ou un admin enrole quelqu'un. C'est ce qui l'a rendu invisible aussi longtemps.
#
# Le stub de `console.sh` JOURNALISE ses arguments : ce qu'on mesure est « le geste a ete demande
# pour CE login », pas « une commande a tourne ».
console_stub() {
  CONSOLE_LOG="$BATS_TEST_TMPDIR/console.log"
  : > "$CONSOLE_LOG"
  cat > "$BATS_TEST_TMPDIR/console.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CONSOLE_LOG"
EOF
  chmod +x "$BATS_TEST_TMPDIR/console.sh"
  export CONSOLE_LOG
}

ensure_console_for() { # ensure_console_for <login>
  run bash -c "
    set -euo pipefail
    export LCARS_CONSOLE_SH='$BATS_TEST_TMPDIR/console.sh'
    source '$SUT'
    ensure_console '$1'"
}

@test "console: le geste est DEMANDE pour un login, et il nomme ce login" {
  console_stub
  ensure_console_for "zoe"
  [ "$status" -eq 0 ]
  grep -q -- "--human zoe" "$CONSOLE_LOG"
}

@test "console: LCARS_CONSOLE=0 coupe le geste — l'interrupteur vaut pour les trois chemins" {
  console_stub
  run bash -c "
    set -euo pipefail
    export LCARS_CONSOLE=0 LCARS_CONSOLE_SH='$BATS_TEST_TMPDIR/console.sh'
    source '$SUT'
    ensure_console 'zoe'"
  [ "$status" -eq 0 ]
  [ ! -s "$CONSOLE_LOG" ]
}

@test "console: un console.sh en echec NE TUE PAS le convergeur — il le DIT et continue" {
  # Le convergeur tourne en boucle sous `set -e` : une console qui ne demarre pas ne doit pas
  # emporter la convergence des autres humains. ssh reste la porte, et le message le dit.
  cat > "$BATS_TEST_TMPDIR/console.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$BATS_TEST_TMPDIR/console.sh"
  run bash -c "
    set -euo pipefail
    export LCARS_CONSOLE_SH='$BATS_TEST_TMPDIR/console.sh'
    source '$SUT'
    ensure_console 'zoe'
    echo SURVECU"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SURVECU"* ]]
  [[ "$output" == *"sa console n'a pas demarre"* ]]
}

@test "console: LE TROISIEME CHEMIN — les appelants passent tous par la MEME fonction" {
  # Ce qui a produit le defaut est le geste RECOPIE : deux exemplaires, un chemin oublie. Le temoin
  # epingle la forme, pas seulement le comportement — N appels, une fonction.
  #
  # ⚖ 2026-08-21 : le nombre est passe a QUATRE quand la promotion en a ajoute un — ce temoin a
  # attrape l'ajout, ce qui est son metier. Il redescend a TROIS avec le retrait de cette passe : la
  # promotion n'existe plus, donc son appel non plus. Le nombre se corrige DELIBEREMENT, en disant
  # pourquoi ; ce qu'il garde est la forme — N appelants, UNE fonction, aucune copie du geste.
  run grep -c '^\s*ensure_console "\$login"' "$SUT"
  [ "$output" -eq 3 ]

  # Et aucune copie ne subsiste : plus personne n'appelle `$CONSOLE` en direct.
  run grep -c '"\$CONSOLE" --human' "$SUT"
  [ "$output" -eq 1 ]
}


# ─── UN ECHEC DE DAEMON QUI JETTE SA SORTIE EST UN ECHEC QU'ON NE DIAGNOSTIQUE JAMAIS ───────────
#
# `converge_human` portait `>/dev/null 2>&1`. L'appelant disait « le provisioning per-humain a
# echoue — diagnose : provision doctor --human X », et ce doctor, joue PLUS TARD, mesure un etat qui
# a change depuis.
#
# Mesure du 2026-08-21, poste natif : `mintos` cree a 19:35, provisioning per-humain en echec — et
# au moment de le rejouer, il passait (4 modules, 0 drift, 0 echec). L'etat avait bouge sous la
# mesure, et il ne restait RIEN de la panne. Un convergeur tourne toutes les 30 s sans personne
# devant : c'est le seul endroit du depot ou la trace doit survivre a l'evenement.
#
# ⚠ `converge_human` est definie APRES le garde de sourcing (elle appelle le provisioning), donc on
# ne peut pas la sourcer comme `reserved`/`valid_login`. On l'EXTRAIT — meme idiome que l'en-tete
# seule dans `forge_host_reach.bats`.

# ⚠ LA DOUBLURE EST UN MODULE, PLUS UN `provision`. Ce service ne passe plus par l'installeur : il
# joue les modules per-humain lui-meme, depuis `$HUMAN_MODULES`. Le decor a suivi — il posait un
# faux `deploy/provision` et un `modules.d/` a grepper, il pose maintenant le module que le
# convergeur SOURCE. Un decor qui garde la forme de l'ancien chemin mesure un chemin qui n'existe
# plus.
converge_with() { # converge_with <corps du module factice> — joue converge_human contre lui
  local fn="$BATS_TEST_TMPDIR/fn.sh"
  sed -n '/^converge_human() {/,/^}/p' "$SUT" > "$fn"
  [ -s "$fn" ] || { echo "converge_human introuvable dans $SUT" >&2; return 1; }
  local mods="$BATS_TEST_TMPDIR/human.d"
  rm -rf "$mods"; mkdir -p "$mods"
  printf '%s\n' "$1" > "$mods/70-human.sh"
  run bash -c "
    set -uo pipefail
    err() { echo \"[err] \$*\"; }
    HUMAN_MODULES='$mods'
    source '$fn'
    converge_human zoe && echo CONVERGE || echo REFUSE"
}

@test "un echec per-humain LAISSE une trace — les dernieres lignes, pas un renvoi vers plus tard" {
  converge_with 'echo "OK    10-truc: quelque chose"
echo "FAIL  70-human: la panne exacte qu'"'"'on veut lire"
exit 1'
  [[ "$output" == *"REFUSE"* ]]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"la panne exacte qu'on veut lire"* ]]
}

@test "un tour NOMINAL reste muet — deux passes par minute, un journal lisible" {
  converge_with 'echo "OK  tout va bien"
exit 0'
  [[ "$output" == *"CONVERGE"* ]]
  [[ "$output" != *"tout va bien"* ]]
}

@test "le rc 2 reste un SUCCES, et il ne laisse pas de trace non plus" {
  # APPLIQUE avec drift residuel : le cas nominal d'un humain frais, a qui il manque ses credentials
  # `claude` — geste d'identite que personne ne peut automatiser.
  converge_with 'echo "DRIFT  70-human: credentials claude absentes"
exit 2'
  [[ "$output" == *"CONVERGE"* ]]
  [[ "$output" != *"rc=2"* ]]
}

# ─── LE PLANCHER D'UID ──────────────────────────────────────────────────────────────────────────
#
# ⚠ CES CINQ TEMOINS VIENNENT DE `fleet_human.bats`, ET LE DEMENAGEMENT EST LE SUJET. Le plancher
# vivait dans `22-fleet-human`, qui creait le compte du poste ; ce module a cesse de creer le
# 2026-08-25 (un seul createur : la forge nomme, ce convergeur materialise). Le convergeur, LUI,
# n'avait aucun plancher : son cas nominal passe un `uid_args` VIDE, donc `useradd` choisit en
# partant de `UID_MIN` — et rendrait l'uid du siege s'il etait libre, c'est-a-dire exactement le
# compte que GUARD B refuse ensuite de laisser lancer une fleet.
#
# Retirer le createur GARDE en laissant le non-garde aurait elargi le trou au lieu de le fermer. Le
# garde demenage avec le geste ; ses temoins demenagent avec le garde.
#
# La regle mesuree est celle de `is_fleet_human` (le protocole, que ce convergeur source) et de
# GUARD B (`bin/fleet`) : `UID_MIN <= uid <= UID_MAX` ET `uid != LCARS_SYSADMIN_UID` — et sans
# bornes lisibles, RIEN (2026-09-05), jamais un defaut.
floor() { # floor <expr>  → source le convergeur avec le decor, evalue <expr>
  run bash -c "set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI'
    source '$SUT' >/dev/null 2>&1
    $1"
}

@test "plancher: c'est UID_MIN, et rien d'autre — le siege n'est pas un plancher" {
  # Les deux gardes sont ORTHOGONAUX. Partir de `siege + 1` les cumulait : avec un siege a 1237, les
  # uid 1000..1236 devenaient inutilisables alors que les deux gardes les acceptent.
  LCARS_SYSADMIN_UID=1237 floor 'uid_floor'
  [ "$status" -eq 0 ]
  [ "$output" = "1000" ]
}

@test "le siege est un TROU dans la plage : first_free_uid le saute, il ne demarre pas apres" {
  # Le siege ne se devine pas — il vient du fichier ou de la variable — et il ne se franchit pas non
  # plus : c'est un uid reserve au milieu d'une plage qui reste ouverte des deux cotes.
  LCARS_SYSADMIN_UID=1000 floor 'first_free_uid'
  [ "$status" -eq 0 ]
  [ "$output" != "1000" ]
}

@test "plancher: un UID_MIN plus haut que le siege l'emporte — les deux regles valent, pas une" {
  printf 'UID_MIN 5000\nUID_MAX 60000\n' > "$PASSWD_DEFS"
  LCARS_SYSADMIN_UID=1000 floor 'uid_floor'
  [ "$status" -eq 0 ]
  [ "$output" = "5000" ]
}

@test "plancher: login.defs ILLISIBLE ne tue pas le service, et ne rend RIEN — jamais un defaut" {
  # Fail-closed (⚖ user 2026-09-05, la politique du BEAM). Une garde qui s'evanouit sur une lecture
  # ratee est pire que pas de garde : ici l'effet serait un convergeur MORT (`set -e`). Mais un
  # defaut est pire encore : 1000 devine sur une machine dont le plancher reel est ailleurs cree
  # des humains sur des uid systeme. `uid_floor` rend 1 et rien ; l'appelant refuse.
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/absent.defs"
  LCARS_SYSADMIN_UID=1000 floor 'uid_floor && echo "RENDU=[$?]"; echo "RC=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" != *"RENDU"* ]]
  [[ "$output" == *"RC=1"* ]]
  [[ "$output" != *"1000"* ]]
  # Et `first_free_uid` ne part pas de 1 (un plancher vide + 1) : il refuse aussi.
  LCARS_SYSADMIN_UID=1000 floor 'first_free_uid || echo "REFUS=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"REFUS=1"* ]]
  [[ "$output" != *"1001"* ]]
}

@test "plancher: un SYSADMIN_UID non numerique ne fait pas DISPARAITRE le plancher" {
  # ⚠ `m` ETAIT VALIDE, `s` NON — asymetrie dans six lignes ecrites d'un coup. `:-` ne protege que du
  # VIDE. Avec `"10 00"` (un espace au clavier) l'arithmetique de bash rend une erreur de syntaxe ;
  # avec `"abc"`, le contexte arithmetique lit `s` comme un NOM de variable et `set -u` tue le shell.
  #
  # LE CAS QUI MORD EST LE SECOND, dans la BOUCLE du convergeur qui tourne sous `set +e` : la
  # substitution rend vide, `uid_args` reste vide, `useradd` repart de `UID_MIN` — le plancher que ce
  # fichier existe pour poser est contourne en silence. On epingle les deux formes.
  local v
  for v in 'abc' '10 00' '-5' '1e3'; do
    LCARS_SYSADMIN_UID="$v" floor 'uid_floor'
    [ "$status" -eq 0 ] || { echo "uid_floor MORT sur LCARS_SYSADMIN_UID=« $v »"; return 1; }
    [[ "$output" =~ ^[0-9]+$ ]] || { echo "uid_floor rend « $output » sur « $v »"; return 1; }
    [ "$output" -ge 1000 ] || { echo "plancher « $output » sous 1000 sur « $v »"; return 1; }
  done
}

@test "le premier uid LIBRE est cherche au-dessus du plancher, jamais en dessous" {
  # On ne mesure pas contre le /etc/passwd de la machine : `getent` est double, 1001 et 1002 pris.
  # Sinon ce temoin dirait la composition du poste qui le joue.
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "$1" == passwd ]] || exit 2' \
    'case "$2" in 1001|1002) exit 0 ;; *) exit 2 ;; esac' > "$bin/getent"
  chmod 0755 "$bin/getent"
  PATH="$bin:$PATH" LCARS_SYSADMIN_UID=1000 floor 'first_free_uid'
  [ "$status" -eq 0 ]
  [ "$output" = "1003" ]
}

@test "CAS NOMINAL: un humain SANS memoire recoit un uid, pas le choix de useradd" {
  # ⚠ LE TEMOIN QUI FERME REELLEMENT LE TROU. Les quatre precedents mesurent le CALCUL ; celui-ci
  # mesure que `uid_wanted` s'en SERT. Il rendait VIDE dans ce cas — ni home, ni entree dans la
  # table — et `uid_args` restait vide, donc `useradd` choisissait seul depuis UID_MIN. Un plancher
  # correct que personne n'appelle est un plancher absent.
  local bin="$BATS_TEST_TMPDIR/bin2"; mkdir -p "$bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "$1" == passwd ]] || exit 2' \
    'case "$2" in 1001) exit 0 ;; *) exit 2 ;; esac' > "$bin/getent"
  chmod 0755 "$bin/getent"
  # `HOME_ROOT` sur un repertoire vide : l'humain n'a pas de home, donc aucune memoire d'uid.
  PATH="$bin:$PATH" LCARS_SYSADMIN_UID=1000 LCARS_HOME_ROOT="$BATS_TEST_TMPDIR/homes" \
    floor 'uid_wanted inconnu-du-parc ""'
  [ "$status" -eq 0 ]
  [ "$output" = "1002" ]
}

@test "un compte EXISTANT reserve (sshd, uid 100) inscrit sur la forge n'est PAS reintegre — refus nomme, une fois, pas de console" {
  # Trou nomme par le lot 14b : la branche « le compte existe » restaurait sans consulter `reserved`.
  local fn="$BATS_TEST_TMPDIR/once.sh"
  sed -n '/^converge_once() {/,/^}/p' "$SUT" > "$fn"
  GESTES="$BATS_TEST_TMPDIR/gestes.log"; : > "$GESTES"
  mkdir -p "$BATS_TEST_TMPDIR/homes"
  run bash -c "
    set -uo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$LCARS_CLI' LCARS_SYSADMIN_UID=1000
    export LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes' LCARS_UID_MAP_FILE='$BATS_TEST_TMPDIR/uid.map'
    export LCARS_CONVERGER_REFUSED='$BATS_TEST_TMPDIR/refused' LCARS_CONSOLE=0
    source '$SUT'
    team_id() { echo 7; }
    api() { printf '[{\"id\":4,\"login\":\"sshd\"}]'; }
    id() { [[ \"\$*\" == *sshd* ]]; }
    getent() { case \"\$1\" in passwd) [[ \"\$2\" == 1000 ]] ;; group) echo 'fleet:x:2000:' ;; esac; }
    useradd() { echo \"USERADD \$*\" >> '$GESTES'; }
    usermod() { echo \"USERMOD \$*\" >> '$GESTES'; }
    restore_human() { echo \"RESTORE \$1\" >> '$GESTES'; }
    ensure_console() { echo \"CONSOLE \$1\" >> '$GESTES'; }
    converge_human() { echo \"CONVERGE \$1\" >> '$GESTES'; }
    revoke_absent() { :; }; reconcile_humans() { :; }; ensure_all_consoles() { :; }
    source '$fn'
    converge_once; converge_once"
  [ "$status" -eq 0 ]
  [ ! -s "$GESTES" ] || { echo "un geste a ete joue sur sshd :"; cat "$GESTES"; return 1; }
  [ "$(grep -c 'REFUS sshd' <<<"$output")" -eq 1 ]
  [[ "$output" == *"compte EXISTANT reserve"* ]]
  grep -q '^sshd	' "$BATS_TEST_TMPDIR/refused"
}

# Roster ILLISIBLE = « je ne sais pas », pas « tout est interdit » : aucun geste, et surtout aucun
# REFUS publie au deck sous une fausse raison — il y resterait jusqu'au reboot.
_passe_alice() { # _passe_alice <LCARS_CLI au source> <LCARS_CLI au 2e tour> -> run
  local fn="$BATS_TEST_TMPDIR/once.sh" pw="$BATS_TEST_TMPDIR/passwd-alice"
  sed -n '/^converge_once() {/,/^}/p' "$SUT" > "$fn"
  { cat "$PASSWD_FILE"; echo 'alice:x:1001:1001::/home/alice:/bin/bash'; } > "$pw"
  GESTES="$BATS_TEST_TMPDIR/gestes.log"; : > "$GESTES"
  mkdir -p "$BATS_TEST_TMPDIR/homes"
  run bash -c "
    set -uo pipefail
    export PASSWD_FILE='$pw' PASSWD_DEFS='$PASSWD_DEFS' LCARS_CLI='$1' LCARS_SYSADMIN_UID=1000
    export LCARS_HOME_ROOT='$BATS_TEST_TMPDIR/homes' LCARS_UID_MAP_FILE='$BATS_TEST_TMPDIR/uid.map'
    export LCARS_CONVERGER_REFUSED='$BATS_TEST_TMPDIR/refused' LCARS_CONSOLE=0
    source '$SUT'
    team_id() { echo 7; }
    api() { printf '[{\"id\":4,\"login\":\"alice\"}]'; }
    id() { [[ \"\$*\" == *alice* ]]; }
    getent() { case \"\$1\" in passwd) [[ \"\$2\" == 1000 ]] ;; group) echo 'fleet:x:2000:' ;; esac; }
    useradd() { echo \"USERADD \$*\" >> '$GESTES'; }
    usermod() { echo \"USERMOD \$*\" >> '$GESTES'; }
    restore_human() { echo \"RESTORE \$1\" >> '$GESTES'; }
    ensure_console() { echo \"CONSOLE \$1\" >> '$GESTES'; }
    converge_human() { echo \"CONVERGE \$1\" >> '$GESTES'; }
    revoke_absent() { :; }; reconcile_humans() { :; }; ensure_all_consoles() { :; }
    source '$fn'
    converge_once
    echo '--- tour 2'
    export LCARS_CLI='$2'
    converge_once"
}

@test "roster ILLISIBLE : rien n'est decide ce tour — aucun geste, aucun REFUS publie" {
  _passe_alice "$BATS_TEST_TMPDIR/pas-de-cli" "$BATS_TEST_TMPDIR/pas-de-cli"
  [ "$status" -eq 0 ]
  [ ! -s "$GESTES" ] || { echo "un geste a ete joue :"; cat "$GESTES"; return 1; }
  [[ "$output" == *"rien converge ce tour"* ]]
  [[ "$output" != *"REFUS alice"* ]]
  [ ! -s "$BATS_TEST_TMPDIR/refused" ]
}

@test "roster relu a CHAQUE tour tant qu'il manque — la release posee apres le demarrage est vue" {
  _passe_alice "$BATS_TEST_TMPDIR/pas-de-cli" "$LCARS_CLI"
  [ "$status" -eq 0 ]
  local apres="${output#*--- tour 2}"
  [[ "$apres" != *"ILLISIBLE"* ]] || { echo "$output"; return 1; }
  grep -q '^CONSOLE alice$' "$GESTES"
}

@test "un refus publie se RETIRE quand le login converge — le deck ne ment pas jusqu'au reboot" {
  printf 'alice\tancienne raison\nbob\tsa raison\n' > "$BATS_TEST_TMPDIR/refused"
  _passe_alice "$LCARS_CLI" "$LCARS_CLI"
  [ "$status" -eq 0 ]
  grep -q '^CONSOLE alice$' "$GESTES"
  refute grep -q '^alice	' "$BATS_TEST_TMPDIR/refused"
  grep -q '^bob	sa raison$' "$BATS_TEST_TMPDIR/refused"
}
