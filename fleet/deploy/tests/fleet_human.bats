#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/fleet_human.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: bats tests for 22-fleet-human — l'humain de fleet du poste, et le plancher d'uid qui le definit
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
# ⚠ CES TEMOINS NE CREENT AUCUN COMPTE, et c'est delibere : `useradd` demande root et laisserait
# des comptes derriere lui sur la machine qui joue les tests. Ce qui se mesure ici est le CALCUL —
# le plancher d'uid, le choix du premier libre, et les verdicts de `check` — c'est-a-dire tout ce
# qui, faux, serait silencieux. La creation elle-meme est un `useradd` nu, et un `useradd` qui
# echoue le DIT.

# ⚠ SC2030/SC2031 : CHAQUE `@test` DE BATS EST UN SOUS-SHELL, et c'est la propriete qu'on veut —
# un test ne teinte pas le suivant. Que les variables posees dans un test soient « locales » est
# l'isolation, pas une fuite.
# shellcheck disable=SC2030,SC2031

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
  export PROV_FLEET_GROUP
  PROV_FLEET_GROUP="$(id -gn)"

  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  # `login.defs` du decor : le plancher est une DONNEE du systeme, donc il se pose ici.
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN 1000\nUID_MAX 60000\n' > "$PASSWD_DEFS"

  MOD="$BATS_TEST_TMPDIR/mod.sh"
  sed '/^case "${1:?usage/,$d' "$SRC" > "$MOD"
}

