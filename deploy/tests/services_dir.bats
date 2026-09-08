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

# Ce que le Dockerfile pose a plat dans /opt/lcars depuis `services/`, plus le convergeur qui va
# ailleurs (`/usr/local/bin`) — il est pose, donc il compte.
# ⚠ `COPY` PORTE DES OPTIONS, ET LE MOTIF LES IGNORAIT. `COPY --chmod=0644 runtime/services/x /y` ne
# matchait pas « ^COPY runtime/services/ » : le fichier etait declare « pose NULLE PART » alors qu'il
# etait copie juste devant. Le premier `--chmod` du Dockerfile (2026-09-01, ecart de mode
# poste/conteneur) a fait rougir ce temoin — et un mur qui rougit sur la CORRECTION du defaut qu'il
# existe pour attraper est un mur qui apprend a etre contourne.
copied() {
  sed -n 's|^COPY \(--[^ ]* \)*runtime/services/\([^ ]*\) .*|\2|p' "$DOCKERFILE"
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
# et pas l'autre — sans un mot, parce qu'aucune LISTE ne le mentionne. Le témoin exige donc les
# DEUX, et accuse les fichiers non nommés dès qu'il n'y en a plus qu'une.
bulk_docker() { grep -qE '^COPY( --[^ ]+)* runtime/services +/' "$DOCKERFILE"; }
bulk_poste()  { sed -n '/^EMBEDDED=(/,/)/p' "$MOD" | tr ' ()' '\n\n\n' | grep -qx 'services'; }
# appele <chemin-relatif> — quelqu'un, HORS de services/, nomme-t-il ce chemin ?
#
# ⚠ C'EST CE QUI REMPLACE « est-il pose ? », DEVENU TRIVIAL. Les deux poses en bloc font arriver
# TOUT fichier range ici sur les deux machines : repondre « oui » pour chacun rendrait le temoin
# vert sur du vide. La question qui discrimine encore est celle que l'en-tete de ce fichier pose
# depuis le debut — « un fichier range est un fichier dont plus personne ne se demande s'il sert » —
# et elle se mesure : un fichier que RIEN n'appelle est une exploration garee.
# Mesure du 2026-09-08 : les 12 fichiers non nommes et non-README ont de 1 a 22 appelants.
appele() {
  git -C "$REPO" grep -l -- "$1" -- . ':!runtime/services' >/dev/null 2>&1
}
# declare_couvre <chemin-relatif> — le chemin lui-même, ou un de ses RÉPERTOIRES ancêtres, est-il
# nommé ? `COPY runtime/services/forge-recipe …` couvre `forge-recipe/gate.sh`, et c'est voulu :
# nommer un répertoire est une déclaration, nommer chacun de ses fichiers serait une liste à tenir.
declare_couvre() {
  local p="$1" liste; liste="$(helpers; copied)"
  while :; do
    printf '%s\n' "$liste" | grep -qx "$p" && return 0
    [[ "$p" == */* ]] || return 1
    p="${p%/*}"
  done
}

@test "GARDE D'INSTRUMENT : les trois listes sont NON VIDES" {
  # Sans ce garde, une extraction cassee (tableau renomme, COPY reecrit, repertoire deplace) rendrait
  # les deux temoins ci-dessous verts en n'ayant RIEN compare. C'est la forme d'echec la plus chere :
  # elle certifie. Ce chantier meme a fait rougir cinq temoins pour cette raison — chacun a refuse
  # plutot que de passer au vert sur du vide.
  [ "$(helpers | wc -l)" -ge 8 ]
  [ "$(copied | wc -l)" -ge 10 ]
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
    # Non nomme dans une liste : alors il faut qu'il soit APPELE. Un fichier ni declare ni appele
    # n'est tenu que par les deux poses en bloc — il arrive sur les machines et personne ne s'en
    # sert : c'est exactement l'exploration garee que ce temoin existe pour attraper.
    appele "$base" && continue
    bad+=("$base")
  done < <(cd "$SERVICES" && git ls-files)
  [ "${#bad[@]}" -eq 0 ] || {
    echo "dans services/ mais pose NULLE PART (ni HELPERS, ni COPY, ni les deux poses en bloc) : ${bad[*]}" >&2
    echo "  soit c'est un service — declare-le ; soit ce n'en est pas un — il n'a rien a faire ici." >&2
    echo "  bloc conteneur (COPY runtime/services) : $(bulk_docker && echo present || echo ABSENT)" >&2
    echo "  bloc poste (EMBEDDED de 62)            : $(bulk_poste  && echo present || echo ABSENT)" >&2
    false
  }
}

@test "PROPRIETE 3 : les DEUX rails posent l'arbre entier — c'est ce qui tient les fichiers non nommes" {
  # ⚠ SANS CE TEMOIN, LA PROPRIETE 2 SERAIT VERTE POUR UNE RAISON QU'ELLE NE DIRAIT PAS. 15 fichiers
  # sur 48 (agent/, container/, forge.d/, human.d/, lib/) ne sont nommes NULLE PART : ni dans
  # HELPERS, ni dans un COPY. Ils n'arrivent sur les machines que par ces deux lignes-ci. Les
  # mesurer separement, c'est nommer la dependance au lieu de la subir — et rendre le refus lisible
  # le jour ou l'une des deux part.
  bulk_docker || { echo "le Dockerfile ne pose plus l'arbre entier (COPY runtime/services /...)" >&2
                   echo "  15 fichiers non nommes n'atteignent plus le CONTENEUR — declare-les, ou remets le COPY" >&2; false; }
  bulk_poste  || { echo "62-runtime-helpers n'embarque plus 'services' (EMBEDDED)" >&2
                   echo "  15 fichiers non nommes n'atteignent plus le POSTE — declare-les, ou remets-le dans EMBEDDED" >&2; false; }
}
