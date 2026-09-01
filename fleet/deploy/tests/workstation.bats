#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/workstation.bats
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: bats tests for fleet/deploy/workstation — le delegue du rail POSTE
#
# ─── CE QUE CES TEMOINS FERMENT ─────────────────────────────────────────────────────────────────
#
# Ce fichier est neuf, mais trois de ses temoins ne le sont pas : ils viennent d'`install_door.bats`
# et ils ONT SUIVI le code qu'ils mesurent (E2 du chantier porte). Un temoin qui disparait parce que
# sa cible a demenage est une propriete perdue — c'est la regle du contrat de gel (`E0-CONTRAT.md`).
#
# ⚠ AUCUN TEMOIN ICI NE PROVISIONNE. `workstation up` escalade en root et joue `provision apply` : un
# temoin qui le traverserait posseder ait la machine qui joue la suite. Ce qui est mesure est la
# DECISION et la FORME — l'escalade, la liste blanche, l'ordre des gestes, les codes de sortie.
#
# ⚠ SC2016 : ces temoins LISENT du code. Leurs motifs portent des `$VAR` qui doivent atteindre
# l'outil TELS QUELS.
# shellcheck disable=SC2016

load refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  unset SUDO_USER

  SRC="$BATS_TEST_DIRNAME/../workstation"
  [ -f "$SRC" ]
}

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  run head -8 "$SRC"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
}

@test "il est EXECUTABLE dans l index git — la porte l appelle, pas la source" {
  # ⚠ CE TEMOIN EXISTE PARCE QUE LE BIT A DEJA ETE PERDU DANS L'INDEX, sur `bench-forge-bootstrap.sh`,
  # par un commit de prose (2026-08-30). Le fichier restait executable sur la machine qui l'avait
  # ecrit : rien ne rougissait ici, et le rail cassait chez le suivant.
  run git -C "$BATS_TEST_DIRNAME/../../.." ls-files -s fleet/deploy/workstation
  [ "$status" -eq 0 ]
  [[ "$output" == 100755* ]]
}

# ─── L'AIDE ─────────────────────────────────────────────────────────────────────────────────────

@test "l aide marche SANS root et SANS rien d autre" {
  run env -i PATH=/usr/bin:/bin bash "$SRC" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"up"* ]]
  [[ "$output" == *"doctor"* ]]
}

@test "un verbe inconnu est REFUSE, jamais avale en silence" {
  run bash "$SRC" zzz
  [ "$status" -eq 1 ]
  [[ "$output" == *"verbe inconnu"* ]]
}

# ─── L'ESCALADE — MIGRE DEPUIS install_door.bats (E2) ───────────────────────────────────────────

@test "MIGRE : le drapeau SURVIT a l escalade sudo" {
  # ⚠ CE TEMOIN VIENT DE LA PORTE, ET SON MOTIF EST INTACT. `sudo` remet l'environnement a zero.
  # Sans ce drapeau dans la liste nommee, le script le lit, decide de laisser passer, escalade — et
  # la SECONDE instance ne le voit plus, donc se refuse elle-meme en invitant a poser le drapeau
  # qu'on vient de poser. Refus parfaitement circulaire, et rien dans la sortie ne dit que sudo est
  # passe entre les deux.
  #
  # Le canon a supprime le re-exec de la PORTE, ce qui semblait dissoudre le sujet. C'etait faux :
  # l'escalade a demenage ici, et le piege avec elle.
  run grep -n 'ESCALADE_ENV=(' "$SRC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LCARS_ALLOW_ANY_HOST"* ]]
  [[ "$output" == *"PROV_FORGE_ADMIN_RESET"* ]]
}