mod() { run bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; $1"; }

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
# poste. Il a cesse le 2026-08-25 : il NOMME, la forge seme (48), le convergeur materialise (64).
# Le garde suit le geste qu'il garde ; il est dans `human_converger.bats`, section « LE PLANCHER
# D'UID », avec un sixieme temoin qui manquait — celui qui verifie que `uid_wanted` s'en SERT.
#
# ⚠ CE QUI RESTE EPINGLE ICI EST L'ABSENCE. Un module qui recreerait un compte reintroduirait le
# deuxieme createur, donc le deuxieme jeu de regles.
@test "ce module ne CREE plus de compte unix — un seul createur, et ce n'est pas lui" {
  # ⚠ CE TEMOIN A ETE UN MOTIF DE TEXTE, ET IL AVAIT TROIS TROUS MESURES. Il epinglait la position
  # de commande — debut de ligne, `;`, `&&`, `||`, `then`, `do`, `{` — pour ne pas rougir sur le
  # VERDICT, qui propose legitimement le geste manuel a l'operateur (« ou crée-le toi-même :
  # useradd -m -G fleet <nom> »). La liste des separateurs est finie, et ces trois formes EXECUTENT
  # `useradd` en passant au vert :
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

  # Un humain NOMME et ABSENT : c'est le seul etat ou l'ancienne version creait un compte, donc le
  # seul ou ce temoin mesure quelque chose. Sur un compte existant il n'y aurait rien a creer et le
  # temoin serait vert sans avoir rien exerce.
  PATH="$bin:$PATH" run env PROV_FLEET_HUMAN="n-existe-pas-$$" \
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
  # tout en privant l'operateur du seul geste qu'il puisse taper lui-meme (P-40).
  passwd_with
  LCARS_SYSADMIN_UID=1000 PROV_HUMAN=root mod 'announce_no_fleet_human'
  [[ "$output" == *"useradd"* ]]
}

@test "AUCUN humain nomme : drift qui donne le GESTE, et surtout aucun compte cree" {
  # ⚖ USER 2026-08-21 : « on cree pas un user sur une machine nue. dans docker c'est sans gravite,
  # la ca demande au moins une validation user. »
  #
  # Ce module portait `: "${PROV_FLEET_HUMAN:=lcars}"` : un apply sur une machine dediee faisait
  # apparaitre un utilisateur `lcars` que personne n'avait demande, sur un rail sans desinstalleur.
  # Le nom N'EST PAS un detail non plus — sur ce parc les humains s'appellent `vanille`, `bob`,
  # `alice` ; `lcars` n'a rien de special.
  #
  # ⚠ LE DECOR POSE SON `passwd`, ET SANS CA CE TEMOIN MESURE LA MACHINE QUI LE JOUE. Le verdict a
  # DEUX branches depuis que « rien n'est declare » a cesse d'etre confondu avec « personne ne peut
  # lancer la fleet » : sur une machine QUI PORTE des humains de fleet, le message les nomme et ne
  # parle pas de `useradd`. Ce temoin tient la branche « aucun », il doit donc poser une machine
  # sans aucun — sinon il est vert ou rouge selon le poste, ce qui ne mesure plus rien.
  passwd_with
  export PROV_HUMAN
  PROV_HUMAN="$(id -un)"
  mod 'check'
  [ "$status" -eq 1 ]     # check : 1 = DRIFT (le contrat INVERSE les codes entre check et apply)
  [[ "$output" == *"DRIFT"* ]]
  [[ "$output" == *"aucun humain de fleet"* ]] || [[ "$output" == *"DÉCLARÉ"* ]]
  # Le geste exact, les deux voies — celle du rail et celle qu'on tape soi-meme.
  [[ "$output" == *"--fleet-human"* ]]
  [[ "$output" == *"useradd"* ]]
}

@test "AUCUN humain nomme : l'APPLY non plus ne cree rien — il dit la meme chose que le check" {
  # C'est le seul module du rail qui fait APPARAITRE UN UTILISATEUR sur la machine de quelqu'un. Le
  # defaut ne peut pas etre « le faire quand meme » : un apply muet sur ce point serait exactement
  # la mutation qu'on refuse.
  # Meme raison qu'au temoin precedent : la machine du decor ne porte aucun humain de fleet, sinon
  # c'est l'autre branche du verdict qu'on lirait.
  passwd_with
  export PROV_HUMAN
  PROV_HUMAN="$(id -un)"
  mod 'apply'
  [[ "$output" == *"aucun humain de fleet"* ]] || [[ "$output" == *"DÉCLARÉ"* ]]
  [[ "$output" != *"cree ("* ]]
  [[ "$output" != *"créé ("* ]]
}

@test "humain NOMME mais absent : la SONDE derive, et elle dit QUI le materialise" {
  # ⚠ CE TEMOIN EXIGEAIT « CRÉERA » — la promesse de ce module. Elle n'est plus vraie : il ne cree
  # plus. Ce que la sonde doit dire maintenant, c'est le CHEMIN — 48 seme, 64 materialise et
  # verifie — sinon un operateur qui lit « absent » n'a aucune idee de ce qui va s'en occuper.
  PROV_FLEET_HUMAN="n-existe-pas-$$" mod 'check'
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"* ]]
  [[ "$output" == *"48"* ]]
  [[ "$output" == *"64"* ]]
}

@test "humain NOMME mais absent : l'APPLY, LUI, ne derive PAS — le compte n'est pas encore du" {
  # ⚠ LES DEUX VERBES DIVERGENT ICI, ET C'EST VOULU. Au rang 22 d'une install neuve le compte est
  # TOUJOURS absent : le signaler en apply ferait imprimer une derive a chaque install sur un etat
  # nominal, et une derive qui sort toujours n'est plus lue. La sonde se joue APRES la passe, ou
  # l'absence est une vraie derive.
  #
  # ⚠ `run` VIA UN PROCESSUS NU, PAS `mod` : `mod` source un module tronque, donc il ne mesure pas
  # le CODE DE SORTIE, et c'est precisement lui qui est en jeu.
  run env PROV_FLEET_HUMAN="n-existe-pas-$$" \
    PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh" \
    PROVISION_MODULE=22-fleet-human PROV_TOKENS_DIR="$BATS_TEST_TMPDIR" \
    PROV_FLEET_GROUP="$(id -gn)" PROV_HUMAN="$(id -un)" \
    bash "$SRC" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"nommé"* ]]
  [[ "$output" != *"DRIFT"* ]]
}

@test "check: un humain que GUARD B REFUSE est un drift NOMMÉ, pas un compte qu'on deplace" {
  # Cas reel : quelqu'un cree le compte a la main sur l'uid du siege. Changer l'uid d'un compte
  # existant orphelinerait tout ce qu'il possede — on le DIT, on ne le repare pas dans son dos.
  LCARS_SYSADMIN_UID="$(id -u)" PROV_FLEET_HUMAN="$(id -un)" mod 'check'
  [ "$status" -eq 1 ]
  [[ "$output" == *"GUARD B refuse"* ]] || [[ "$output" == *"siège"* ]] || [[ "$output" == *"siege"* ]]
}

@test "TEMOIN: un humain qui PASSE GUARD B et porte le groupe est conforme" {
  # Sans ce pendant, un module qui deriverait TOUJOURS passerait les deux temoins ci-dessus (P-40).
  # Le compte qui joue les tests convient : uid >= UID_MIN, et on ecarte le siege de son uid.
  LCARS_SYSADMIN_UID=0 PROV_FLEET_HUMAN="$(id -un)" mod 'check'
  [ "$status" -eq 0 ]
  [[ "$output" == *"il peut lancer la fleet"* ]]
}

@test "sans humain nomme : DRIFT dans les deux verbes, mais CHAQUE VERBE SON CODE" {
  # ⚠ LES CODES SONT INVERSES ENTRE LES DEUX VERBES, et ce module servait les deux avec UN SEUL
  # verdict :
  #     check   0 conforme · 1 DRIFT · 2 erreur de sonde
  #     apply   0 converge · 1 ECHEC · 2 applique, drift residuel
  #
  # L'assignation est justifiee VERBE PAR VERBE — chacun donne `1` a son mauvais resultat principal.
  # Mais rien n'ecrivait la contrainte EN TRAVERS : `apply()` faisait `{ check; return; }`, et
  # `verdict_check` fait un `exit`. Le module sortait donc en `1` pendant un apply, et le runner
  # traduisait « apply en echec … MORT avant de rendre son verdict » sur une derive parfaitement
  # nommee. Mesure du 2026-08-22, install a froid sans `--fleet-human`.
  #
  # ⚠ `run`, PAS UN APPEL NU : bats tourne sous `set -e`, donc un module qui sort en 1 tue le temoin
  # AVANT la ligne qui lit son code. L'instrument tuait la mesure qu'il devait prendre.
  nu() { run env -u PROV_FLEET_HUMAN \
      PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh" \
      PROVISION_MODULE=22-fleet-human PROV_TOKENS_DIR="$BATS_TEST_TMPDIR" \
      PROV_FLEET_GROUP="$(id -gn)" PROV_HUMAN="$(id -un)" \
      bash "$BATS_TEST_DIRNAME/../modules.d/22-fleet-human.sh" "$1"; }

  nu check
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun humain de fleet DÉCLARÉ"* ]]

  nu apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"aucun humain de fleet DÉCLARÉ"* ]]
}

