#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/forge-gestures.sh
# AUTHOR: drdree
# STARDATE: 2026-08-16
# STATUS: les gestes forge de la boite — poses UNE fois, joues par tout appelant
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
# Ces trois gestes vivaient dans `docker.sh`, sous forme de scripts distants passes a
# `compose exec bash -c`. Le banc ne peut PAS appeler `docker.sh` : sa boite est creee par un autre
# couple de fichiers compose (`docker-compose.install.yml` + `.bench.yml`), et `docker.sh` refuse
# — a raison — d'agir sur un projet qu'il n'a pas cree. Le banc aurait donc recopie les memes
# gestes, et deux copies d'un meme contrat derivent.
#
# Ils vivent donc DANS L'IMAGE, versionnes avec la recette qu'ils jouent. `docker.sh` et le banc
# sont alors deux facons d'entrer par la meme porte :
#     docker.sh          -> compose exec -T -u root lcars /opt/lcars/forge-gestures.sh <geste>
#     bench              -> docker exec -i -u root <box>  /opt/lcars/forge-gestures.sh <geste>
#
# ─── LES SECRETS ENTRENT PAR STDIN, JAMAIS PAR argv ─────────────────────────────────────────────
# `/proc/<pid>/cmdline` est lisible par tout le monde pendant l'appel — la lecon payee deux fois
# par 6-141 et 6-141bis, sur des credentials moins puissants que le master token. Un `--token X`
# l'aurait mis dans la ligne de commande de CE script ET dans celle du client docker.
#
# USAGE : forge-gestures.sh <geste>
#   config-token   lit un jeton master sur STDIN, le VERIFIE contre la forge de la boite, puis le
#                  pose en 0600 root. Un jeton qui ne s'authentifie pas n'est PAS ecrit.
#   config-seed    lit le seed sur STDIN et le pose en 0600 root (handoff tofu -> mint A4).
#   apply          joue la recette : module instance/, module catalogue, puis le depot modele.
#                  Ne prend RIEN — il lit ce que la boite detient. Un jeton sur STDIN l'emporte.
#   install <nom>  installe — ou MET A JOUR — le catalogue <nom> depuis le depot que la forge porte :
#                  resolution du depot, clone, MEME verification que le boot, roster derive, recette
#                  (org + comptes + teams), puis la source poussee dans <nom>/catalogue. Jamais
#                  declenche par le boot.
#   runner-token   minte un jeton d'ENREGISTREMENT de runner et l'imprime. Sortie unique, sur
#                  stdout : c'est un credential a usage unique, il ne se pose nulle part.
#
# EXIT : 0 · 1 donnee manquante ou geste en echec · 2 la boite n'a pas de FORGE_BASE_URL (et, pour
#        `install`, aucun depot ne porte ce nom) · 3 le jeton ne s'authentifie pas (et, pour
#        `install`, DEUX depots revendiquent le nom) · 4 `install` d'un catalogue livre dans le release

set -euo pipefail

# Les chemins sont SURCHARGEABLES, comme ceux de `provision-lib.sh`, et pour la meme raison : un
# temoin doit pouvoir exercer ce script sans etre root ni ecrire dans /home/private. Les defauts
# sont les chemins reels ; aucun appelant de production ne les passe.
PRIVATE_DIR="${LCARS_PRIVATE_DIR:-/home/private}"
MASTER_TOKEN_FILE="${LCARS_MASTER_TOKEN_FILE:-$PRIVATE_DIR/forge-master.token}"
SEED_FILE="${LCARS_FORGE_SEED_FILE:-$PRIVATE_DIR/forge-seed.pass}"
RECIPE_DIR="${LCARS_RECIPE_DIR:-/opt/lcars/fleet/deploy/deps}"
# L'ENTRYPOINT porte les portes outil du release (`verify`, `roles-tfvars`,
# `catalogue-source`, `template-sync`). Il s'appelait `TEMPLATE_SYNC` quand il n'en servait
# qu'une : un nom qui decrit un seul usage devient faux au deuxieme.
ENTRYPOINT="${LCARS_ENTRYPOINT:-${LCARS_TEMPLATE_SYNC:-/opt/lcars/entrypoint.sh}}"

die() { echo "forge-gestures: $*" >&2; exit "${2:-1}"; }

