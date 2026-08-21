#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/45-catalogues.sh
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: PROTO-V2 — le materiel des catalogues INSTALLES, converge depuis la forge
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# INSTALLE EST UN FAIT DE FORGE, ET CE MODULE EST CE QUI LE REND VRAI SUR LE DISQUE.
# `lcars catalogue install <nom>` pose deux choses sur la forge : l'org avec ses comptes de role, et
# la SOURCE du catalogue dans `<nom>/_catalogue`. Ce depot-la est la signature de l'installation. Ce
# module lit cette signature et fait suivre le materiel local — un clone, rien de plus.
#
# LE MATERIEL LOCAL EST UN CACHE, PAS UN ETAT. C'est ce qui autorise ce module a supprimer : ce
# qu'il efface est re-clonable depuis l'autorite, donc effacer ne perd rien. Un repertoire que la
# forge ne signe plus est un catalogue qu'on aurait continue a servir — des roles, des cartes et des
# projets qui tournent sur un metier que plus personne ne declare.
#
# ⚠ IL TOURNE AVANT `50-forge`, ET CET ORDRE PORTE LE ROSTER. Les comptes de role a minter se
# derivent du materiel present (`prov_roles`, provision-lib) : sans le materiel, la derivation
# retombe sur la liste tenue a la main, et un catalogue installe passe un cycle entier sans ses
# jetons — donc en `role_token_unavailable` au premier dispatch. La convergence doit precede le
# mint, pas le suivre.
#
# AUCUNE AUTORITE N'EST REQUISE, et c'est deliberé. Un depot de catalogue est PUBLIC par
# construction (⚖ user : un depot prive est simplement invisible, on ne fait pas de tuto forge), donc
# la lecture et le clone se font en anonyme. Une boite qui n'a jamais recu `docker.sh config`
# converge quand meme son materiel — elle ne peut simplement pas en installer de nouveau.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# Le nom du depot ou la source d'un catalogue installe est POUSSEE. C'est une ADRESSE — l'endroit ou
# `push_store` ecrit et ou l'on va donc chercher — jamais un predicat : rien ne se decide en la
# lisant, cf. l'identite ci-dessous. Le `_` initial est de l'UX (⚖ user, 2026-08-21) : il separe a
# l'oeil, dans une liste de depots, ce que la fleet a pose de ce qu'un humain a depose. Il ne
# protege rien et ne doit jamais recommencer a proteger quoi que ce soit.
STORE_REPO="_catalogue"
MANIFEST="catalogue.yaml"

# ⚠ LA REQUETE NE PORTE PAS LE PREFIXE, ET CE N'EST PAS UN OUBLI. `q=` est un match de SOUS-CHAINE
# cote Gitea — mesure — et `_catalogue` contient `catalogue`, donc chercher le mot nu ramene les
# deux. L'inverse n'est pas garanti : personne n'a mesure ce que le moteur de la forge fait d'un `_`
# initial (tokenisation, troncature), et ce module SUPPRIME sur une liste vide. Interroger sur un
# token dont le comportement EST mesure, puis trancher exactement ici, coute quelques entrees de
# plus dans la reponse et ne parie jamais le materiel de la boite sur une supposition.
STORE_QUERY="catalogue"