# ─── LA LISTE SE DERIVE DE CE QUE LE RAIL LIT, ELLE NE SE RELIT PAS ─────────────────────────────
#
# ⚠ LE TEMOIN DU DESSUS EPINGLAIT DEUX NOMS, ET LA LISTE EN OUBLIAIT DEUX AUTRES. Aucune `FORGE_*`
# n y figurait, alors que `lib/provision-lib.sh` les lit DANS L ENVIRONNEMENT : `FORGE_BASE_URL`
# (l. 79) decide de MONTER ou de CONSOMMER une forge, `FORGE_PUBLIC_URL` (l. 88) porte l adresse que
# le navigateur doit resoudre. Le preflight tourne NON-ROOT, donc avant l escalade : il affichait
# « forge fournie », puis le sudo mangeait la variable et `48-forge-host` montait un conteneur.
# L axe « forge fournie » du § 13 n existait pas sur ce rail.
#
# Le discriminant est mecanique et il est le bon : la lib est l endroit ou l environnement de
# l operateur ENTRE dans le rail. Ce qu elle y lit doit traverser le sudo, sinon le geste demande
# disparait entre deux processus.
@test "ESCALADE : toute FORGE_ que la lib lit dans l environnement TRAVERSE le sudo" {
  local lib="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  local lues manquantes="" v
  lues="$(grep -ohE '\$\{FORGE_[A-Z_]+' "$lib" | tr -d '${' | sort -u)"
  [ -n "$lues" ] || { echo "extraction ratee : aucune FORGE_ lue dans la lib"; return 1; }
  for v in $lues; do
    grep -qE "ESCALADE_ENV=\(.*[( ]$v([) ]|\$)" "$SRC" \
      || manquantes="$manquantes $v"
  done
  [ -z "$manquantes" ] \
    || { echo "lue(s) par la lib et MANGEE(S) par le sudo :$manquantes"; return 1; }
}

@test "ESCALADE : aucun secret dans la liste — sudo met la valeur dans l argv d un process root" {
  # `sudo VAR=valeur` rend la valeur lisible par tout compte local. Un secret traverse par un
  # FICHIER, jamais par cette liste. Meme frontiere que le shim docker, qui ecarte explicitement
  # `*TOKEN*`, `*PASSWORD*` et `*SECRET*` de ce qu il repasse.
  local decl; decl="$(grep 'ESCALADE_ENV=(' "$SRC")"
  [ -n "$decl" ]
  refute grep -qiE 'TOKEN|PASSWORD|SECRET|CREDENTIAL|PASSWD|_PW=|_KEY' <<<"$decl"
}

@test "la liste blanche vit en UN SEUL endroit, et l escalade l emploie" {
  # Deux listes deriveraient, et celle qu'on ne relit pas mangerait un drapeau en silence.
  run grep -c 'ESCALADE_ENV' "$SRC"
  [ "$output" -eq 2 ]   # la declaration, et son unique lecture
}

@test "AUCUN drapeau de passage : la seconde instance se reconnait a EUID" {
  # ⚠ C'EST LE POINT D'E2. La porte se rejouait elle-meme et devait donc se DIRE de sauter l'accueil
  # et la pause — `--consented`, un drapeau pour contourner un probleme qu'elle s'etait cree. Ici
  # l'escalade n'a rien a sauter. `EUID` est un FAIT ; un marqueur passe en argument est une
  # CROYANCE, que n'importe qui peut poser a la main.
  local corps; corps="$(sed -n '/^escalade_si_besoin()/,/^}/p' "$SRC")"
  grep -q 'EUID' <<<"$corps"
  refute grep -qE 'consented|--escalated|--reexec' <<<"$corps"
}

@test "l escalade REFUSE proprement quand sudo manque — elle ne plante pas" {
  local corps; corps="$(sed -n '/^escalade_si_besoin()/,/^}/p' "$SRC")"
  grep -q 'command -v sudo' <<<"$corps"
  grep -q 'fail ' <<<"$corps"
}

# ─── LA TRANCHE PAQUETS — MIGRE DEPUIS install_door.bats (E2) ───────────────────────────────────

