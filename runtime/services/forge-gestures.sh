#!/usr/bin/env bash
# SOURCE: runtime/services/forge-gestures.sh
# AUTHOR: drdree
# STARDATE: 2026-08-16
# STATUS: les gestes de forge — posés une fois, joués sur un poste comme dans un conteneur
# ⚠ LES SECRETS ENTRENT PAR STDIN, JAMAIS PAR argv : `/proc/<pid>/cmdline` est lisible par tout le
# monde pendant l'appel, et un `--token X` l'aurait mis dans la ligne de commande de CE script ET
# dans celle du client docker.
#
# USAGE : forge-gestures.sh <geste>
#   config-token   lit un jeton master sur STDIN et le pose, APRES verification contre la forge.
#   config-seed    lit le seed sur STDIN, meme mode (handoff tofu -> mint A4).
#   builtin-human  imprime le nom du compte integre. Ce fichier en est l'AUTORITE ; le verbe existe
#                  pour que ses appelants le DEMANDENT au lieu d'en recopier le defaut.
#   apply          joue la recette avec le jeton master lu sur STDIN, à défaut celui que la
#                  machine détient, et le seed posé : l'org SYSTÈME (sans rôle métier), son dépôt,
#                  puis le catalogue de la release, installé comme n'importe quel catalogue.
#   install <nom>  installe ou MET A JOUR le catalogue <nom> depuis le depot que la forge porte —
#                  ou depuis la release, pour le catalogue qu'elle embarque. Jamais declenche par
#                  le boot.
#   runner-token   minte un jeton d'ENREGISTREMENT de runner et l'imprime. Credential a usage
#                  unique : sortie sur stdout, il ne se pose nulle part.
#
# EXIT : 0 · 1 donnee manquante ou geste en echec · 2 pas de FORGE_BASE_URL (et, pour `install`,
#        aucun depot de ce nom) · 3 jeton non authentifie (et, pour `install`, DEUX depots
#        revendiquent le nom)

set -euo pipefail

# Chemins et noms se lisent dans l'environnement : sur un poste, l'installeur les passe depuis ses
# constantes (`prov_product_env`), un témoin les pose dans son décor. Les défauts sont ceux d'un
# conteneur.
PRIVATE_DIR="${LCARS_PRIVATE_DIR:-/opt/lcars/var/tokens}"
# Le compte intégré, résolu une fois : `TF_VAR_builtin_human` et le verbe `builtin-human` lisent
# celui-ci. Vide par défaut : un déploiement de travail ne fabrique pas d'humain, les personnes
# s'enrôlent par la page d'inscription. Un banc le nomme (`bench-up.sh`, `install.sh --bench`).
BUILTIN_HUMAN="${LCARS_BUILTIN_HUMAN:-}"
# Les deux projections de catalogue lisent le compte système ici ; le contrat
# `forge.system_account_single_source` tient ce défaut d'accord avec `Fleet.Credentials.ForgeIdentity`.
SYSTEM_ACCOUNT="${LCARS_SYSTEM_ACCOUNT:-system_starfleet}"
# L'org SYSTEME : l'identite (team `humans`) et le depot du systeme (`_ops`). Les projets vivent
# dans l'org de leur catalogue. Meme defaut que `system_org` de la recette, `LCARS_FORGE_ORG` du
# protocole et `PROV_FORGE_ORG_DEFAULT` de l'installeur — un mur bats tient les quatre d'accord.
SYSTEM_ORG="${LCARS_FORGE_ORG:-lcars}"
# La team des APPROBATEURS de `tool_request`. La recette la declare (`local.approvers_team` de
# `forge-recipe/forge.tf`) et la nomme dans ses protections ; ce geste la COMPOSE (`derive_admins`).
# Deux ecritures d'un meme nom derivent : un mur bats les tient d'accord.
APPROVERS_TEAM="admins"
# Le détenteur des secrets de forge : le compte que `put_secret` pose sur ce qu'il écrit, le seul qui
# ouvrira ces fichiers (`PROV_AUTHORITY_USER` de `deploy/installer-constants.env` sur un poste).
AUTHORITY_USER="${LCARS_AUTHORITY_USER:-lcars-authority}"
# Le groupe qui TRAVERSE `/opt/lcars/var/tokens` — jamais celui qui lit. Meme defaut que partout ailleurs
# dans l'arbre, et il est ici parce que `put_secret` pose ce repertoire lui-meme : sans lui, ce geste
# et la table diraient deux choses differentes du meme objet.
FLEET_GROUP="${LCARS_FLEET_GROUP:-fleet}"
SYSTEM_EMAIL="${LCARS_SYSTEM_EMAIL:-${SYSTEM_ACCOUNT}@lcars.local}"
# ⚠ NE FINIT PAS PAR `.gitea_token`, ET C'EST VOULU : ce suffixe est celui des jetons de ROLE
# (`<login>.gitea_token`, plus bas). Le premier lecteur qui globbera ce repertoire ne doit pas
# ramasser un site-admin.
MASTER_TOKEN_FILE="${LCARS_MASTER_TOKEN_FILE:-$PRIVATE_DIR/forge-master.token}"
SEED_FILE="${LCARS_FORGE_SEED_FILE:-$PRIVATE_DIR/forge-seed.pass}"
# LA RECETTE ET SON ETAT. `LCARS_RECIPE_DIR` est le dossier ou l'appelant veut le play du systeme
# joue — sur un poste, la copie que fait 61-forge-structure, avec l'etat de la passe precedente
# (garde dans PROV_FORGE_STATE_DIR). Sans lui (le conteneur), la recette de l'image est un GABARIT :
# elle vit hors des volumes, un etat qu'on y ecrirait mourrait avec l'image, et la passe suivante
# recreerait ce qui existe (409 sur le depot). Le play se fait alors dans le dossier de travail
# persistant (`$CATALOGUE_WORK/_system`), seme depuis le gabarit, comme le play d'un catalogue.
RECIPE_SOURCE="${LCARS_RECIPE_SOURCE:-/opt/lcars/services/forge-recipe}"
RECIPE_DIR="${LCARS_RECIPE_DIR:-$RECIPE_SOURCE}"
# Le repertoire de travail des gestes de structure. Il remonte ICI, avec les autres chemins, parce
# que le verrou d'apply y vit — et une variable definie plus bas que sa premiere lecture
# ne tient que par l'ordre d'execution.
CATALOGUE_WORK="${LCARS_CATALOGUES_WORK:-/opt/lcars/var/tofu}"
# LE MAGASIN DES CATALOGUES : UN DEPOT, UNE BRANCHE PAR CATALOGUE (⚖ user 2026-09-16). Il vit dans
# l'org SYSTEME — tout ce qui est systeme y vit —, et « quels catalogues sont installes » devient UNE
# question a la forge (les branches de ce depot) la ou c'etait une recherche sur tous les depots
# visibles. Le `_` initial est de l'UX (⚖ user) : il separe a l'oeil ce que la fleet pose de ce qu'un
# humain depose. Le nom vit ici parce que ce fichier est ce qui ECRIT le magasin ; `Fleet.Catalogue`
# en est l'autorite cote produit, et un temoin tient les trois d'accord.
STORE_REPO="${LCARS_STORE_REPO:-_catalogues}"
STORE_FULL="$SYSTEM_ORG/$STORE_REPO"
# La CLI posee vit dans le repertoire des liens (`PROV_LINK_DIR` de l'installeur, meme defaut que
# `lib/module-protocol.sh`). Ce script tourne depuis DEUX places : l'arbre embarque
# (`/opt/lcars/services/`, un checkout), ou `bin/` est son voisin, et la copie a plat
# (`/opt/lcars/forge-gestures.sh`, celle que lancent l'executeur de catalogue et le boot), dont le
# `../bin` ne designe rien. Un candidat n'est rendu que s'il existe ; aucun candidat rend vide, et
# `need_cli` refuse en nommant ce qui a ete cherche.
_lcars_cli() {
  local here cand
  [[ -n "${LCARS_CLI:-}" ]] && { printf '%s' "$LCARS_CLI"; return 0; }
  if command -v lcars >/dev/null 2>&1; then command -v lcars; return 0; fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for cand in "${LCARS_LINK_DIR:-/usr/local/bin}/lcars" "$here/../bin/lcars"; do
    [[ -f "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  return 0
}
LCARS_CLI="$(_lcars_cli)"
tool() { bash "$LCARS_CLI" tool "$@"; }

need_cli() {
  [[ -n "$LCARS_CLI" && -r "$LCARS_CLI" ]] && return 0
  local vu="$LCARS_CLI"
  [[ -n "$vu" ]] || vu="ni « lcars » sur le PATH, ni ${LCARS_LINK_DIR:-/usr/local/bin}/lcars, ni $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../bin/lcars"
  die "portes outil du release introuvables ($vu).
  Ce script les appelle pour résoudre, vérifier et enrôler un catalogue (« lcars tool … »). Sur un
  poste, « deploy/workstation up » pose la CLI ; dans un conteneur, l'image la porte.
  « LCARS_CLI=<chemin> » désigne une CLI posée ailleurs."
}

die() { echo "forge-gestures: $*" >&2; exit "${2:-1}"; }

need_forge_url() {
  [[ -n "${FORGE_BASE_URL:-}" ]] || {
    echo "forge-gestures: cette machine n'a pas de FORGE_BASE_URL — un jeton sans forge ne veut rien dire." >&2
    echo "                Sur un poste, « deploy/workstation up » la pose ; pour un conteneur, « FORGE_BASE_URL=<url> deploy/container config » depuis l'hôte, puis « deploy/container up »." >&2
    exit 2; }
}

# La config de curl est un format CITE : la valeur s'echappe, elle ne s'espere pas propre.
curl_cfg_escape() { local v="$1"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "$v"; }

# Ecriture ATOMIQUE dans le repertoire cible (rename garanti par le noyau sur le meme systeme de
# fichiers) : un appel interrompu ne laisse jamais un demi-secret que le lecteur suivant prendrait
# pour le vrai.
put_secret() { # $1=chemin  $2=valeur
  # `chown` n'est tente QUE si on est root : tout appelant reel l'est, un temoin ne l'est pas, et
  # conditionner ici evite un `|| true` qui avalerait un vrai echec de propriete sur un conteneur.
  if [[ "$(id -u)" -eq 0 ]]; then
    install -d -m 0710 -o "$AUTHORITY_USER" -g "$FLEET_GROUP" "$PRIVATE_DIR"
  else
    install -d -m 0710 "$PRIVATE_DIR"
  fi
  local tmp
  tmp="${1%/*}/.$(basename "$1").tmp"   # SC2155 : `local` masquerait le statut de `basename`
  umask 077
  printf '%s\n' "$2" > "$tmp"

  # ⚠ UN `if`, PAS `[[ ]] && cmd` : un AND-list dont le test est faux rend 1 — sans effet au milieu
  # d'une fonction, MORTEL sous `set -e` s'il en devient la derniere instruction, la fonction rendant
  # alors 1 et l'appelant mourant sans un mot. On n'ecrit pas une ligne dont la surete depend de ce
  # qui la suit.
  chmod 0600 "$tmp"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown "$AUTHORITY_USER:$AUTHORITY_USER" "$tmp"
  fi
  mv -f "$tmp" "$1"
}

read_stdin_secret() { # un secret arrive par un tube ; un terminal n'en porte pas, et une ligne tapée n'en est pas un
  local v=""
  [[ -t 0 ]] || { IFS= read -r v || true; }
  printf '%s' "$v"
}

# ─── hcurl <jeton> <args curl…> — le jeton passe par stdin (-K -), JAMAIS en argv ─────────────
# `/proc/<pid>/cmdline` est lisible par tout compte du conteneur ; un `-H "Authorization: token …"`
# y expose le jeton le temps de l'appel. MUR I2 (idiom_walls, cote installeur ET cote produit).
hcurl() { local tok="$1"; shift; printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" | curl -K - "$@"; }

# nom_libre <jeton> <nom> — rc 0 si AUCUN compte ne porte ce nom, rc 1 s'il y en a un ; MEURT si la
# forge ne repond ni 200 ni 404. La question se pose DEUX FOIS parce qu'une seule reponse ne suffit
# pas : `/users/<nom>` rend 200 pour une org comme pour un compte, `/orgs/<nom>` ne rend 200 que
# pour une org. Un org qui repond, c'est deja la notre et la question est close.
# Tout autre code est FATAL, comme pour `probe_id` de la recette : un 500, un 403 ou une connexion
# coupee lus comme « absent » desarment le garde en silence, et c'est le silence qui coute.
nom_libre() { # nom_libre <jeton> <nom>
  local tok="$1" nom="$2" code
  code="$(hcurl "$tok" -sS -o /dev/null -w '%{http_code}' -m 15 "${FORGE_BASE_URL%/}/api/v1/orgs/$nom" 2>/dev/null || true)"
  case "$code" in
    200) return 0 ;;
    404) ;;
    *)   die "la forge ne dit pas si « $nom » est libre (/api/v1/orgs : HTTP ${code:-aucune reponse}) — un espace de noms qu'on ne lit pas ne se pose pas a l'aveugle. RIEN n'a ete pose" ;;
  esac
  code="$(hcurl "$tok" -sS -o /dev/null -w '%{http_code}' -m 15 "${FORGE_BASE_URL%/}/api/v1/users/$nom" 2>/dev/null || true)"
  case "$code" in
    404) return 0 ;;
    200) return 1 ;;
    *)   die "la forge ne dit pas si « $nom » est libre (/api/v1/users : HTTP ${code:-aucune reponse}) — un espace de noms qu'on ne lit pas ne se pose pas a l'aveugle. RIEN n'a ete pose" ;;
  esac
}

