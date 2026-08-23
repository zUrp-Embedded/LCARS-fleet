#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/adminite_walls.bats
# AUTHOR: bob
# STARDATE: 2026-08-23
# STATUS: actif — les deux invariants de l'adminite, tenus par une mesure et non par la discipline
#
# ⚠ POURQUOI DES MURS ET PAS DES TEMOINS PAR FICHIER. Le chantier qui a retire le groupe unix a
# touche vingt-quatre fichiers. Chacun a son temoin, et chacun est vert — mais un vingt-cinquieme
# site, ecrit dans six mois par quelqu'un qui n'a lu aucun des vingt-quatre, ne rougirait nulle
# part. Une regle tenue par de la discipline est une regle que le prochain site rate.
#
# LES DEUX INVARIANTS :
#   1. aucun process d'humain ne peut lire le jeton master ni le seed ;
#   2. aucune porte n'interroge un groupe unix pour decider d'une adminite.
#
# ⚠ ON MESURE LE CODE, PAS LA PROSE. Les cicatrices de ce depot NOMMENT ce qu'elles ont retire —
# c'est leur metier. Un mur qui attraperait l'explication d'un defaut interdirait de l'expliquer, et
# la prochaine session referait le defaut faute de savoir pourquoi il en etait un. Chaque balayage
# retire donc les commentaires avant de compter.

setup() {
  # ⚠ LE CHEMIN EST RESOLU, ET SANS CA LE MUR MESURAIT ZERO FICHIER. `$BATS_TEST_DIRNAME/../..`
  # garde `deploy/tests/` dans la chaine, donc l'exclusion `-not -path '*/tests/*'` plus bas
  # eliminait TOUT le perimetre — les quatre murs passaient au vert sur une liste vide. C'est le
  # garde d'instrument juste en dessous qui l'a attrape, pas la relecture.
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # fleet/
  # Le perimetre : ce qui S'EXECUTE. Les temoins (`deploy/tests`, `test/`) nomment legitimement ce
  # qu'ils epinglent, et les documents de chantier ne tournent nulle part.
  mapfile -t CODE < <(
    find "$REPO/deploy" "$REPO/bin" "$REPO/priv" -type f \
      \( -name '*.sh' -o -name '*.py' -o -name '*.yaml' -o -name 'lcars' -o -name 'box' \
         -o -name 'accept' -o -name 'provision' -o -name 'Dockerfile' -o -name '*.manifest' \) \
      -not -path '*/tests/*' 2>/dev/null | sort
  )
}

# Le code d'un fichier, prose retiree. `#` couvre shell, python et yaml — les trois langages de ce
# perimetre. Un `#` dans une chaine serait un faux positif, mais dans le sens QUI PROTEGE : il cache
# du code au mur, donc le mur ne peut que sous-compter, jamais accuser a tort.
code_of() { sed 's/#.*//' "$1"; }

# ⚠ AUCUNE ASSERTION NEGATIVE DANS CE FICHIER, ET C'EST UNE CORRECTION MESUREE. Bash EXEMPTE de
# `set -e` toute commande dont le statut est inverse par `!` : une `! grep` qui n'est pas la
# DERNIERE instruction d'un test est INERTE — elle s'execute, elle echoue, et rien ne le remarque.
# Deux de ces murs etaient muets a leur premiere ecriture ; une mutation l'a montre, pas la
# relecture. Un mur inerte est pire qu'un mur absent : il certifie.
absent() { # absent <motif etendu> <fichier> — echoue si le CODE du fichier porte le motif
  local n; n="$(code_of "$2" | grep -cE -- "$1" || true)"
  [ "$n" -eq 0 ] || {
    echo "MUR rompu — « $1 » present $n fois dans le CODE de $2 :" >&2
    code_of "$2" | grep -nE -- "$1" >&2
    return 1
  }
}

@test "MUR: le perimetre n'est pas VIDE — un balayage casse compte zero, comme un sans-faute" {
  # Sans ce garde, un `find` qui ne trouve plus rien (arbre deplace, extension renommee) rendrait
  # les deux murs verts en n'ayant rien lu. C'est la forme d'echec la plus chere : elle certifie.
  [ "${#CODE[@]}" -ge 30 ]
  printf '%s\n' "${CODE[@]}" | grep -q 'forge-gestures.sh'
  printf '%s\n' "${CODE[@]}" | grep -q 'catalogue-executor.py'
  printf '%s\n' "${CODE[@]}" | grep -q 'bin/lcars'
}