@test "MIGRE : la tranche paquets ne se joue QUE si docker manque ET que le rail peut le poser" {
  # Sur une machine qui a deja docker, rejouer trois modules serait du bruit ; sur une machine non
  # declaree, ce serait une promesse que `00-preflight` refusera dix secondes plus tard.
  local bloc; bloc="$(sed -n '/LES PAQUETS D.ABORD/,/^  fi$/p' "$SRC")"
  [ -n "$bloc" ]
  grep -q 'fait docker' <<<"$bloc"
  grep -q 'absent' <<<"$bloc"
  grep -q 'fait consent' <<<"$bloc"
  grep -q 'fait substrat' <<<"$bloc"
}

@test "MIGRE : la MESURE est rejouee apres la tranche paquets" {
  # Poser docker change la reponse. Sans ce second passage, la suite du rail travaillerait sur une
  # photographie prise avant l'installation.
  local bloc; bloc="$(sed -n '/LES PAQUETS D.ABORD/,/^  fi$/p' "$SRC")"
  grep -q 'mesurer' <<<"$bloc"
}

@test "aucune sonde propre : ce delegue LIT les faits, il ne mesure pas" {
  # Meme regle que la porte depuis E1. Une seconde sonde ici conclurait peut-etre autrement que le
  # module, et c'est exactement la duplication que le canon proscrit.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -q 'docker_endpoint' <<<"$code"
  # `command -v` survit pour UNE chose : verifier que `sudo` existe avant de l'appeler. Ce n'est pas
  # une sonde de l'etat de la machine, c'est la garde d'un appel.
  [ "$(grep -c 'command -v' <<<"$code")" -eq 1 ]
  grep -q 'command -v sudo' <<<"$code"
}

# ─── LES VERDICTS ───────────────────────────────────────────────────────────────────────────────

@test "les TROIS codes de provision apply sont lus, et 2 n est pas un echec" {
  # `provision apply` rend 0, 2 (drift residuel, rien n'est casse) ou 1. Sous `set -e` une ligne nue
  # tuerait ce script sur 1 ET 2, sans un mot — et deux delegues qui en tirent deux verdicts, c'est
  # un code de retour qui ne veut plus rien dire.
  local bloc; bloc="$(sed -n '/^  local rc=0$/,/^  esac$/p' "$SRC")"
  [ -n "$bloc" ]
  grep -qE '^\s+0\)' <<<"$bloc"
  grep -qE '^\s+2\)' <<<"$bloc"
  grep -q 'DRIFT RÉSIDUEL' <<<"$bloc"
  grep -q 'exit "$rc"' <<<"$bloc"
}

@test "doctor n ESCALADE PAS — une sonde ne coute pas un mot de passe" {
  # ⚠ `doctor` est read-only : `NEEDS: root` n'est controle qu'a l'apply. Demander sudo pour SONDER
  # apprendrait a l'operateur qu'une sonde coute un mot de passe, et il finirait par le donner a
  # n'importe quoi.
  local corps; corps="$(sed -n '/^cmd_doctor()/,/^}/p' "$SRC")"
  refute grep -q 'escalade_si_besoin' <<<"$corps"
  grep -q 'exec "$PROVISION" doctor' <<<"$corps"
}

# ─── LES IDENTIFIANTS ───────────────────────────────────────────────────────────────────────────

@test "imprimer PUIS detruire, sur TOUS les chemins de sortie" {
  # Un `rm` qui s'execute sans l'impression perd POUR DE BON un secret deja pose sur la forge : le
  # compte existe, avec un mot de passe que personne n'a jamais vu.
  run grep -n 'trap nettoyer EXIT INT TERM' "$SRC"
  [ "$status" -eq 0 ]
  local corps; corps="$(sed -n '/^nettoyer()/,/^}/p' "$SRC")"
  # L'impression AVANT le rm, dans le corps de la meme fonction.
  local l_print l_rm
  l_print="$(grep -n 'print_credentials_once' <<<"$corps" | head -1 | cut -d: -f1)"
  l_rm="$(grep -n 'rm -f "\$PROV_ANNOUNCE_FILE"' <<<"$corps" | head -1 | cut -d: -f1)"
  [ "$l_print" -lt "$l_rm" ]
}

