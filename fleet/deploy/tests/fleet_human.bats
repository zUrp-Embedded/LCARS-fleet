#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/fleet_human.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: bats tests for 22-fleet-human — la SONDE de l'humain de fleet du poste
#
# CE QUE CES TEMOINS FERMENT. Le rail poste installait un runtime que personne ne pouvait lancer, et
# il se contredisait en le faisant. Mesure du 2026-08-21, install a froid sur machine dediee, humain
# = l'operateur (uid 1000) :
#
#     POSÉ  20-groups:   lordzurp ∈ fleet
#     POSÉ  70-human:    ~/.lcars, ~/pods, env  →  pour lordzurp
#     OK    75-projects: lordzurp n'est pas un humain de fleet (compte systeme ou sysadmin)
#
# GUARD B (`bin/fleet_v2`) et `is_fleet_human` appliquent la meme regle : `uid >= UID_MIN` ET
# `uid != LCARS_SYSADMIN_UID`. Or le premier utilisateur d'une Linux ou d'une WSL standard EST uid
# 1000. La regle « uid >= 1001 » n'etait ecrite que pour la BOITE.
#
# ⚠ CE MODULE NE CREE PLUS (2026-08-25) ET NE NOMME PLUS (retrait de `--fleet-human`). Il ATTESTE.
# La moitie de ces temoins portait la dichotomie « humain nomme / pas nomme » — un etat qui n'existe
# plus : le nom vient de `services/forge-gestures.sh builtin-human`, seul declarant, et il repond
# toujours. Ce qui les remplace mesure les etats REELS : le compte est la, il n'y est pas encore, il
# y est sous un uid que GUARD B refuse, ou l'autorite du nom est muette.
#
# ⚠ ET LA COUTURE DE CES TEMOINS EST `LCARS_BUILTIN_HUMAN`, la surcharge que l'autorite DECLARE.
# Piloter par une variable que le module ne lit plus les rendrait verts sur la machine du lanceur.
#
# ⚠ CES TEMOINS NE CREENT AUCUN COMPTE, et c'est delibere : `useradd` demande root et laisserait
# des comptes derriere lui sur la machine qui joue les tests. Ce qui se mesure ici est le CALCUL —
# les verdicts, les codes de sortie, les deux dialectes — c'est-a-dire tout ce qui, faux, serait
# silencieux.

# ⚠ SC2030/SC2031 : CHAQUE `@test` DE BATS EST UN SOUS-SHELL, et c'est la propriete qu'on veut —
# un test ne teinte pas le suivant. Que les variables posees dans un test soient « locales » est
# l'isolation, pas une fuite.
# shellcheck disable=SC2030,SC2031

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2097 — prefixe d'environnement sur `run` : bats le transmet a la commande forkee
#   SC2098 — idem — la seconde affectation recalcule depuis le PATH d'origine, sans effet de bord
# shellcheck disable=SC2097,SC2098

load refute

setup() {
  # Le decor possede l'environnement : ces temoins jugent ce que le module fait d'un environnement
  # DONNE (plancher d'uid, siege, groupe). L'heriter reviendrait a juger la machine qui les joue.
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)

  SRC="$BATS_TEST_DIRNAME/../modules.d/22-fleet-human.sh"
  [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  # `deploy/provision` derive le siege de l'appelant et l'exporte avant tout module ; sans defaut
  # `:-1000` dans la lib, une fixture qui ne le pose pas mesure une machine sans siege.
  export LCARS_SYSADMIN_UID="${LCARS_SYSADMIN_UID:-1000}"
  export PROVISION_MODULE=22-fleet-human
  export PROV_FLEET_GROUP="$(id -gn)"
  export PROV_HUMAN="$(id -un)"

  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  # `login.defs` du decor : le plancher est une DONNEE du systeme, donc il se pose ici.
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN 1000\nUID_MAX 60000\n' > "$PASSWD_DEFS"

  MOD="$BATS_TEST_TMPDIR/mod.sh"
  sed '/^case "${1:?usage/,$d' "$SRC" > "$MOD"
}