# ─── ce que la FORGE signe ────────────────────────────────────────────────────────────────────────
#
# UN DEPOT QUI SE DECLARE AU NOM DE SON ORG = CE CATALOGUE EST INSTALLE. Quatre filtres, chacun paye :
#
#   * l'ADRESSE, exacte — `q=catalogue` est un match de SOUS-CHAINE cote Gitea,
#     `mon-catalogue-perso` remonte aussi ; le filtre exact (`_catalogue`) est fait ici, sur
#     `.name`, jamais laisse au serveur. Il ne CONCLUT rien : il dit seulement ou regarder ;
#   * l'IDENTITE — `manifest.name == owner`. C'est ce qui decide. Un depot pose a l'adresse d'un
#     magasin, dans une org, mais qui ne se declare pas au nom de cette org, n'est pas le magasin de
#     ce catalogue : le cloner le servirait sous un nom qu'il ne revendique pas, et le roster du
#     mint en descendrait. 404 sur le manifeste = ce n'est pas un magasin (reponse) ; illisible =
#     HOLD (absence de reponse) ;
#   * le TYPE DU PROPRIETAIRE — ⚠ D1 de l'audit independant (2026-08-16) : orgs et comptes perso
#     partagent l'espace de noms, et sans ce filtre un user non-admin qui pousse un depot public
#     a cette adresse chez lui faisait apparaitre son login comme catalogue INSTALLE — clone de son
#     materiel, roster derive pour le mint, « seul un admin installe » contourne par un push.
#     L'IDENTITE NE LE REMPLACE PAS : `bob` qui declare `name: bob` chez lui la satisfait, et ment —
#     le catalogue `bob` ne peut pas etre installe sur une forge ou `bob` est un humain, son org
#     entrerait en collision avec le compte. L'objet `owner` de la recherche ne porte AUCUN champ
#     discriminant (mesure 1.26.1) ; la question se pose a `/orgs/<owner>` — 200 = org, 404 = espace
#     perso prouve, le reste est une ABSENCE de reponse et ne conclut rien (HOLD) ;
#   * la TRONCATURE — D4 : le serveur borne la page a SA limite, et une liste partielle lue comme
#     entiere ferait SUPPRIMER le materiel des catalogues au-dela de la borne. `X-Total-Count`
#     (mesure : le header existe) est compare au nombre recu ; ecart = refus, jamais une
#     convergence sur une liste partielle.
#
# Sorties, TOUJOURS trois champs : « OK <nom> <url> » / « HOLD <nom> <cause> ». La cause est portee
# parce qu'il y a maintenant DEUX facons de ne pas savoir — le manifeste ou le type du proprietaire —
# et qu'un refus qui nomme la mauvaise en envoie l'operateur regarder le mauvais objet.
# rc=1 forge muette, rc=3 liste tronquee.
forge_installed() {
  local hdr body total count
  hdr="$(mktemp)"
  body="$(curl -fsS -m 20 -D "$hdr" "$PROV_FORGE_URL/api/v1/repos/search?q=$STORE_QUERY&limit=50" 2>/dev/null)" \
    || { rm -f "$hdr"; return 1; }
  total="$(tr -d '\r' < "$hdr" | awk -F': ' 'tolower($1)=="x-total-count"{print $2}')"
  rm -f "$hdr"

  count="$(printf '%s' "$body" | jq -r '.data | length')"
  [[ -n "$total" && "$count" -lt "$total" ]] && return 3

  local name full url code declared drc
  while read -r name full url; do
    [[ -n "$name" ]] || continue

    # ⚠ DEUX LIGNES ET PAS UNE : `local d="$(f)"` rendrait TOUJOURS 0 — `local` est une commande, et
    # c'est SON code de sortie qui est vu, pas celui de la substitution. Le muet passerait alors pour
    # un manifeste absent, donc pour un refus, et le materiel serait supprime sur une non-reponse.
    drc=0
    declared="$(declared_name "$full")" || drc=$?
    [[ "$drc" -eq 2 ]] && { printf 'HOLD %s manifeste\n' "$name"; continue; }

    # ⚠ NE PAS SIGNER SE DIT, PARCE QUE CE MODULE SUPPRIME. Un depot pose ICI — a l'adresse exacte
    # d'un magasin — et que la forge nous a DECRIT sans qu'on le signe fait disparaitre `$name` de
    # `$signed`, donc de `$seen`, donc son materiel local part au balayage. C'etait muet : la seule
    # sortie etait « materiel de X retire », sans jamais dire quelle couche avait dit non.
    #
    # Sur STDERR et pas stdout : l'appelant CAPTURE stdout (`signed="$(forge_installed)"`) et le lit
    # champ par champ. Une ligne de diagnostic y deviendrait une entree de la liste signee.
    #
    # Le volume est borne : seuls les depots portant exactement le nom de l'adresse arrivent ici.
    if [[ "$declared" != "$name" ]]; then
      if [[ -z "$declared" ]]; then
        echo "45-catalogues: $full repond, mais son $MANIFEST ne declare aucun \`name:\` en" \
             "COLONNE ZERO — non signe. En YAML un \`name:\` indente appartient a la cle du dessus." >&2
      else
        echo "45-catalogues: $full se declare \`$declared\`, pas \`$name\` — ce n'est pas le magasin" \
             "de $name, il n'est pas signe." >&2
      fi
      continue
    fi

    code="$(curl -sS -o /dev/null -w '%{http_code}' -m 10 "$PROV_FORGE_URL/api/v1/orgs/$name" 2>/dev/null)" || code=000
    case "$code" in
      200) printf 'OK %s %s\n' "$name" "$url" ;;
      404) : ;;
      *)   printf 'HOLD %s proprietaire\n' "$name" ;;
    esac
  done <<< "$(printf '%s' "$body" \
    | jq -r --arg store "$STORE_REPO" \
           '.data[]? | select(.name == $store) | select(.empty != true)
            | "\(.owner.login) \(.full_name) \(.clone_url)"')"
}

