#!/usr/bin/env bats
# SOURCE: deploy/tests/services_dir.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for runtime/services — un repertoire par ROLE, et il doit le rester
#
# ⚠ CE QUE CES TEMOINS TIENNENT, ET QU'UN MIROIR DE LISTES NE PEUT PAS TENIR.
#
# Croiser une LISTE avec une AUTRE LISTE — les auxiliaires declares contre les `COPY` de
# l'image — ne voit pas le REPERTOIRE. Un fichier PRESENT et declare NULLE PART n'est dans
# aucune des deux listes comparees : il est invisible a ce croisement-la, par construction.
#
# Un fichier range est un fichier dont plus personne ne se demande s'il sert. Ces temoins
# refusent qu'un fichier vive ici sans etre pose quelque part.

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2012 — `ls` sur des noms que ce depot controle — pas de nom exotique a manier
# shellcheck disable=SC2012

load refute

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # la RACINE du depot — `deploy/` et `runtime/` y sont FRERES
  MOD="$REPO/deploy/modules.d/62-runtime-helpers.sh"
  DOCKERFILE="$REPO/deploy/docker/Dockerfile"
  SERVICES="$REPO/runtime/services"
  [ -f "$MOD" ] && [ -f "$DOCKERFILE" ] && [ -d "$SERVICES" ]
}

# La liste des auxiliaires, EXTRAITE du module — jamais recopiee : un instrument qui mesure une copie
# de la source ne mesure pas la source, il est vert au moment precis ou ca derive.
helpers() {
  sed -n '/^HELPERS=(/,/^)/p' "$MOD" | sed '1d;$d;s/#.*//' | tr -d ' \t' | grep -v '^$'
}
# Les DONNEES de 62 (`DATA`, « nom destination mode ») declarent leur fichier par leur premier champ —
# `console.tmux.conf` en vient, et il n'est plus nomme par un COPY de l'image depuis le 2026-09-11.
data() {
  sed -n '/^DATA=(/,/^)/p' "$MOD" | sed '1d;$d;s/#.*//' | tr -d '"' | awk 'NF { print $1 }'
}