mod() { run bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; $1"; }

# Le module joue POUR DE VRAI, dispatch compris : `mod` source un fichier tronque, donc il ne mesure
# pas le CODE DE SORTIE — et c'est lui qui porte les deux dialectes.
nu() { # nu <check|apply>
  run env PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh" \
    PROVISION_MODULE=22-fleet-human PROV_TOKENS_DIR="$BATS_TEST_TMPDIR" \
    PROV_FLEET_GROUP="$(id -gn)" PROV_HUMAN="$(id -un)" \
    PASSWD_DEFS="$PASSWD_DEFS" \
    ${LCARS_SYSADMIN_UID:+LCARS_SYSADMIN_UID="$LCARS_SYSADMIN_UID"} \
    ${LCARS_BUILTIN_HUMAN:+LCARS_BUILTIN_HUMAN="$LCARS_BUILTIN_HUMAN"} \
    bash "$SRC" "$1"
}

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  run head -8 "$SRC"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
}

# ─── LE PLANCHER D'UID A DEMENAGE, ET SES CINQ TEMOINS AVEC LUI ─────────────────────────────────
#
# Ils vivaient ici — `fleet_uid_floor`, `first_free_uid` — parce que ce module creait le compte du
# poste. Il a cesse le 2026-08-25 : la forge seme (48), le convergeur materialise (64). Le garde suit
# le geste qu'il garde ; il est dans `human_converger.bats`, section « LE PLANCHER D'UID », avec un
# sixieme temoin qui manquait — celui qui verifie que `uid_wanted` s'en SERT.
#
# ⚠ CE QUI RESTE EPINGLE ICI EST L'ABSENCE. Un module qui recreerait un compte reintroduirait le
# deuxieme createur, donc le deuxieme jeu de regles.
@test "ce module ne CREE plus de compte unix — un seul createur, et ce n'est pas lui" {
  # ⚠ CE TEMOIN A ETE UN MOTIF DE TEXTE, ET IL AVAIT TROIS TROUS MESURES. Il epinglait la position
  # de commande — debut de ligne, `;`, `&&`, `||`, `then`, `do`, `{` — pour ne pas rougir sur le
  # VERDICT, qui propose legitimement le geste manuel a l'operateur (« useradd -m -G fleet <nom> »).
  # La liste des separateurs est finie, et ces trois formes EXECUTENT `useradd` en passant au vert :
  #
  #     r=$(useradd -m x)                    → precede de `$(`
  #     runuser -u root -- useradd -m x      → precede de `-- `, la forme que provision-lib emploie
  #     sudo useradd -m x                    → precede de `sudo `
  #
  # UN MUR DE TEXTE NE VOIT PAS UN APPEL, IL VOIT UNE ORTHOGRAPHE. On pose donc de FAUX `useradd` et
  # `adduser` en tete du PATH, on joue l'apply pour de vrai, et on regarde s'ils ont ete appeles.
  # Peu importe alors par quel detour on les atteint.
  local bin="$BATS_TEST_TMPDIR/nocreate"; mkdir -p "$bin"
  local mouchard="$BATS_TEST_TMPDIR/appele"
  local u
  for u in useradd adduser; do
    printf '%s\n' '#!/usr/bin/env bash' \
      "printf '%s %s\n' \"\$0\" \"\$*\" >> '$mouchard'" \
      'exit 0' > "$bin/$u"
    chmod 0755 "$bin/$u"
  done

  # Un compte ABSENT : c'est le seul etat ou l'ancienne version creait, donc le seul ou ce temoin
  # mesure quelque chose. Sur un compte existant il n'y aurait rien a creer et le temoin serait vert
  # sans avoir rien exerce.
  PATH="$bin:$PATH" run env LCARS_BUILTIN_HUMAN="n-existe-pas-$$" \
    PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh" \
    PROVISION_MODULE=22-fleet-human PROV_TOKENS_DIR="$BATS_TEST_TMPDIR" \
    PROV_FLEET_GROUP="$(id -gn)" PROV_HUMAN="$(id -un)" PATH="$bin:$PATH" \
    bash "$SRC" apply

  [ ! -e "$mouchard" ] || { echo "createur APPELE : $(cat "$mouchard")"; return 1; }
}