need_forge_url() {
  [[ -n "${FORGE_BASE_URL:-}" ]] || {
    echo "forge-gestures: cette boite n'a pas de FORGE_BASE_URL — un jeton sans forge ne veut rien dire." >&2
    echo "                FORGE_BASE_URL=<url> ./docker.sh up, puis rejoue." >&2
    exit 2; }
}

# La config de curl est un format cite : la valeur est ECHAPPEE, pas esperee propre. Meme geste
# que `provision-forge-charte.sh` et `forge-existing.sh`.
curl_cfg_escape() { local v="$1"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "$v"; }

# Ecriture ATOMIQUE dans le repertoire cible (rename garanti par le noyau sur le meme systeme de
# fichiers) : un appel interrompu ne laisse jamais un demi-secret que le lecteur suivant prendrait
# pour le vrai.
put_secret() { # $1=chemin  $2=valeur
  # `chown`/`-o root` ne sont tentes QUE si on est root. Tout appelant reel l'est (`docker exec
  # -u root`), et un temoin ne l'est pas : conditionner ici evite une garde `|| true` qui
  # avalerait un vrai echec de propriete sur une boite.
  if [[ "$(id -u)" -eq 0 ]]; then
    install -d -m 0750 -o root -g fleet "$PRIVATE_DIR"
  else
    install -d -m 0750 "$PRIVATE_DIR"
  fi
  local tmp="${1%/*}/.$(basename "$1").tmp"
  umask 077
  printf '%s\n' "$2" > "$tmp"
  chmod 0600 "$tmp"
  [[ "$(id -u)" -eq 0 ]] && chown root:root "$tmp"
  mv -f "$tmp" "$1"
}

read_stdin_secret() {
  local v=""
  IFS= read -r v || true
  printf '%s' "$v"
}

cmd_config_token() {
  need_forge_url
  local tok; tok="$(read_stdin_secret)"
  [[ -n "$tok" ]] || die "jeton vide sur stdin"

  # VERIFIER AVANT D'ECRIRE. Poser un jeton qui ne s'authentifie pas produirait une boite qui croit
  # tenir son autorite et le decouvre au premier geste structurel, des mois plus tard.
  local code
  code="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
          | curl -sS -K - -o /dev/null -w '%{http_code}' -m 15 "${FORGE_BASE_URL%/}/api/v1/user" || true)"
  [[ "$code" == "200" ]] \
    || die "ce jeton ne s'authentifie pas sur $FORGE_BASE_URL (HTTP $code) — RIEN n'a ete ecrit" 3

  put_secret "$MASTER_TOKEN_FILE" "$tok"
  echo "forge-gestures: jeton master pose et VERIFIE ($MASTER_TOKEN_FILE, 0600 root)"
}

cmd_config_seed() {
  local seed; seed="$(read_stdin_secret)"
  [[ -n "$seed" ]] || die "seed vide sur stdin"
  put_secret "$SEED_FILE" "$seed"
  echo "forge-gestures: seed pose ($SEED_FILE, 0600 root)"
}

# ⚠ UN SEUL APPLY A LA FOIS. Deux `forge-apply` concurrents ecriraient le meme `terraform.tfstate`
# dans `$RECIPE_DIR`, et tofu ne se protege pas d'un backend local partage. L'etat est jetable
# depuis le lot 1, donc le degat n'est pas durable — mais un apply qui se termine sur l'etat de
# l'autre rend un verdict sur un travail qu'il n'a pas fait, et c'est ca qu'on refuse.
#
# `flock -n` : on REFUSE, on n'attend pas. Un appelant qui attendrait aurait deja recu son verdict
# quand l'autre finit, et il repartirait sur une forge qui a bouge sous lui. Meme choix que
# `provision`, qui refuse aussi (`un autre apply est en cours`).
with_apply_lock() {
  local lock="${LCARS_APPLY_LOCK:-/run/lock/lcars-forge-apply.lock}"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  exec 9>"$lock" || die "verrou d'apply inouvrable ($lock)"
  flock -n 9 || die "un autre apply de structure est en cours (verrou $lock) — rien n'a ete tente"
  "$@"
}

