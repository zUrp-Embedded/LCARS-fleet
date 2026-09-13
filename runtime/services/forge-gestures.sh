#!/usr/bin/env bash
# SOURCE: runtime/services/forge-gestures.sh
# AUTHOR: drdree
# STARDATE: 2026-08-16
# STATUS: les gestes forge du conteneur — poses UNE fois, joues par tout appelant
# ⚠ LES SECRETS ENTRENT PAR STDIN, JAMAIS PAR argv : `/proc/<pid>/cmdline` est lisible par tout le
# monde pendant l'appel, et un `--token X` l'aurait mis dans la ligne de commande de CE script ET
# dans celle du client docker.
#
# USAGE : forge-gestures.sh <geste>
#   config-token   lit un jeton master sur STDIN et le pose, APRES verification contre la forge.
#   config-seed    lit le seed sur STDIN, meme mode (handoff tofu -> mint A4).
#   builtin-human  imprime le nom du compte integre. Ce fichier en est l'AUTORITE ; le verbe existe
#                  pour que ses appelants le DEMANDENT au lieu d'en recopier le defaut.
#   apply          joue la recette. Ne prend RIEN — il lit ce que le conteneur detient.
#   toolchain-protection <login-du-siege> [admins...]
#                  pose la protection de branche du depot ops. Le login du siege est VARIABLE,
#                  jamais en dur. SANS status check : l'allumage se fait en deux temps.
#   install <nom>  installe ou MET A JOUR le catalogue <nom> depuis le depot que la forge porte.
#                  Jamais declenche par le boot.
#   runner-token   minte un jeton d'ENREGISTREMENT de runner et l'imprime. Credential a usage
#                  unique : sortie sur stdout, il ne se pose nulle part.
#
# EXIT : 0 · 1 donnee manquante ou geste en echec · 2 pas de FORGE_BASE_URL (et, pour `install`,
#        aucun depot de ce nom) · 3 jeton non authentifie (et, pour `install`, DEUX depots
#        revendiquent le nom)

set -euo pipefail