@test "TEMOIN DU TEMOIN : le mouchard attrape bien un createur, quel que soit le detour" {
  # ⚠ SANS CE PENDANT, UN MOUCHARD QUI N'ATTRAPE RIEN PASSE POUR UNE ABSENCE DE CREATION. On lui
  # donne les trois formes qui contournaient le motif de texte, et il doit voir les trois.
  local bin="$BATS_TEST_TMPDIR/probe"; mkdir -p "$bin"
  local mouchard="$BATS_TEST_TMPDIR/probe.log"
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf 'vu %s\n' \"\$*\" >> '$mouchard'" 'exit 0' > "$bin/useradd"
  chmod 0755 "$bin/useradd"

  # `$( … )` et un WRAPPER qui exec depuis le PATH — deux des trois formes qui passaient le motif.
  # `env` tient lieu de `runuser`/`sudo` : meme mecanique (un programme qui en exec un autre), et il
  # existe partout, la ou une doublure de `runuser` ajouterait un decor a debugger.
  PATH="$bin:$PATH" bash -c 'r=$(useradd -m a); env useradd -m b'
  [ -f "$mouchard" ]
  [ "$(grep -c '^vu ' "$mouchard")" -eq 2 ]
}

@test "le geste manuel reste PROPOSE dans le verdict — on retire le createur, pas la sortie de secours" {
  # Sans ce pendant, supprimer purement le mot `useradd` du fichier passerait le temoin precedent
  # tout en privant l'operateur du seul geste qu'il puisse taper lui-meme (P-40). Le rail est le
  # chemin ; ce geste est ce qui reste a celui pour qui le rail n'a pas abouti.
  LCARS_BUILTIN_HUMAN="n-existe-pas-$$" mod 'observe'
  [[ "$output" == *"useradd"* ]]
  [[ "$output" == *"$PROV_FLEET_GROUP"* ]]
}

# ─── LE NOM VIENT DE SON AUTORITE, ET RIEN D'AUTRE ──────────────────────────────────────────────

@test "le nom du compte integre n'est PAS recopie ici — son auteur est forge-gestures.sh" {
  # Un second litteral ne reste d'accord avec le premier que jusqu'au jour ou l'un des deux bouge.
  # ⚠ LE MOTIF EXCLUT UN POINT DEVANT : `~/.lcars` est un REPERTOIRE, pas le nom d'un compte, et il
  # est legitime dans ce module. Un grep nu sur « lcars » rougit dessus et fait croire a une regle
  # enfreinte la ou il n'y a qu'un chemin.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -qE '(^|[^.[:alnum:]_/])lcars([^[:alnum:]_.-]|$)' <<<"$code"
  # ET IL LA DEMANDE : ne pas recopier ne suffit pas, encore faut-il aller chercher.
  grep -q 'forge-gestures.sh" builtin-human' <<<"$code"
  # ⚠ ET PLUS AUCUNE SECONDE ORIGINE. `PROV_FLEET_HUMAN` etait posee par `--fleet-human`, retire :
  # la rouvrir redonnerait deux sources a un fait qui n'en a qu'une, et la seconde serait vide.
  refute grep -q 'PROV_FLEET_HUMAN' <<<"$code"
}

@test "AUTORITE MUETTE : « je ne peux pas mesurer » n'est pas « il n'y a personne »" {
  # Les deux appellent des gestes OPPOSES : l'un fait chercher un compte manquant, l'autre fait
  # reparer l'arbre du provisionnement. Un repli cable ici ferait pire que les confondre — il
  # accuserait un compte precis sur la foi d'un nom que personne n'a declare.
  #
  # L'arbre est deplace dans un bac ou `repo_root` ne trouve PAS `fleet/services/`. La lib emmene son
  # voisin `docker-endpoint.sh` : elle le source par chemin relatif, et sans lui l'echec viendrait du
  # decor au lieu du sujet.
  local orph="$BATS_TEST_TMPDIR/vide/fleet/deploy/lib"
  mkdir -p "$orph"
  cp "$PROVISION_LIB" "$(dirname "$PROVISION_LIB")/docker-endpoint.sh" "$orph/"
  run env PROVISION_LIB="$orph/provision-lib.sh" PROVISION_MODULE=22-fleet-human \
    PROV_TOKENS_DIR="$BATS_TEST_TMPDIR" PROV_FLEET_GROUP="$(id -gn)" \
    PROV_HUMAN="$(id -un)" PASSWD_DEFS="$PASSWD_DEFS" LCARS_SYSADMIN_UID=1000 \
    bash "$SRC" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"indéterminable"* ]]
  [[ "$output" == *"builtin-human"* ]]
  # Et surtout : il n'invente aucun nom pour le dire.
  [[ "$output" != *"« lcars »"* ]]
}