cmd_apply() {
  local tok seed
  # Le jeton donne a la main l'emporte sur celui que la boite garde ; le SEED, lui, n'a pas de
  # variante : il doit etre celui des comptes existants, et rien d'autre. Le provider n'ecrit pas
  # le password d'un compte existant (mesure 2026-08-16), donc un autre seed ne changerait rien
  # sur la forge et casserait le mint.
  tok="$(read_stdin_secret)"
  [[ -n "$tok" ]] || tok="$(cat "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  seed="$(cat "$SEED_FILE" 2>/dev/null || true)"

  local manque=""
  [[ -n "${FORGE_BASE_URL:-}" ]] || manque="$manque\n  l'URL de la forge   -> FORGE_BASE_URL=<url> ./docker.sh up"
  [[ -n "$tok" ]]                || manque="$manque\n  l'autorite          -> FORGE_ADMIN_TOKEN=<token master> ./docker.sh config"
  [[ -n "$seed" ]]               || manque="$manque\n  le seed des comptes -> FORGE_SEED_PASSWORD=<mot de passe> ./docker.sh config"
  if [[ -n "$manque" ]]; then
    printf 'forge-gestures: la boite ne detient pas ce qu il faut :%b\n' "$manque" >&2
    exit 1
  fi

  export TF_VAR_gitea_url="$FORGE_BASE_URL"
  export TF_VAR_gitea_token="$tok"
  export TF_VAR_seed_password="$seed"
  export TF_VAR_human_username="${LCARS_FORGE_HUMAN:-${LCARS_HUMAN:-lcars}}"
  export TF_VAR_human_email="${LCARS_HUMAN_EMAIL:-${TF_VAR_human_username}@lcars.local}"

  # L'ORDRE EST UN INVARIANT, pas une preference : `instance/` porte les comptes partages, et une
  # adhesion peut nommer un compte qu'elle ne cree pas, jamais un compte qui n'existe pas.
  local m
  for m in instance .; do
    echo "forge-gestures: apply $m"
    ( cd "$RECIPE_DIR/$m" && tofu apply -auto-approve -input=false -no-color ) \
      || die "apply $m en echec — rien n'est suppose, relis la sortie ci-dessus"
  done

  # ─── LE DEPOT MODELE, dans le meme geste ──────────────────────────────────────────────────────
  # `create_project` GENERE depuis lui ; absent, l'onboard degrade en bare-create sur chaque projet.
  # AVEC LE JETON MASTER, ce qui supprime un ordre : le poser avec le jeton SYSTEME exigerait qu'il
  # soit deja minte, donc un boot entre l'apply et ce geste.
  #
  # ⚠ NON FATAL, ET C'EST DELIBERE : la structure EST posee a ce stade. Un modele qui ne part pas
  # est une degradation NOMMEE, pas une raison de rendre un echec sur un geste qui a reussi.
  echo "forge-gestures: depot modele (project-template)"
  local tf; tf="$(umask 077; mktemp)"
  printf '%s\n' "$tok" > "$tf"
  # shellcheck disable=SC2064 -- on veut la valeur d'ICI, pas celle du moment du trap
  trap "rm -f '$tf'" EXIT
  FORGE_TOKEN_FILE="$tf" "$ENTRYPOINT" template-sync \
    || echo "forge-gestures: depot modele NON pose — l'onboard degradera en bare-create (dit a chaque projet)" >&2

  seed_demo_catalogue "$tok"
}

# ─── LA DEMO, DEPOSEE CHEZ LE MASTER ────────────────────────────────────────────────────────────
# `web-demo` est un catalogue metier COMPLET qui montre comment on en fait un et comment on
# l'installe. Il est livre dans l'image, depose sur la forge — donc immediatement `available` — et
# JAMAIS installe : c'est a l'operateur de decider, et le nom le pousse au fork plutot qu'a
# l'installation.
#
# DANS L'ESPACE DE `id = 1`, et pas ailleurs. C'est le seul espace garanti present que LCARS n'a pas
# invente : Gitea le cree a son installation, avant nous, et la recette ecrit deja « le premier admin
# est un PREREQUIS D'ENTREE, pas un produit ». Le compte humain, lui, EST cree par la recette mais
# sous le login que l'operateur choisit — on ne peut pas s'y ancrer.
#
# ⚠ REPOSE A CHAQUE APPLY, en projection (force-push). Son README le dit en toutes lettres : un
# admin qui l'edite en place perd ses modifications. C'est la bonne semantique pour une demo, et
# c'est pour ca qu'elle doit etre ECRITE plutot qu'apprise.
#
# NON FATAL : la structure est posee a ce stade. Une demo qui ne part pas est une demo absente, pas
# un deploiement casse.
DEMO_CATALOGUE="${LCARS_DEMO_CATALOGUE:-/opt/lcars/catalogues/web-demo}"

