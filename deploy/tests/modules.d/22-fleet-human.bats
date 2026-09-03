#!/usr/bin/env bats
# SOURCE: deploy/tests/modules.d/22-fleet-human.bats
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

load ../refute

setup() {
  # Le decor possede l'environnement : ces temoins jugent ce que le module fait d'un environnement
  # DONNE (plancher d'uid, siege, groupe). L'heriter reviendrait a juger la machine qui les joue.
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  # ⚠ LE SIEGE SE LIT DANS UN FICHIER AVANT LA VARIABLE (`prov_seat_uid`), et ce fichier existe sur toute
  # machine provisionnee : sans decor, un temoin qui attend que celui qui joue passe GUARD B rougit des
  # le second run du gate — le siege, c'est lui (banc .63, 2026-08-30). Le decor nomme un fichier absent.
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/etc/lcars/seat.uid"

  SRC="$BATS_TEST_DIRNAME/../../modules.d/22-fleet-human.sh"
  [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
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
# ⚠ `PASSWD_FILE` TRAVERSE, ET IL LE DOIT DEPUIS QUE LE MODULE ENUMERE. Il attendait un compte
# NOMME (`LCARS_BUILTIN_HUMAN`) ; il lit maintenant la population (`fleet_humans`), donc un temoin
# qui ne transmet pas le passwd du decor mesure la MACHINE qui le joue — et rend vert ou rouge
# selon qui lance le gate. Le pendant `LCARS_BUILTIN_HUMAN` a disparu avec le sujet.
nu() { # nu <check|apply>
  run env PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh" \
    PROVISION_MODULE=22-fleet-human PROV_TOKENS_DIR="$BATS_TEST_TMPDIR" \
    PROV_FLEET_GROUP="$(id -gn)" PROV_HUMAN="$(id -un)" \
    PASSWD_DEFS="$PASSWD_DEFS" \
    ${PASSWD_FILE:+PASSWD_FILE="$PASSWD_FILE"} \
    ${LCARS_SYSADMIN_UID:+LCARS_SYSADMIN_UID="$LCARS_SYSADMIN_UID"} \
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
    PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh" \
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
  # ⚠ LA CIBLE A CHANGE AVEC LE CANON (⚖ user 2026-08-30) : le chemin nominal n'est plus « creer le
  # compte integre » — plus aucun deploiement de travail ne fabrique d'humain — mais « s'enroler sur
  # la forge ». Les DEUX doivent etre dits : le chemin, et le recours.
  passwd_with
  mod 'observe'
  [[ "$output" == *"useradd"* ]]
  [[ "$output" == *"$PROV_FLEET_GROUP"* ]]
  [[ "$output" == *"inscription"* ]]
}

# ─── AUCUN HUMAIN N'EST NOMME ICI ───────────────────────────────────────────────────────────────

@test "le nom d'un compte n'est JAMAIS ecrit ici — ce module ne connait personne par son nom" {
  # ⚠ CE TEMOIN A CHANGE DE RAISON, PAS DE FORME (⚖ user 2026-08-30). Il interdisait de RECOPIER le
  # nom du compte integre, dont `forge-gestures.sh` etait l'autorite, et exigeait qu'on aille le lui
  # DEMANDER. Le canon a supprime le sujet : le rail pose les autorites, les personnes s'enrolent
  # sous LEUR nom. Ce module n'attend donc plus personne — il enumere (`fleet_humans`) et regarde le
  # groupe.
  #
  # L'interdiction du litteral survit, avec une raison PLUS FORTE qu'avant : un nom ecrit ici serait
  # un humain que le rail declare, ce que le canon interdit — pas seulement une seconde copie.
  # ⚠ LE MOTIF EXCLUT UN POINT DEVANT : `~/.lcars` est un REPERTOIRE, pas le nom d'un compte.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  # ⚠ `refute`, PAS `!` : POSIX exempte d'`errexit` toute commande niee par `!`, donc un `! grep`
  # qui n'est pas la DERNIERE ligne de son bloc s'execute, rend 1, et bats passe a la suite — verte
  # au moment precis ou ce qu'elle interdit arrive. Les trois assertions d'ici etaient dans ce cas.
  refute grep -qE '(^|[^.[:alnum:]_/])lcars([^[:alnum:]_.-]|$)' <<<"$code"
  # ⚠ ET PLUS AUCUNE SECONDE ORIGINE. `PROV_FLEET_HUMAN` etait posee par `--fleet-human`, retire :
  # la rouvrir redonnerait deux sources a un fait qui n'en a qu'une, et la seconde serait vide.
  refute grep -q 'PROV_FLEET_HUMAN' <<<"$code"
  # ET IL N'INTERROGE PLUS L'AUTORITE DU NOM : il n'a plus de nom a demander. Le temoin exigeait
  # l'inverse — `grep -q 'forge-gestures.sh" builtin-human'` — et c'est le canon qui a change, pas
  # la mesure : ce module enumere `fleet_humans`, il n'attend plus aucun compte nomme.
  refute grep -q 'builtin-human' <<<"$code"
}

# ⚠ DEUX TEMOINS ONT DISPARU ICI, ET LEUR SUJET AVEC (⚖ user 2026-08-30) — pas leur motif, qu'il
# n'y a simplement plus rien pour porter :
#
#   « AUTORITE MUETTE : je ne peux pas mesurer n'est pas il n'y a personne » — il gardait le module
#   d'accuser un compte precis quand `forge-gestures.sh builtin-human` ne repondait pas. Le module
#   n'interroge plus aucune autorite de nom : il enumere la population, et une population vide se
#   mesure sans ambiguite.
#
#   « un humain que GUARD B REFUSE est un drift NOMME » — il couvrait le compte cree a la main sur
#   l'uid du siege. Il exigeait qu'on sache QUI aurait du etre un humain ; sans compte attendu, la
#   phrase n'a plus de sujet — un compte a l'uid du siege est simplement le siege. La regle qu'il
#   protegeait (on DIT, on ne deplace pas un uid) vit dans `is_fleet_human`, et `fleet_human.bats`
#   la mesure par la borne (temoins « nobody » et « la population ne regarde AUCUN groupe »).

# ─── LES ETATS REELS DE LA MACHINE ──────────────────────────────────────────────────────────────

@test "AUCUN humain : la sonde le DIT sans deriver, et elle dit qui s'en occupera" {
  # ⚠ CE TEMOIN A CHANGE DE VERDICT, ET C'EST LE CANON (⚖ user 2026-08-30). Il exigeait un DRIFT sur
  # l'absence. Or aucun deploiement de travail ne fabrique d'humain : zero humain est l'etat NOMINAL
  # d'une machine neuve, jusqu'a la premiere inscription. Une derive qui sort toujours n'est plus
  # lue — c'est l'argument que le temoin voisin (« l'APPLY ne derive PAS ») portait deja au rang 22,
  # et qui vaut aussi pour la sonde depuis que plus rien ne cree ce compte.
  #
  # Ce que la sonde DOIT continuer de faire : le dire, et dire qui s'en occupera. Muette, elle
  # laisserait un operateur devant un « fleet_v2 start » qui refuse sans une ligne pour l'expliquer.
  passwd_with
  nu check
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"convergeur"* ]]
}