# ─── LES ETATS REELS DE LA MACHINE ──────────────────────────────────────────────────────────────

@test "compte ABSENT : la SONDE derive, et elle dit QUI le materialise" {
  # ⚠ CE TEMOIN EXIGEAIT « CRÉERA » — la promesse de ce module. Elle n'est plus vraie : il ne cree
  # plus. Ce que la sonde doit dire maintenant, c'est le CHEMIN — 48 seme, 64 materialise et
  # verifie — sinon un operateur qui lit « absent » n'a aucune idee de ce qui va s'en occuper.
  LCARS_BUILTIN_HUMAN="n-existe-pas-$$" mod 'check'
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"* ]]
  [[ "$output" == *"48"* ]]
  [[ "$output" == *"64"* ]]
}

@test "compte ABSENT : l'APPLY, LUI, ne derive PAS — le compte n'est pas encore du" {
  # ⚠ LES DEUX VERBES DIVERGENT ICI, ET C'EST VOULU. Au rang 22 d'une install neuve le compte est
  # TOUJOURS absent : le signaler en apply ferait imprimer une derive a chaque install sur un etat
  # nominal, et une derive qui sort toujours n'est plus lue. La sonde se joue APRES la passe, ou
  # l'absence est une vraie derive.
  LCARS_BUILTIN_HUMAN="n-existe-pas-$$" nu apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"sera posé"* ]]
  [[ "$output" != *"DRIFT"* ]]
}

@test "check: un humain que GUARD B REFUSE est un drift NOMMÉ, pas un compte qu'on deplace" {
  # Cas reel : quelqu'un cree le compte a la main sur l'uid du siege. Changer l'uid d'un compte
  # existant orphelinerait tout ce qu'il possede — on le DIT, on ne le repare pas dans son dos.
  LCARS_SYSADMIN_UID="$(id -u)" LCARS_BUILTIN_HUMAN="$(id -un)" mod 'check'
  [ "$status" -eq 1 ]
  [[ "$output" == *"GUARD B refuse"* ]] || [[ "$output" == *"siège"* ]] || [[ "$output" == *"siege"* ]]
}

@test "TEMOIN: un humain qui PASSE GUARD B et porte le groupe est conforme" {
  # Sans ce pendant, un module qui deriverait TOUJOURS passerait les deux temoins ci-dessus (P-40).
  # Le compte qui joue les tests convient : uid >= UID_MIN, et on ecarte le siege de son uid.
  LCARS_SYSADMIN_UID=0 LCARS_BUILTIN_HUMAN="$(id -un)" mod 'check'
  [ "$status" -eq 0 ]
  [[ "$output" == *"il peut lancer la fleet"* ]]
}

# ─── L'ADHESION AU GROUPE : LA SEULE ASSERTION QUE CE MODULE PORTE SEUL ─────────────────────────
#
# ⚠ ET C'EST CE QUI L'A SAUVE DE LA SUPPRESSION. `probe_fleet_humans` de `64-services` mesure la
# POPULATION (`fleet_humans` balaie `/etc/passwd` par plage d'uid) ; il ne regarde aucun groupe. Le
# `usermod -aG` du convergeur, lui, est suivi d'un `|| true` : son echec est MUET. Un humain de fleet
# hors du groupe demarre et n'ouvre ni `/home/private` ni `/local/LCARS_v2` — la fleet part, et
# echoue sur une traversee, loin de la cause.

@test "l'adhesion au GROUPE est mesuree ici, et par personne d'autre" {
  # Le compte qui joue les tests existe et passe GUARD B ; on lui demande un groupe auquel il
  # n'appartient pas, donc seule l'assertion d'adhesion peut rougir.
  LCARS_SYSADMIN_UID=0 LCARS_BUILTIN_HUMAN="$(id -un)" \
    PROV_FLEET_GROUP="groupe-absent-$$" mod 'check'
  [ "$status" -eq 1 ]
  [[ "$output" == *"hors du groupe"* ]]
  # ⚠ LE REPERTOIRE SE DEMANDE, IL NE SE GRAVE PAS. Ce temoin attendait `/home/private` en dur ;
  # depuis que la racine est unique il derive, et un litteral fige aurait fait rougir ce temoin sur
  # un module parfaitement correct — ou pire, l'aurait fait passer au vert sur un module qui nomme
  # encore l'ancien chemin. On lit le meme fait que le sujet.
  local secdir
  secdir="$(env -i PATH="$PATH" bash -c ". '$PROVISION_LIB' >/dev/null 2>&1; printf '%s' \"\$PROV_TOKENS_DIR\"")"
  [ -n "$secdir" ] || { echo "PROV_TOKENS_DIR ne se lit plus dans provision-lib" >&2; return 1; }
  [[ "$output" == *"$secdir"* ]]
}