@test "les identifiants sont la DERNIERE chose imprimee sur le chemin nominal" {
  # La derniere chose a l'ecran est la seule qu'on est sur de ne pas avoir fait defiler.
  local corps; corps="$(sed -n '/^cmd_up()/,/^}/p' "$SRC")"
  local l_bandeau l_creds
  l_bandeau="$(grep -n 'bandeau_final' <<<"$corps" | tail -1 | cut -d: -f1)"
  l_creds="$(grep -n 'print_credentials_once' <<<"$corps" | tail -1 | cut -d: -f1)"
  [ "$l_bandeau" -lt "$l_creds" ]
}

# ─── LE BANDEAU ─────────────────────────────────────────────────────────────────────────────────

@test "le bandeau ne PROMET aucun humain — ce rail n en cree pas" {
  # ⚠ Meme regle que la porte (canon du 2026-08-30) : a cette seconde il n'y a peut-etre encore
  # personne, et nommer un compte que l'operateur n'a pas serait lui faire taper une commande qui
  # echoue. LE MOTIF EXCLUT UN POINT DEVANT : `~/.lcars` est un repertoire.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -qE '(^|[^.[:alnum:]_/-])lcars([^[:alnum:]_.-]|$)' <<<"$code"
  grep -q 'ton humain' <<<"$code"
}

@test "le cartouche vient de la LIB — il n est pas recopie ici" {
  # Deux implementations du meme cadre derivent, et celle qu'on ne relit pas casse son bord droit
  # au premier accent. `prov_box_emit` vit dans `provision-lib.sh`.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  grep -q 'prov_box_emit' <<<"$code"
  refute grep -qE '_box_pad|_box_plain|printf .*┌' <<<"$code"
}

@test "MIGRE : la DERNIERE instruction lue est vraie sur CE terrain — pas celle d un autre" {
  # ⚠ CE TEMOIN VIENT DE `install_door.bats`, AVEC LE BANDEAU DE FIN QU'IL GARDE, et mon classement
  # E0 l'avait range en GARDE sur la foi de son titre : il ne nomme pas le bandeau, il nomme sa
  # propriete. Un temoin se classe sur ce qu'il LIT, pas sur ce qu'il dit.
  #
  # Ce qu'il ferme : le bandeau disait « WSL : wsl --shutdown » sur une machine dediee sans WSL, et
  # « fleet_v2 start — ta fleet, sous ton uid » alors que ce rail fait tourner la fleet sous l'humain
  # de fleet que la forge seme (48) et que le convergeur materialise (64), pas sous l'operateur :
  # GUARD B refuse l'uid du siege, qui est justement le sien sur une machine standard. Un operateur
  # qui suit cette ligne se fait refuser par un garde, sans savoir pourquoi.
  #
  # ⚠ ON MESURE LE TEXTE, PAS UNE EXECUTION : atteindre ce bandeau demande un provisionnement complet
  # (paquets, /opt/lcars, une forge), ce qu'un temoin ne joue pas. Ce qui se garde est que les deux
  # formes EXISTENT et sont choisies par le terrain — un bandeau qui redeviendrait inconditionnel les
  # perdrait sans que rien ne rougisse.
  run grep -c 'sudo -u <ton humain> fleet_v2 start' "$SRC"
  [ "$output" = "1" ]
  run grep -c "Rien à redémarrer : ce terrain n'a pas de WSL" "$SRC"
  [ "$output" = "1" ]
  # ET LE CHOIX SE FAIT SUR LE FAIT, pas sur une variable que ce script aurait devinee.
  local corps; corps="$(sed -n '/^bandeau_final()/,/^}/p' "$SRC")"
  grep -q 'wsl' <<<"$corps"
  run bash -c "grep -c 'bandeau_final \"\$(fait substrat)\"' '$SRC'"
  [ "$output" = "1" ]
}