@test "AUCUN humain : l'APPLY non plus ne derive pas — les deux verbes s'accordent enfin" {
  # ⚠ LES DEUX VERBES DIVERGEAIENT ICI, ET CE N'EST PLUS LE CAS. L'apply tolerait deja l'absence au
  # motif qu'« au rang 22 d'une install neuve le compte est TOUJOURS absent » ; la sonde, elle,
  # derivait. Le canon a tranche dans le sens de l'apply : c'est la sonde qui a rejoint le verbe qui
  # avait raison, pas l'inverse.
  passwd_with
  nu apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"DRIFT"* ]]
}

@test "TEMOIN: un humain qui PASSE GUARD B et porte le groupe est conforme" {
  # Sans ce pendant, un module qui deriverait TOUJOURS passerait les deux temoins ci-dessus (P-40).
  # Le compte qui joue les tests convient : uid >= UID_MIN, et le siege du decor est ailleurs.
  #
  # ⚠ LE DECOR POSSEDE LA POPULATION DEPUIS QUE LE MODULE L'ENUMERE. Il jugeait UN nom qu'on lui
  # donnait ; il lit maintenant `fleet_humans`, donc un passwd non pose ferait juger les humains de
  # la MACHINE qui joue le gate — verte ou rouge selon qui la possede, et selon leurs groupes.
  # Le NOM doit exister pour de vrai : `id -nG` interroge le systeme, pas le decor. L'UID, lui, est
  # une donnee du decor comme le reste.
  #
  # ⚠ ET IL NE DOIT PAS ETRE `id -u`, PARCE QUE `passwd_with` POSE DEJA UN SIEGE A 1000. Cette ligne
  # s'ecrivait `…:x:$(id -u):$(id -u):…` : sur toute machine ou le lanceur porte l'uid 1000 — le
  # premier compte d'une Ubuntu ou d'une WSL standard, c'est-a-dire le CAS NOMINAL — le compte du
  # decor tombait sur l'uid du siege, GUARD B le refusait a bon droit, et le temoin rougissait sur
  # du code sain. Il passait sur cette machine-ci pour une raison ETRANGERE a ce qu'il epingle : le
  # compte y porte 1002. Le banc 2004 l'a mis par terre au premier rejeu.
  #
  # 1234 : superieur au plancher, inferieur au plafond, et different du siege du decor — les trois
  # proprietes que ce temoin exige, aucune heritee de la machine.
  passwd_with "$(id -un):x:1234:1234::/home/$(id -un):/bin/bash"
  mod 'check'
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
  #
  # ⚠ LE CAS DE DRIFT A CHANGE, LA CICATRICE NON (⚖ user 2026-08-30). Le drift etait « le compte
  # attendu est absent » ; l'absence est desormais l'etat nominal, et la sonde n'en derive plus. Le
  # drift qui reste est celui que ce module mesure SEUL : un humain hors du groupe. Il faut un cas
  # qui derive VRAIMENT, sinon ce temoin ne mesure plus la difference des deux dialectes — le
  # defaut qu'il existe pour tenir.
  passwd_with 'horsgroupe:x:1001:1001::/home/horsgroupe:/bin/bash'

  nu check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"* ]]

  # Et l'apply, lui, ne rend PAS 1 : son `1` a lui veut dire ECHEC, et un groupe manquant n'en est
  # pas un. C'est la moitie du contrat que le partage de verdict avait cassee.
  nu apply
  [ "$status" -ne 1 ]
}

@test "un apply ne DELEGUE JAMAIS a check — le verdict n'est pas partageable" {
  # Le VERDICT porte le dialecte, donc il ne se partage pas. Ce temoin garde la regle pour les
  # VINGT-CINQ modules, pas seulement pour celui qui l'a payee.
  local m bad=0
  for m in "$BATS_TEST_DIRNAME"/../../modules.d/*.sh; do
    awk '/^apply\(\) \{/,/^\}/' "$m" | grep -vE '^\s*#' | grep -qE '(^|[^_[:alnum:]])check;' \
      && { echo "apply() delegue a check() : $(basename "$m")"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}