cmd_config_token() {
  need_forge_url
  local tok; tok="$(read_stdin_secret)"
  [[ -n "$tok" ]] || die "jeton vide sur stdin"

  # VERIFIER AVANT D'ECRIRE : un jeton pose sans l'etre produirait un conteneur qui croit tenir son
  # autorite et le decouvre au premier geste structurel, des mois plus tard.
  local code
  code="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
          | curl -sS -K - -o /dev/null -w '%{http_code}' -m 15 "${FORGE_BASE_URL%/}/api/v1/user" || true)"
  [[ "$code" == "200" ]] \
    || die "ce jeton ne s'authentifie pas sur $FORGE_BASE_URL (HTTP $code) — RIEN n'a ete ecrit" 3

  put_secret "$MASTER_TOKEN_FILE" "$tok"
  echo "forge-gestures: jeton master pose et VERIFIE ($MASTER_TOKEN_FILE, $AUTHORITY_USER seul)"
}

cmd_config_seed() {
  local seed; seed="$(read_stdin_secret)"
  [[ -n "$seed" ]] || die "seed vide sur stdin"
  put_secret "$SEED_FILE" "$seed"
  echo "forge-gestures: seed pose ($SEED_FILE, $AUTHORITY_USER seul)"
}

# ⚠ TOFU NE SE PROTEGE PAS D'UN BACKEND LOCAL PARTAGE : deux applys concurrents ecriraient le meme
# `terraform.tfstate`, et celui qui finit rendrait un verdict sur un travail qu'il n'a pas fait.
# `flock -n` REFUSE au lieu d'attendre — un appelant qui attend repartirait sur une forge qui a
# bouge sous lui.
#
# `apply` se joue en root (61-forge-structure, `container forge-apply`), `install` sous le compte
# d'autorité (le service lcars-catalogue). Le verrou est le dossier de travail lui-même : rien n'y est
# créé, rien n'est à rendre, et son parent appartient à root, qui seul pourrait le remplacer.
with_apply_lock() {
  exec 9<"$CATALOGUE_WORK" \
    || die "dossier de travail des applies inaccessible ($CATALOGUE_WORK) — ce geste se joue en root ou sous $AUTHORITY_USER, et l'installation pose ce dossier (sur un poste « deploy/workstation up », dans un conteneur son démarrage)"
  flock -n 9 || die "un autre apply de structure est en cours (verrou $CATALOGUE_WORK) — rien n'a ete tente"
  "$@"
}

publicize_org_members() { # $1=org  $2=jeton de lecture  $3=seed
  local org="$1" tok="$2" seed="$3" acct code posed=0 skipped=0
  local -a members=()
  mapfile -t members < <(hcurl "$tok" -sS -m 15 \
      "${FORGE_BASE_URL%/}/api/v1/orgs/$org/members" 2>/dev/null \
    | jq -r 'if type=="array" then .[].login else empty end' 2>/dev/null || true)

  [[ ${#members[@]} -gt 0 ]] || { echo "forge-gestures: $org — aucun membre lu, visibilite non posee" >&2; return 0; }

  for acct in "${members[@]}"; do
    [[ -n "$acct" ]] || continue
    # DEJA PUBLIC : on ne rejoue pas un PUT pour le plaisir d'un 204. 204 = public, 404 = prive.
    [[ "$(hcurl "$tok" -sS -o /dev/null -w '%{http_code}' -m 10 \
          "${FORGE_BASE_URL%/}/api/v1/orgs/$org/public_members/$acct" 2>/dev/null)" == "204" ]] && continue
    # Le seed part dans la config de curl, sur stdin, comme les jetons de `hcurl` : un `-u` en argv
    # le montrerait dans `/proc/<pid>/cmdline` a chaque compte de la boucle.
    code="$(printf 'user = "%s:%s"\n' "$(curl_cfg_escape "$acct")" "$(curl_cfg_escape "$seed")" \
            | curl -sS -K - -o /dev/null -w '%{http_code}' -m 10 -X PUT \
                "${FORGE_BASE_URL%/}/api/v1/orgs/$org/public_members/$acct" 2>/dev/null || true)"
    case "$code" in
      204) posed=$((posed + 1)) ;;
      # 401/403 = ce compte n'est pas a nous (une personne a change son mot de passe, ou n'a jamais
      # eu le seed). C'est le cas NOMINAL pour un humain : sa visibilite lui appartient.
      401|403) skipped=$((skipped + 1)) ;;
      *) echo "forge-gestures: $org/$acct — publicize HTTP $code" >&2 ;;
    esac
  done

  echo "forge-gestures: $org — $posed adhesion(s) rendue(s) visible(s), $skipped compte(s) hors de notre autorite"
}