# ─── LES DEUX POSES EN BLOC, ET POURQUOI ELLES SE MESURENT SÉPARÉMENT ────────────────────────────
#
# ⚠ DEPUIS QUE LES DEUX RAILS POSENT L'ARBRE ENTIER, « est-il posé ? » NE DISCRIMINE PLUS.
# Le conteneur fait `COPY runtime/services /opt/lcars/services` (Dockerfile), le poste embarque
# `services` dans `EMBEDDED` (62-runtime-helpers) : tout fichier rangé ici arrive sur les deux
# machines, déclaré ou non. Répondre « oui » pour chacun rendrait le témoin vert sur du vide.
#
# CE QUI RESTE VRAI ET NON TRIVIAL, C'EST QUE LES DEUX RAILS POSENT LA MÊME CHOSE. Un fichier qui
# n'est nommé nulle part ne survit que par ces deux lignes ; si l'une disparaît, il atteint un rail
# et pas l'autre — sans un mot, parce qu'aucune LISTE ne le mentionne.
#
# ⚠ CE SONT DEUX PROPRIÉTÉS, ET ELLES NE SE MÉLANGENT PAS — cette prose disait le contraire, et le
# code ne l'a jamais fait (relecture hostile du 2026-09-08). La PROPRIÉTÉ 2 exige de CHAQUE fichier
# une déclaration ou une exemption NOMMÉE avec son poseur ; elle n'appelle `bulk_*` que pour rendre
# son message d'échec lisible. La PROPRIÉTÉ 3, elle, exige les deux poses en bloc — parce que ce
# sont elles, et elles seules, qui portent les 12 fichiers exemptés jusqu'aux machines.
# ⚠ CES DEUX SONDES ETAIENT FAUSSES DANS LES DEUX SENS, mesure par relecture hostile le 2026-09-08.
#   · `bulk_docker` ne regardait NI la destination NI la strate : `COPY runtime/services /tmp/poubelle`
#     passait, et un COPY deplace dans la strate `build` (jetee) aussi — le scenario meme que cette
#     propriete pretend fermer. Il rougissait en revanche sur `COPY runtime/services/ /opt/...` (slash
#     final, forme Docker idiomatique), sur un double espace, et sur la forme JSON.
#   · `bulk_poste` : la plage `sed '/^EMBEDDED=(/,/)/' ` cherche la fin APRES la ligne de debut ;
#     le tableau tenant sur une ligne, elle courait jusqu'au premier `)` suivant — quatre lignes de
#     commentaire incluses. `services` dans un commentaire voisin suffisait a rendre VERT.
#     Et `EMBEDDED=("etc" "services" "bin")` (quotage shellcheck) rougissait.
# On lit donc la SOURCE et la DESTINATION, on tolere les formes equivalentes, et on ne lit que la
# ligne du tableau.
bulk_poste() { # `services` est-il dans le TABLEAU EMBEDDED, et pas dans un commentaire voisin ?
  grep -E '^EMBEDDED=\(' "$MOD" | sed 's/#.*//' | tr ' ()"' '\n\n\n\n' | grep -qx 'services'
}
# ⚠ `appele()` A ETE RETIRE LE 2026-09-08, ET C'EST UNE RETRACTATION. Il demandait « quelqu'un
# ecrit-il cette chaine hors de services/ ? » et pretendait mesurer « quelqu'un l'appelle ». Une
# relecture hostile l'a casse en deux appats : `gate.sh` et `lib/provision-lib.sh` poses ici, gares,
# declares NULLE PART — VERTS, parce que ces noms apparaissent 31 et 84 fois ailleurs dans le depot.
# Pire, c'etait une REGRESSION : l'ancien temoin exigeait HELPERS ou COPY pour tout fichier de
# premier niveau et accusait `gate.sh` ; le mien le laissait passer. Le message du commit `2c585572`
# affirmait « rien n'a ete perdu » — c'etait faux, et mesurable en une commande.
#
# La regle redevient donc : TOUT fichier est DECLARE. Les 16 fichiers racine le sont deja (verifie).
# Les cinq repertoires que ni HELPERS ni un COPY nominatif ne nomment sont EXEMPTES A LA LIGNE, avec
# leur poseur reel — meme motif que les exemptions d'ISO 2/2 dans `system_manifest.bats` : « une
# ligne par objet, jamais une regex ». Elargir cette liste sans nommer le poseur rouvrirait la porte
# exacte que ce temoin ferme.
# declare_couvre <chemin-relatif> — le chemin lui-même, ou un de ses RÉPERTOIRES ancêtres, est-il
# nommé ? `COPY runtime/services/forge-recipe …` couvre `forge-recipe/gate.sh`, et c'est voulu :
# nommer un répertoire est une déclaration, nommer chacun de ses fichiers serait une liste à tenir.
declare_couvre() {
  local p="$1" liste; liste="$(helpers; data)"
  while :; do
    printf '%s\n' "$liste" | grep -qx "$p" && return 0
    [[ "$p" == */* ]] || return 1
    p="${p%/*}"
  done
}

@test "GARDE D'INSTRUMENT : les deux listes sont NON VIDES" {
  # Sans ce garde, une extraction cassee (tableau renomme, COPY reecrit, repertoire deplace) rendrait
  # les deux temoins ci-dessous verts en n'ayant RIEN compare. C'est la forme d'echec la plus chere :
  # elle certifie. Ce chantier meme a fait rougir cinq temoins pour cette raison — chacun a refuse
  # plutot que de passer au vert sur du vide.
  [ "$(helpers | wc -l)" -ge 8 ]
  [ "$(ls -1 "$SERVICES" | wc -l)" -ge 10 ]
}

@test "PROPRIETE 1 : deploy/docker ne porte plus AUCUN auxiliaire pose" {
  # Le repertoire `docker/` redevient ce que son nom dit : du packaging conteneur. Un auxiliaire qui
  # y reapparaitrait remettrait du runtime privilegie sous un nom d'outil — le defaut que ce chantier
  # repare, et il se referait par simple habitude d'un `git mv` de confort.
  local n bad=()
  while read -r n; do
    [[ -e "$REPO/deploy/docker/$n" ]] && bad+=("$n")
  done < <(helpers)
  [ "${#bad[@]}" -eq 0 ] || {
    echo "auxiliaires revenus dans deploy/docker/ : ${bad[*]}" >&2
    false
  }
}

@test "PROPRIETE 2 : tout fichier de services est POSE quelque part" {
  # ⚠ C'EST LE TEMOIN QUI ATTRAPE LE FICHIER QUE PERSONNE N'A DECLARE, et aucun autre ne le fait :
  # le miroir de `runtime_helpers` croise deux LISTES, celui-ci croise le REPERTOIRE avec elles. Un
  # fichier present et declare nulle part n'est pas un service, c'est une exploration garee — et un
  # fichier range est un fichier dont plus personne ne se demande s'il sert.
  local base bad=()
  # ⚠ ON MESURE CE QUE GIT SUIT, PAS CE QUE LE DISQUE PORTE. Un `__pycache__` regenere par le
  # premier `python3` venu n'est pas un service non declare : c'est un artefact, deja ignore
  # (`.gitignore:28`). Un temoin qui le compte crie a chaque execution de test, et un mur qui
  # crie sans raison apprend a etre ignore.
  # ⚠ CE TEMOIN NE DESCENDAIT PAS, ET SA PROPRE PROSE DISAIT QUE C'ETAIT UNE LIMITE : « le jour ou
  # un sous-repertoire apparait, c'est ICI qu'il faut descendre ». Sept sont apparus (agent,
  # container, forge-recipe, forge.d, human.d, lib, admiral) et 32 fichiers sur 48 vivaient hors de
  # portee. La condition annoncee est survenue ; on descend.
  # (les deux poses en bloc sont mesurees par la PROPRIETE 3, pas ici)
  while read -r base; do
    # ⚠ UNE SEULE EXCLUSION, ET ELLE EST NOMMEE — meme regle que le miroir de
    # `runtime_helpers.bats`, qui nomme les siennes. La carte d'une couche n'est pas un
    # service : c'est la convention par laquelle ce depot documente un repertoire
    # (`deploy/README.md`, `lib/fleet/<dom>/README.md`), et elle n'est posee nulle part par
    # construction. Elargir cette exclusion — a `*.md`, a un repertoire — rouvrirait la porte
    # exacte que ce temoin ferme.
    [[ "$(basename "$base")" == "README.md" ]] && continue
    declare_couvre "$base" && continue
    # ⚠ EXEMPTIONS NOMMEES — une ligne par repertoire, avec SON poseur. Ces cinq arbres ne sont
    # nommes ni par HELPERS ni par un COPY : ils n'arrivent que par les deux poses en bloc, que la
    # PROPRIETE 3 tient a part. Chacun est ici parce qu'un appelant reel le lit, verifie le
    # 2026-09-08 par `git grep -l "services/<d>"` hors de son propre arbre.
    # ⚠ PAR FICHIER, PAS PAR REPERTOIRE. Un `forge.d/*` exempterait tout fichier POSE dans forge.d/ —
    # exactement l'exploration garee que ce temoin existe pour attraper, et le relecteur l'a montre
    # en glissant un `lib/provision-lib.sh` mort dans un repertoire exempte. Une ligne par objet,
    # avec son appelant reel (verifie le 2026-09-08 par `git grep -l` hors de son propre arbre).
    case "$base" in
      # ⚠ DEUX ARBRES QUE LE COPY DE L'IMAGE NOMMAIT, ET QUE LE RAIL LIT PAR LEUR RACINE — le jumeau
      # est parti le 2026-09-11, leur lecteur reel reste : un fichier par ligne, avec lui.
      forge-recipe/*)             continue ;;  # 61-forge-structure (LCARS_RECIPE_DIR, copie de l'arbre entier)
      admiral/skills/system-issues/SKILL.md) continue ;;  # container/init.sh (le skill du siege)
      admiral/skills/system-issues/list.sh)  continue ;;  # container/init.sh
      agent/claude-automode.json) continue ;;  # human.d/70-human.sh
      container/boot.sh)          continue ;;  # ENTRYPOINT du Dockerfile
      container/init.sh)          continue ;;  # boot.sh, 25-directories
      forge.d/catalogues.sh)      continue ;;  # 45-catalogues
      forge.d/deck-oidc.sh)       continue ;;  # 66-deck-oidc
      forge.d/ops-branch.sh)      continue ;;  # 65-ops-branch
      forge.d/tokens.sh)          continue ;;  # 63-forge-tokens
      human.d/40-claude-bin.sh)   continue ;;  # 60-deploy (convergeur d'humains)
      human.d/70-human.sh)        continue ;;  # 60-deploy, provision-lib
      human.d/75-projects.sh)     continue ;;  # 60-deploy
      lib/human-protocol.sh)      continue ;;  # provision-lib, 22-fleet-human
      lib/module-protocol.sh)     continue ;;  # provision-lib, 63-forge-tokens
    esac
    bad+=("$base")
  done < <(cd "$SERVICES" && git ls-files)
  [ "${#bad[@]}" -eq 0 ] || {
    echo "dans services/ mais pose NULLE PART (ni HELPERS, ni la pose en bloc) : ${bad[*]}" >&2
    echo "  soit c'est un service — declare-le ; soit ce n'en est pas un — il n'a rien a faire ici." >&2
    echo "  bloc (EMBEDDED de 62, les deux terrains) : $(bulk_poste && echo present || echo ABSENT)" >&2
    false
  }
}

@test "PROPRIETE 3 : le rail pose l'arbre entier — c'est ce qui tient les fichiers non nommes, sur les deux terrains" {
  # ⚠ SANS CE TEMOIN, LA PROPRIETE 2 SERAIT VERTE POUR UNE RAISON QU'ELLE NE DIRAIT PAS. 12 fichiers
  # sur 48 (agent/, container/, forge.d/, human.d/, lib/) ne sont nommes NULLE PART : ni dans
  # HELPERS, ni dans un COPY — ce sont exactement les 12 exemptions nominatives de la PROPRIETE 2,
  # comptees le 2026-09-08 (48 suivis, 4 README, 12 exemptes, 32 nommes). Le chiffre disait 15, et
  # aucun compte ne le rendait. Ils n'arrivent sur les machines que par ces deux lignes-ci. Les
  # mesurer separement, c'est nommer la dependance au lieu de la subir — et rendre le refus lisible
  # le jour ou l'une des deux part.
  # Depuis le 2026-09-11 l'image se pose par le meme rail : UNE pose en bloc, celle de 62, sert les
  # deux terrains. Le `COPY runtime/services` de l'image etait le jumeau ; il est parti.
  bulk_poste  || { echo "62-runtime-helpers n'embarque plus 'services' (EMBEDDED)" >&2
                   echo "  12 fichiers non nommes n'atteignent plus les machines — declare-les, ou remets-le dans EMBEDDED" >&2; false; }
  refute grep -qE '^COPY .*runtime/services' "$DOCKERFILE"
}