# Le `name:` que le depot `$1` (`<owner>/<repo>`) declare. rc=0 avec le nom sur stdout · rc=1 pas de
# manifeste (une REPONSE : ce n'est pas un magasin) · rc=2 la forge n'a pas repondu (une ABSENCE de
# reponse, qui ne conclut rien). Le code de sortie et pas une sentinelle dans la sortie : un nom de
# catalogue est une chaine libre, et toute valeur reservee finit par etre celle de quelqu'un.
#
# ⚠ COLONNE ZERO, meme regle que `CatalogueDeposits.manifest_name/1` et pour la meme raison : en YAML
# un `name:` INDENTE appartient a la cle du dessus (`roles:\n  name: dev` declare un role), donc
# accepter une indentation laisserait le premier `name:` imbrique voler l'identite du catalogue.
#
# `-sS` sans `-f` : le corps ET le code sont necessaires, et `-f` avalerait le corps sur un 404.
#
# ⚠ LE `|| raw=$'\n000'` EST REDONDANT, ET IL RESTE — MESURE, pas suppose. L'assignation est dans une
# liste `||` chez l'appelant, donc bash y desactive `errexit` jusque dans la substitution : un `curl`
# qui echoue laisse simplement `raw` VIDE. `code` vaut alors `""`, qui tombe sur `*` du `case`,
# c'est-a-dire rc=2, c'est-a-dire HOLD — la meme reponse que le rescue. Les deux chemins convergent.
#
# Il est garde parce qu'il ENONCE l'intention, et retire il ne changerait rien : la mutation qui le
# supprime ne fait rougir aucun temoin (verifie le 2026-08-21). Ce qui est tenu par les temoins est
# la PROPRIETE — « pas de reponse -> HOLD » — et elle tient avec ou sans lui. Ne pas le lire comme
# un garde : le garde est le `*` du `case`.
declared_name() {
  local raw code body
  raw="$(curl -sS -m 10 -w '\n%{http_code}' "$PROV_FORGE_URL/api/v1/repos/$1/raw/$MANIFEST" 2>/dev/null)" \
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

# ─── ce que la BOITE porte ────────────────────────────────────────────────────────────────────────
#
# Un repertoire compte quand il porte un MANIFESTE, la meme regle que `Fleet.Catalogue` : un clone
# interrompu ou un `lost+found` n'est pas un catalogue, et le compter en ferait un que le boot
# refuserait de verifier.
local_installed() {
  local d
  [[ -d "$PROV_CATALOGUES_DIR" ]] || return 0
  for d in "$PROV_CATALOGUES_DIR"/*/; do
    [[ -f "${d}catalogue.yaml" ]] || continue
    basename "$d"
  done
}

# Le sha que la forge porte, sans cloner. `git ls-remote` sur `HEAD` suit la branche par defaut du
# depot, quel que soit son nom — la coder en dur ferait dependre la convergence d'une convention que
# le proprietaire du catalogue n'a jamais promise.
remote_head() { GIT_TERMINAL_PROMPT=0 git ls-remote "$1" HEAD 2>/dev/null | awk 'NR==1{print $1}'; }
local_head()  { git -C "$1" rev-parse HEAD 2>/dev/null || true; }

check() {
  if [[ -z "$PROV_FORGE_URL" ]]; then
    p_warn "FORGE_BASE_URL non posé — le materiel des catalogues ne peut pas etre compare a son autorite"
    verdict_check
  fi

  local signed status name arg url rc=0
  signed="$(forge_installed)" || rc=$?
  if [[ "$rc" -eq 3 ]]; then
    p_drift "liste des catalogues TRONQUEE par la forge — rien n'est conclu sur une liste partielle"
    verdict_check
  elif [[ "$rc" -ne 0 ]]; then
    # ON NE CONCLUT PAS QUE RIEN N'EST INSTALLE. Une forge injoignable rendrait la liste vide, et
    # l'apply supprimerait alors TOUT le materiel local en croyant converger.
    p_drift "forge injoignable ($PROV_FORGE_URL) — l'etat installe des catalogues n'a pas pu etre lu"
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
    # Passe HOLD, le troisieme champ est l'url de clone — le protocole le dit, cf. `forge_installed`.
    url="$arg"

    local dir="$PROV_CATALOGUES_DIR/$name"
    if [[ ! -d "$dir/.git" ]]; then
      p_drift "catalogue $name installe sur la forge, materiel absent ici ($dir)"
    elif [[ "$(local_head "$dir")" != "$(remote_head "$url")" ]]; then
      p_drift "catalogue $name en retard sur sa source ($url)"
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
  [[ -n "$PROV_FORGE_URL" ]] || { p_warn "FORGE_BASE_URL non posé — rien a converger"; verdict_apply; }

  local signed rc=0
  signed="$(forge_installed)" || rc=$?
  if [[ "$rc" -eq 3 ]]; then
    p_drift "liste des catalogues TRONQUEE par la forge — materiel laisse EN L'ETAT, rien n'est supprime"
    verdict_apply
  elif [[ "$rc" -ne 0 ]]; then
    p_drift "forge injoignable ($PROV_FORGE_URL) — materiel laisse EN L'ETAT, rien n'est supprime"
    verdict_apply
  fi

  # `mkdir -p` et pas `install -d -o root -g root` : la PROPRIETE de ce repertoire appartient a
  # `25-directories`, dont c'est tout le metier, et deux modules qui posent le meme owner finissent
  # par ne plus etre d'accord. Ici on garantit seulement qu'il existe avant d'y ecrire.
  mkdir -p "$PROV_CATALOGUES_DIR"

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

    dir="$PROV_CATALOGUES_DIR/$name"

    if [[ -d "$dir/.git" ]]; then
      # `fetch` + `reset --hard` et PAS `pull` : le cache n'a pas d'historique a preserver, et un
      # `pull` sur un depot reecrit cote proprietaire s'arrete sur un conflit de merge qu'aucun
      # humain ne viendra resoudre ici.
      if GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch --quiet --depth 1 origin HEAD \
         && git -C "$dir" reset --quiet --hard FETCH_HEAD; then
        p_ok "catalogue $name converge ($(local_head "$dir" | cut -c1-8))"
      else
        p_drift "catalogue $name : fetch impossible depuis $url — materiel laisse EN L'ETAT"
      fi
      continue
    fi

    # Le clone atterrit a cote puis se renomme : un clone interrompu laisserait sinon un repertoire
    # a demi rempli SOUS le nom du catalogue, et le boot suivant le verifierait comme s'il etait
    # entier. `mv` dans le meme systeme de fichiers est un rename atomique.
    rm -rf "$dir.tmp"
    if GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 "$url" "$dir.tmp"; then
      rm -rf "$dir"
      mv "$dir.tmp" "$dir"
      p_ok "catalogue $name clone depuis $url"
    else
      rm -rf "$dir.tmp"
      p_drift "catalogue $name : clone impossible depuis $url"
    fi
  done <<< "$signed"

  # LA SUPPRESSION, et elle n'arrive qu'ici — apres une lecture REUSSIE de la forge. Le materiel est
  # un cache : ce qu'on efface se re-clone. Ce qu'on garderait, en revanche, continuerait a etre
  # servi comme un catalogue vivant.
  local have
  while read -r have; do
    [[ -n "$have" ]] || continue
    if [[ "$seen" != *" $have "* ]]; then
      rm -rf "${PROV_CATALOGUES_DIR:?}/$have"
      p_ok "materiel de $have retire (la forge ne l'installe plus)"
    fi
  done < <(local_installed)

  verdict_apply
}

case "${1:?usage: 45-catalogues.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