@test "MUR 1: le jeton master et le seed ne sont poses QUE root seul" {
  # ⚠ CE MUR NE PEUT PAS SE DERIVER DU MANIFESTE, et le croire etait une erreur d'ecriture du plan.
  # `system.manifest` porte les REPERTOIRES ; le mode des deux secrets est pose ailleurs, par TROIS
  # ecrivains — `48-forge-host` au mint, `50-forge converge_authority_modes()` a chaque apply, et
  # `put_secret()` a l'ecriture. Un mur bati sur le manifeste serait VERT avec le jeton en 0640.
  # ⚠ ET CE MUR AVAIT LE DEFAUT QU'IL EXISTE POUR ATTRAPER. Il parcourt les lignes qui posent un
  # mode sur l'un des deux secrets — et si ces lignes DISPARAISSENT (un refactor amont, un rebase
  # qui deplace le geste ailleurs), la boucle tourne a vide et le mur passe au VERT en n'ayant rien
  # mesure. Un balayage doit distinguer « zero violation » de « population vide », toujours.
  local trouvees=0 f mode
  for f in "${CODE[@]}"; do
    trouvees=$((trouvees + $(code_of "$f" \
      | grep -cE 'MASTER_TOKEN_FILE|forge-master\.token|SEED_FILE|forge-seed\.pass' \
      | head -1) ))
  done
  [ "$trouvees" -ge 3 ] || {
    echo "MUR 1 INSTRUMENT CASSE — seulement $trouvees ligne(s) parlent des secrets d'autorite." >&2
    echo "  Ce mur ne mesure plus rien : les ecrivains ont bouge, ou le balayage est faux." >&2
    return 1
  }

  for f in "${CODE[@]}"; do
    # Les lignes de CODE qui posent un mode sur l'un des deux secrets.
    while IFS= read -r ligne; do
      [[ -z "$ligne" ]] && continue
      # Tout mode octal a quatre chiffres cite sur cette ligne doit etre 0600.
      for mode in $(grep -oE '0[0-7]{3}' <<<"$ligne"); do
        [[ "$mode" == "0600" ]] || {
          echo "MUR 1 rompu — $f pose un secret d'autorite en $mode :" >&2
          echo "  $ligne" >&2
          return 1
        }
      done
      # Et aucun groupe ne s'y attache.
      grep -qE 'root:(root)?$|root:root' <<<"$ligne" || grep -qv 'root:' <<<"$ligne" || {
        echo "MUR 1 rompu — $f attache un groupe a un secret d'autorite :" >&2
        echo "  $ligne" >&2
        return 1
      }
    done < <(code_of "$f" | grep -E 'MASTER_TOKEN_FILE|forge-master\.token|SEED_FILE|forge-seed\.pass' \
                          | grep -E 'chmod|chown|chgrp|write_atomic|install -m|0[0-7]{3}')
  done
}

@test "MUR 2: aucune porte n'interroge un groupe unix pour decider d'une adminite" {
  # `lcars-admin` PROJETAIT `is_admin` de la forge en adhesion unix, pour qu'un mode de fichier
  # serve de gate. Une projection est un cache : posee au login, jamais rattrapee dans un process
  # vivant — d'ou un convergeur pour la tenir, un poll pour la rafraichir, un rattrapage pour les
  # shells nes avant elle. L'adminite se DEMANDE a la forge a l'instant du geste.
  local f
  for f in "${CODE[@]}"; do
    absent 'lcars-admin|ADMIN_GROUP' "$f"
  done
}

@test "MUR 2 bis: les deux portes du geste ne lisent AUCUN groupe unix" {
  # Le mur ci-dessus interdit LE nom. Celui-ci interdit la MECANIQUE, sous n'importe quel nom : les
  # deux fichiers qui decident si un geste de catalogue a lieu ne consultent pas la base des
  # groupes. `bin/lcars` ne decide plus rien (il demande), et l'executeur demande a la forge.
  local porte
  for porte in "$REPO/bin/lcars" "$REPO/deploy/docker/catalogue-executor.py"; do
    [ -r "$porte" ]
    absent 'id -nG|getent group|os\.getgroups|grp\.getgrall' "$porte"
  done
  # ⚠ UNE EXCEPTION NOMMEE, ET ELLE N'EN EST PAS UNE : l'executeur appelle `grp.getgrnam` pour poser
  # le GROUPE DE SA SOCKET. Ce groupe borne qui peut FRAPPER, il n'autorise rien — l'autorisation
  # vient de `SO_PEERCRED` puis de la forge. Confondre les deux serait refaire le defaut.
  code_of "$REPO/deploy/docker/catalogue-executor.py" | grep -q 'grp.getgrnam'
}

@test "MUR 3: le convergeur ne lit plus l'autorite de la boite" {
  # Il PROVISIONNE — un compte unix ne se cree pas au moment ou quelqu'un tape. Il n'AUTORISE pas :
  # ca se demande a l'instant ou ca compte. Son unique usage du jeton master etait la projection.
  local c="$REPO/deploy/docker/human-converger.sh"
  [ -r "$c" ]
  absent 'MASTER_TOKEN' "$c"
  absent 'forge-master' "$c"
  # Le garde d'instrument : il lit TOUJOURS le jeton systeme, sinon il ne converge rien.
  code_of "$c" | grep -q 'TOKEN_FILE='
}
