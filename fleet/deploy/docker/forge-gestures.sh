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
#   runner-token   minte un jeton d'ENREGISTREMENT de runner et l'imprime. Sortie unique, sur
#                  stdout : c'est un credential a usage unique, il ne se pose nulle part.
#
# EXIT : 0 · 1 donnee manquante ou geste en echec · 2 la boite n'a pas de FORGE_BASE_URL
#        3 le jeton ne s'authentifie pas

set -euo pipefail

# Les chemins sont SURCHARGEABLES, comme ceux de `provision-lib.sh`, et pour la meme raison : un
# temoin doit pouvoir exercer ce script sans etre root ni ecrire dans /home/private. Les defauts
# sont les chemins reels ; aucun appelant de production ne les passe.
PRIVATE_DIR="${LCARS_PRIVATE_DIR:-/home/private}"
MASTER_TOKEN_FILE="${LCARS_MASTER_TOKEN_FILE:-$PRIVATE_DIR/forge-master.token}"
SEED_FILE="${LCARS_FORGE_SEED_FILE:-$PRIVATE_DIR/forge-seed.pass}"
RECIPE_DIR="${LCARS_RECIPE_DIR:-/opt/lcars/fleet/deploy/deps}"
TEMPLATE_SYNC="${LCARS_TEMPLATE_SYNC:-/opt/lcars/entrypoint.sh}"

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
  FORGE_TOKEN_FILE="$tf" "$TEMPLATE_SYNC" template-sync \
    || echo "forge-gestures: depot modele NON pose — l'onboard degradera en bare-create (dit a chaque projet)" >&2
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

case "${1:-}" in
  config-token) cmd_config_token ;;
  config-seed)  cmd_config_seed ;;
  apply)        cmd_apply ;;
  runner-token) cmd_runner_token ;;
  *) echo "forge-gestures: geste requis (config-token|config-seed|apply|runner-token)" >&2; exit 1 ;;
esac