# ─── LE CREATEUR DE L'ORG N'EN EST PAS LE PROPRIETAIRE ──────────────────────────────────────────
# Gitea fait de qui CREE une org un membre de son equipe `Owners` — le master s'y retrouve donc par
# effet de bord, parce que c'est son jeton que tofu porte, et une liste de proprietaires qui nomme
# quelqu'un n'ayant fait que creer ment sur qui tient l'org.
#
# ⚠ L'ORDRE EST LE GESTE : on RELIT la liste et on confirme que le compte systeme y est AVANT de
# retirer le master. Une passe ou tofu n'a pas encore pose l'adhesion laisserait sinon une org SANS
# proprietaire — irreparable sans site-admin.
demote_creator_from_owners() { # $1=org  $2=jeton master
  local org="$1" tok="$2" api="${FORGE_BASE_URL%/}/api/v1" tid owners
  tid="$(hcurl "$tok" -sS -m 15 "$api/orgs/$org/teams" 2>/dev/null \
        | python3 -c 'import json,sys;print(next((t["id"] for t in json.load(sys.stdin) if t["name"]=="Owners"),""))' 2>/dev/null || true)"
  [[ -n "$tid" ]] || { echo "forge-gestures: equipe Owners de $org introuvable — le master y reste (rien n'est retire a l'aveugle)" >&2; return 0; }

  owners="$(hcurl "$tok" -sS -m 15 "$api/teams/$tid/members" 2>/dev/null \
           | python3 -c 'import json,sys;print(" ".join(m["login"] for m in json.load(sys.stdin)))' 2>/dev/null || true)"

  [[ " $owners " == *" $SYSTEM_ACCOUNT "* ]] || {
    echo "forge-gestures: $SYSTEM_ACCOUNT n'est PAS owner de $org (vu: ${owners:-aucun}) — le master y reste" >&2
    return 0; }

  # Le login du master est VARIABLE : on le demande a la forge plutot que de le deviner.
  local master
  master="$(hcurl "$tok" -sS -m 15 "$api/user" 2>/dev/null \
           | python3 -c 'import json,sys;print(json.load(sys.stdin).get("login",""))' 2>/dev/null || true)"
  [[ -n "$master" ]] || return 0
  [[ " $owners " == *" $master "* ]] || return 0   # deja retire : rien a dire

  # capturer puis tester : `| grep -q` ferme le tuyau au premier match, et sous `pipefail` le SIGPIPE
  # du producteur rend 141 — un retrait reussi lu comme un refus
  local code
  code="$(hcurl "$tok" -sS -m 15 -o /dev/null -w '%{http_code}' \
       -X DELETE "$api/teams/$tid/members/$master" 2>/dev/null || true)"
  if [[ "$code" == 204 ]]; then
    echo "forge-gestures: $master retire des Owners de $org — il l'etait par creation, pas par decision ($SYSTEM_ACCOUNT reste proprietaire ; le site-admin est intact)"
  else
    echo "forge-gestures: retrait de $master des Owners de $org REFUSE — la liste garde son proprietaire de creation" >&2
  fi
}

# Le dossier du play systeme, seme depuis le gabarit de la recette : l'etat de la passe precedente
# (racine et instance/) survit a la copie, le reste est recopie a neuf — meme discipline que le
# dossier d'un catalogue dans `cmd_install`, pour la meme raison (un etat perdu re-importe la forge,
# et ce qui ne s'importe pas se recree).
seed_system_play() { # $1=dossier du play
  local play="$1" keep m f
  mkdir -p "$play/instance"
  keep="$(mktemp -d)"
  for m in . instance; do
    for f in terraform.tfstate terraform.tfstate.backup; do
      [[ -f "$play/$m/$f" ]] && { mkdir -p "$keep/$m"; cp "$play/$m/$f" "$keep/$m/$f"; }
    done
  done
  cp -r "$RECIPE_SOURCE/." "$play/" || die "apply : gabarit de recette non copiable ($RECIPE_SOURCE)"
  rm -rf "$play/.terraform" "$play/instance/.terraform"
  rm -f "$play"/terraform.tfstate* "$play"/instance/terraform.tfstate*
  for m in . instance; do
    for f in terraform.tfstate terraform.tfstate.backup; do
      [[ -f "$keep/$m/$f" ]] && mv "$keep/$m/$f" "$play/$m/$f"
    done
  done
  rm -rf "$keep"
}

cmd_apply() {
  local tok seed
  # Le jeton donne a la main l'emporte sur celui que le conteneur garde ; le SEED, lui, n'a pas de
  # variante : il doit etre celui des comptes existants, et rien d'autre. Le provider n'ecrit pas
  # le password d'un compte existant (mesure 2026-08-16), donc un autre seed ne changerait rien
  # sur la forge et casserait le mint.
  tok="$(read_stdin_secret)"
  [[ -n "$tok" ]] || tok="$(cat "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  seed="$(cat "$SEED_FILE" 2>/dev/null || true)"

  local manque=""
  [[ -n "${FORGE_BASE_URL:-}" ]] || manque="$manque\n  l'URL de la forge   -> pour un conteneur : FORGE_BASE_URL=<url> deploy/container config, puis deploy/container up"
  [[ -n "$tok" ]]                || manque="$manque\n  l'autorité          -> pour un conteneur : FORGE_ADMIN_TOKEN=<jeton master> deploy/container config"
  [[ -n "$seed" ]]               || manque="$manque\n  le seed des comptes -> pour un conteneur : FORGE_SEED_PASSWORD=<mot de passe> deploy/container config"
  if [[ -n "$manque" ]]; then
    printf "forge-gestures: cette machine ne détient pas ce qu'il faut :%b\n  sur un poste, « deploy/workstation up » pose les trois\n" "$manque" >&2
    exit 1
  fi

  # UN SEUL JETON POUR TOUT LE GESTE : celui de stdin l'emporte, et `cmd_install`, joue plus bas,
  # le prend ici plutot que de relire le fichier — sinon deux autorites dans un geste, et un fichier
  # absent ou perime ferait echouer le catalogue apres que l'org systeme est posee.
  MASTER_TOKEN_OVERRIDE="$tok"
  # La release est demandee UNE fois par geste : chaque porte `tool` la demarre.
  REFERENCE_CATALOGUE="$(reference_catalogue_root)"

  # LE SIEGE SIGNE LES DEMANDES D'OUTILLAGE : le master — le compte du jeton, n°1 de la forge, celui
  # qui installe. Resolu ici, jamais devine, et passe a la recette qui pose la protection de
  # `tool_request` avec lui pour seul approbateur (`forge-recipe/ops.tf`). Un manifeste d'outillage
  # est applique par root sur le conteneur : le signer est l'affaire de l'admin du systeme.
  local siege
  siege="$(hcurl "$tok" -sS -m 15 "${FORGE_BASE_URL%/}/api/v1/user" 2>/dev/null | jq -r '.login // empty' 2>/dev/null || true)"
  [[ -n "$siege" ]] \
    || die "apply : la forge ne dit pas a qui appartient le jeton master (/api/v1/user) — la protection de tool_request n'aurait aucun approbateur, RIEN n'est pose"

  # ⚠ SUR GITEA, UNE ORG *EST* UN UTILISATEUR : les deux partagent un espace de noms, et l'org
  # systeme meurt en « user already exists », au milieu d'un plan tofu, sur une ligne qui parle
  # d'une org, des qu'un compte porte son nom. La collision a DEUX AGES, et un seul garde n'en
  # voit qu'un :
  #
  #   1. DANS LE MEME PLAN. Mesure du 2026-09-17, banc VIERGE : `gitea_user.builtin` et
  #      `gitea_org.this` sont joues par le meme apply, et l'humain de demonstration s'appelait
  #      comme l'org systeme. Ni l'un ni l'autre n'existait avant : aucune sonde ne l'aurait vu.
  #      Cette collision-la se lit SANS RESEAU, en comparant deux noms qu'on tient deja.
  #   2. DEJA SUR LA FORGE. Un compte pose par une passe anterieure, ou par une personne.
  local n
  for n in "$BUILTIN_HUMAN" "$SYSTEM_ACCOUNT"; do
    [[ "$n" != "$SYSTEM_ORG" ]] \
      || die "apply : « $n » est demande a la fois comme COMPTE et comme nom de l'org systeme — sur Gitea une org et un compte partagent l'espace de noms, et le meme plan poserait les deux. RIEN n'a ete pose : nommer le compte autrement (LCARS_BUILTIN_HUMAN, LCARS_SYSTEM_ACCOUNT), ou l'org autrement (LCARS_FORGE_ORG)"
  done
  # deux COMPTES du meme nom dans le meme plan : le second meurt en 409, plus tard et plus loin
  [[ -z "$BUILTIN_HUMAN" || "$BUILTIN_HUMAN" != "$SYSTEM_ACCOUNT" ]] \
    || die "apply : l'humain de demonstration et le compte systeme s'appellent tous deux « $BUILTIN_HUMAN » — la meme recette pose les deux. RIEN n'a ete pose : nommer l'un des deux autrement (LCARS_BUILTIN_HUMAN, LCARS_SYSTEM_ACCOUNT)"
  nom_libre "$tok" "$SYSTEM_ORG" \
    || die "apply : un COMPTE nomme « $SYSTEM_ORG » existe deja sur cette forge, et l'org systeme doit porter ce nom — sur Gitea une org et un compte partagent l'espace de noms, l'un des deux doit ceder. RIEN n'a ete pose : renommer ou supprimer ce compte, ou nommer l'org autrement (PROV_FORGE_ORG)"

  export TF_VAR_gitea_url="$FORGE_BASE_URL"
  export TF_VAR_gitea_token="$tok"
  export TF_VAR_seed_password="$seed"
  export TF_VAR_builtin_human="$BUILTIN_HUMAN"
  # Sans compte de demonstration, pas d'adresse a lui donner : la deriver rendrait « @lcars.local ».
  export TF_VAR_builtin_email="${LCARS_BUILTIN_EMAIL:-${TF_VAR_builtin_human:+${TF_VAR_builtin_human}@lcars.local}}"

  # L'ORDRE EST UN INVARIANT, pas une preference : `instance/` porte les comptes partages, et une
  # adhesion peut nommer un compte qu'elle ne cree pas, jamais un compte qui n'existe pas.
  #
  # ⚠ LE PLAY `.` EST CELUI DE L'ORG SYSTEME, ET ELLE N'A AUCUN ROLE METIER (⚖ user 2026-09-16,
  # option B) : elle porte l'identite (`humans`), le compte systeme dans `system` et `Owners`, et
  # les depots du systeme. Le rail d'outillage et le registre d'incidents ecrivent sous le compte
  # systeme ; les roles metier ecrivent dans l'org de LEUR catalogue, posee par `cmd_install` — le
  # catalogue standard compris, juste apres. Les `-var` l'emportent sur `roles.auto.tfvars.json`,
  # qui porte l'org et les roles du catalogue standard : ce fichier reste la, il nomme le compte
  # systeme (`system_account`, sans defaut par contrat).
  local play="$RECIPE_DIR"
  if [[ -z "${LCARS_RECIPE_DIR:-}" ]]; then
    play="$CATALOGUE_WORK/_system"
    seed_system_play "$play"
  fi

  local m
  local -a vars
  for m in instance .; do
    vars=()
    [[ "$m" == instance ]] \
      || vars=(-var "org=$SYSTEM_ORG" -var 'roles=[]' -var 'writers=[]' -var 'judges=[]' -var 'externals=[]'
               -var "approvers=$(jq -cn --arg s "$siege" '[$s]')")
    echo "forge-gestures: apply $m${vars[0]:+ (org $SYSTEM_ORG, sans role metier)}"
    ( cd "$play/$m" && tofu init -input=false -no-color >/dev/null ) \
      || die "init $m en echec — le miroir de providers (TF_CLI_CONFIG_FILE) couvre-t-il cette recette ?"
    [[ "$m" != . ]] || etat_dune_autre_org "$play/$m"
    oublier_comptes_disparus "$play/$m" "$tok"
    ( cd "$play/$m" && tofu apply -auto-approve -input=false -no-color ${vars[@]+"${vars[@]}"} ) \
      || die "apply $m en echec — rien n'est suppose, relis la sortie ci-dessus"
  done

  publicize_org_members "$SYSTEM_ORG" "$tok" "$seed"

  derive_admins "$SYSTEM_ORG" "$tok"

  demote_creator_from_owners "$SYSTEM_ORG" "$tok"

  # LE CATALOGUE STANDARD S'INSTALLE COMME N'IMPORTE QUEL CATALOGUE : son org, ses comptes de role,
  # ses teams, sa source dans son magasin. Il etait « installe » gratuitement tant que son org etait
  # l'org systeme ; il ne l'est plus, et une forge sans lui n'accueille aucun projet.
  local embarque
  embarque="$(bundled_catalogue_name)"
  [[ -n "$embarque" ]] \
    || die "apply : la release ne nomme pas son catalogue — la structure est posee, mais AUCUNE org de projets ne l'est (« lcars tool catalogue-root » ne repond pas)"
  cmd_install "$embarque"
  seed_system_project "$tok" "$embarque"

  seed_catalogue_deposit "$tok" "$(reference_catalogue_root)" "catalogue de reference"
  seed_catalogue_deposit "$tok" "$DEMO_CATALOGUE" "catalogue de demonstration"
}

