#!/usr/bin/env bash
# SOURCE: runtime/services/forge.d/catalogues.sh
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: PROTO-V2 — le materiel des catalogues INSTALLES, converge depuis la forge
# JOUE PAR : le boot du conteneur (a chaque demarrage) et l'installeur d'un poste, par un
# appelant mince. Ni terrain ni ordre ne se declarent ici : ces en-tetes ne sont lus que dans
# `deploy/modules.d`, et les recopier ici promettait une mecanique que personne ne joue.
# AUCUNE AUTORITE N'EST REQUISE, et c'est deliberé. Un depot de catalogue est PUBLIC par
# construction (⚖ user : un depot prive est simplement invisible, on ne fait pas de tuto forge), donc
# la lecture et le clone se font en anonyme. Un conteneur qui n'a jamais recu `container config`
# converge quand meme son materiel — elle ne peut simplement pas en installer de nouveau.

set -euo pipefail

# Ce geste est joue par le boot du conteneur et, sur un poste, par 50-catalogues (un appelant
# mince) ; l'hote — l'un ou l'autre, ou un temoin — nomme le fichier du protocole.
# shellcheck source=../lib/module-protocol.sh
. "${LCARS_MODULE_PROTOCOL:?LCARS_MODULE_PROTOCOL non pose — lance via un module de l installeur ou le boot du conteneur, pas le geste nu}"

# LE MAGASIN DES CATALOGUES : UN DEPOT DU SYSTEME, UNE BRANCHE PAR CATALOGUE (⚖ user 2026-09-16).
# `Fleet.Catalogue` en est l'autorite ; `forge-gestures.sh` ECRIT dessus ; ce geste LIT. Un temoin
# tient les trois d'accord. L'org systeme se lit dans le protocole (une org renommee emmene ses
# depots), le nom du depot est un litteral — c'est la meme adresse pour toutes les installations.
STORE_REPO="_catalogues"
STORE_FULL="${LCARS_FORGE_ORG}/${STORE_REPO}"
MANIFEST="catalogue.yaml"
# La page que la forge sert, et le budget de pages. Gitea borne la page a SA limite (50 par defaut) :
# demander 100 n'en rend pas 100, donc la fin de liste se lit a une page COURTE, jamais a la taille
# demandee. Le budget borne une forge qui repondrait toujours plein.
PAGE_LIMIT=50
PAGES_MAX=40


# LE CATALOGUE DE LA RELEASE N'EST PAS SUIVI ICI. Son magasin est sur la forge — il s'installe comme
# les autres (`forge-gestures apply`) —, mais son materiel est la release elle-meme, et
# `Fleet.Catalogue` ignore un dossier installe de ce nom : le cloner poserait un arbre mort. Son nom
# se demande a la release (`lcars tool catalogue-root`, puis le `name:` du manifeste, colonne zero).
# Sans reponse, rien n'est exclu et c'est DIT : un arbre mort de plus n'est pas une panne.
# `lcars_cli` vit dans le protocole : trois gestes la cherchaient, avec le meme corps.
bundled_name() {
  local cli root
  cli="$(lcars_cli)"
  [[ -r "$cli" ]] || return 0
  root="$(bash "$cli" tool catalogue-root 2>/dev/null | tail -n1)" || root=""
  [[ -n "$root" && -r "$root/$MANIFEST" ]] || return 0
  awk '/^name:/ { sub(/^name:[ \t]*/, ""); sub(/[ \t]*#.*$/, ""); gsub(/"/, ""); sub(/[ \t]+$/, ""); if ($0 != "") { print; exit } }' "$root/$MANIFEST"
}
BUNDLED="$(bundled_name)"