seed_demo_catalogue() { # $1=jeton master
  local tok="$1"
  [[ -d "$DEMO_CATALOGUE" ]] || return 0

  local name; name="$(basename "$DEMO_CATALOGUE")"
  local master
  master="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
            | curl -sS -K - -m 15 "${FORGE_BASE_URL%/}/api/v1/admin/users?limit=50" 2>/dev/null \
            | jq -r 'map(select(.id == 1)) | .[0].login // empty' 2>/dev/null || true)"
  if [[ -z "$master" ]]; then
    # Un refus qui ne nomme pas SON objet est un demi-message : celui qui le lit ne sait pas ce
    # qui manque a sa forge.
    echo "forge-gestures: master (id=1) non resolu — $name NON depose, il n'apparaitra pas dans « catalogue list »" >&2
    return 0
  fi

  echo "forge-gestures: catalogue de demonstration ($name -> $master/$name)"
  printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -m 20 -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"$name\",\"private\":false,\"auto_init\":false}" \
      "${FORGE_BASE_URL%/}/api/v1/user/repos" 2>/dev/null || true

  local stage; stage="$(mktemp -d)"
  cp -r "$DEMO_CATALOGUE/." "$stage/"
  rm -rf "$stage/.git"
  ( cd "$stage" \
    && git init -q -b main \
    && git add -A \
    && git -c user.name=lcars-system -c user.email=lcars-system@lcars.local \
         commit -q -m "chore(catalogue): projection de $name depuis l image" \
    && GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
       GIT_CONFIG_KEY_0="http.${FORGE_BASE_URL%/}.extraheader" \
       GIT_CONFIG_VALUE_0="Authorization: token $tok" \
       git push -q --force "${FORGE_BASE_URL%/}/${master}/${name}.git" main ) \
    || echo "forge-gestures: $name NON depose chez $master — il n'apparaitra pas dans « catalogue list »" >&2
  rm -rf "$stage"
}

# Le jeton d'ENREGISTREMENT d'un runner. Il n'entre PAS dans la recette, et c'est un choix mesure :
# le provider sait le produire (`data.gitea_actions_runner_registration_token`, scope « admin »,
# 0.8.1), mais une data source ECRIT sa valeur dans le tfstate — un credential dans un fichier
# d'etat, pour un objet qui n'est pas de la structure. C'est une LECTURE a usage unique : elle
# s'imprime et s'oublie.
cmd_runner_token() {
  need_forge_url
  local tok
  tok="$(read_stdin_secret)"
  [[ -n "$tok" ]] || tok="$(cat "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  [[ -n "$tok" ]] || die "pas d'autorite — « FORGE_ADMIN_TOKEN=<token master> ./docker.sh config »"

  local body
  body="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
          | curl -sS -K - -m 15 -X POST "${FORGE_BASE_URL%/}/api/v1/admin/actions/runners/registration-token" || true)"
  local reg
  reg="$(printf '%s' "$body" | jq -r '.token // empty' 2>/dev/null || true)"
  [[ -n "$reg" ]] || die "la forge n'a pas rendu de jeton d'enregistrement (portee du jeton master ?)"
  printf '%s\n' "$reg"
}