# ⚠ QUI APPROUVE UNE DEMANDE D'OUTILLAGE SE DERIVE, IL NE SE DECLARE PAS.
#
# Gitea n'accepte dans une whitelist de protection QUE les membres d'une team de l'org : un
# collaborateur de depot, fut-il site-admin et proprietaire effectif, en est ecarte EN SILENCE — le
# PATCH rend 200, la liste reste vide, et le journal du conteneur ne dit rien (mesure du 2026-09-18,
# banc VIERGE 2004). La recette nomme donc une TEAM et aucun compte ; sa composition est ici.
#
# ⚖ user 2026-09-18 : « tu peux pas juste faire un truc qui se met a jour tout seul avec le flag
# admin forge ? une autre table tenue a la main va diverger, c'est perdu d'avance ». Donc : les
# membres de cette team sont EXACTEMENT les site-admins de la forge, recalcules a chaque passe. Rien
# n'est tenu a la main, et un admin ajoute sur la forge devient approbateur a la passe suivante.
#
# ⚠ ET LE CALCUL EST TOTAL : on AJOUTE les admins absents et on RETIRE les membres qui ne le sont
# plus. Une derivation qui n'ajoute jamais rien laisse la porte fermee ; une qui ne retire jamais
# rien laisse approuver un compte qu'on a justement retire des admins.
derive_admins() { # derive_admins <org> <jeton master>
  local org="$1" tok="$2"
  command -v jq >/dev/null || die "apply : jq absent — la team des approbateurs ne se derive pas, et la protection de tool_request nommerait une team vide"

  # ⚠ PAS DE `head` DERRIERE `jq` : il ferme le tube, `jq` meurt en SIGPIPE, `pipefail` rend non
  # zero et `set -e` tue le geste SANS UN MOT (mesure du 2026-09-18). `first(…)` fait le meme
  # travail dans jq, sans tube a fermer.
  local team_id
  team_id="$(hcurl "$tok" -sS -m 15 "${FORGE_BASE_URL%/}/api/v1/orgs/$org/teams" 2>/dev/null \
    | jq -r --arg n "$APPROVERS_TEAM" 'if type=="array" then (first(.[] | select(.name==$n) | .id) // "") else "" end' 2>/dev/null || true)"
  [[ -n "$team_id" ]] \
    || die "apply : la team « $APPROVERS_TEAM » n'est pas sur la forge — la recette la pose, et sans elle la protection de tool_request n'a aucun signataire"

  # Les site-admins ACTIFS : un compte desactive ne signe rien, et Gitea l'ecarterait de toute facon.
  local admins
  admins="$(hcurl "$tok" -sS -m 20 "${FORGE_BASE_URL%/}/api/v1/admin/users?limit=200" 2>/dev/null \
    | jq -r 'if type=="array" then (.[] | select(.is_admin == true and .active == true) | .login) else empty end' 2>/dev/null | sort -u)"
  [[ -n "$admins" ]] \
    || die "apply : la forge ne nomme AUCUN site-admin actif (/api/v1/admin/users) — personne ne pourrait approuver une demande d'outillage, et la protection serait un piege"

  local membres
  membres="$(hcurl "$tok" -sS -m 15 "${FORGE_BASE_URL%/}/api/v1/teams/$team_id/members" 2>/dev/null \
    | jq -r 'if type=="array" then .[].login else empty end' 2>/dev/null | sort -u)"

  local login code
  while read -r login; do
    [[ -n "$login" ]] || continue
    code="$(hcurl "$tok" -sS -o /dev/null -w '%{http_code}' -m 15 -X PUT \
         "${FORGE_BASE_URL%/}/api/v1/teams/$team_id/members/$login" 2>/dev/null || true)"
    [[ "$code" == "204" ]] \
      || die "apply : « $login » est site-admin et n'entre pas dans la team « $APPROVERS_TEAM » (HTTP ${code:-aucune reponse}) — il ne pourrait pas approuver"
    echo "forge-gestures: $APPROVERS_TEAM += $login (site-admin de la forge)"
  done < <(comm -23 <(printf '%s\n' "$admins") <(printf '%s\n' "$membres"))

  while read -r login; do
    [[ -n "$login" ]] || continue
    code="$(hcurl "$tok" -sS -o /dev/null -w '%{http_code}' -m 15 -X DELETE \
         "${FORGE_BASE_URL%/}/api/v1/teams/$team_id/members/$login" 2>/dev/null || true)"
    [[ "$code" == "204" ]] \
      || die "apply : « $login » n'est plus site-admin et ne sort pas de la team « $APPROVERS_TEAM » (HTTP ${code:-aucune reponse}) — il approuverait encore"
    echo "forge-gestures: $APPROVERS_TEAM -= $login (n'est plus site-admin)"
  done < <(comm -13 <(printf '%s\n' "$admins") <(printf '%s\n' "$membres"))
}