#   * l'IDENTITE — `manifest.name == <nom de la branche>`. C'est ce qui decide. Une branche posee
#     sous le nom d'un catalogue mais dont le manifeste ne se declare pas a ce nom n'est pas le
#     magasin de ce catalogue : le cloner le servirait sous un nom qu'il ne revendique pas, et le
#     roster du mint en descendrait. 404 sur le manifeste = cette branche ne porte pas un catalogue
#     (reponse — c'est le cas de `main`, qui porte le README du magasin) ; illisible = HOLD ;
#   * l'ORG DU CATALOGUE — sa source sans ses comptes de role est un install interrompu, et ses
#     projets n'auraient nulle part ou naitre. 200 = org, 404 = pas d'org, le reste est une ABSENCE
#     de reponse et ne conclut rien (HOLD) ;
#   * LA PAGINATION — le serveur borne la page a SA limite (`api.MAX_RESPONSE_ITEMS`, 50 par defaut
#     sur Gitea), et une liste partielle lue comme entiere ferait SUPPRIMER le materiel des
#     catalogues au-dela de la borne. Les pages sont donc suivies jusqu'a une page COURTE, avec un
#     budget ; une page pleine au budget est un refus, jamais une convergence sur une liste partielle.
#
# ⚠ ET LA REGLE QUI TIENT TOUT LE MODULE : ON NE SUPPRIME QUE SUR UNE LECTURE REUSSIE. « Le magasin
# n'existe pas » est une reponse quand il n'y a rien en local, et un DRIFT des qu'il y a du materiel
# a effacer : un depot prive lu en anonyme, une org renommee, une recette jamais jouee rendent le
# meme 404 qu'une forge qui n'a rien installe, et trois de ces quatre causes ne justifient aucun
# effacement (relecture hostile du 2026-09-17).
#
# Sorties, TOUJOURS trois champs : « OK <nom> <url> » / « HOLD <nom> <cause> ». La cause est portee
# parce qu'il y a DEUX facons de ne pas savoir — le manifeste ou l'org — et qu'un refus qui nomme la
# mauvaise envoie l'operateur regarder le mauvais objet.
# rc=1 forge muette, illisible ou liste tronquee · rc=2 magasin ABSENT (404) · rc=0 liste signee.
forge_installed() {
  # ⚠ `jq` EST UN PREREQUIS DE CETTE LECTURE, et son absence ne doit pas ressembler a une forge vide :
  # sans lui, le corps ne se lit pas, et « aucune branche » ferait effacer tout le cache.
  command -v jq >/dev/null 2>&1 || return 1

  local page=1 body code noms recues
  while :; do
    [[ "$page" -le "$PAGES_MAX" ]] || return 1
    body="$(curl -sS -m 20 -w '\n%{http_code}' \
      "$FORGE_BASE_URL/api/v1/repos/$STORE_FULL/branches?page=$page&limit=$PAGE_LIMIT" 2>/dev/null)" \
      || return 1
    code="${body##*$'\n'}"
    body="${body%$'\n'*}"

    case "$code" in
      200) : ;;
      404) return 2 ;;
      *)   return 1 ;;
    esac

    # LE CORPS DOIT ETRE UN TABLEAU JSON. Un proxy, une page d'erreur ou un corps tronque rendent 200
    # avec autre chose : lu comme une liste vide, il ferait effacer le materiel de TOUS les catalogues.
    noms="$(printf '%s' "$body" | jq -r 'if type == "array" then (.[].name // empty) else error("pas un tableau") end' 2>/dev/null)" \
      || return 1
    recues="$(printf '%s' "$body" | jq -r 'length' 2>/dev/null)" || return 1

    local nom
    while read -r nom; do
      [[ -n "$nom" ]] || continue
      signe_branche "$nom"
    done <<< "$noms"

    # Une page COURTE est la derniere : la suivante serait vide. Une page PLEINE demande la suivante.
    [[ "$recues" -ge "$PAGE_LIMIT" ]] || return 0
    page=$((page + 1))
  done
}

# Ce qu'une branche du magasin signe, ou ne signe pas. Imprime une ligne de la liste signee, ou rien.
signe_branche() { # signe_branche <branche>
  local name="$1" declared drc code
  # le catalogue de la release n'est suivi par personne ici : son materiel EST la release
  [[ -z "$BUNDLED" || "$name" != "$BUNDLED" ]] || return 0

  drc=0
  declared="$(declared_name "$name")" || drc=$?
  [[ "$drc" -eq 2 ]] && { printf 'HOLD %s manifeste\n' "$name"; return 0; }
  # Pas de manifeste : la branche par defaut du magasin porte un README, et c'est normal.
  [[ "$drc" -eq 1 ]] && return 0

  if [[ "$declared" != "$name" ]]; then
    if [[ -z "$declared" ]]; then
      echo "${LCARS_MODULE_TAG:-catalogues}: $STORE_FULL:$name repond, mais son $MANIFEST ne declare aucun" \
           "\`name:\` en COLONNE ZERO — non signe. En YAML un \`name:\` indente appartient a la cle du dessus." >&2
    else
      echo "${LCARS_MODULE_TAG:-catalogues}: $STORE_FULL:$name se declare \`$declared\` — ce n'est pas le magasin" \
           "de $name, il n'est pas signe." >&2
    fi
    return 0
  fi

  # L'ORG DU CATALOGUE EST L'AUTRE MOITIE DE L'INSTALLATION : sa source sans ses comptes de role est
  # un install interrompu, et ses projets n'auraient nulle part ou naitre.
  code="$(curl -sS -o /dev/null -w '%{http_code}' -m 10 "$FORGE_BASE_URL/api/v1/orgs/$name" 2>/dev/null)" || code=000
  case "$code" in
    200) printf 'OK %s %s\n' "$name" "${FORGE_BASE_URL%/}/${STORE_FULL}.git" ;;
    404) : ;;
    *)   printf 'HOLD %s proprietaire\n' "$name" ;;
  esac
}