@test "TEMOIN DU TEMOIN : la population, elle, ne regarde AUCUN groupe" {
  # Si `fleet_humans` filtrait sur le groupe, l'assertion ci-dessus serait un doublon de
  # `probe_fleet_humans` et ce module n'aurait plus de raison d'etre. Elle ne le fait pas : le compte
  # courant sort de l'enumeration alors qu'on vient de nommer un groupe auquel il n'appartient pas.
  passwd_with "$(id -un):x:1001:1004::/home/$(id -un):/bin/bash"
  LCARS_SYSADMIN_UID=1000 PROV_FLEET_GROUP="groupe-absent-$$" mod 'fleet_humans'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(id -un)"* ]]
}

# ─── LES DEUX DIALECTES ─────────────────────────────────────────────────────────────────────────

passwd_with() { # passwd_with <ligne>...  → pose le fichier passwd du decor
  local f="$BATS_TEST_TMPDIR/passwd"
  printf 'root:x:0:0:root:/root:/bin/bash\n' > "$f"
  printf 'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n' >> "$f"
  printf 'siege:x:1000:1000::/home/siege:/bin/bash\n' >> "$f"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
  export PASSWD_FILE="$f"
}

@test "nobody n'est JAMAIS un humain de fleet — enumerer exige la borne HAUTE" {
  # Il est sur toute machine, uid 65534 : superieur a UID_MIN et different du siege. La regle basse
  # seule le compte — enumerer exige donc les DEUX bornes que `login.defs` declare.
  passwd_with
  LCARS_SYSADMIN_UID=1000 mod 'fleet_humans'
  [ -z "$output" ]
}

@test "un compte ABSENT : DRIFT dans la sonde, JAMAIS un echec dans l'apply — chaque verbe son code" {
  # ⚠ LES CODES SONT INVERSES ENTRE LES DEUX VERBES, et ce module servait les deux avec UN SEUL
  # verdict :
  #     check   0 conforme · 1 DRIFT · 2 erreur de sonde
  #     apply   0 converge · 1 ECHEC · 2 applique, drift residuel
  #
  # L'assignation est justifiee VERBE PAR VERBE — chacun donne `1` a son mauvais resultat principal.
  # Mais rien n'ecrivait la contrainte EN TRAVERS : `apply()` faisait `{ check; return; }`, et
  # `verdict_check` fait un `exit`. Le module sortait donc en `1` pendant un apply, et le runner
  # traduisait « apply en echec … MORT avant de rendre son verdict » sur une derive parfaitement
  # nommee. Mesure du 2026-08-22, install a froid.
  #
  # ⚠ `run`, PAS UN APPEL NU : bats tourne sous `set -e`, donc un module qui sort en 1 tue le temoin
  # AVANT la ligne qui lit son code. L'instrument tuait la mesure qu'il devait prendre.
  export LCARS_BUILTIN_HUMAN="n-existe-pas-$$"

  nu check
  [ "$status" -eq 1 ]
  [[ "$output" == *"absent"* ]]

  # Et l'apply, lui, rend 0 : au rang 22 ce compte n'est PAS ENCORE DU. C'est la moitie du contrat
  # que le partage de verdict avait cassee.
  nu apply
  [ "$status" -eq 0 ]
}

@test "un apply ne DELEGUE JAMAIS a check — le verdict n'est pas partageable" {
  # Le VERDICT porte le dialecte, donc il ne se partage pas. Ce temoin garde la regle pour les
  # VINGT-CINQ modules, pas seulement pour celui qui l'a payee.
  local m bad=0
  for m in "$BATS_TEST_DIRNAME"/../modules.d/*.sh; do
    awk '/^apply\(\) \{/,/^\}/' "$m" | grep -vE '^\s*#' | grep -qE '(^|[^_[:alnum:]])check;' \
      && { echo "apply() delegue a check() : $(basename "$m")"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}