# ─── INSTALLER UN CATALOGUE ─────────────────────────────────────────────────────────────────────
# Un seul verbe, et il MET A JOUR quand le catalogue est deja la (⚖ user 2026-08-16). Rien n'existe
# -> il cree ; la source a bouge -> il reconverge ; rien n'a bouge -> il ne touche rien. Jamais
# declenche par le boot : une mise a jour automatique changerait le metier sous les pieds d'une
# flotte qui tourne.
#
# LE GATE ADMIN N'EST PAS UN DRAPEAU QU'ON INVENTE. Installer exige de lire le jeton master
# (0600 root) et d'ecrire l'etat de tofu : la capacite EST la permission. Un worker qui tente le
# geste est refuse par le systeme de fichiers, pas par un booleen qu'on pourrait oublier de poser.
#
# ⚠ UN DOSSIER DE RECETTE PAR CATALOGUE. La recette lit `roles.auto.tfvars.json` dans son propre
# dossier, et ce fichier porte l'org ET le roster : deux catalogues dans le meme dossier, c'est le
# dernier installe qui decide de ce que le suivant applique. L'etat etant jetable (il se reconstruit
# par import), un dossier par catalogue ne coute qu'une copie et supprime la question.
CATALOGUE_WORK="${LCARS_CATALOGUE_WORK:-/var/lib/lcars/tofu}"

cmd_install() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "install: nom de catalogue requis"
  need_forge_url

  local tok; tok="$(cat "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  [[ -n "$tok" ]] || die "install: pas d'autorite — « FORGE_ADMIN_TOKEN=<token master> ./docker.sh config »"
  local seed; seed="$(cat "$SEED_FILE" 2>/dev/null || true)"
  [[ -n "$seed" ]] || die "install: pas de seed — « FORGE_SEED_PASSWORD=<mot de passe> ./docker.sh config »"

  # 1. QUI porte ce catalogue. La porte refuse l'absent, le doublon et le catalogue livre, chacun
  #    avec son code — on ne traduit pas, on relaie.
  local src rc=0
  src="$(FORGE_BASE_URL="$FORGE_BASE_URL" FORGE_TOKEN_FILE="$MASTER_TOKEN_FILE" \
         "$ENTRYPOINT" catalogue-source "$name" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$src" >&2
    die "install: $name — pas de source installable (cf. ci-dessus)" "$rc"
  fi
  local repo branch sha
  read -r repo branch sha <<< "$src"
  echo "forge-gestures: $name <- $repo ($branch@${sha:0:8})"

  # 2. Le materiel, clone dans un jetable. Le jeton voyage par l'ENVIRON de git (extraheader),
  #    jamais dans l'URL : `/proc/<pid>/cmdline` est lisible par tout le monde, `environ` non.
  local work; work="$(mktemp -d)"
  # shellcheck disable=SC2064 -- on veut la valeur d'ICI
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
  "$ENTRYPOINT" verify "$work/src" || die "install: $name ne passe pas la verification — RIEN n'a ete pose"

  # 4. Le roster, derive du materiel du candidat — jamais tenu a la main.
  local dir="$CATALOGUE_WORK/$name"
  mkdir -p "$dir"
  cp -r "$RECIPE_DIR/." "$dir/"
  # LES AVATARS DU CATALOGUE, a cote de la recette qui va les poser. Ils vivent dans l'arbre du
  # catalogue (`<catalogue>/avatars/<role>.png`) et sont nommes par le ROLE : la recette n'a donc
  # aucune table a tenir pour un catalogue tiers, le compte se derive en `<org>_<role>`.
  # Facultatif : un catalogue qui n'en livre pas laisse ses comptes en identicon, et c'est tout.
  rm -rf "$dir/catalogue-avatars"
  [[ -d "$work/src/avatars" ]] && cp -r "$work/src/avatars" "$dir/catalogue-avatars"
  "$ENTRYPOINT" roles-tfvars "$work/src" > "$dir/roles.auto.tfvars.json" \
    || die "install: roster non derive depuis $name"

  # 5. La structure : org, comptes de role, teams, adhesions, propriete, charte. LA RECETTE, pas une
  #    reecriture — `var.org` porte le nom du catalogue depuis le premier jour.
  export TF_VAR_gitea_url="$FORGE_BASE_URL" TF_VAR_gitea_token="$tok" TF_VAR_seed_password="$seed"
  export TF_VAR_human_username="${LCARS_FORGE_HUMAN:-${LCARS_HUMAN:-lcars}}"
  export TF_VAR_human_email="${LCARS_HUMAN_EMAIL:-${TF_VAR_human_username}@lcars.local}"
  ( cd "$dir" && tofu init -input=false -no-color >/dev/null && tofu apply -auto-approve -input=false -no-color ) \
    || die "install: apply de la structure de $name en echec"

  # 6. Le STORE : la source dans l'org du catalogue. C'est LUI qui signe l'installation — une org
  #    sans sa source est un install interrompu, et aucune boite ne peut servir un catalogue dont le
  #    materiel n'est nulle part.
  push_store "$name" "$work/src" "$tok"

  # 7. LE MATERIEL LOCAL, POSE TOUT DE SUITE. Il n'est pas l'installation — celle-ci est le depot
  #    `$name/catalogue` pousse juste au-dessus — et `45-catalogues` le reposerait de toute facon au
  #    prochain boot. Mais « au prochain boot » veut dire que la commande rend la main sur une boite
  #    qui ne sert pas encore le catalogue qu'elle vient d'installer, et l'admin n'a aucun moyen de
  #    savoir qu'il doit redemarrer. On converge donc ici le meme cache, par le meme geste.
  #
  #    Un echec ici n'annule RIEN : la forge porte l'org et la source, l'installation a eu lieu. Le
  #    dire, et laisser le boot suivant rattraper, est plus honnete que de defaire ce qui est bon.
  if install_material "$name" "$work/src"; then
    echo "forge-gestures: $name installe (org, comptes, teams, sa source dans $name/catalogue, materiel pose)"
  else
    echo "forge-gestures: $name INSTALLE sur la forge, mais le materiel local n'a pas pu etre pose" >&2
    echo "  la boite ne le servira qu'apres un redemarrage (provision apply le reconverge)" >&2
  fi
}