# Le `name:` que la branche `$1` du magasin declare. rc=0 avec le nom sur stdout · rc=1 pas de
# manifeste (une REPONSE : cette branche ne porte pas un catalogue) · rc=2 la forge n'a pas repondu
# (une ABSENCE de reponse, qui ne conclut rien). Le code de sortie et pas une sentinelle dans la sortie : un nom de
# catalogue est une chaine libre, et toute valeur reservee finit par etre celle de quelqu'un.
#
# ⚠ COLONNE ZERO, meme regle que `CatalogueDeposits.manifest_name/1` et pour la meme raison : en YAML
# un `name:` INDENTE appartient a la cle du dessus (`roles:\n  name: dev` declare un role), donc
# accepter une indentation laisserait le premier `name:` imbrique voler l'identite du catalogue.
#
# `-sS` sans `-f` : le corps ET le code sont necessaires, et `-f` avalerait le corps sur un 404.
#
declared_name() {
  local raw code body
  raw="$(curl -sS -m 10 -w '\n%{http_code}' "$FORGE_BASE_URL/api/v1/repos/$STORE_FULL/raw/$MANIFEST?ref=$1" 2>/dev/null)" \
    || raw=$'\n000'
  code="${raw##*$'\n'}"
  body="${raw%$'\n'*}"

  case "$code" in
    200) printf '%s' "$body" | awk '
           /^name:/ { sub(/^name:[ \t]*/, ""); sub(/[ \t]*#.*$/, ""); gsub(/"/, "");
                      sub(/[ \t]+$/, ""); if ($0 != "") { print; exit } }' ;;
    404) return 1 ;;
    *)   return 2 ;;
  esac
}

