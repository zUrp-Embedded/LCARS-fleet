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

# ─── LA MESURE VIT DANS LE RELEASE, PAS ICI (phase 7) ───────────────────────────────────────────
#
# Le client de forge du BEAM est le seul client de la forge. Ce geste ne PARLE PLUS a la forge : il
# ouvre la porte `catalogue-installed` UNE fois et converge le materiel local sur ce qu'elle rend.
# Sont partis avec elle : la pagination des branches du magasin, la lecture du manifeste de chaque
# branche, la verification de l'org du catalogue, la dependance a `jq`, et les trois litteraux que
# ce fichier recopiait — le nom du magasin, celui du manifeste, et le nom du catalogue embarque.
#
# ⚠ UN SEUL EVAL, ET C'EST POURQUOI LA PORTE REND TOUT D'UN COUP. Un `lcars_fleet eval` coute
# 0,27 s et 89 Mo ; un appelant qui en ferait un par branche paierait ce prix a chaque catalogue.
#
# CE QUI RESTE ICI, et qui ne peut pas etre ailleurs : POSER le materiel. Cloner, mettre a jour,
# retirer — des gestes de systeme de fichiers joues en root sur le cache de la machine.
REMEDE_RELEASE="la release n'est pas posée : sur un poste, « deploy/workstation up » la pose ; dans un conteneur, l'image la porte"