# ⚠ UN ETAT QUI DECRIT UNE AUTRE ORG N'EST PAS L'ETAT DE CE PLAY.
#
# Le play racine porte UNE org, celle du systeme. Quand cette org CHANGE DE NOM — ce que le lot 1 a
# fait, `fleet` → `lcars` —, l'etat d'avant decrit un objet que ce play ne possede plus. Tofu, lui,
# ne voit pas un renommage : il voit une ressource en trop, et la DETRUIT. Mesure du 2026-09-18 sur
# LCARS-beta, mise a jour par-dessus l'instance :
#
#     Error: user is the last member of owner team [uid: 4]
#
# C'est la destruction de l'org `fleet` qui parlait — celle qui porte desormais les PROJETS, et le
# travail qu'on voulait garder. Un etat perime ne justifie jamais de detruire ce qu'il decrit.
#
# On le MET DE COTE, on ne le supprime pas : le fichier reste a cote, date, et `existing.tf`
# reimporte au tour suivant ce qui existe sous la NOUVELLE org. Rien n'est touche sur la forge.
etat_dune_autre_org() { # etat_dune_autre_org <dossier du play racine>
  local dir="$1"
  local etat="$dir/terraform.tfstate"
  [[ -r "$etat" ]] || return 0
  command -v jq >/dev/null || return 0

  local vue
  vue="$(jq -r '[.resources[]? | select(.type == "gitea_org") | .instances[]?.attributes.name] | first // ""' \
        "$etat" 2>/dev/null || true)"
  [[ -n "$vue" && "$vue" != "$SYSTEM_ORG" ]] || return 0

  local mis
  mis="$etat.autre-org-$vue.$(date +%Y%m%dT%H%M%S)"
  mv "$etat" "$mis" \
    || die "apply : l'etat de ce play decrit l'org « $vue » et non « $SYSTEM_ORG », et il ne se met pas de cote ($mis) — le rejouer DETRUIRAIT « $vue »"
  rm -f "$etat.backup"
  echo "forge-gestures: l'etat decrivait l'org « $vue », ce play porte « $SYSTEM_ORG » — etat mis de cote ($mis) ; rien n'est touche sur la forge, la recette reimporte ce qui existe"
}

# ⚠ LE PENDANT DE L'IMPORT : OUBLIER CE QUE LA FORGE N'A PLUS.
#
# `existing.tf` reprend dans l'etat ce qui existe deja sur la forge. Le cas MIROIR n'avait rien : un
# etat qui nomme un compte SUPPRIME de la forge. Le provider ne l'oublie pas au rafraichissement, il
# MEURT dessus — mesure du 2026-09-17 sur LCARS-beta, ou l'architecte avait retire le compte
# homonyme de l'org systeme :
#
#     gitea_user.human[0]: Refreshing state... [id=2]
#     Error: user not found with id 2
#
# Et il meurt au PLAN, donc AVANT que le moindre objet ne soit pose : une installation entiere
# s'arrete sur un compte que plus personne ne veut. Un etat qui nomme un objet absent est PERIME par
# definition ; ce qui existe encore, `existing.tf` le reimporte au tour suivant.
#
# On ne retire QUE des comptes, et seulement sur un 404 FRANC : toute autre reponse laisse l'etat
# tel quel, parce qu'une forge qu'on lit mal n'autorise a oublier personne.
oublier_comptes_disparus() { # oublier_comptes_disparus <dossier du play> <jeton>
  local dir="$1" tok="$2"
  local etat="$dir/terraform.tfstate"
  [[ -r "$etat" ]] || return 0
  command -v jq >/dev/null || return 0

  local adresse login code
  while IFS=$'\t' read -r adresse login; do
    [[ -n "$adresse" && -n "$login" ]] || continue
    code="$(hcurl "$tok" -sS -o /dev/null -w '%{http_code}' -m 15 \
         "${FORGE_BASE_URL%/}/api/v1/users/$login" 2>/dev/null || true)"
    [[ "$code" == "404" ]] || continue
    echo "forge-gestures: $adresse (« $login ») n'est plus sur la forge — retire de l'etat ; la recette le reposera s'il est encore declare"
    ( cd "$dir" && tofu state rm -no-color "$adresse" >/dev/null 2>&1 ) \
      || die "apply : « $adresse » nomme un compte absent de la forge et ne sort pas de l'etat — le plan mourra dessus (« user not found »)"
  done < <(jq -r '
      .resources[]? | select(.type == "gitea_user")
      | .name as $n | .instances[]?
      | ((if .index_key == null then "gitea_user." + $n
          else "gitea_user." + $n + "[" + (.index_key | tostring | if test("^[0-9]+$") then . else "\"" + . + "\"" end) + "]"
          end)) + "\t" + (.attributes.username // "")
    ' "$etat" 2>/dev/null || true)
}

# ⚠ LCARS EST UN PROJET DE LA FLEET QU'IL INSTALLE (⚖ user 2026-09-16), ET IL SE POSE ICI.
#
# Pas dans un module, pas par une porte du runtime : le projet doit ETRE LA, et c'est ce geste qui a
# ce qu'il faut pour l'y mettre — le jeton master, l'adresse de la forge, et git. Une porte du
# runtime aurait demande son jeton au rail d'autorite, qui ne sert QUE les humains de la flotte
# (`not_a_worker`, mesure du 2026-09-17, banc 2003) : sur un poste neuf il n'y en a pas encore, et
# « pas encore d'humain » n'est pas une raison pour que le projet n'existe pas.
#
# ⚠ ON NE POUSSE QU'UNE FOIS. Creer le depot puis y semer la source, c'est la premiere passe ; aux
# suivantes, `main` est ce que le projet est devenu, et le remplacer par l'arbre d'installation
# effacerait du travail. La seconde passe ne fait donc RIEN, et le dit.
#
# ⚠ ET LE NOM VIENT DE LA RELEASE (`Fleet.Layout.system_project/0`), jamais d'un litteral ici : deux
# ecritures d'un meme nom derivent, et MUR 21 tient les lecteurs d'accord avec le layout.
seed_system_project() { # $1=jeton master  $2=org du catalogue embarque
  local tok="$1" org="$2" tree="${LCARS_SYSTEM_SOURCE:-}"

  # Sans arbre a publier, rien a faire : un kit sans historique, ou un appelant qui ne le dit pas.
  [[ -n "$tree" && -d "$tree/.git" ]] || return 0
  [[ -n "$org" ]] || return 0

  local nom; nom="$("$LCARS_CLI" tool system-project 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$nom" ]]     || { echo "forge-gestures: la release ne nomme pas le projet du systeme — il n'est pas pose (la structure, elle, l'est)" >&2; return 0; }

  local full="$org/$nom" code
  code="$(hcurl "$tok" -sS -o /dev/null -w '%{http_code}' -m 15 "${FORGE_BASE_URL%/}/api/v1/repos/$full" 2>/dev/null || true)"
  case "$code" in
    200) echo "forge-gestures: $full est deja sur la forge — la source n'est PAS reecrite"; return 0 ;;
    404) ;;
    *)   die "apply : la forge ne dit pas si $full existe (HTTP ${code:-aucune reponse}) — le projet du systeme n'est pas pose a l'aveugle" ;;
  esac

  code="$(hcurl "$tok" -sS -o /dev/null -w '%{http_code}' -m 20 -X POST        -H 'Content-Type: application/json'        -d "$(printf '{"name":"%s","private":false,"auto_init":false,"description":"La source dont cette machine a ete installee."}' "$nom")"        "${FORGE_BASE_URL%/}/api/v1/orgs/$org/repos" 2>/dev/null || true)"
  [[ "$code" == "201" ]]     || die "apply : $full non cree (HTTP ${code:-aucune reponse}) — la fleet n'a pas sa propre source comme projet"

  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1     GIT_CONFIG_KEY_0="http.${FORGE_BASE_URL%/}.extraheader"     GIT_CONFIG_VALUE_0="Authorization: token $tok"     git -C "$tree" push -q "${FORGE_BASE_URL%/}/${full}.git" "HEAD:refs/heads/main"     || die "apply : source NON poussee sur $full — le depot est cree et VIDE ; rejouer ce geste"

  echo "forge-gestures: $full pose — la source dont cette machine a ete installee est un projet de sa fleet"
}

# ─── LA DEMO, DEPOSEE CHEZ LE MASTER ────────────────────────────────────────────────────────────
# Livree dans l'image, deposee sur la forge — donc immediatement `available` — et JAMAIS installee :
# c'est a l'operateur de decider.
#
# DANS L'ESPACE DE `id = 1` : le seul espace garanti present que LCARS n'a pas invente, Gitea le cree
# avant nous. Le compte humain, lui, porte le login que l'operateur choisit — on ne peut pas s'y
# ancrer.
#
# ⚠ REPOSEE A CHAQUE APPLY, en force-push : un admin qui l'edite en place perd ses modifications.
# NON FATAL — une demo qui ne part pas est une demo absente, pas un deploiement casse.
DEMO_CATALOGUE="${LCARS_DEMO_CATALOGUE:-/opt/lcars/catalogues/web-demo}"

# ─── LA REFERENCE, DEPOSEE AU MEME ENDROIT ──────────────────────────────────────────────────────
# Elle vit DANS LE RELEASE et n'a jamais eu besoin de la forge pour tourner : ce qu'elle gagne a y
# etre est la LISIBILITE — on ne forke pas ce qu'on ne peut pas ouvrir.
#
# ⚠ ELLE NE DEVIENT PAS INSTALLABLE POUR AUTANT : une candidature portant le nom du catalogue livre
# est ecartee cote lecteur. Sans cette clause, le premier fork qui garde son manifeste tel quel en
# ferait DEUX sous ce nom, et la liste entiere serait refusee. Publier un objet fait pour etre forke
# ne doit pas armer la casse au premier fork.
#
# ⚠ LE CHEMIN SE DEMANDE AU RELEASE, il ne se recompose pas : il porte sa VERSION, donc tout glob
# ecrit ici marcherait jusqu'a la premiere reorganisation puis echouerait en silence sur un vide.
REFERENCE_CATALOGUE="${LCARS_REFERENCE_CATALOGUE:-}"

