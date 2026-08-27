#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/variable_walls.bats
# AUTHOR: vanille
# STARDATE: 2026-08-27
# STATUS: actif — les invariants d'ECRITURE des variables, tenus par une mesure et non par la relecture
#
# ─── POURQUOI CE FICHIER ────────────────────────────────────────────────────────────────────────
# Les defauts que l'inventaire des variables a trouves ne sont pas des fautes de frappe : ce sont
# des FORMES. Un repli ecrit contre un cas qui ne peut pas arriver, un nom recopie sans arbitre,
# une valeur inventee la ou l'absence est un fait. Une forme ne se corrige pas une fois — elle se
# refuse, sinon elle revient par le prochain fichier, ecrit par quelqu'un qui n'a lu aucun des
# precedents.
#
# ⚠ ON MESURE LE CODE, PAS LA PROSE — meme regle que `adminite_walls.bats`, et pour la meme raison :
# les cicatrices de ce depot NOMMENT ce qu'elles interdisent, c'est leur metier. Un mur qui lirait
# les commentaires interdirait de les ecrire.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # fleet/

  # ⚠ LE PERIMETRE SE DIT PAR SHEBANG, ET C'EST L'INVARIANT LUI-MEME QUI L'EXIGE. `EUID` n'est pose
  # que par bash : dans un fichier `#!/bin/sh`, `${EUID:-...}` est un repli LEGITIME, et un mur qui
  # balaierait `*.sh` l'accuserait a tort. Dans l'autre sens, balayer par extension raterait
  # `bin/fleet_v2`, `bin/lcars`, `deploy/box`, `deploy/provision`, `deploy/accept` — des programmes
  # bash sans suffixe. La question n'est pas « quel nom porte le fichier » mais « quel interprete
  # le lit », et la seule reponse est sur sa premiere ligne.
  #
  # ⚠ CE QUI EST EXCLU, ET CE QUI NE L'EST PAS — la premiere redaction de ce commentaire disait
  # « tests hors perimetre », et c'etait FAUX de son propre instrument : `*/tests/*` ne retire que
  # les suites de `deploy/tests/` et `git-hooks/tests/`, pas les 32 fichiers bash de `test/`, qui
  # SONT balayes. La mesure du 2026-08-27 : deploy 41 · test 32 · bin 11 · services 8 ·
  # git-hooks 4 · etc 3 · vendor 2 · priv 1 = 102.
  #
  # Et c'est le bon perimetre : un repli mort dans un temoin est une affirmation fausse comme
  # ailleurs. La seule exclusion NECESSAIRE est celle des fichiers de mur eux-memes — la liste de
  # variables ci-dessous est du CODE, donc un mur inclus dans son propre balayage s'accuse au
  # premier motif qu'il epingle. `*/tests/*` la couvre, et c'est sa vraie raison d'etre.
  mapfile -t BASH_CODE < <(
    find "$REPO" -type f \
      -not -path '*/tests/*' -not -path '*/_build/*' -not -path '*/deps/*' -not -path '*/.git/*' \
      2>/dev/null \
      | while read -r f; do
          head -1 "$f" 2>/dev/null | grep -qE '^#!.*(bash|bats)' && echo "$f"
        done | sort
  )
}

# Le code d'un fichier, prose retiree. La troncature sur un `#` qui n'ouvre pas un commentaire
# (`${VAR#motif}`, `"$#"`) fait PERDRE de la fin de ligne : le mur peut donc sous-compter, jamais
# accuser a tort. C'est le sens qui protege.
code_of() { sed 's/#.*//' "$1"; }

