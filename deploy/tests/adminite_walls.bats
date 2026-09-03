#!/usr/bin/env bats
# SOURCE: deploy/tests/adminite_walls.bats
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

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2013 — lecture mot a mot VOULUE : le champ mesure ne contient pas d'espace
# shellcheck disable=SC2013

setup() {
  # ⚠ LE CHEMIN EST RESOLU, ET SANS CA LE MUR MESURAIT ZERO FICHIER. `$BATS_TEST_DIRNAME/../..`
  # garde `deploy/tests/` dans la chaine, donc l'exclusion `-not -path '*/tests/*'` plus bas
  # eliminait TOUT le perimetre — les quatre murs passaient au vert sur une liste vide. C'est le
  # garde d'instrument juste en dessous qui l'a attrape, pas la relecture.
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # la RACINE du depot — `deploy/` et `fleet/` y sont FRERES depuis la separation
  # Le perimetre : ce qui S'EXECUTE. Les temoins (`deploy/tests`, `test/`) nomment legitimement ce
  # qu'ils epinglent, et les documents de chantier ne tournent nulle part.
  # ⚠ LA LISTE DES ARBRES EST UNE VARIABLE, ET C'EST CE QUI REND LE GARDE DERIVABLE. Ecrite en
  # dur dans le `find`, elle ne pouvait etre comparee a rien : le garde plus bas devait la RECOPIER,
  # donc il aurait fallu maintenir deux listes pour qu'un arbre perdu se voie. Une seule source, et
  # le garde la consomme.
  ARBRES=("$REPO/deploy" "$REPO/fleet/services" "$REPO/fleet/bin" "$REPO/fleet/priv")
  mapfile -t CODE < <(
    # ⚠ `services` EST DANS LE PERIMETRE, ET C EST LA MOITIE QUI COMPTE : c'est la que vivent
    # l'executeur de catalogue, le convergeur d'humains et le convergeur d'outillage — le code
    # privilegie de la machine. L'oublier ferait passer les murs au vert en n'ayant rien lu.
    find "${ARBRES[@]}" -type f \
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
  # ⚠ UN PLANCHER NE VOIT PAS LA PERTE D'UN ARBRE, ET CELUI-CI ETAIT A 30 POUR 123 FICHIERS
  # (mesure du 2026-08-27 : deploy 43, priv 59, services 12, bin 9). Perdre `priv` en entier laisse
  # 64 fichiers — vert. Perdre `services`, la moitie qui compte selon le commentaire du `find`
  # ci-dessus, en laisse 111 — vert. Le plancher ne detecte que le balayage TOTALEMENT casse.
  #
  # CHAQUE ARBRE NOMME DOIT DONC CONTRIBUER, et la regle se DERIVE de `ARBRES` — elle ne le recopie
  # pas. Un arbre ajoute au `find` est garde le jour meme, sans que personne y pense.
  local a
  for a in "${ARBRES[@]}"; do
    printf '%s\n' "${CODE[@]}" | grep -q "^$a/" || {
      echo "MUR 0 rompu — l'arbre « ${a#"$REPO"/} » ne contribue AUCUN fichier au perimetre" >&2
      return 1
    }
  done
  # Le plancher reste, un cran sous la mesure : il attrape la perte massive qu'un arbre encore
  # represente par un seul fichier laisserait passer.
  [ "${#CODE[@]}" -ge 100 ]
  printf '%s\n' "${CODE[@]}" | grep -q 'forge-gestures.sh'
  printf '%s\n' "${CODE[@]}" | grep -q 'catalogue-executor.py'
  printf '%s\n' "${CODE[@]}" | grep -q 'bin/lcars'
}

@test "MUR 1: le jeton master et le seed ne sont poses QUE pour leur detenteur, sans groupe" {
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
  for porte in "$REPO/fleet/bin/lcars" "$REPO/fleet/services/catalogue-executor.py"; do
    [ -r "$porte" ]
    absent 'id -nG|getent group|os\.getgroups|grp\.getgrall' "$porte"
  done
  # ⚠ UNE EXCEPTION NOMMEE, ET ELLE N'EN EST PAS UNE : l'executeur consulte le groupe pour poser
  # celui DE SA SOCKET. Ce groupe borne qui peut FRAPPER, il n'autorise rien — l'autorisation vient
  # de `SO_PEERCRED` puis de la forge. Confondre les deux serait refaire le defaut.
  #
  # ⚠ ET CE TEMOIN EXIGEAIT `grp.getgrnam`, C'EST-A-DIRE UNE IMPLEMENTATION. Il aurait rougi sur un
  # `bind()` qui pose son groupe autrement — donc il EMPECHAIT un changement legitime au lieu de
  # garder une propriete. Un temoin qui epingle le code qu'on vient d'ecrire ne mesure rien, il fige.
  #
  # La propriete, elle, est de PORTEE : toute consultation de groupe dans ce fichier vit dans
  # `bind()`. Ailleurs, c'est une decision d'autorisation qui lit une projection — le defaut.
  # ⚠ ET LA CONSULTATION A DEMENAGE : elle vit dans `lcars_socket.bind()`, le module que TOUS les
  # services importent. Le mur suit l'objet, sinon il garde une adresse vide — c'est exactement le
  # perimetre mort qu'un garde d'instrument existe pour attraper.
  local cible hors_bind
  for cible in "$REPO/fleet/services/catalogue-executor.py" "$REPO/fleet/services/lcars_socket.py"; do
    [ -r "$cible" ]
    hors_bind="$(code_of "$cible" | sed '/^def bind(/,/^def /d' \
                  | grep -cE 'grp\.|getgrnam|getgrall' || true)"
    [ "$hors_bind" -eq 0 ] || {
      echo "MUR 2 bis rompu — le groupe est consulte HORS de bind() dans $cible ($hors_bind fois)" >&2
      return 1
    }
  done
  # Garde d'instrument : si `bind()` cesse d'exister ou change de nom, la coupe ci-dessus ne
  # retirerait plus rien et le mur passerait au vert sur un fichier qu'il n'a pas lu.
  code_of "$REPO/fleet/services/lcars_socket.py" | grep -q '^def bind('
  # Et la consultation existe QUELQUE PART : un mur vert sur zero occurrence ne mesure rien.
  code_of "$REPO/fleet/services/lcars_socket.py" | grep -q 'getgrnam'
}

@test "MUR 3: le convergeur ne lit plus l'autorite de la boite" {
  # Il PROVISIONNE — un compte unix ne se cree pas au moment ou quelqu'un tape. Il n'AUTORISE pas :
  # ca se demande a l'instant ou ca compte. Son unique usage du jeton master etait la projection.
  local c="$REPO/fleet/services/human-converger.sh"
  [ -r "$c" ]
  absent 'MASTER_TOKEN' "$c"
  absent 'forge-master' "$c"
  # Le garde d'instrument : il lit TOUJOURS le jeton systeme, sinon il ne converge rien.
  code_of "$c" | grep -q 'TOKEN_FILE='
}

# ─── MUR 5 — LE DECK A UNE IDENTITE A LUI, ET LE FICHIER DE SON SECRET LA NOMME ─────────────────
#
# ⚠ `nobody` N'EST PAS UNE IDENTITE, c'est la convention de ceux qui n'en ont pas choisi. Le prix ne
# se lisait pas sur l'uid mais sur le GROUPE : `deck-oidc.json` porte le `client_secret` OAuth2 de la
# boite et se posait `0640 root:nogroup`, avec pour motif « le mode le plus etroit qui marche ».
# Releve sur une Debian/Ubuntu ordinaire le 2026-08-27 : `nogroup` (gid 65534) est le groupe PRIMAIRE
# de `sync`, `_apt`, `nobody` et `dhcpcd`. Un demon reseau lisait le secret.
#
# ⚠ ET LE MANIFESTE EN DECLARAIT UN TROISIEME. Il disait `root:fleet` — ce qui aurait ouvert le
# secret a tout HUMAIN de la fleet, l'exact contraire de ce que le module annoncait. Deux documents,
# deux valeurs, et RIEN qui les compare : c'est le temoin qui manquait autant que la valeur. Le
# second test ci-dessous est ce temoin, et il vaut independamment du compte qu'on choisit.

@test "MUR 5: le deck ne se depose plus sur une identite partagee, et son compte existe des DEUX cotes" {
  local landing="$REPO/fleet/services/console-landing.sh"
  local dockerfile="$REPO/deploy/docker/Dockerfile"
  local mod="$REPO/deploy/modules.d/21-service-accounts.sh"

  # Le drop ne nomme plus `nobody` : ni en uid, ni en gid.
  absent 'reuid nobody' "$landing"
  absent 'regid nogroup' "$landing"
  # ... et il nomme un compte, par une variable dont le defaut est lisible.
  code_of "$landing" | grep -q 'DECK_USER="\${LCARS_DECK_USER:-lcars-system}"'

  # LES DEUX RAILS POSENT LE COMPTE. En verifier un seul laisserait l'autre demarrer un `setpriv`
  # vers un nom que `/etc/passwd` ne connait pas — et `setpriv` echoue alors en parlant de lui-meme.
  grep -q 'useradd --system .* lcars-system' "$dockerfile"
  code_of "$mod" | grep -q 'SYSTEM_USER="\${PROV_SYSTEM_USER:-lcars-system}"'
  code_of "$mod" | grep -q -- '-g "\$SYSTEM_GROUP" -- "\$SYSTEM_USER"'
}

@test "MUR 5 bis: le groupe du secret OIDC est le compte du deck, et le MANIFESTE dit la meme chose" {
  # LE TEMOIN QUI MANQUAIT. Deux documents portent le proprietaire de ce fichier : le module qui
  # l'ecrit et le manifeste qui declare l'empreinte machine. Rien ne les comparait, et ils ont
  # diverge — `nogroup` d'un cote, `fleet` de l'autre. Un manifeste qui ment sur un secret est pire
  # qu'un manifeste absent : on le lit pour savoir qui peut lire.
  local mod="$REPO/deploy/modules.d/55-deck-oidc.sh"
  local manifest="$REPO/deploy/system.manifest"
  local row group

  # ⚠ LE REPLI EST IMBRIQUE DEPUIS LE 2026-08-28, ET CE MOTIF NE LE LISAIT PLUS. `55-deck-oidc`
  # gravait `${PROV_SYSTEM_GROUP:-lcars-system}` pendant que `21-service-accounts`, qui CREE le
  # compte, derive `${PROV_SYSTEM_GROUP:-$SYSTEM_USER}` : deux replis pour une variable, qui
  # divergent des qu'on regle `PROV_SYSTEM_USER` seul. Le module derive desormais lui aussi
  # (`${PROV_SYSTEM_GROUP:-${PROV_SYSTEM_USER:-<nom>}}`), et ce temoin lit LE NOM AU FOND de la
  # chaine — c'est lui que le manifeste doit porter, quel que soit le nombre de replis devant.
  group="$(code_of "$mod" | sed -nE 's@^OIDC_GROUP=.*:-([a-z0-9-]+)\}+"$@\1@p')"
  [ -n "$group" ] || { echo "OIDC_GROUP illisible dans $mod" >&2; return 1; }

  row="$(grep -E '^anchor[[:space:]]+/etc/lcars/deck-oidc\.json[[:space:]]' "$manifest")"
  [ -n "$row" ] || { echo "deck-oidc.json n'est plus declare dans le manifeste" >&2; return 1; }
  [[ "$row" == *0640* ]] || { echo "mode attendu 0640 : $row" >&2; return 1; }
  [[ "$row" == *"root:$group"* ]] \
    || { echo "le module pose root:$group, le manifeste declare autre chose : $row" >&2; return 1; }
}

@test "MUR 5 ter: lcars-console n'a AUCUN membre declare — il s'accorde a l'exec, jamais par adhesion" {
  # C'EST CE QUI LE GARDE ETROIT. Le groupe donne la traversee vers la socket du terminal de CHAQUE
  # humain : une adhesion persistante rendrait ce pouvoir disponible a tout ce qui prendrait cette
  # identite ensuite. Root le rend a un processus nomme, a l'exec (`setpriv --groups`), et
  # l'ensemble des detenteurs est VIDE entre deux lancements.
  local f
  for f in "${CODE[@]}"; do
    absent 'ensure_member.*(lcars-console|PROV_CONSOLE_GROUP)' "$f"
    absent 'usermod.*-aG.*(lcars-console|PROV_CONSOLE_GROUP)' "$f"
  done
}

@test "MUR 4: le detenteur des secrets n'a AUCUN privilege noyau, sur les DEUX rails" {
  # ⚠ LE PARTAGE QUI TIENT TOUT LE MODELE : celui qui DETIENT ne peut pas escalader, celui qui
  # ESCALADE ne detient rien. `lcars-authority` porte les secrets de la forge et tourne sous un
  # compte systeme ; `lcars-converger` porte `useradd` et n'ouvre aucun secret.
  #
  # Deux rails, deux mecanismes de drop, et il FAUT les deux : l'unite systemd sur le poste,
  # `setpriv` dans le conteneur — qui n'a pas systemd et dont l'entrypoint est PID 1. En verifier un
  # seul laisserait l'autre tourner en root sans qu'une ligne le dise.
  local unit="$REPO/deploy/modules.d/64-services.sh"
  local entry="$REPO/deploy/docker/entrypoint.sh"
  local dockerfile="$REPO/deploy/docker/Dockerfile"

  # RAIL POSTE : l'unite du service d'autorite porte un `User=`, celle du convergeur n'en porte PAS.
  code_of "$unit" | sed -n '/lcars-catalogue)/,/^      ;;/p' | grep -q 'User='
  run bash -c "sed 's/#.*//' '$unit' | sed -n '/lcars-converger)/,/^      ;;/p' | grep -c 'User=' || true"
  [ "$output" -eq 0 ]

  # RAIL CONTENEUR : le service est depose par setpriv, et le compte existe dans l'image.
  code_of "$entry" | grep -q 'setpriv .*catalogue-executor.py\|setpriv[^|]*\\$'
  code_of "$entry" | grep -q 'catalogue-executor.py'
  grep -q 'useradd --system .* lcars-authority' "$dockerfile"

  # LE COMPTE EST POSE PAR LE RAIL POSTE AUSSI — sinon `User=` designe un compte absent et l'unite
  # meurt au demarrage sur `failed to determine user credentials`.
  [ -r "$REPO/deploy/modules.d/21-service-accounts.sh" ]
  code_of "$REPO/deploy/modules.d/21-service-accounts.sh" | grep -q 'useradd'
}

@test "MUR 4 bis: le nom du compte est une COPIE, et les copies s'accordent" {
  # DEUX fichiers le copient, et deux seulement : le rail BOITE. `entrypoint.sh` et le `Dockerfile`
  # ne sourcent pas `provision-lib.sh` — ils ne peuvent pas LIRE le nom, donc ils l'ecrivent. Les
  # deux modules du rail POSTE le lisaient en `${PROV_AUTHORITY_USER:-lcars-authority}` : une copie
  # sur une branche morte, retiree le 2026-08-27 (`MUR 2` de `variable_walls` la refuse desormais).
  # Moins de copies vaut mieux qu'une copie verifiee ; ce mur garde celles qui ne peuvent pas
  # disparaitre.
  #
  # ⚠ ET IL ETAIT SATISFAIT PAR N'IMPORTE QUOI, MESURE DEUX FOIS LE MEME JOUR :
  #
  #   1. PAR UNE SOUS-CHAINE FORTUITE. `grep -q -- "lcars-authority"` sur le `Dockerfile` matche
  #      `lcars-authority-ask`, un nom de BINAIRE. Mutation jouee : le compte renomme en
  #      `lcars-autoritay` dans le `useradd` — le mur restait VERT. Le verrou cense tenir le nom du
  #      compte du service d'autorite ne tenait rien dans l'image.
  #
  #   2. PAR UN COMMENTAIRE. `grep` brut, sans retrait de la prose. Apres avoir retire les deux
  #      copies mortes, les deux modules avaient `CODE=0` occurrence du nom — et le mur restait VERT,
  #      satisfait par le commentaire qui documentait le RETRAIT de la copie qu'il verifiait.
  #
  # On mesure donc le CODE, et on ancre sur le GESTE : l'image CREE le compte (`useradd`),
  # l'entrypoint le POSE dans sa variable. Un nom qui apparait ailleurs ne compte pas.
  local attendu
  attendu="$(sed -n 's/^: "${PROV_AUTHORITY_USER:=\([a-z-]*\)}"$/\1/p' "$REPO/deploy/lib/provision-lib.sh")"
  [ -n "$attendu" ] || { echo "MUR 4 bis — l'autorite est illisible dans provision-lib.sh" >&2; return 1; }

  code_of "$REPO/deploy/docker/Dockerfile" \
    | grep -qE "useradd.*[[:space:]]${attendu}([[:space:]]|\\\\|$)" || {
      echo "MUR 4 bis rompu — le Dockerfile ne CREE pas le compte « $attendu » (useradd)" >&2
      code_of "$REPO/deploy/docker/Dockerfile" | grep -nE 'useradd.*lcars' >&2
      return 1
    }

  code_of "$REPO/deploy/docker/entrypoint.sh" \
    | grep -qE "LCARS_AUTHORITY_USER=\"\\\$\{LCARS_AUTHORITY_USER:-${attendu}\}\"" || {
      echo "MUR 4 bis rompu — l'entrypoint ne pose pas « $attendu » dans LCARS_AUTHORITY_USER" >&2
      code_of "$REPO/deploy/docker/entrypoint.sh" | grep -nE 'LCARS_AUTHORITY_USER=' >&2
      return 1
    }
}