reference_catalogue_root() {
  [[ -n "$REFERENCE_CATALOGUE" ]] && { printf '%s' "$REFERENCE_CATALOGUE"; return 0; }

  local root
  root="$(tool catalogue-root 2>/dev/null | tail -n1)" || root=""
  if [[ -z "$root" || ! -d "$root" ]]; then
    # Un refus MUET ferait croire a une image sans reference — or elle en porte toujours une.
    echo "forge-gestures: le release ne dit pas ou vit son catalogue de reference — NON depose" >&2
    return 0
  fi
  printf '%s' "$root"
}

# LE NOM VIENT DU MANIFESTE, jamais du repertoire. Un arbre range sous `catalogues/web-demo` qui
# declarerait `name: autre` serait pousse sous `web-demo` et n'apparaitrait JAMAIS dans
# `catalogue list`, qui indexe par identite declaree. Meme regle a l'install et au depot, meme
# colonne zero. Rend vide si l'arbre ne declare rien.
catalogue_name_of() { # $1=arbre
  awk '/^name:/ { sub(/^name:[ \t]*/, ""); sub(/[ \t]*#.*$/, ""); gsub(/"/, "");
                  sub(/[ \t]+$/, ""); if ($0 != "") { print; exit } }' \
      "$1/catalogue.yaml" 2>/dev/null || true
}

# Le nom du catalogue que la release embarque — l'org de ses projets. Vide si la release ne dit
# pas ou il vit, ou si son manifeste ne declare rien : l'appelant nomme alors ce qui manque.
bundled_catalogue_name() {
  local root; root="$(reference_catalogue_root 2>/dev/null)"
  [[ -n "$root" ]] || return 0
  catalogue_name_of "$root"
}

# ─── LE GESTE, POUR LES DEUX ────────────────────────────────────────────────────────────────────
seed_catalogue_deposit() { # $1=jeton master  $2=arbre  $3=quoi (pour le message)
  local tok="$1" tree="$2" kind="$3"
  [[ -d "$tree" ]] || return 0

  local name
  name="$(catalogue_name_of "$tree")"
  if [[ -z "$name" ]]; then
    echo "forge-gestures: $tree ne declare pas de \`name:\` en colonne zero — $kind NON depose" >&2
    return 0
  fi

  local master
  master="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
            | curl -sS -K - -m 15 "${FORGE_BASE_URL%/}/api/v1/admin/users?limit=50" 2>/dev/null \
            | jq -r 'map(select(.id == 1)) | .[0].login // empty' 2>/dev/null || true)"
  if [[ -z "$master" ]]; then
    echo "forge-gestures: master (id=1) non resolu — $name NON depose, il n'apparaitra pas dans « catalogue list »" >&2
    return 0
  fi

  echo "forge-gestures: $kind ($name -> $master/$name)"
  printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -m 20 -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"$name\",\"private\":false,\"auto_init\":false}" \
      "${FORGE_BASE_URL%/}/api/v1/user/repos" 2>/dev/null || true

  # ⚠ `cp` PEUT ECHOUER, ET `set -e` TUE ALORS LE SCRIPT AVANT LE `rm -rf` DE FIN. Source illisible,
  # disque plein : le repertoire temporaire fuit. Le nettoyer sur place vaut mieux qu'un `trap`, qui
  # est global au processus et ecraserait celui qu'un autre geste aurait pose.
  local stage; stage="$(mktemp -d)"
  cp -r "$tree/." "$stage/" || {
    rm -rf "$stage"
    echo "forge-gestures: $tree illisible — $name NON depose" >&2
    return 0
  }
  rm -rf "$stage/.git"
  ( cd "$stage" \
    && git init -q -b main \
    && git add -A \
    && git -c "user.name=$SYSTEM_ACCOUNT" -c "user.email=$SYSTEM_EMAIL" \
         commit -q -m "chore(catalogue): projection de $name depuis l image" \
    && GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
       GIT_CONFIG_KEY_0="http.${FORGE_BASE_URL%/}.extraheader" \
       GIT_CONFIG_VALUE_0="Authorization: token $tok" \
       git push -q --force "${FORGE_BASE_URL%/}/${master}/${name}.git" main ) \
    || echo "forge-gestures: $name NON depose chez $master — il n'apparaitra pas dans « catalogue list »" >&2
  rm -rf "$stage"
}

# ⚠ LE JETON DE RUNNER N'ENTRE PAS DANS LA RECETTE, et c'est un choix : le provider sait le produire,
# mais une data source ECRIT sa valeur dans le tfstate — un credential dans un fichier d'etat, pour
# un objet qui n'est meme pas de la structure. C'est une LECTURE a usage unique.

cmd_runner_token() {
  need_forge_url
  local tok
  tok="$(read_stdin_secret)"
  [[ -n "$tok" ]] || tok="$(cat "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  [[ -n "$tok" ]] || die "pas d'autorité — sur un poste, « deploy/workstation up » la pose ; pour un conteneur, « FORGE_ADMIN_TOKEN=<jeton master> deploy/container config » depuis l'hôte"

  local body
  body="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
          | curl -sS -K - -m 15 -X POST "${FORGE_BASE_URL%/}/api/v1/admin/actions/runners/registration-token" || true)"
  local reg
  reg="$(printf '%s' "$body" | jq -r '.token // empty' 2>/dev/null || true)"
  [[ -n "$reg" ]] || die "la forge n'a pas rendu de jeton d'enregistrement (portee du jeton master ?)"
  printf '%s\n' "$reg"
}

# ─── INSTALLER UN CATALOGUE ─────────────────────────────────────────────────────────────────────
# ⚠ CE FICHIER NE GATE RIEN, ET IL NE DOIT PAS ESSAYER : l'autorisation est prise EN AMONT, par
# le service qui l'appelle. Un second gate ici serait une seconde verite sur la meme question.
#
# ⚠ ET CE SERVICE N'EST PAS ROOT. Il tourne sous `lcars-authority` — assez pour ouvrir les secrets
# qu'il possede, pas assez pour autre chose. Consequence pratique plus bas : les portes qui tombent
# en `nobody` ne peuvent PAS lire `$PRIVATE_DIR`, donc ce qu'on leur passe est une VALEUR, pas un
# chemin.
#
# ⚠ UN DOSSIER DE RECETTE PAR CATALOGUE : le `roles.auto.tfvars.json` d'un dossier porte l'org ET le
# roster, donc deux catalogues partageant un dossier laisseraient le dernier installe decider de ce
# que le suivant applique.