local_installed() {
  local d
  [[ -d "$LCARS_CATALOGUES_DIR" ]] || return 0
  for d in "$LCARS_CATALOGUES_DIR"/*/; do
    [[ -f "${d}catalogue.yaml" ]] || continue
    basename "$d"
  done
}

# Le sha que la forge porte sur la branche d'un catalogue, sans cloner. La branche porte le nom du
# catalogue : c'est le magasin qui le decide (`push_store`), pas le proprietaire de la source.
remote_head() { # remote_head <url du magasin> <branche>
  GIT_TERMINAL_PROMPT=0 git ls-remote "$1" "refs/heads/$2" 2>/dev/null | awk 'NR==1{print $1}'
}
local_head()  { git -c safe.directory="$1" -C "$1" rev-parse HEAD 2>/dev/null || true; }

# ⚠ UN RELIQUAT QUE LE PRODUIT NE PEUT PAS RETIRER SE DIT — c'est la seule chose qu'on puisse en
# faire honnetement. Aucun geste du rail ne touche a `/home`, donc un cache de catalogues laisse
# la-bas y restera : se taire laisserait un arbre orphelin de plusieurs centaines de mega sur une
# machine dont l'operateur croit que le produit gere ses chemins. Ce n'est PAS un drift : un drift
# promet qu'`apply` converge, et `apply` ne le fera jamais.
LEGACY_CATALOGUES_DIR="$LCARS_LEGACY_CATALOGUES_DIR"

say_leftover() {
  [[ -d "$LEGACY_CATALOGUES_DIR" ]] || return 0
  [[ "$LEGACY_CATALOGUES_DIR" != "$LCARS_CATALOGUES_DIR" ]] || return 0
  p_warn "$LEGACY_CATALOGUES_DIR subsiste — le cache des catalogues a déménagé sous $LCARS_CATALOGUES_DIR. Rien sous /home n'est retiré par LCARS : à supprimer à la main si vous n'en voulez plus (« rm -rf $LEGACY_CATALOGUES_DIR »), le matériel se reclone depuis la forge"
}

# ─── FORGE INCONNUE : LE VERBE DEPEND DE CE QUE LA MACHINE PORTE DEJA ───────────────────────────
#
# L'adresse vient de `FORGE_BASE_URL` ou de `$LCARS_PRIVATE_DIR/forge.url`. Sans elle, deux cas.
# Aucun catalogue installe : il n'y a rien a cloner ni a comparer, et la fleet tourne sur le
# catalogue embarque de la release — un WARN (on ne sait pas, et ca ne coute rien). Du materiel
# LOCAL et plus d'adresse (jetons disparus, cache survivant) : un etat-cible cesse d'etre tenu — un
# DRIFT, parce que `p_warn` n'incremente ni LCARS_DRIFT ni LCARS_FAILED et que le bilan resterait vert.
# ⚠ UN MAGASIN QUI REPOND 404 NE PROUVE PAS QU'IL N'Y A RIEN D'INSTALLE. Gitea rend le meme 404 pour
# quatre faits differents : le depot n'existe pas (la recette n'a pas ete jouee), il est prive et ce
# geste lit en ANONYME, l'org systeme a ete renommee sous nos pieds, ou quelqu'un l'a supprime a la
# main. Une seule de ces causes veut dire « aucun catalogue installe ». Alors :
#   - rien en local : c'est une REPONSE, et le conteneur tourne sur le catalogue de la release ;
#   - du materiel en local : c'est un DRIFT, et on n'efface RIEN — la regle de surete du module.
# Rend 0 quand l'appelant peut continuer (rien a effacer), 1 quand il doit s'arreter la.
magasin_absent() { # magasin_absent <check|apply>
  local n=0
  [[ -d "$LCARS_CATALOGUES_DIR" ]] \
    && n="$(find "$LCARS_CATALOGUES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  if [[ "$n" -gt 0 ]]; then
    p_drift "magasin des catalogues ABSENT ($STORE_FULL) alors que $n catalogue(s) sont installes ici ($LCARS_CATALOGUES_DIR) — leur source est injoignable, RIEN n'est supprime. Le depot est pose par la recette de la forge (sur un poste « deploy/workstation up » ; pour un conteneur « deploy/container forge-apply » depuis l'hote) ; s'il existe, il est peut-etre prive — ce geste le lit en anonyme"
    return 1
  fi
  p_ok "magasin des catalogues absent de la forge ($STORE_FULL) et rien d'installe ici — la fleet tourne sur le catalogue de la release"
  return 0
}

forge_inconnue() { # forge_inconnue <verbe: check|apply> — dit le bon mot, selon ce qui est deja la
  local n=0
  [[ -d "$LCARS_CATALOGUES_DIR" ]] \
    && n="$(find "$LCARS_CATALOGUES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  if [[ "$n" -gt 0 ]]; then
    p_drift "adresse de forge inconnue alors que $n catalogue(s) sont déjà installés ici ($LCARS_CATALOGUES_DIR) — leur autorité est injoignable, rien ne peut être comparé ni convergé. Sur un poste, « deploy/workstation up » écrit $LCARS_PRIVATE_DIR/forge.url ; pour un conteneur, « FORGE_BASE_URL=<url> deploy/container config » depuis l'hôte, puis « deploy/container up »"
  else
    p_warn "adresse de forge inconnue, et AUCUN catalogue installé ici — rien à comparer : la fleet tourne sur le catalogue embarqué de la release"
  fi
}

check() {
  say_leftover
  [[ -n "$BUNDLED" ]] || p_warn "nom du catalogue de la release inconnu (« lcars tool catalogue-root » ne repond pas) — son magasin, s'il est sur la forge, sera suivi comme un catalogue installe"
  if [[ -z "$FORGE_BASE_URL" ]]; then
    forge_inconnue check
    verdict_check
  fi

  local signed status name arg url rc=0
  signed="$(forge_installed)" || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    magasin_absent check
    verdict_check
  elif [[ "$rc" -ne 0 ]]; then
    p_drift "magasin des catalogues ILLISIBLE ($STORE_FULL) — l'etat installe des catalogues n'a pas pu etre lu (forge muette, reponse inattendue, liste tronquee, ou jq absent)"
    verdict_check
  fi

  local seen=" "
  while read -r status name arg; do
    [[ -n "$name" ]] || continue
    seen="$seen$name "
    if [[ "$status" == "HOLD" ]]; then
      p_drift "catalogue $name : $arg illisible sur la forge — rien n'est conclu"
      continue
    fi
    url="$arg"

    local dir="$LCARS_CATALOGUES_DIR/$name"
    if [[ ! -d "$dir/.git" ]]; then
      p_drift "catalogue $name installe sur la forge, materiel absent ici ($dir)"
    elif [[ "$(local_head "$dir")" != "$(remote_head "$url" "$name")" ]]; then
      p_drift "catalogue $name en retard sur sa source ($url, branche $name)"
    else
      p_ok "catalogue $name a jour"
    fi
  done <<< "$signed"

  local have
  while read -r have; do
    [[ -n "$have" ]] || continue
    [[ "$seen" == *" $have "* ]] || p_drift "materiel de $have present ici, la forge ne l'installe plus"
  done < <(local_installed)

  verdict_check
}

apply() {
  # Dit AUSSI a l'apply : c'est le geste que l'operateur lance apres une mise a jour, donc celui ou
  # le demenagement vient d'avoir lieu. Le taire ici le reserverait a qui pense a jouer un doctor.
  say_leftover
  [[ -n "$BUNDLED" ]] || p_warn "nom du catalogue de la release inconnu (« lcars tool catalogue-root » ne repond pas) — son magasin, s'il est sur la forge, sera suivi comme un catalogue installe"
  [[ -n "$FORGE_BASE_URL" ]] || { forge_inconnue apply; verdict_apply; }

  local signed rc=0
  signed="$(forge_installed)" || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    magasin_absent apply || verdict_apply
    signed=""
  elif [[ "$rc" -ne 0 ]]; then
    p_drift "magasin des catalogues ILLISIBLE ($STORE_FULL) — materiel laisse EN L'ETAT, rien n'est supprime (forge muette, reponse inattendue, liste tronquee, ou jq absent)"
    verdict_apply
  fi

  # `mkdir -p` et pas `install -d -o root -g root` : la PROPRIETE de ce repertoire appartient a
  # `25-directories`, dont c'est tout le metier, et deux modules qui posent le meme owner finissent
  # par ne plus etre d'accord. Ici on garantit seulement qu'il existe avant d'y ecrire.
  mkdir -p "$LCARS_CATALOGUES_DIR"

  local status name arg url dir seen=" "
  while read -r status name arg; do
    [[ -n "$name" ]] || continue
    # HOLD entre dans `seen` et nulle part ailleurs : son materiel survit au balayage (on n'a pas pu
    # lire le type du proprietaire, on ne conclut rien), et rien n'est clone sous un nom non signe.
    seen="$seen$name "
    if [[ "$status" == "HOLD" ]]; then
      p_drift "catalogue $name : $arg illisible — materiel laisse EN L'ETAT"
      continue
    fi
    url="$arg"

    dir="$LCARS_CATALOGUES_DIR/$name"

    if [[ -d "$dir/.git" ]]; then
      # `fetch` + `reset --hard` et PAS `pull` : le cache n'a pas d'historique a preserver, et un
      # `pull` sur un depot reecrit cote proprietaire s'arrete sur un conflit de merge qu'aucun
      # humain ne viendra resoudre ici.
      # le cache appartient au compte d'autorite : git joue en root le refuse sans `safe.directory`,
      # et ce qu'il y ecrit revient ensuite au proprietaire du cache
      if GIT_TERMINAL_PROMPT=0 git -c safe.directory="$dir" -C "$dir" fetch --quiet --depth 1 origin "refs/heads/$name" \
         && git -c safe.directory="$dir" -C "$dir" reset --quiet --hard FETCH_HEAD; then
        [[ "$EUID" -ne 0 ]] || chown -R --reference="$LCARS_CATALOGUES_DIR" "$dir"
        p_ok "catalogue $name converge ($(local_head "$dir" | cut -c1-8))"
      else
        p_drift "catalogue $name : fetch impossible depuis $url (branche $name) — materiel laisse EN L'ETAT"
      fi
      continue
    fi

    # Le clone atterrit a cote puis se renomme : un clone interrompu laisserait sinon un repertoire
    # a demi rempli SOUS le nom du catalogue, et le boot suivant le verifierait comme s'il etait
    # entier. `mv` dans le meme systeme de fichiers est un rename atomique.
    rm -rf "$dir.tmp"
    if GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --branch "$name" "$url" "$dir.tmp"; then
      # un clone joue en root prend le proprietaire du cache : l'installation, sous le compte
      # d'autorite, doit pouvoir le remplacer
      [[ "$EUID" -ne 0 ]] || chown -R --reference="$LCARS_CATALOGUES_DIR" "$dir.tmp"
      rm -rf "$dir"
      mv "$dir.tmp" "$dir"
      p_ok "catalogue $name clone depuis $url (branche $name)"
    else
      rm -rf "$dir.tmp"
      p_drift "catalogue $name : clone impossible depuis $url"
    fi
  done <<< "$signed"

  local have
  while read -r have; do
    [[ -n "$have" ]] || continue
    if [[ "$seen" != *" $have "* ]]; then
      rm -rf "${LCARS_CATALOGUES_DIR:?}/$have"
      p_ok "materiel de $have retire (la forge ne l'installe plus)"
    fi
  done < <(local_installed)

  verdict_apply
}

case "${1:?usage: catalogues.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