# Le CACHE local, clone depuis le store qu'on vient de pousser — jamais copie depuis `$work/src`.
# La difference n'est pas cosmetique : `45-catalogues` compare le sha local au sha du store, et un
# repertoire copie n'a pas de `.git`, donc pas de sha. Il serait re-clone au premier boot, ce qui
# marche mais fait mentir le premier `check` (« materiel absent ») sur une boite qui vient
# d'installer. Cloner depuis la meme autorite met les deux d'accord immediatement.
install_material() { # $1=catalogue  $2=arbre (non utilise : on clone l autorite)
  local name="$1" dir="${LCARS_CATALOGUES_DIR:-/home/catalogues}/$name"
  mkdir -p "$(dirname "$dir")"
  rm -rf "$dir.tmp"
  GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 \
    "${FORGE_BASE_URL%/}/${name}/catalogue.git" "$dir.tmp" || { rm -rf "$dir.tmp"; return 1; }
  rm -rf "$dir"
  mv "$dir.tmp" "$dir"
}

# Projection, pas fusion : la copie sur la forge REFLETE le depot, un commit frais a chaque fois.
# L'historique du store n'est pas porteur — celui du depot l'est, et il reste chez son proprietaire.
push_store() { # $1=catalogue  $2=arbre  $3=jeton
  local name="$1" tree="$2" tok="$3"
  local url="${FORGE_BASE_URL%/}/${name}/catalogue.git"

  printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -m 20 -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"catalogue\",\"private\":false,\"auto_init\":false}" \
      "${FORGE_BASE_URL%/}/api/v1/orgs/${name}/repos" || true

  local stage; stage="$(mktemp -d)"
  cp -r "$tree/." "$stage/"
  rm -rf "$stage/.git"
  ( cd "$stage" \
    && git init -q -b main \
    && git add -A \
    && git -c user.name=lcars-system -c user.email=lcars-system@lcars.local \
         commit -q -m "chore(catalogue): projection de $name depuis son depot" \
    && GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
       GIT_CONFIG_KEY_0="http.${FORGE_BASE_URL%/}.extraheader" \
       GIT_CONFIG_VALUE_0="Authorization: token $tok" \
       git push -q --force "$url" main ) \
    || { rm -rf "$stage"; die "install: source NON poussee dans $name/catalogue — l'org est posee mais le catalogue n'est PAS installe"; }
  rm -rf "$stage"
}

case "${1:-}" in
  config-token) cmd_config_token ;;
  config-seed)  cmd_config_seed ;;
  apply)        with_apply_lock cmd_apply ;;
  install)      shift; with_apply_lock cmd_install "$@" ;;
  runner-token) cmd_runner_token ;;
  *) echo "forge-gestures: geste requis (config-token|config-seed|apply|install|runner-token)" >&2; exit 1 ;;
esac