# Les chemins sont SURCHARGEABLES, comme ceux de `provision-lib.sh`, et pour la meme raison : un
# temoin doit pouvoir exercer ce script sans etre root ni ecrire dans /opt/lcars/var/tokens. Les defauts
# sont les chemins reels ; aucun appelant de production ne les passe.
PRIVATE_DIR="${LCARS_PRIVATE_DIR:-/opt/lcars/var/tokens}"
# LE COMPTE SYSTEME EN UN SEUL ENDROIT DE CE FICHIER (les deux projections de catalogue le lisent
# ici, jamais en dur). Le defaut suit celui de `provision-lib.sh` et de `forge.tf` — trois recopies d'un meme nom, mais
# chacune est un DEFAUT dans un runtime different (bash de conteneur, bash de provisioning, HCL), pas
# une seconde autorite : l'appelant les surcharge ensemble ou pas du tout.
# Le compte integre, resolu UNE fois : le `TF_VAR_builtin_human` plus bas et le verbe
# `builtin-human` lisent celui-ci. Trois `${LCARS_BUILTIN_HUMAN:-…}` dans le meme fichier seraient
# trois autorites pour un nom, et c'est celle qu'on ne relit pas qui gagne.
#
# ⚠ VIDE PAR DEFAUT, ET C'EST LE CANON (⚖ user 2026-08-30). Un defaut nomme semerait un compte
# humain sur tout deploiement, avec un mot de passe pose et ANNONCE. Or aucun deploiement de
# TRAVAIL ne fabrique d'humain — le rail pose les autorites (le siege, l'admin de forge, le master
# token) et les personnes s'enrolent par la page d'inscription, sous leur nom.
#
# Qui en veut un le NOMME : les deux bancs posent `LCARS_BUILTIN_HUMAN` — `bench-up.sh`
# pour le conteneur, `install.sh --bench` pour le poste (il traverse le sudo par l'ESCALADE_ENV de
# `deploy/workstation`) ; ⚖ user 2026-09-11, « les install doivent etre ISO a la fin ». C'est la
# SEULE voie. Un `LCARS_DISPOSABLE` a vecu ici, qui demandait un humain de demonstration
# sans le nommer (« lcars » par defaut) depuis un `--disposable` de la porte, quatre etages plus
# haut : ⚖ user 2026-09-04, « un vieux reliquat a virer » — un axe entier pour un defaut que plus
# personne ne demandait. Ce fichier reste le seul declarant du nom ; deux temoins de
# le temoin de 48 le garde.
BUILTIN_HUMAN="${LCARS_BUILTIN_HUMAN:-}"
SYSTEM_ACCOUNT="${LCARS_SYSTEM_ACCOUNT:-system_starfleet}"
# LE DETENTEUR DES SECRETS DE FORGE. Meme defaut que `provision-lib.sh` et que `21-service-accounts`,
# et meme raison qu'au-dessus : une recopie par runtime, surchargee ensemble ou pas du tout. C'est le
# compte que `put_secret` pose sur ce qu'il ecrit — le seul qui ouvrira ces fichiers.
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
RECIPE_DIR="${LCARS_RECIPE_DIR:-/opt/lcars/services/forge-recipe}"
# Le repertoire de travail des gestes de structure. Il remonte ICI, avec les autres chemins, parce
# que le verrou d'apply y vit — et une variable definie plus bas que sa premiere lecture
# ne tient que par l'ordre d'execution.
CATALOGUE_WORK="${LCARS_CATALOGUES_WORK:-/opt/lcars/var/tofu}"
# Le nom vit ici parce que ce fichier est ce qui ECRIT le magasin : une adresse appartient a celui
# qui pose. Rien ne se DECIDE en la lisant. Le `_` initial est de l'UX (⚖ user) : il separe a l'oeil
# ce que la fleet pose de ce qu'un humain depose.
STORE_REPO="${LCARS_STORE_REPO:-_catalogue}"
_lcars_cli() {
  local here
  [[ -n "${LCARS_CLI:-}" ]] && { printf '%s' "$LCARS_CLI"; return 0; }
  if command -v lcars >/dev/null 2>&1; then command -v lcars; return 0; fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "$here/../bin/lcars"
}
LCARS_CLI="$(_lcars_cli)"
tool() { bash "$LCARS_CLI" tool "$@"; }