@test "MUR: le perimetre n'est pas VIDE — un balayage casse compte zero, comme un sans-faute" {
  # Sans ce garde, un `find` qui ne trouve plus rien (arbre deplace, `head -1` qui change de forme)
  # rendrait le mur vert en n'ayant rien lu. C'est la forme d'echec la plus chere : elle certifie.
  # ⚠ UN PLANCHER NE VOIT PAS LA PERTE D'UN ARBRE, ET J'AI POSE LE DEFAUT ICI AVANT DE LE CHASSER
  # AILLEURS : 60 pour 102 fichiers laisse perdre `test` (32) EN ENTIER sans un mot. Les deux murs
  # voisins portaient la meme forme, a 30 pour 123 et 30 pour 65.
  #
  # Le balayage etant par SHEBANG, il n'y a pas de liste d'arbres a consommer — le garde nomme donc
  # les cinq arbres stables, un par voie d'entree du bash dans ce depot : recette, temoins,
  # programmes de PATH, demons, outils d'install. Perdre l'un d'eux se voit ici.
  local t
  for t in deploy test bin services etc; do
    printf '%s\n' "${BASH_CODE[@]}" | grep -q "^$REPO/$t/" || {
      echo "MUR 0 rompu — l'arbre « $t » ne contribue AUCUN fichier bash au perimetre" >&2
      return 1
    }
  done
  [ "${#BASH_CODE[@]}" -ge 85 ]
  # Trois membres NOMMES, un par forme de nom : suffixe, sans suffixe, et le fichier meme pour
  # lequel ce mur a ete ecrit. Si `install.sh` sort du perimetre, c'est ici que ca rougit.
  printf '%s\n' "${BASH_CODE[@]}" | grep -q '/etc/install.sh$'
  printf '%s\n' "${BASH_CODE[@]}" | grep -q '/bin/fleet_v2$'
  printf '%s\n' "${BASH_CODE[@]}" | grep -q '/deploy/lib/provision-lib.sh$'
}

@test "MUR 1: aucun repli sur une variable que bash pose TOUJOURS" {
  # Bash pose ces variables au demarrage de chaque shell, avant la premiere ligne du script. Leur
  # ecrire un repli garde contre un cas qui n'existe pas — la branche de repli est du code MORT,
  # et personne ne le saura jamais parce qu'elle ne s'execute pas.
  #
  # ⚠ LE COUT N'EST PAS LE FORK QU'ON N'ECONOMISE PAS. C'est que la ligne AFFIRME que la valeur peut
  # manquer. `${1:-${EUID:-$(id -u)}}` se lit « trois sources possibles » alors qu'il y en a deux,
  # et le lecteur suivant ecrit son propre garde en croyant cette affirmation. Un repli est une
  # documentation executable de ce qui peut arriver ; contre l'impossible, il documente faux.
  #
  # ⚠ QUATRE VARIABLES INTERNES SONT DELIBEREMENT ABSENTES DE CETTE LISTE, et leur absence est la
  # mesure qui rend la liste utilisable :
  #   · `FUNCNAME`  — n'existe QUE dans un appel de fonction, vide au niveau du fichier ;
  #   · `OLDPWD`    — non pose tant qu'aucun `cd` n'a eu lieu ;
  #   · `BASH_SOURCE`— tableau, dont l'element lu peut legitimement ne pas exister ;
  #   · `HOSTNAME`  — pose par bash, mais sa valeur depend de l'hote et un repli y est un choix.
  # Un repli sur ces quatre-la est du code VIVANT. Les mettre dans la liste aurait fait de ce mur
  # un mur qui a raison en moyenne, ce qui n'est pas une propriete d'un mur.
  local internes='EUID|UID|PPID|BASHPID|RANDOM|SECONDS|LINENO|SHLVL|GROUPS|PWD|IFS|BASH_VERSION|MACHTYPE|OSTYPE|HOSTTYPE'

  # Les formes REFUSEES sont celles qui INVENTENT une valeur : `${V-x}`, `${V:-x}`, `${V=x}`,
  # `${V:=x}`. Pas `${V:?msg}` ni `${V?msg}` — celles-la REFUSENT, et un refus contre l'impossible
  # est du bruit, pas un mensonge. Pas `${V:+x}` non plus : elle ne se declenche que si la variable
  # EST posee, donc elle ne parle pas de son absence.
  local motif="\\\$\\{($internes):?[-=]"

  local f n total=0 rompu=0
  for f in "${BASH_CODE[@]}"; do
    n="$(code_of "$f" | grep -cE -- "$motif" || true)"
    [ "$n" -eq 0 ] && continue
    rompu=1
    total=$((total + n))
    echo "MUR 1 rompu — ${f#"$REPO"/} :" >&2
    code_of "$f" | grep -nE -- "$motif" >&2
  done
  [ "$rompu" -eq 0 ] || {
    echo "MUR 1 : $total repli(s) contre une variable que bash pose toujours." >&2
    echo "Le geste : retirer le repli, pas le remplacer par un autre." >&2
    return 1
  }
}
