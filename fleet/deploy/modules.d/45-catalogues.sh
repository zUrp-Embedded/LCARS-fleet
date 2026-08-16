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
# la SOURCE du catalogue dans `<nom>/catalogue`. Ce depot-la est la signature de l'installation. Ce
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

# ─── ce que la FORGE signe ────────────────────────────────────────────────────────────────────────
#
# UN DEPOT `catalogue` DANS UNE ORG = CE CATALOGUE EST INSTALLE. Trois filtres, chacun paye :
#
#   * le NOM, exact — `q=catalogue` est un match de SOUS-CHAINE cote Gitea, `mon-catalogue-perso`
#     remonte aussi ; le filtre est fait ici, sur `.name`, jamais laisse au serveur ;
#   * le TYPE DU PROPRIETAIRE — ⚠ D1 de l'audit independant (2026-08-16) : orgs et comptes perso
#     partagent l'espace de noms, et sans ce filtre un user non-admin qui pousse un depot public
#     `catalogue` chez lui faisait apparaitre son login comme catalogue INSTALLE — clone de son
#     materiel, roster derive pour le mint, « seul un admin installe » contourne par un push.
#     L'objet `owner` de la recherche ne porte AUCUN champ discriminant (mesure 1.26.1) ; la
#     question se pose a `/orgs/<owner>` — 200 = org, 404 = espace perso prouve, le reste est une
#     ABSENCE de reponse et ne conclut rien (sortie HOLD : ni converge, ni supprime) ;
#   * la TRONCATURE — D4 : le serveur borne la page a SA limite, et une liste partielle lue comme
#     entiere ferait SUPPRIMER le materiel des catalogues au-dela de la borne. `X-Total-Count`
#     (mesure : le header existe) est compare au nombre recu ; ecart = refus, jamais une
#     convergence sur une liste partielle.
#
# Sorties : « OK <nom> <url> » / « HOLD <nom> » ; rc=1 forge muette, rc=3 liste tronquee.
forge_installed() {
  local hdr body total count
  hdr="$(mktemp)"
  body="$(curl -fsS -m 20 -D "$hdr" "$PROV_FORGE_URL/api/v1/repos/search?q=catalogue&limit=50" 2>/dev/null)" \
    || { rm -f "$hdr"; return 1; }
  total="$(tr -d '\r' < "$hdr" | awk -F': ' 'tolower($1)=="x-total-count"{print $2}')"
  rm -f "$hdr"

  count="$(printf '%s' "$body" | jq -r '.data | length')"
  [[ -n "$total" && "$count" -lt "$total" ]] && return 3

  local name url code
  while read -r name url; do
    [[ -n "$name" ]] || continue
    code="$(curl -sS -o /dev/null -w '%{http_code}' -m 10 "$PROV_FORGE_URL/api/v1/orgs/$name" 2>/dev/null)" || code=000
    case "$code" in
      200) printf 'OK %s %s\n' "$name" "$url" ;;
      404) : ;;
      *)   printf 'HOLD %s\n' "$name" ;;
    esac
  done <<< "$(printf '%s' "$body" \
    | jq -r '.data[]? | select(.name == "catalogue") | select(.empty != true)
             | "\(.owner.login) \(.clone_url)"')"
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

  local signed status name url rc=0
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
  while read -r status name url; do
    [[ -n "$name" ]] || continue
    seen="$seen$name "
    if [[ "$status" == "HOLD" ]]; then
      p_drift "catalogue $name : type du proprietaire illisible sur la forge — rien n'est conclu"
      continue
    fi

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

  local status name url dir seen=" "
  while read -r status name url; do
    [[ -n "$name" ]] || continue
    # HOLD entre dans `seen` et nulle part ailleurs : son materiel survit au balayage (on n'a pas pu
    # lire le type du proprietaire, on ne conclut rien), et rien n'est clone sous un nom non signe.
    seen="$seen$name "
    if [[ "$status" == "HOLD" ]]; then
      p_drift "catalogue $name : type du proprietaire illisible — materiel laisse EN L'ETAT"
      continue
    fi

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