cmd_install() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "install: nom de catalogue requis"
  # LES NOMS DU SYSTEME NE SE PORTENT PAS : l'org systeme, et tout nom qui commence par `_` (ce que
  # la fleet pose elle-meme : `_ops`, `_catalogue`). Un catalogue de ce nom poserait ses projets dans
  # l'org du systeme, ou son magasin la ou le systeme ecrit. Meme regle cote runtime pour les projets
  # (`Fleet.Project.Onboard.Refute.refute_system_name/2`).
  case "$name" in
    _*|"$SYSTEM_ORG") die "install: « $name » est un nom du systeme (l'org systeme « $SYSTEM_ORG », ou un nom qui commence par « _ ») — un catalogue ne le porte pas, RIEN n'a ete pose" ;;
  esac
  need_forge_url
  need_cli

  # Le jeton : celui du geste appelant (`cmd_apply` l'a lu sur stdin ou dans le fichier), sinon le
  # fichier — jamais les deux dans un meme geste.
  local tok="${MASTER_TOKEN_OVERRIDE:-}"
  [[ -n "$tok" ]] || tok="$(cat "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  [[ -n "$tok" ]] || die "install: pas d'autorité — sur un poste, « deploy/workstation up » la pose ; pour un conteneur, « FORGE_ADMIN_TOKEN=<jeton master> deploy/container config » depuis l'hôte"
  local seed; seed="$(cat "$SEED_FILE" 2>/dev/null || true)"
  [[ -n "$seed" ]] || die "install: pas de seed — sur un poste, « deploy/workstation up » le pose ; pour un conteneur, « FORGE_SEED_PASSWORD=<mot de passe> deploy/container config » depuis l'hôte"
  [[ -n "$REFERENCE_CATALOGUE" ]] || REFERENCE_CATALOGUE="$(reference_catalogue_root)"

  # L'org d'un catalogue vit dans LE MEME espace de noms que les comptes : le trou de l'org systeme
  # est le meme une ligne plus bas. Et le compte systeme est pose par le meme plan que cette org.
  [[ "$name" != "$SYSTEM_ACCOUNT" ]] \
    || die "install: « $name » est le nom du compte systeme, que la meme recette pose — sur Gitea une org et un compte partagent l'espace de noms. RIEN n'a ete pose"
  nom_libre "$tok" "$name" \
    || die "install: un COMPTE nomme « $name » existe deja sur cette forge, et l'org de ce catalogue doit porter ce nom — sur Gitea une org et un compte partagent l'espace de noms, l'un des deux doit ceder. RIEN n'a ete pose"

  # 0. LE CATALOGUE DE LA RELEASE S'INSTALLE COMME LES AUTRES — org, comptes de role, teams, sa
  #    source dans son magasin —, a une difference pres : sa source est l'arbre que la release porte,
  #    pas un depot de la forge (`tool catalogue-source` le refuse a dessein, exit 4), et son materiel
  #    local reste celui de la release (`Fleet.Catalogue` ignore un dossier installe de ce nom).
  #    Il etait « installe » gratuitement tant que son org etait l'org systeme ; il ne l'est plus.
  local src sha="" work="" embarque
  embarque="$(bundled_catalogue_name)"
  if [[ -n "$embarque" && "$name" == "$embarque" ]]; then
    src="$(reference_catalogue_root)"
    [[ -n "$src" && -d "$src" ]] \
      || die "install: $name est le catalogue de la release, et la release ne dit pas ou il vit (« lcars tool catalogue-root ») — RIEN de ce catalogue n'a ete pose"
    # La revision de la release, quand la machine la connait (l'image d'un conteneur la porte).
    # Sans elle la projection n'a pas de trailer `Source-Commit`, et rien ne la compare : le
    # catalogue de la release n'a pas de « mise a jour disponible », il change avec la release.
    sha="${LCARS_IMAGE_REVISION:-}"
    echo "forge-gestures: $name <- la release ($src${sha:+ @ ${sha:0:8}})"
  else
    # 1. QUI porte ce catalogue. La porte refuse l'absent, le doublon et le catalogue livre, chacun
    #    avec son code — on ne traduit pas, on relaie.
    #
    #    ⚠ LE JETON SYSTEME, PAS LE MASTER, ET CE N'EST PAS UNE PREFERENCE : la porte tourne en
    #    `nobody` parce que c'est une LECTURE, et le jeton master lui est illisible. Le refus de
    #    permission remonterait alors en « pas de source installable » — le mauvais diagnostic pour
    #    le mauvais probleme. Un depot de catalogue est public, donc le jeton systeme suffit ; donner le
    #    site-admin a une lecture lui accorderait un pouvoir sans usage.
    #
    # ⚠ LA VALEUR PART PAR L'ENVIRONNEMENT : `/proc/<pid>/environ` n'est lisible que par le
    # proprietaire et root, un argv l'est par tout le monde.
    local sys_token="$PRIVATE_DIR/$SYSTEM_ACCOUNT.gitea_token"
    [[ -r "$sys_token" ]] \
      || die "install: $sys_token illisible — cette machine n'a pas encore de jeton système : sur un poste, « deploy/workstation up » le minte ; dans un conteneur, le démarrage le minte (« deploy/container up » depuis l'hôte)"
    local sys_tok_value; sys_tok_value="$(tr -d '[:space:]' < "$sys_token")"
    [[ -n "$sys_tok_value" ]] \
      || die "install: $sys_token est VIDE — un jeton vide part en 401, et la forge accuserait la source"

    # ⚠ LA REPONSE SE LIT SUR STDOUT SEUL. Le journal du release part sur stderr
    # (`Fleet.ReleaseDoor.claim_stdout!`), et il parle pendant la resolution : un depot qui declare le
    # catalogue livre y laisse une ligne `[info]`, precedee d'une ligne vide. Lus ensemble, journal et
    # reponse donnent une premiere ligne vide, et la reponse juste est refusee. Stderr est garde a part
    # et montre quand la porte refuse ou ne repond pas ; sur une reponse exploitable, il ne dit rien a
    # l'operateur.
    local src rc=0 src_err="" err_file
    err_file="$(mktemp)" || die "install: fichier temporaire impossible à créer (mktemp) — le disque ou \$TMPDIR refuse l'écriture"
    src="$(FORGE_BASE_URL="$FORGE_BASE_URL" FORGE_TOKEN="$sys_tok_value" \
           tool catalogue-source "$name" 2>"$err_file")" || rc=$?
    src_err="$(cat "$err_file")"
    rm -f "$err_file"
    if [[ "$rc" -ne 0 ]]; then
      [[ -z "$src" ]] || printf '%s\n' "$src" >&2
      [[ -z "$src_err" ]] || printf '%s\n' "$src_err" >&2
      die "install: $name — pas de source installable (cf. ci-dessus)" "$rc"
    fi
    local repo branch sha
    read -r repo branch sha <<< "$src"

    # ⚠ UN CODE DE SORTIE 0 N'EST PAS UNE REPONSE : aucune branche de la porte ne rend 0 sans imprimer,
    # donc un 0 MUET vient de ce qui a repondu A SA PLACE — et c'est ca qu'il faut nommer. Sans ce
    # controle, les trois champs vides construisent une URL a partir de rien, git echoue dessus, et le
    # refus cite l'erreur d'un outil auquel on a passe du vide : il accuse l'outil.
    if [[ -z "$repo" || -z "$branch" || -z "$sha" ]]; then
      [[ -z "$src_err" ]] || printf '%s\n' "$src_err" >&2
      die "install: $name — la porte de resolution a rendu 0 sans reponse exploitable.
    Attendu sur stdout : « <owner>/<depot> <branche> <sha> ». Recu : $(
      [[ -z "$src" ]] && printf 'RIEN' || printf '%s' "«$src»")
    Ce n'est pas un refus de la forge : un refus porte un code de sortie et une phrase. Un zero muet
    vient de ce qui a repondu A LA PLACE de la porte — verifier ce que « lcars » designe
    ($LCARS_CLI) et ce que « lcars tool catalogue-source $name » imprime a la main."
    fi

    echo "forge-gestures: $name <- $repo ($branch@${sha:0:8})"

    # 2. Le materiel, clone dans un jetable. Le jeton voyage par l'ENVIRON de git (extraheader),
    #    jamais dans l'URL : `/proc/<pid>/cmdline` est lisible par tout le monde, `environ` non.
    local work; work="$(mktemp -d)"
    # ⚠ `mktemp -d` REND 0700, ET LES PORTES QUI LISENT CE CLONE TOURNENT EN `nobody` : elles ne
    # peuvent pas traverser un repertoire que seul root ouvre, et le refus remonte alors en « refus de
    # catalogue » sur un catalogue parfaitement valide. Rien de secret n'atterrit ici — le materiel est
    # public, et le jeton voyage par l'ENVIRON de git, jamais dans le `.git/config` du clone.
    chmod 0755 "$work"
    # SC2064 : on veut la valeur d'ICI, pas celle du moment ou le trap se declenche.
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT
    GIT_TERMINAL_PROMPT=0 \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="http.${FORGE_BASE_URL%/}.extraheader" \
    GIT_CONFIG_VALUE_0="Authorization: token $tok" \
      git clone --quiet --depth 1 --branch "$branch" "${FORGE_BASE_URL%/}/${repo}.git" "$work/src" \
      || die "install: clone de $repo impossible"
    src="$work/src"
  fi

  # 3. LE MEME CONTROLE QUE LE BOOT, avant de toucher la forge. Un catalogue incoherent refuse ici
  #    coute un message ; installe, il coute un boot qui refuse ou un dispatch qui boucle, loin de
  #    sa cause.
  tool verify "$src" || die "install: $name ne passe pas la verification — RIEN de ce catalogue n'a ete pose"

  # 4. Le roster, derive du materiel du candidat — jamais tenu a la main.
  local dir="$CATALOGUE_WORK/$name"
  mkdir -p "$dir"

  # L'état de ce catalogue-ci survit à la copie, celui du voisin non : le dossier de recette de
  # référence peut porter l'état de `fleet`, et `cp -r` l'écrirait par-dessus celui de `web-demo`.
  # Sans son état, tofu réimporte la forge et recrée ce qui ne s'importe pas, et la CLI ne tient plus
  # sa promesse : « rien n'a bougé -> il ne touche rien ».
  local keep; keep="$(mktemp -d)"
  for f in terraform.tfstate terraform.tfstate.backup; do
    [[ -f "$dir/$f" ]] && cp "$dir/$f" "$keep/$f"
  done

  cp -r "$RECIPE_DIR/." "$dir/"

  # ⚠ L'ETAT DE TOFU NE SE COPIE PAS D'UN CATALOGUE A L'AUTRE. Un etat portant les comptes du
  # voisin, applique avec les variables de CELUI-CI, decrit ces comptes comme « plus dans la
  # configuration » — et le plan suivant les DETRUIT. Installer un catalogue desinstallerait l'autre.
  rm -rf "$dir/.terraform" "$dir/instance/.terraform"
  rm -f "$dir"/terraform.tfstate* "$dir"/instance/terraform.tfstate*

  # …puis on REND a ce catalogue le sien, s'il en avait un.
  for f in terraform.tfstate terraform.tfstate.backup; do
    [[ -f "$keep/$f" ]] && mv "$keep/$f" "$dir/$f"
  done
  rmdir "$keep" 2>/dev/null || true
  # Les avatars sont nommes par le ROLE, donc la recette n'a aucune table a tenir pour un catalogue
  # tiers. Facultatif : sans eux, les comptes restent en identicon.
  rm -rf "$dir/catalogue-avatars"
  [[ -d "$src/avatars" ]] && cp -r "$src/avatars" "$dir/catalogue-avatars"
  tool roles-tfvars "$src" > "$dir/roles.auto.tfvars.json" \
    || die "install: roster non derive depuis $name"

  # 5. La structure : org, comptes de role, teams, adhesions, propriete, charte. LA RECETTE, pas une
  #    reecriture — `var.org` porte le nom du catalogue depuis le premier jour.
  export TF_VAR_gitea_url="$FORGE_BASE_URL" TF_VAR_gitea_token="$tok" TF_VAR_seed_password="$seed"
  export TF_VAR_builtin_human="$BUILTIN_HUMAN"
  # Sans compte de demonstration, pas d'adresse a lui donner : la deriver rendrait « @lcars.local ».
  export TF_VAR_builtin_email="${LCARS_BUILTIN_EMAIL:-${TF_VAR_builtin_human:+${TF_VAR_builtin_human}@lcars.local}}"
  ( cd "$dir" && tofu init -input=false -no-color >/dev/null && tofu apply -auto-approve -input=false -no-color ) \
    || die "install: apply de la structure de $name en echec"

  # ⚠ RIEN A ROOT SOUS LE DOSSIER DE TRAVAIL. `install` se joue sous le compte d'autorite (l'executeur
  # de catalogue), `apply` en root — et `apply` installe le catalogue de la release par cette meme
  # fonction. Ce que root vient d'ecrire ici (recette copiee, etat tofu, providers) est rendu au
  # compte d'autorite, sinon son prochain `catalogue install` de ce nom ne relit ni ne reecrit son
  # etat, et tofu re-importe la forge a chaque passe. Meme garde que `put_secret` : `chown` n'est
  # tente que par root, tout appelant reel de `apply` l'est, un temoin ne l'est pas.
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "$AUTHORITY_USER:$(id -g "$AUTHORITY_USER")" "$dir" \
      || die "install: $dir n'a pas pu etre rendu a $AUTHORITY_USER — son prochain « catalogue install $name » ne verrait pas cet etat"
  fi

  publicize_org_members "$name" "$tok" "$seed"

  # Le master a cree l'org avec son jeton, Gitea en fait un Owner par effet de bord ; la recette a
  # mis le compte systeme dans `Owners`, et c'est lui le proprietaire — meme regle que pour l'org
  # systeme, pour la meme raison (cf. `demote_creator_from_owners`).
  demote_creator_from_owners "$name" "$tok"

  # 6. Le STORE : la source sur SA branche du magasin des catalogues. C'est LUI qui signe
  #    l'installation — une org sans sa source est un install interrompu, et aucun conteneur ne peut
  #    servir un catalogue dont le materiel n'est nulle part.
  push_store "$name" "$src" "$tok" "$sha"

  # Le catalogue de la release n'a pas de materiel a poser : la release EST son materiel. Le geste
  # du boot (`forge.d/catalogues.sh`) le sait par son nom et ne clone pas son magasin.
  if [[ -n "$embarque" && "$name" == "$embarque" ]]; then
    echo "forge-gestures: $name installe (org, comptes, teams, sa source sur $STORE_FULL:$name) — le materiel est celui de la release"
    return 0
  fi

  # 7. LE MATERIEL LOCAL, POSE TOUT DE SUITE. Le boot suivant le reposerait de toute facon, mais la
  #    commande rendrait alors la main sur un conteneur qui ne sert pas encore ce qu'il vient
  #    d'installer, sans que l'admin sache qu'il doit redemarrer.
  #
  #    Un echec ici n'annule RIEN : la forge porte l'org et la source, l'installation a eu lieu.
  #
  #    ⚠ CE MATERIEL EST AUSSI LE SQUELETTE DES PROJETS DE CE CATALOGUE. `Scaffold.template_root/1`
  #    lit `project_template/` SOUS CE REPERTOIRE ; absent, il se replie sur le catalogue livre. Un
  #    catalogue qui livre son propre arbre et dont le materiel n'est pas pose voit donc ses projets
  #    naitre du squelette d'un voisin — c'est ce que le message d'echec ci-dessous doit dire.
  local materiel=1
  install_material "$name" "$src" && materiel=0

  if [[ "$materiel" -eq 0 ]]; then
    echo "forge-gestures: $name installe (org, comptes, teams, sa source sur $STORE_FULL:$name, materiel pose)"
  else
    # la forge porte l'installation, mais cette machine ne sert pas encore le catalogue : ce n'est pas un succes
    die "install: $name est posé sur la forge (org, comptes, source sur $STORE_FULL:$name), mais son matériel local n'a pas pu être posé dans ${LCARS_CATALOGUES_DIR:-/opt/lcars/var/catalogues} (cause au-dessus) — tant qu'il manque, ses projets naissent du squelette du catalogue livré. Il se repose au prochain démarrage du conteneur, ou sur un poste par « deploy/workstation up »"
  fi
}