@test "un apply ne DELEGUE JAMAIS a check — le verdict n'est pas partageable" {
  # Le message, oui : `announce_no_fleet_human` est appele par les deux. Le VERDICT, jamais — c'est
  # lui qui porte le dialecte. Ce temoin garde la regle pour les VINGT-SIX modules, pas seulement
  # pour celui qui l'a payee.
  local m bad=0
  for m in "$BATS_TEST_DIRNAME"/../modules.d/*.sh; do
    awk '/^apply\(\) \{/,/^\}/' "$m" | grep -vE '^\s*#' | grep -qE '(^|[^_[:alnum:]])check;' \
      && { echo "apply() delegue a check() : $(basename "$m")"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

# ─── « RIEN N'EST DECLARE » N'EST PAS « PERSONNE NE PEUT LANCER LA FLEET » ───────────────────────
#
# Le verdict lisait une VARIABLE (`PROV_FLEET_HUMAN`) et concluait sur la MACHINE. Mesure du
# 2026-08-22, poste portant `lcars` (1001) et `mintos` (1002) : le module annonçait que personne ne
# pourrait lancer la fleet ici. Les deux comptes passent la regle de GUARD B.
passwd_with() { # passwd_with <ligne>...  → pose le fichier passwd du decor
  local f="$BATS_TEST_TMPDIR/passwd"
  printf 'root:x:0:0:root:/root:/bin/bash\n' > "$f"
  printf 'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n' >> "$f"
  printf 'siege:x:1000:1000::/home/siege:/bin/bash\n' >> "$f"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
  export PASSWD_FILE="$f"
}

@test "aucun humain DECLARE mais la machine en PORTE : le verdict les NOMME" {
  passwd_with 'lcars:x:1001:1004::/home/lcars:/bin/bash' 'mintos:x:1002:1005::/home/mintos:/bin/bash'
  LCARS_SYSADMIN_UID=1000 PROV_HUMAN=root mod 'announce_no_fleet_human'
  [[ "$output" == *"lcars"* ]]
  [[ "$output" == *"mintos"* ]]
  # ⚠ ET IL NE DIT PLUS LA PHRASE FAUSSE. Sans cette ligne, un verdict qui nommerait les comptes
  # tout en affirmant que personne ne peut lancer la fleet passerait ce temoin.
  [[ "$output" != *"personne ne pourra"* ]]
}

@test "nobody n'est JAMAIS un humain de fleet — enumerer exige la borne HAUTE" {
  # Il est sur toute machine, uid 65534 : superieur a UID_MIN et different du siege. La regle basse
  # seule le compte — enumerer exige donc les DEUX bornes que `login.defs` declare.
  passwd_with
  LCARS_SYSADMIN_UID=1000 PROV_HUMAN=root mod 'fleet_humans'
  [ -z "$output" ]
}

@test "aucun humain DECLARE et la machine n'en porte AUCUN : le verdict dit ce qui SUIT" {
  # ⚠ « AUCUN » EST UN ETAT DE RANG 22, PAS UN ETAT FINAL. Sans `--fleet-human`, `48-forge-host`
  # passe une valeur VIDE, la recette cree le compte integre sur la forge, et le convergeur de
  # `64-services` le materialise : le rail PRODUIT un humain de fleet, il ne laisse pas choisir son
  # nom. Un verdict de rang 22 qui conclurait « personne ne pourra lancer la fleet ici » serait donc
  # faux vingt-six modules plus loin.
  passwd_with
  LCARS_SYSADMIN_UID=1000 PROV_HUMAN=root mod 'announce_no_fleet_human'
  [[ "$output" != *"personne ne pourra"* ]]
  # Ce que la suite de la passe fait, et le geste qui reprend la main dessus.
  [[ "$output" == *"48"* ]]
  [[ "$output" == *"64"* ]]
  [[ "$output" == *"--fleet-human"* ]]
  [[ "$output" == *"useradd"* ]]
}

@test "le nom du compte integre n'est PAS recopie ici — son auteur est forge-gestures.sh" {
  # Un second litteral ne reste d'accord avec le premier que jusqu'au jour ou l'un des deux bouge.
  # C'est la meme regle que `LCARS_BUILTIN_HUMAN=""` dans 48-forge-host : vide est une reponse.
  # ⚠ LE MOTIF EXCLUT UN POINT DEVANT : `~/.lcars` est un REPERTOIRE, pas le nom d'un compte, et il
  # est legitime dans ce module. Un grep nu sur « lcars » rougit dessus et fait croire a une regle
  # enfreinte la ou il n'y a qu'un chemin.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -qE '(^|[^.[:alnum:]_/])lcars([^[:alnum:]_.-]|$)' <<<"$code"
}