need_cli() {
  [[ -r "$LCARS_CLI" ]] && return 0
  die "portes outil du release introuvables ($LCARS_CLI).
  Ce script les appelle pour resoudre, verifier et enroler un catalogue (« lcars tool … »). Sur un
  poste, 60-deploy pose la CLI ; l'image la porte. « LCARS_CLI=<chemin> » force la resolution."
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
with_apply_lock() {
  local lock="${LCARS_APPLY_LOCK:-$CATALOGUE_WORK/.apply.lock}"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  [[ -e "$lock" ]] || ( : > "$lock" ) 2>/dev/null || true
  exec 9>"$lock" || die "verrou d'apply inouvrable ($lock) — regarde son proprietaire et son mode : ce geste tourne en root, donc un refus ici designe un montage ou un systeme de fichiers en lecture seule, pas une permission"
  flock -n 9 || die "un autre apply de structure est en cours (verrou $lock) — rien n'a ete tente"
  "$@"
}

# ─── ensure_ops_repo — LE DEPOT DU SYSADMIN ─────────────────────────────────────────────────────
#
# Le runtime le LIT sans que rien ne le CREE : la recette tofu fait les orgs, les comptes et les
# teams, pas les depots.
#
# ⚠ `auto_init` VRAI : un depot vide n'a pas de branche, et on pousse SUR une branche. Sans branche
# par defaut la forge repond « Push to create is not enabled for organizations » — un message qui
# parle d'un reglage alors que le fait est « il n'y a rien ou pousser ».
ensure_ops_repo() { # $1=org  $2=jeton master
  local org="$1" tok="$2"
  # ⚠ DEUX LIGNES, ET CE N'EST PAS DU STYLE : `local a=… b="${a#…}"` NE VOIT PAS `a` — bash expanse
  # toute la ligne AVANT d'assigner. Sous `set -u`, c'est un « unbound variable » qui tue le script
  # au milieu d'un apply, en pointant une ligne qui a l'air juste.
  local repo="${LCARS_OPS_REPO:-$org/lcars}"
  local name="${repo#*/}"

  local code
  code="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -w '%{http_code}' -m 15 \
      "${FORGE_BASE_URL%/}/api/v1/repos/$repo" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    echo "forge-gestures: depot ops $repo deja la"
    return 0
  fi

  # ⚠ LA RELECTURE FAIT FOI, PAS LE CODE DU POST : Gitea rend des codes qui varient selon la
  # version, donc on POST au mieux puis on REDEMANDE.
  printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -m 20 -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"${name}\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\",\"description\":\"Depot du sysadmin : escalades, demandes d'outillage, registre d'incidents.\"}" \
      "${FORGE_BASE_URL%/}/api/v1/orgs/${org}/repos" 2>/dev/null || true

  code="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -w '%{http_code}' -m 15 \
      "${FORGE_BASE_URL%/}/api/v1/repos/$repo" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    echo "forge-gestures: depot ops $repo cree (auto_init, branche main)"
  else
    # NON FATAL, ET C'EST DELIBERE : une forge sans depot ops reste une forge. `65-ops-branch` le
    # dira en derive au passage suivant — ce qui est exactement son travail.
    echo "forge-gestures: depot ops $repo NON cree (HTTP $code) — 65-ops-branch le dira en derive" >&2
  fi
  return 0
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
    code="$(curl -sS -o /dev/null -w '%{http_code}' -m 10 -X PUT -u "$acct:$seed" \
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

  if hcurl "$tok" -sS -m 15 -o /dev/null -w '%{http_code}' \
       -X DELETE "$api/teams/$tid/members/$master" 2>/dev/null | grep -q '^204$'; then
    echo "forge-gestures: $master retire des Owners de $org — il l'etait par creation, pas par decision ($SYSTEM_ACCOUNT reste proprietaire ; le site-admin est intact)"
  else
    echo "forge-gestures: retrait de $master des Owners de $org REFUSE — la liste garde son proprietaire de creation" >&2
  fi
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

  export TF_VAR_gitea_url="$FORGE_BASE_URL"
  export TF_VAR_gitea_token="$tok"
  export TF_VAR_seed_password="$seed"
  export TF_VAR_builtin_human="$BUILTIN_HUMAN"
  # Sans compte de demonstration, pas d'adresse a lui donner : la deriver rendrait « @lcars.local ».
  export TF_VAR_builtin_email="${LCARS_BUILTIN_EMAIL:-${TF_VAR_builtin_human:+${TF_VAR_builtin_human}@lcars.local}}"

  # L'ORDRE EST UN INVARIANT, pas une preference : `instance/` porte les comptes partages, et une
  # adhesion peut nommer un compte qu'elle ne cree pas, jamais un compte qui n'existe pas.
  local m
  for m in instance .; do
    echo "forge-gestures: apply $m"
    ( cd "$RECIPE_DIR/$m" && tofu init -input=false -no-color >/dev/null ) \
      || die "init $m en echec — le miroir de providers (TF_CLI_CONFIG_FILE) couvre-t-il cette recette ?"
    ( cd "$RECIPE_DIR/$m" && tofu apply -auto-approve -input=false -no-color ) \
      || die "apply $m en echec — rien n'est suppose, relis la sortie ci-dessus"
  done

  ensure_ops_repo "${LCARS_FORGE_ORG:-fleet}" "$tok"

  publicize_org_members "${LCARS_FORGE_ORG:-fleet}" "$tok" "$seed"

  demote_creator_from_owners "${LCARS_FORGE_ORG:-fleet}" "$tok"

  seed_catalogue_deposit "$tok" "$(reference_catalogue_root)" "catalogue de reference"
  seed_catalogue_deposit "$tok" "$DEMO_CATALOGUE" "catalogue de demonstration"
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

# ─── LE GESTE, POUR LES DEUX ────────────────────────────────────────────────────────────────────
# LE NOM VIENT DU MANIFESTE, jamais du repertoire. Un arbre range sous `catalogues/web-demo` qui
# declarerait `name: autre` serait pousse sous `web-demo` et n'apparaitrait JAMAIS dans
# `catalogue list`, qui indexe par identite declaree. Meme regle qu'a l'install, meme colonne zero.
seed_catalogue_deposit() { # $1=jeton master  $2=arbre  $3=quoi (pour le message)
  local tok="$1" tree="$2" kind="$3"
  [[ -d "$tree" ]] || return 0

  local name
  name="$(awk '/^name:/ { sub(/^name:[ \t]*/, ""); sub(/[ \t]*#.*$/, ""); gsub(/"/, "");
                          sub(/[ \t]+$/, ""); if ($0 != "") { print; exit } }' \
          "$tree/catalogue.yaml" 2>/dev/null || true)"
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
#
# ─── toolchain-protection — LE GESTE D'INSTALLATION du rail toolchain (⚖ user) ──────────────────
# `dismiss_stale_approvals` : un re-push tue l'approbation, et c'est la seule propriete qu'aucun
# test ni ACL ne porte. SANS status check, parce que l'allumage est en DEUX temps — le contexte
# viendra AVEC son job.
#
# ⚠ CE GESTE ET LA CONFIG :toolchain_auto_merge VONT ENSEMBLE, JAMAIS L'UN SANS L'AUTRE : armer
# l'auto-merge sur une branche sans protection, c'est « conditions remplies » tout de suite, donc
# un merge sans signature avec le convergeur derriere.
cmd_toolchain_protection() { # toolchain-protection <login-du-siege> [autres-approbateurs...]
  need_forge_url
  [[ $# -ge 1 ]] || die "toolchain-protection: le LOGIN du siege est requis (variable — celui de l'installeur ; jamais en dur)"
  local tok; tok="$(cat "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  [[ -n "$tok" ]] || die "pas d'autorité — sur un poste, « deploy/workstation up » la pose ; pour un conteneur, « FORGE_ADMIN_TOKEN=<jeton master> deploy/container config » depuis l'hôte"

  # ⚠ LE NOM EST GELE, ET SON AUTORITE EST `Fleet.Toolchain.branch/0` : cette ligne en est une
  # RECOPIE, tenue par le contrat `toolchain.branch_single_source`. Rendu reglable ICI seulement, il
  # poserait la protection sur une branche pendant que le reconciliateur en interrogerait une autre.
  local repo="${LCARS_OPS_REPO:-fleet/lcars}" branch="tool_request"
  local approvers; approvers="$(printf '"%s",' "$@")"; approvers="[${approvers%,}]"

  hcurl "$tok" -sS -m 15 -o /dev/null -H 'Content-Type: application/json'     -X POST "${FORGE_BASE_URL%/}/api/v1/repos/$repo/branch_protections"     -d "{\"branch_name\":\"$branch\",\"required_approvals\":1,\"enable_approvals_whitelist\":true,\"approvals_whitelist_username\":$approvers,\"dismiss_stale_approvals\":true}" || true

  local got
  got="$(hcurl "$tok" -sS -m 15     "${FORGE_BASE_URL%/}/api/v1/repos/$repo/branch_protections/$branch" 2>/dev/null || true)"

  local ra ds
  ra="$(jq -r '.required_approvals // empty' <<< "$got" 2>/dev/null || true)"
  ds="$(jq -r '.dismiss_stale_approvals // empty' <<< "$got" 2>/dev/null || true)"

  if [[ "$ra" == "1" && "$ds" == "true" ]]; then
    echo "forge-gestures: protection VERIFIEE par relecture sur $repo:$branch (required_approvals=1, dismiss_stale, approbateurs: $approvers)"
    echo "  -> ACTIVER l'auto-merge maintenant que la protection TIENT :"
    echo "     config :lcars_fleet, :toolchain_auto_merge, true   (runtime.exs / env du deploy)"
  else
    echo "relecture: $got" >&2
    die "toolchain-protection: la protection n'est PAS en place sur $repo:$branch — NE PAS activer :toolchain_auto_merge"
  fi
}

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
  need_forge_url
  need_cli

  local tok; tok="$(cat "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  [[ -n "$tok" ]] || die "install: pas d'autorité — sur un poste, « deploy/workstation up » la pose ; pour un conteneur, « FORGE_ADMIN_TOKEN=<jeton master> deploy/container config » depuis l'hôte"
  local seed; seed="$(cat "$SEED_FILE" 2>/dev/null || true)"
  [[ -n "$seed" ]] || die "install: pas de seed — sur un poste, « deploy/workstation up » le pose ; pour un conteneur, « FORGE_SEED_PASSWORD=<mot de passe> deploy/container config » depuis l'hôte"

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

  local src rc=0
  src="$(FORGE_BASE_URL="$FORGE_BASE_URL" FORGE_TOKEN="$sys_tok_value" \
         tool catalogue-source "$name" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$src" >&2
    die "install: $name — pas de source installable (cf. ci-dessus)" "$rc"
  fi
  local repo branch sha
  read -r repo branch sha <<< "$src"

  # ⚠ UN CODE DE SORTIE 0 N'EST PAS UNE REPONSE : aucune branche de la porte ne rend 0 sans imprimer,
  # donc un 0 MUET vient de ce qui a repondu A SA PLACE — et c'est ca qu'il faut nommer. Sans ce
  # controle, les trois champs vides construisent une URL a partir de rien, git echoue dessus, et le
  # refus cite l'erreur d'un outil auquel on a passe du vide : il accuse l'outil.
  if [[ -z "$repo" || -z "$branch" || -z "$sha" ]]; then
    printf '%s\n' "$src" >&2
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

  # 3. LE MEME CONTROLE QUE LE BOOT, avant de toucher la forge. Un catalogue incoherent refuse ici
  #    coute un message ; installe, il coute un boot qui refuse ou un dispatch qui boucle, loin de
  #    sa cause.
  tool verify "$work/src" || die "install: $name ne passe pas la verification — RIEN n'a ete pose"

  # 4. Le roster, derive du materiel du candidat — jamais tenu a la main.
  local dir="$CATALOGUE_WORK/$name"
  mkdir -p "$dir"

  # L'ETAT DE CE CATALOGUE-CI SURVIT A LA COPIE, celui du voisin non. `cp -r` ecraserait le premier
  # avec le second : le dossier de recette de reference porte l'etat de `fleet`, et le copier par
  # dessus celui de `web-demo` revient a jeter le sien A CHAQUE passe. Le rejeu re-importerait alors
  # tout depuis zero — ca converge (l'etat est jetable par construction, « tofu dedans »),
  # mais ca ne tient pas la promesse que la CLI affiche : « rien n'a bouge -> il ne touche rien ».
  local keep; keep="$(mktemp -d)"
  for f in terraform.tfstate terraform.tfstate.backup; do
    [[ -f "$dir/$f" ]] && cp "$dir/$f" "$keep/$f"
  done

  cp -r "$RECIPE_DIR/." "$dir/"

  # ⚠ L'ETAT DE TOFU NE SE COPIE PAS D'UN CATALOGUE A L'AUTRE. Un etat portant les comptes du
  # voisin, applique avec les variables de CELUI-CI, decrit ces comptes comme « plus dans la
  # configuration » — et le plan suivant les DETRUIT. Installer un catalogue desinstallerait l'autre.
  #
  # Partir d'un etat VIDE est le design : la recette reconstruit ce qui existe par ses blocs
  # `import`, donc l'etat est jetable. En apporter un etranger, c'est lui mentir sur ce qu'il gouverne.
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
  [[ -d "$work/src/avatars" ]] && cp -r "$work/src/avatars" "$dir/catalogue-avatars"
  tool roles-tfvars "$work/src" > "$dir/roles.auto.tfvars.json" \
    || die "install: roster non derive depuis $name"

  # 5. La structure : org, comptes de role, teams, adhesions, propriete, charte. LA RECETTE, pas une
  #    reecriture — `var.org` porte le nom du catalogue depuis le premier jour.
  export TF_VAR_gitea_url="$FORGE_BASE_URL" TF_VAR_gitea_token="$tok" TF_VAR_seed_password="$seed"
  export TF_VAR_builtin_human="$BUILTIN_HUMAN"
  # Sans compte de demonstration, pas d'adresse a lui donner : la deriver rendrait « @lcars.local ».
  export TF_VAR_builtin_email="${LCARS_BUILTIN_EMAIL:-${TF_VAR_builtin_human:+${TF_VAR_builtin_human}@lcars.local}}"
  ( cd "$dir" && tofu init -input=false -no-color >/dev/null && tofu apply -auto-approve -input=false -no-color ) \
    || die "install: apply de la structure de $name en echec"

  publicize_org_members "$name" "$tok" "$seed"

  # 6. Le STORE : la source dans l'org du catalogue. C'est LUI qui signe l'installation — une org
  #    sans sa source est un install interrompu, et aucun conteneur ne peut servir un catalogue dont le
  #    materiel n'est nulle part.
  push_store "$name" "$work/src" "$tok" "$sha"

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
  install_material "$name" "$work/src" && materiel=0

  if [[ "$materiel" -eq 0 ]]; then
    echo "forge-gestures: $name installe (org, comptes, teams, sa source dans $name/$STORE_REPO, materiel pose)"
  else
    echo "forge-gestures: $name INSTALLE sur la forge, mais le materiel local n'a pas pu etre pose" >&2
    echo "  il se repose au prochain démarrage du conteneur, ou sur un poste par « deploy/workstation up »" >&2
    echo "  son squelette de projet n'est donc pas lisible : ses projets naitront de celui du catalogue livre" >&2
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
  GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 \
    "${FORGE_BASE_URL%/}/${name}/${STORE_REPO}.git" "$dir.tmp" || { rm -rf "$dir.tmp"; return 1; }
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
  local url="${FORGE_BASE_URL%/}/${name}/${STORE_REPO}.git"

  printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -m 20 -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"${STORE_REPO}\",\"private\":false,\"auto_init\":false}" \
      "${FORGE_BASE_URL%/}/api/v1/orgs/${name}/repos" || true

  local stage; stage="$(mktemp -d)"
  cp -r "$tree/." "$stage/"
  rm -rf "$stage/.git"
  ( cd "$stage" \
    && git init -q -b main \
    && git add -A \
    && git -c "user.name=$SYSTEM_ACCOUNT" -c "user.email=$SYSTEM_EMAIL" \
         commit -q -m "chore(catalogue): projection de $name depuis son depot" \
                   -m "Source-Commit: $src_sha" \
    && GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
       GIT_CONFIG_KEY_0="http.${FORGE_BASE_URL%/}.extraheader" \
       GIT_CONFIG_VALUE_0="Authorization: token $tok" \
       git push -q --force "$url" main ) \
    || { rm -rf "$stage"; die "install: source NON poussee dans $name/$STORE_REPO — l'org est posee mais le catalogue n'est PAS installe"; }
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
  toolchain-protection) shift; cmd_toolchain_protection "$@" ;;
  # ⚠ CE VERBE EXISTE POUR QU'AUCUN APPELANT N'AIT A RECOPIER LE DEFAUT. Le nom du compte integre a
  # UN auteur — la ligne `TF_VAR_builtin_human` ci-dessus — et un second litteral ailleurs ne reste
  # d'accord avec elle que jusqu'au jour ou l'un des deux bouge. `25-directories` et `deploy/accept`
  # le DEMANDENT ici.
  builtin-human) printf "%s\n" "$BUILTIN_HUMAN" ;;
  *) echo "forge-gestures: geste requis (config-token|config-seed|apply|install|runner-token|toolchain-protection|builtin-human)" >&2; exit 1 ;;
esac