# ⚠ CLONE DEPUIS LE STORE, JAMAIS COPIE DEPUIS L'ARBRE : le boot compare le sha local a celui du
# store, et un repertoire copie n'a pas de `.git`, donc pas de sha. Il ferait mentir le premier
# `check` (« materiel absent ») sur un conteneur qui vient d'installer.
#
# ⚠ DEUX `local`, PAS UN : bash expanse TOUS les arguments du builtin AVANT de l'executer, donc dans
# `local a="$1" b="/base/$a"` le `$a` n'est pas celui qu'on vient d'ecrire — `b` vaut `/base/`.
install_material() { # $1=catalogue  $2=arbre (non utilise : on clone l autorite)
  local name="$1"
  local dir="${LCARS_CATALOGUES_DIR:-/opt/lcars/var/catalogues}/$name"
  mkdir -p "$(dirname "$dir")"
  rm -rf "$dir.tmp"
  GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --branch "$name" \
    "${FORGE_BASE_URL%/}/${STORE_FULL}.git" "$dir.tmp" || { rm -rf "$dir.tmp"; return 1; }
  rm -rf "$dir"
  mv "$dir.tmp" "$dir"
}

# Projection, pas fusion : un commit frais a chaque fois. L'historique porteur est celui du depot,
# et il reste chez son proprietaire.
#
# ⚠ LA PROJECTION PORTE SA SOURCE EN TRAILER, ET SANS CA « updatable » EST TOUJOURS VRAI : un commit
# frais ne partage jamais son sha avec celui qu'il projette, donc comparer les deux tetes repond
# « different » par construction — un catalogue installe trente secondes plus tot s'affiche « MAJ
# DISPO ». La forge ne donne pas non plus de hash de CONTENU exploitable.
push_store() { # $1=catalogue  $2=arbre  $3=jeton  $4=sha source
  local name="$1" tree="$2" tok="$3" src_sha="${4:-}"
  local url="${FORGE_BASE_URL%/}/${STORE_FULL}.git"

  # ⚠ LE DEPOT EST POSE PAR LA RECETTE, PAS ICI : un geste qui creerait le magasin du systeme
  # laisserait deux poseurs pour un objet (cf. `_ops`, lot 3). Absent, on REFUSE en le nommant —
  # pousser une branche sur un depot qui n'existe pas rend « Push to create is not enabled for
  # organizations », un message qui parle d'un reglage alors que le fait est qu'il n'y a rien.
  local code
  code="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -w '%{http_code}' -m 15 \
      "${FORGE_BASE_URL%/}/api/v1/repos/$STORE_FULL" 2>/dev/null || true)"
  [[ "$code" == "200" ]] \
    || die "install: le magasin des catalogues ($STORE_FULL) ne repond pas (HTTP ${code:-aucune reponse}) — la recette de la forge le pose ; l'org de $name est posee, mais sa source n'est nulle part et $name n'est PAS installe"

  local stage; stage="$(mktemp -d)"
  cp -r "$tree/." "$stage/"
  rm -rf "$stage/.git"
  ( cd "$stage" \
    && git init -q -b main \
    && git add -A \
    && git -c "user.name=$SYSTEM_ACCOUNT" -c "user.email=$SYSTEM_EMAIL" \
         commit -q -m "chore(catalogue): projection de $name depuis sa source" \
                   ${src_sha:+-m "Source-Commit: $src_sha"} \
    && GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
       GIT_CONFIG_KEY_0="http.${FORGE_BASE_URL%/}.extraheader" \
       GIT_CONFIG_VALUE_0="Authorization: token $tok" \
       git push -q --force "$url" "HEAD:refs/heads/$name" ) \
    || { rm -rf "$stage"; die "install: source NON poussee sur $STORE_FULL:$name — l'org est posee mais le catalogue n'est PAS installe"; }
  rm -rf "$stage"
}

# ⚠ FRONTIERE DE SOURCING — TOUT CE QUI EST AU-DESSUS EST TESTABLE, TOUT CE QUI EST DESSOUS NE
# L'EST PAS. Un temoin charge ce fichier pour appeler UNE fonction sans jouer le dispatch ; sans
# cette ligne, `case "${1:-}"` tombe sur `*)` et sort 1 des le `source`. Meme forme et meme motif que
# `human-converger.sh`.
#
# ⚠ ET LE PIEGE EST DE POSER UNE FONCTION SOUS CETTE LIGNE : elle devient invisible aux temoins,
# qui echouent alors sur « command not found » — une erreur qui accuse le test, pas le rangement.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

case "${1:-}" in
  config-token) cmd_config_token ;;
  config-seed)  cmd_config_seed ;;
  apply)        with_apply_lock cmd_apply ;;
  install)      shift; with_apply_lock cmd_install "$@" ;;
  runner-token) cmd_runner_token ;;
  # ⚠ CE VERBE EXISTE POUR QU'AUCUN APPELANT N'AIT A RECOPIER LE DEFAUT. Le nom du compte integre a
  # UN auteur — la ligne `TF_VAR_builtin_human` ci-dessus — et un second litteral ailleurs ne reste
  # d'accord avec elle que jusqu'au jour ou l'un des deux bouge. `25-directories` et `deploy/accept`
  # le DEMANDENT ici.
  builtin-human) printf "%s\n" "$BUILTIN_HUMAN" ;;
  *) echo "forge-gestures: geste requis (config-token|config-seed|apply|install|runner-token|builtin-human)" >&2; exit 1 ;;
esac