# ⚠ LA REGLE QUI TIENT TOUT LE MODULE : ON NE SUPPRIME QUE SUR UNE LECTURE REUSSIE. « Le magasin
# n'existe pas » est une reponse quand il n'y a rien en local, et un DRIFT des qu'il y a du materiel
# a effacer : un depot prive lu en anonyme, une org renommee, une recette jamais jouee rendent le
# meme 404 qu'une forge qui n'a rien installe, et trois de ces quatre causes ne justifient aucun
# effacement (relecture hostile du 2026-09-17). C'est le CODE de la porte qui porte cette
# distinction — 0 lu entier · 2 magasin ABSENT · 1 illisible —, et ce geste la relaie telle quelle.
#
# Sorties de la porte, TOUJOURS trois champs separes par une TABULATION :
#   OK   <nom> <url de clone>  — la branche est signee : manifeste a son nom, et l'org existe
#   HOLD <nom> <moitie>        — « manifeste » ou « proprietaire » : la lecture n'a pas conclu
#   WARN <nom> <phrase>        — la branche a repondu et n'est PAS un magasin ; l'operateur a
#                                besoin de la phrase pour comprendre pourquoi son catalogue
#                                n'est pas installe. Rien n'est clone, rien n'est retenu.
# La moitie est portee parce qu'il y a DEUX facons de ne pas savoir, et qu'un refus qui nomme la
# mauvaise envoie l'operateur regarder le mauvais objet.
#
# rc=1 forge muette, illisible ou liste tronquee · rc=2 magasin ABSENT · rc=0 liste signee.
#
# ⚠ LA MESURE ATTERRIT DANS UN FICHIER, PAS DANS UNE SUBSTITUTION, et ce n'est pas un detail :
# `x="$(forge_installed)"` jouerait la fonction dans un SOUS-SHELL, et le nom du magasin qu'elle
# retient de la porte mourrait avec lui — les phrases d'ici nommeraient « le magasin des
# catalogues » a la place du depot que l'operateur doit aller voir (mesure du 2026-09-19).
#
# MAGASIN porte le nom que la porte a lu, quand elle a pu le dire : le recopier ici en ferait une
# seconde ecriture qui deriverait.
MAGASIN="le magasin des catalogues"
SIGNATURES=""
# ⚠ CETTE FONCTION NE REND AUCUN CONSTAT, ET C'EST DELIBERE. Ne pas avoir pu lire le magasin est UN
# fait, que l'appelant dit UNE fois, en DRIFT : rien n'est casse, la mesure n'a pas pu etre faite et
# rien n'est efface. Un `p_fail` ici dirait la meme chose deux fois, et a une gravite que le geste
# ne merite pas — mesure du 2026-09-19 : `50-catalogues check` rendait 2 la ou son temoin attend 1.
# POURQUOI porte la cause, que l'appelant colle a sa phrase.
POURQUOI=""
forge_installed() {
  local cli; cli="$(lcars_cli)"
  [[ -r "$cli" ]] || { POURQUOI="porte catalogue-installed injouable ($cli illisible) — $REMEDE_RELEASE"; return 1; }

  SIGNATURES="$(mktemp)" || { POURQUOI="fichier temporaire impossible à créer (mktemp)"; return 1; }

  # ⚠ STDOUT PORTE LA MESURE, STDERR LA PLAINTE, ET ON NE LES MELANGE PAS : la porte reclame stdout
  # pour elle seule, precisement pour qu'une ligne de journal du BEAM ne passe pas devant un constat.
  local err rc=0
  err="$(mktemp)" || { POURQUOI="fichier temporaire impossible à créer (mktemp)"; return 1; }
  FORGE_BASE_URL="$FORGE_BASE_URL" bash "$cli" tool catalogue-installed >"$SIGNATURES" 2>"$err" || rc=$?

  # « ABSENT <depot> » nomme le magasin : on le retient pour que les phrases d'ici le nomment aussi.
  local dit; dit="$(tr '\n' ' ' < "$err" | cut -c1-300)"
  case "$dit" in ABSENT\ *) MAGASIN="${dit#ABSENT }"; MAGASIN="${MAGASIN%% *}" ;; esac
  rm -f "$err"

  case "$rc" in
    0) return 0 ;;
    # rien a lire : le magasin est absent, et l'appelant decide ce que ca veut dire ici
    2) : > "$SIGNATURES"; return 2 ;;
    *) POURQUOI="porte catalogue-installed en échec (code $rc) — $dit"; return 1 ;;
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
    p_drift "magasin des catalogues ABSENT ($MAGASIN) alors que $n catalogue(s) sont installes ici ($LCARS_CATALOGUES_DIR) — leur source est injoignable, RIEN n'est supprime. Le depot est pose par la recette de la forge (sur un poste « deploy/workstation up » ; pour un conteneur « deploy/container forge-apply » depuis l'hote) ; s'il existe, il est peut-etre prive — ce geste le lit en anonyme"
    return 1
  fi
  p_ok "magasin des catalogues absent de la forge ($MAGASIN) et rien d'installe ici — la fleet tourne sur le catalogue de la release"
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
  if [[ -z "$FORGE_BASE_URL" ]]; then
    forge_inconnue check
    verdict_check
  fi

  local status name arg url rc=0
  forge_installed || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    magasin_absent check
    verdict_check
  elif [[ "$rc" -ne 0 ]]; then
    p_drift "magasin des catalogues ILLISIBLE ($MAGASIN) — l'etat installe des catalogues n'a pas pu etre lu : $POURQUOI"
    verdict_check
  fi

  local seen=" "
  # ⚠ `|| [[ -n … ]]` : `read` rend faux sur une DERNIERE ligne sans saut, et le corps ne la verrait
  # jamais. La porte en pose un, mais une mesure entiere perdue sur un octet manquant ferait
  # effacer le materiel de tous les catalogues.
  while IFS=$'\t' read -r status name arg || [[ -n "$status$name$arg" ]]; do
    [[ -n "$name" ]] || continue
    # WARN : la branche a repondu et n'est PAS un magasin. Elle n'entre PAS dans `seen` — rien ne la
    # retient, et du materiel local de ce nom reste un reliquat que le balayage doit voir.
    if [[ "$status" == "WARN" ]]; then p_warn "$arg"; continue; fi
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
  done < "$SIGNATURES"

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
  [[ -n "$FORGE_BASE_URL" ]] || { forge_inconnue apply; verdict_apply; }

  local rc=0
  forge_installed || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    magasin_absent apply || verdict_apply

  elif [[ "$rc" -ne 0 ]]; then
    p_drift "magasin des catalogues ILLISIBLE ($MAGASIN) — materiel laisse EN L'ETAT, rien n'est supprime : $POURQUOI"
    verdict_apply
  fi

  # `mkdir -p` et pas `install -d -o root -g root` : la PROPRIETE de ce repertoire appartient a
  # `25-directories`, dont c'est tout le metier, et deux modules qui posent le meme owner finissent
  # par ne plus etre d'accord. Ici on garantit seulement qu'il existe avant d'y ecrire.
  mkdir -p "$LCARS_CATALOGUES_DIR"

  local status name arg url dir seen=" "
  while IFS=$'\t' read -r status name arg || [[ -n "$status$name$arg" ]]; do
    [[ -n "$name" ]] || continue
    # WARN : la branche a repondu et n'est PAS un magasin. Elle n'entre PAS dans `seen` — un
    # materiel local de ce nom est un reliquat, et le balayage doit pouvoir le retirer.
    if [[ "$status" == "WARN" ]]; then p_warn "$arg"; continue; fi
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
  done < "$SIGNATURES"

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
