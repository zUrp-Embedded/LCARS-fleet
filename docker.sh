#!/usr/bin/env bash
# SOURCE: docker.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — entrée Docker user-facing : wrapper mince sur compose (le compose est un détail d'implémentation)
#
# LCARS fleet v2 en conteneur. Modèle : l'image embarque le runtime déployé (release RO) + sshd
# comme login-manager ; l'humain SSH dans le conteneur EN TANT QUE LUI puis `fleet_v2 start`.
# Le fichier compose vit dans fleet/deploy/docker/ — l'humain ne le touche pas.
#
# USAGE : ./docker.sh [-p <projet>] <commande>
#   build            construit l'image (labels OCI : sha git + date stampés ici)
#   up               démarre le conteneur fleet (détaché). La forge est à TOI : LCARS ne la
#                    fabrique pas, il la consomme (FORGE_BASE_URL + un token master)
#   doctor           sonde l'état DANS le conteneur (le même doctor que le chemin WSL)
#   shell            shell dans le conteneur, en tant qu'un WORKER (LCARS_HUMAN, defaut lcars)
#   logs             logs du conteneur (suivi)
#   down             arrête et retire lcars (les volumes restent)
#   reset            détruit lcars : conteneur + image + volume /home. La forge n'est PAS
#                    dans ce projet : aucune commande d'ici ne peut l'atteindre
#   source-push [DIR] copie TON clone LCARS dans la boîte (/home/projects/LCARS) — la jambe
#                     source du triangle, sans laquelle la fleet ne peut pas se maintenir
#   config           pose DURABLEMENT dans la boîte le token master de ta forge et le seed des
#                    comptes. Une fois. Ils y restent — un geste structurel (un catalogue de plus)
#                    en a besoin au jour 400 comme au premier
#   forge-check      le contrat que TA forge doit tenir + les gestes pour l'y amener
#   forge-apply      pose la structure sur TA forge (OpenTofu tourne DANS la boîte — rien à
#                    installer chez toi). Rejouable : un second passage importe ce qui existe
#   help             cette aide
#
# -p <projet> (ou LCARS_PROJECT) : QUEL déploiement on vise. Défaut « lcars ». Un poste de dev en
#   porte plusieurs à la fois (un banc de validation, une boîte de travail, un rail) et le nom du
#   projet est la SEULE chose qui les distingue. Les commandes qui créent ou détruisent refusent
#   d'agir sur un projet que ce compose n'a pas créé — cf. la garde plus bas, elle mesure.
#
# ENV (tous optionnels) :
#   LCARS_PROJECT              projet compose visé (défaut lcars) — équivalent de -p
#   LCARS_HUMAN                login WORKER cible par shell/doctor/hint (defaut lcars) — PAS le
#                              sysadmin de la boite (celui-la est `admiral`, cf. LCARS_ADMIRAL, entrypoint)
#   LCARS_UID                  uid de l'humain (défaut 1000)
#   LCARS_SSH_AUTHORIZED_KEYS  clés publiques SSH (contenu authorized_keys)
#   LCARS_SSH_PORT             bind du port SSH (défaut 127.0.0.1:2222)
#   LCARS_CONSOLE_PORT         bind de la console web (défaut 127.0.0.1:21004)
#   LCARS_HOSTNAME             hostname du conteneur (défaut bridge)
#   FORGE_BASE_URL             URL de TA forge (ex http://host.docker.internal:3300) — vide =
#                              modules forge en instruct-only, le doctor le dit
#   FORGE_ADMIN_TOKEN          token master site-admin — lu par `config` (qui le POSE) et par
#                              `forge-apply` (qui l'utilise sans le poser). Transmis par stdin :
#                              jamais argv, jamais l'env du client docker
#   FORGE_SEED_PASSWORD        mot de passe posé sur les comptes À LEUR CRÉATION — `config` seul
#   LCARS_HUMAN_EMAIL          email du compte forge de l'humain (défaut <human>@lcars.local)
#
# EXIT : 0 succès · 1 erreur/commande inconnue

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/fleet/deploy/docker/docker-compose.yml"
PROJECT="${LCARS_PROJECT:-lcars}"

# L'aide se DELIMITE par son contenu, pas par des numeros de ligne : la forme `sed -n '6,35p'`
# tronque en silence des qu'on insere une ligne dans l'en-tete, et une aide amputee ne se signale
# jamais. Ancrage sur la premiere et la derniere ligne du bloc.
usage() {
  sed -n '/^# LCARS fleet v2 en conteneur/,/^# EXIT :/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ─── Le projet visé est un ARGUMENT (cf. assert_project_ours) ─────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)
      [[ -n "${2:-}" ]] || { echo "docker.sh: -p attend un nom de projet" >&2; exit 1; }
      PROJECT="$2"; shift 2 ;;
    *) break ;;
  esac
done

# ─── Préflight (sauté pour help : l'aide doit marcher SANS docker) ────────────────────────────────
case "${1:-help}" in
  help|-h|--help) usage; exit 0 ;;
esac
command -v docker >/dev/null || { echo "docker.sh: docker introuvable — installe Docker d'abord" >&2; exit 1; }
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null; then
  COMPOSE=(docker-compose)
else
  echo "docker.sh: docker compose introuvable (plugin ou standalone)" >&2; exit 1
fi
[[ -f "$COMPOSE_FILE" ]] || { echo "docker.sh: compose introuvable: $COMPOSE_FILE (checkout incomplet ?)" >&2; exit 1; }

compose() { "${COMPOSE[@]}" -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

# ─── LE PROJET VISÉ EXISTE-T-IL, ET EST-CE LE NÔTRE ? ─────────────────────────────────────────────
# Un nom de projet compose N'EST PAS une adresse sûre. Compose applique volontiers un fichier à un
# projet qu'il n'a pas créé : il calcule l'état désiré depuis CE fichier et recrée, republie les
# ports, supprime ce qui n'y figure pas — sans une seule erreur, parce que de son point de vue rien
# n'est anormal. Le nom suffit à le désigner, il ne suffit pas à prouver qu'on parle du même objet.
#
# Mesuré ici le 2026-08-07 : ce script visait « lcars » en dur, et sur ce poste « lcars » était une
# boîte de travail vivante depuis 47 h, créée depuis `fleet/provisioning_v2/docker/…` — un chemin
# SUPPRIMÉ par le déménagement du 2026-08-04. `down` l'arrêtait, `reset` emportait son volume /home.
#
# La preuve est dans le conteneur, pas dans une convention : compose y stampe le label
# `com.docker.compose.project.config_files`, la liste des fichiers qui l'ont réellement créé. On la
# lit. Un projet SANS conteneur ne se garde pas — il n'y a rien à confondre, et `up` a le droit de
# le créer.
project_config_files() {
  local ids
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null)" || return 0
  [[ -n "$ids" ]] || return 0
  # shellcheck disable=SC2086 -- liste d'ids séparés par des blancs, à éclater
  docker inspect $ids \
    --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null | sort -u
}

assert_project_ours() {
  local files line
  files="$(project_config_files)"
  [[ -n "$files" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # Le label est une liste séparée par des virgules : on encadre pour ne matcher qu'un élément
    # entier (sans quoi `…/docker-compose.yml` matcherait un `…/docker-compose.yml.bak`).
    case ",$line," in *",$COMPOSE_FILE,"*) return 0 ;; esac
  done <<< "$files"
  {
    echo "docker.sh: REFUS — le projet compose « $PROJECT » existe, et ce n'est pas celui de ce fichier."
    echo "  il a été créé depuis : ${files//$'\n'/ ; }"
    echo "  ce script appliquerait : $COMPOSE_FILE"
    echo ""
    echo "  Appliquer un compose à un projet qu'il n'a pas créé recrée et republie SANS erreur."
    echo "  Vise le bon projet    : ./docker.sh -p <projet> $*"
    echo "  Ou agis sur celui-ci avec SA recette (un banc se descend par dev/bench-down.sh)."
    echo "  Projets visibles      : docker compose ls"
  } >&2
  exit 1
}

# La vérité de révision : stampée au build dans les labels OCI (le worktree/clone HÔTE a git ;
# le contexte, lui, n'embarque pas .git — cf. Dockerfile).
build_env() {
  LCARS_GIT_SHA="$(git -C "$SCRIPT_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
  LCARS_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  export LCARS_GIT_SHA LCARS_BUILD_DATE
}

cmd_build() { build_env; compose build "$@"; }

cmd_up() {
  assert_project_ours up
  build_env
  # --no-build : up ne builde JAMAIS implicitement — le run de validation a montré un `up`
  # qui masquait un build --no-cache raté en repartant du cache de layers. Un build, c'est
  # « ./docker.sh build », et son verdict est le sien ; image absente → up échoue en le disant.
  compose up -d --no-build "$@"
  echo ""
  echo "LCARS fleet up (projet $PROJECT). Accès :"
  echo "  ssh ${LCARS_HUMAN:-lcars}@127.0.0.1 -p ${LCARS_SSH_PORT##*:}    # puis : fleet_v2 start"
  echo "  ./docker.sh doctor                                   # état provisionné ?"
}

cmd_doctor() {
  # -T (B8) : pas d'allocation TTY — le doctor doit tourner depuis un script/CI/cron, pas
  # seulement depuis un terminal interactif.
  compose exec -T lcars /opt/lcars/fleet/deploy/provision doctor --substrate docker \
    --human "${LCARS_HUMAN:-lcars}" "$@"
}

cmd_shell() { compose exec -it -u "${LCARS_HUMAN:-lcars}" lcars bash; }

# ─── CE QUE L'OPÉRATEUR FOURNIT, ET QUI RESTE ───────────────────────────────────────────────────
# ⚖ ARBITRAGE (user, 2026-08-16) : « on pose le token, IL RESTE ». Le motif est structurel et pas
# une commodité — l'autorité de création n'est PAS un besoin de bootstrap. La structure d'une forge
# change pendant toute la vie du système : enrôler un catalogue crée un compte par rôle. Au jour 400,
# `lcars catalogue enable` a exactement le même besoin qu'au premier jour, et un credential qu'il
# faudrait re-fournir rendrait chacun de ces gestes manuel — ce que ce chantier existe pour tuer.
#
# CE QUE ÇA POSE, ÉCRIT POUR QUE CE SOIT SU ET NON DÉCOUVERT : la boîte détient durablement un
# credential qui peut tout créer et tout détruire sur la forge. C'est le prix de gestes structurels
# autonomes, et il est assumé. La contrepartie est tenue par la recette : le boot nominal n'en a PAS
# besoin — l'apply converge en lisant la forge — donc l'usage de ce pouvoir reste borné aux gestes
# qui changent la structure.
#
# L'URL N'EST PAS DOUBLÉE ICI. Elle arrive déjà par `FORGE_BASE_URL` (compose → env de la boîte →
# PROV_FORGE_URL) : la réécrire dans un fichier ferait deux vérités pour un fait, et c'est toujours
# la mauvaise qu'on lit. Cette commande la LIT dans la boîte et refuse d'écrire si elle manque.
#
# LE NOM DU FICHIER NE FINIT PAS PAR `.gitea_token`, ET C'EST VOULU : ce suffixe est celui des
# jetons de RÔLE (`<login>.gitea_token`, contrat FORGE_ROLE_TOKENS_DIR). Aucun lecteur ne globbe ce
# répertoire aujourd'hui — le premier qui le fera ne doit pas ramasser un site-admin.
FORGE_MASTER_TOKEN_FILE=/home/private/forge-master.token
FORGE_SEED_FILE=/home/private/forge-seed.pass

# Le secret voyage par STDIN, de bout en bout : ni argv du client docker, ni argv dans la boîte.
# `bash -c "$remote"` avec un script LITTÉRAL (heredoc cité) — aucune interpolation, donc rien
# d'injectable, et le quoting reste lisible.
config_put_token() {
  local remote
  remote=$(cat <<'REMOTE'
set -eu
IFS= read -r tok || true
[[ -n "$tok" ]] || { echo "config: jeton vide sur stdin" >&2; exit 1; }
[[ -n "${FORGE_BASE_URL:-}" ]] || {
  echo "config: cette boite n'a pas de FORGE_BASE_URL — un jeton sans forge ne veut rien dire." >&2
  echo "        FORGE_BASE_URL=<url> ./docker.sh up   puis rejoue ce config." >&2
  exit 2; }
# VERIFIER AVANT D'ECRIRE. Poser un jeton qui ne s'authentifie pas produirait une boite qui croit
# tenir son autorite et decouvre le contraire au premier geste structurel, des mois plus tard.
esc() { local v="$1"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "$v"; }
code="$(printf 'header = "Authorization: token %s"\n' "$(esc "$tok")" \
        | curl -sS -K - -o /dev/null -w '%{http_code}' -m 15 "${FORGE_BASE_URL%/}/api/v1/user" || true)"
[[ "$code" == "200" ]] || {
  echo "config: ce jeton ne s'authentifie pas sur $FORGE_BASE_URL (HTTP $code) — RIEN n'a ete ecrit." >&2
  exit 3; }
install -d -m 0750 -o root -g fleet /home/private
umask 077
printf '%s\n' "$tok" > /home/private/.forge-master.token.tmp
chmod 0600 /home/private/.forge-master.token.tmp
chown root:root /home/private/.forge-master.token.tmp
mv -f /home/private/.forge-master.token.tmp /home/private/forge-master.token
echo "config: jeton master pose et VERIFIE (/home/private/forge-master.token, 0600 root)"
REMOTE
)
  printf '%s' "$1" | compose exec -T -u root lcars bash -c "$remote"
}

# Le seed n'a pas de verification possible : c'est un mot de passe, pas un credential qu'on peut
# presenter. Ce qui compte est qu'il soit posé UNE FOIS et ne bouge plus — tofu ne REMPLACE pas le
# password d'un compte existant (mesure du 2026-08-16 sur le provider 0.8), donc un seed regenere
# a chaque passe donnerait un fichier qui ne correspond plus aux comptes, et le mint des jetons de
# role partirait en 401. Ce fichier EST le handoff tofu -> A4.
config_put_seed() {
  local remote
  remote=$(cat <<'REMOTE'
set -eu
IFS= read -r seed || true
[[ -n "$seed" ]] || { echo "config: seed vide sur stdin" >&2; exit 1; }
install -d -m 0750 -o root -g fleet /home/private
umask 077
printf '%s' "$seed" > /home/private/.forge-seed.pass.tmp
chmod 0600 /home/private/.forge-seed.pass.tmp
chown root:root /home/private/.forge-seed.pass.tmp
mv -f /home/private/.forge-seed.pass.tmp /home/private/forge-seed.pass
echo "config: seed pose (/home/private/forge-seed.pass, 0600 root)"
REMOTE
)
  printf '%s' "$1" | compose exec -T -u root lcars bash -c "$remote"
}

cmd_config() {
  local token="${FORGE_ADMIN_TOKEN:-}" seed="${FORGE_SEED_PASSWORD:-}"
  if [[ -z "$token" && -z "$seed" ]]; then
    { echo "docker.sh config: pose DURABLEMENT dans la boîte ce que LCARS ne peut pas deviner."
      echo ""
      echo "  FORGE_ADMIN_TOKEN=<token master site-admin>   l'autorité qui CRÉE sur ta forge."
      echo "     Dans Gitea : Settings → Applications → Generate New Token, scope « all »."
      echo "     Il RESTE : enrôler un catalogue crée des comptes, au jour 400 comme au premier."
      echo "  FORGE_SEED_PASSWORD=<mot de passe>            posé sur les comptes À LEUR CRÉATION."
      echo "     Il RESTE aussi : c'est lui que la boîte relit pour minter les tokens de rôle, et"
      echo "     tofu ne le remplace PAS sur un compte existant. Le changer ne changerait rien"
      echo "     sur la forge — et casserait le mint."
      echo ""
      echo "  FORGE_ADMIN_TOKEN=… FORGE_SEED_PASSWORD=… ./docker.sh config"
      echo "  (l'un des deux suffit : ce qui n'est pas donné n'est pas touché)"
      echo "  Puis :  ./docker.sh forge-apply    # sans plus rien fournir"
    } >&2
    exit 1
  fi
  [[ -n "$token" ]] && { config_put_token "$token" || exit 1; }
  [[ -n "$seed" ]]  && { config_put_seed  "$seed"  || exit 1; }
  echo ""
  echo "docker.sh config: posé. La boîte tient son autorité — « ./docker.sh forge-apply » n'a plus"
  echo "                  besoin d'aucune variable."
}

# ─── L'APPLY DE LA STRUCTURE, DANS LA BOÎTE ─────────────────────────────────────────────────────
# CE QUE CETTE COMMANDE FERME. `forge-check` imprimait `cd fleet/deploy/deps && tofu init && …`,
# une commande que l'opérateur ne pouvait PAS exécuter : tofu n'était installé nulle part — ni chez
# lui, ni dans l'image, ni par un module de provision, ni par install.sh. Il vit désormais dans
# l'image avec ses providers vendorés, donc l'apply se joue ICI, et rien ne s'installe sur la
# machine de l'opérateur.
#
# EN ROOT, et ce n'est pas un confort : `/opt/lcars/fleet/deploy/deps` est root:root, donc l'humain
# de la boîte ne peut pas y écrire le tfstate. Cet état est jetable (la recette importe ce que la
# forge porte déjà), il n'a donc rien à faire ailleurs — il meurt avec le conteneur, comme il doit.
#
# LE JETON N'EST NI DANS argv NI DANS L'ENVIRONNEMENT DE `docker` : il passe par STDIN. `-e
# TF_VAR_gitea_token=…` l'aurait mis dans la ligne de commande du client docker, lisible dans
# `/proc` de tout l'hôte pendant l'appel — la leçon payée deux fois par 6-141 et 6-141bis, sur des
# credentials moins puissants que celui-ci.
#
# ⚠ CE DÉCLENCHEMENT À LA MAIN EST PROVISOIRE. La cible est que le boot le joue seul ; ce qui
# manque pour ça n'est pas tofu (il est là) mais l'endroit où le jeton vit durablement.
#
# IL NE PREND PLUS RIEN EN ENTRÉE, et c'est tout l'intérêt : la boîte DÉTIENT son autorité et son
# seed (`./docker.sh config`), et l'URL vient de son environnement. Un `FORGE_ADMIN_TOKEN` ou un
# `FORGE_SEED_PASSWORD` dans l'environnement l'emporte quand même — c'est le chemin d'un opérateur
# qui veut jouer un apply avec une autre autorité sans toucher à ce que la boîte garde.
cmd_forge_apply() {
  local human="${LCARS_HUMAN:-lcars}" email="${LCARS_HUMAN_EMAIL:-}"
  # Le script distant est un LITTÉRAL : `$m` n'y est pas interpolé, il arrive par l'environnement.
  # Une interpolation shell dans un script qu'on envoie est une porte qu'on n'a aucune raison
  # d'ouvrir, et elle se referme mal.
  local remote
  remote=$(cat <<'REMOTE'
set -eu
stdin_tok=""
IFS= read -r stdin_tok || true
# Le jeton donne a la main l'emporte sur celui que la boite garde ; le seed, LUI, n'a pas de
# variante : il doit etre celui des comptes existants, et rien d'autre.
TF_VAR_gitea_token="$stdin_tok"
[[ -n "$TF_VAR_gitea_token" ]] || TF_VAR_gitea_token="$(cat /home/private/forge-master.token 2>/dev/null || true)"
TF_VAR_seed_password="$(cat /home/private/forge-seed.pass 2>/dev/null || true)"
TF_VAR_gitea_url="${FORGE_BASE_URL:-}"
manque=""
[[ -n "$TF_VAR_gitea_url" ]]     || manque="$manque\n  l'URL de la forge   -> FORGE_BASE_URL=<url> ./docker.sh up"
[[ -n "$TF_VAR_gitea_token" ]]   || manque="$manque\n  l'autorite          -> FORGE_ADMIN_TOKEN=<token master> ./docker.sh config"
[[ -n "$TF_VAR_seed_password" ]] || manque="$manque\n  le seed des comptes -> FORGE_SEED_PASSWORD=<mot de passe> ./docker.sh config"
if [[ -n "$manque" ]]; then
  printf 'forge-apply: la boite ne detient pas ce qu il faut :%b\n' "$manque" >&2
  exit 1
fi
export TF_VAR_gitea_token TF_VAR_seed_password TF_VAR_gitea_url
cd "/opt/lcars/fleet/deploy/$LCARS_TOFU_MODULE"
exec tofu apply -auto-approve -input=false -no-color
REMOTE
)
  # L'ORDRE EST UN INVARIANT, pas une préférence : `instance/` porte les comptes partagés, et une
  # adhésion peut nommer un compte qu'elle ne crée pas, jamais un compte qui n'existe pas.
  local m
  for m in deps/instance deps; do
    echo "docker.sh forge-apply: $m"
    printf '%s' "${FORGE_ADMIN_TOKEN:-}" | compose exec -T -u root \
      -e LCARS_TOFU_MODULE="$m" \
      -e TF_VAR_human_username="$human" \
      -e TF_VAR_human_email="${email:-$human@lcars.local}" \
      lcars bash -c "$remote" \
      || { echo "docker.sh forge-apply: échec sur $m — rien n'est supposé, relis la sortie ci-dessus" >&2; exit 1; }
  done
  echo ""
  echo "docker.sh forge-apply: structure posée. Rejouable — un second passage IMPORTE ce qui existe."
  echo "  ./docker.sh doctor    # ce que la boîte voit de sa forge maintenant"
}
cmd_logs()  { compose logs -f "$@"; }
cmd_down() {
  assert_project_ours down
  # LCARS seul, et il n'y a plus rien d'autre à descendre : la forge est à l'opérateur, dans
  # son propre déploiement. Aucune commande d'ici ne peut l'atteindre — c'est la frontière.
  compose down "$@"
}

cmd_reset() {
  # Destructif pour LCARS, et LCARS SEULEMENT. La forge — les repos, les issues, les PR, la
  # seule copie durable du travail — n'est pas dans ce projet compose et ne peut donc PAS être
  # emportée par un reset. La frontière est structurelle (projet compose séparé) : un drapeau de
  # sécurité dans un projet commun ne l'est pas, il se contourne d'une commande.
  assert_project_ours reset
  # Le projet est NOMMÉ dans la question. Un poste de dev en porte plusieurs, et « conteneur lcars »
  # ne dit pas LEQUEL : on ne fait pas confirmer une destruction sans dire ce qu'elle vise.
  echo "docker.sh: RESET du projet « $PROJECT » — conteneur + image + volume ${PROJECT}_lcars-home."
  echo "           La forge n'est pas concernée (elle est à toi, dans son propre déploiement)."
  echo "           Ton travail poussé y survit."
  read -r -p "Confirmer (yes/N) ? " a < /dev/tty || a=""
  [[ "$a" == "yes" ]] || { echo "docker.sh: annulé."; exit 1; }
  compose down --rmi local
  docker volume rm -f "${PROJECT}_lcars-home" >/dev/null 2>&1 || true
  echo "docker.sh: reset fait. « ./docker.sh up » pour repartir de zéro."
}

cmd_source_push() {
  # LA jambe source du triangle, posée dans la boîte : sans checkout, `provision update` n'a rien
  # à puller et aucun agent ne peut travailler sur LCARS lui-même (auto-maintenance). Le projet
  # BOUGE : on ne fige rien dans l'image, on copie LE clone que l'humain maintient — le sien,
  # celui-là même qui a bâti l'image. Copie (pas bind) parce que le daemon ne voit pas forcément
  # notre FS ; `docker cp` traverse toutes les topologies.
  local src="${1:-$SCRIPT_DIR}" ctr
  src="$(cd "$src" && pwd)"
  [[ -d "$src/.git" ]] || { echo "docker.sh: $src n'est pas un clone git (pas de .git)" >&2; exit 1; }
  ctr="$(compose ps -q lcars)"
  [[ -n "$ctr" ]] || { echo "docker.sh: conteneur lcars absent — « ./docker.sh up » d'abord" >&2; exit 1; }
  local human="${LCARS_HUMAN:-lcars}"

  echo "docker.sh: copie de $src → /home/projects/LCARS (historique git compris, ça prend un moment)…"
  compose exec -T lcars rm -rf /home/projects/.LCARS.incoming
  docker cp "$src/." "$ctr:/home/projects/.LCARS.incoming" || { echo "docker.sh: copie échouée" >&2; exit 1; }
  # Bascule ATOMIQUE (rename), après la copie : la fleet ne voit jamais un arbre à moitié copié.
  # `mv -T` obligatoire : `mv src dst` NICHE dans dst quand dst est un dossier existant, et
  # l'arbre se retrouve imbriqué. Et pas de `[ -e x ] && mv … || true` : la forme AVALE l'échec
  # du mv (un ancien LCARS monté rend EBUSY) et la copie se rapporte verte sans avoir basculé.
  compose exec -T lcars bash -c "
    set -euo pipefail
    chown -R '$human':fleet /home/projects/.LCARS.incoming
    rm -rf /home/projects/.LCARS.old
    if [ -e /home/projects/LCARS ]; then
      if ! mv -T /home/projects/LCARS /home/projects/.LCARS.old; then
        echo 'source-push: /home/projects/LCARS ne peut pas etre deplace (point de montage ?) — rien ecrase' >&2
        exit 1
      fi
    fi
    mv -T /home/projects/.LCARS.incoming /home/projects/LCARS
    rm -rf /home/projects/.LCARS.old
    git config --system --replace-all safe.directory /home/projects/LCARS
    test -d /home/projects/LCARS/.git
    git -C /home/projects/LCARS rev-parse --short HEAD"
  echo "docker.sh: source posée. « ./docker.sh doctor » la sonde ; la fleet peut se maintenir."
}

cmd_forge_check() {
  local port="${LCARS_FORGE_PORT##*:}"
  cat <<EOF
docker.sh: LE CONTRAT DE LA FORGE — ce que LCARS attend d'ELLE, et rien de plus.

LCARS ne fabrique PAS ta forge : tu la déploies comme tu veux (app TrueNAS, Docker Desktop,
machine dédiée), tu la sauvegardes, tu la mets à jour. Elle porte les repos, les issues et les
PR — la seule copie durable du travail. LCARS, lui, est jetable : on le nuke et on le redéploie.
Un jetable ne doit pas pouvoir détruire ce qui ne l'est pas, donc il ne la gère pas.

CE QU'IL LUI FAUT, EXACTEMENT DEUX CHOSES :

  1. SON URL           → FORGE_BASE_URL=http://<hôte-ou-service>:<port> ./docker.sh up
     Depuis le conteneur, ta machine hôte se joint par « host.docker.internal ».

  2. UN TOKEN MASTER (site-admin) ET UN SEED. Dans Gitea : Settings → Applications →
     Generate New Token, scope « all ». Le seed est le mot de passe que les comptes de rôle
     recevront à leur création. Tu les poses UNE FOIS, ils restent dans la boîte :

         FORGE_ADMIN_TOKEN=<token-master> FORGE_SEED_PASSWORD=<seed> ./docker.sh config

     Puis, sans plus rien fournir — RIEN N'EST INSTALLÉ SUR TA MACHINE, OpenTofu, ses
     providers et la recette sont DANS l'image. L'apply est REJOUABLE : il importe ce que
     ta forge porte déjà au lieu de mourir en « user already exists ».

         ./docker.sh forge-apply

     POURQUOI LE TOKEN RESTE : la structure d'une forge change pendant toute la vie du
     système — enrôler un catalogue crée un compte par rôle. Au jour 400, ce geste a le même
     besoin qu'au premier jour. Un credential à re-fournir rendrait chacun d'eux manuel.
     Le prix, dit et non découvert : la boîte détient de quoi tout créer et tout détruire
     sur ta forge. Le boot nominal, lui, n'en a pas besoin — l'apply converge en lisant.

     POURQUOI LE SEED RESTE : c'est lui que la boîte relit pour minter les tokens de rôle,
     et tofu ne le REMPLACE PAS sur un compte existant (mesuré). En changer casserait le
     mint sans rien changer sur la forge.

     Rotation réelle d'un password de rôle — le seul chemin qui marche :
         curl -X PATCH -H "Authorization: token <token-master>" -H 'Content-Type: application/json' \\
           -d '{"login_name":"<compte>","source_id":0,"password":"<seed>","must_change_password":false}' \\
           <url>/api/v1/admin/users/<compte>

CE QUE LCARS VÉRIFIE (il ne répare pas ce qui ne lui appartient pas) :
      ./docker.sh doctor      → forge joignable ? org présente ? comptes de rôle ? tokens
                                valides ? l'humain est-il membre de l'org ? Chaque manque est
                                dit avec le geste exact pour le combler.

BESOIN D'UNE FORGE JETABLE POUR DÉVELOPPER ?
      docker compose -f fleet/deploy/docker/dev/forge-compose.yml -p lcars-devforge up -d
      → projet SÉPARÉ, volumes à lui, détruit uniquement par TA commande explicite.
      Puis : FORGE_BASE_URL=http://host.docker.internal:${port:-3300} ./docker.sh up
EOF
}

# ⚠ UNE SECONDE DEFINITION DE `usage()` VIVAIT ICI, ET C'ETAIT ELLE QUI SERVAIT — la derniere
# definition gagne en bash. Elle decoupait l'aide par NUMEROS DE LIGNE (`sed -n '6,35p'`), la forme
# que le commentaire de la premiere declare cassee : elle tronque en silence des qu'on insere une
# ligne dans l'en-tete, et une aide amputee ne se signale jamais. L'ancrage sur le texte, plus haut,
# est le seul survivant.

# Défauts visibles dans les messages (accès SSH, consigne bootstrap).
: "${LCARS_SSH_PORT:=127.0.0.1:2222}"
: "${LCARS_FORGE_PORT:=127.0.0.1:3300}"

case "${1:-help}" in
  build)  shift; cmd_build "$@" ;;
  up)     shift; cmd_up "$@" ;;
  doctor) shift; cmd_doctor "$@" ;;
  shell)  cmd_shell ;;
  logs)   shift; cmd_logs "$@" ;;
  down)   shift; cmd_down "$@" ;;
  reset)  shift; cmd_reset "$@" ;;
  source-push) shift; cmd_source_push "$@" ;;
  config)      cmd_config ;;
  forge-check) cmd_forge_check ;;
  forge-apply) cmd_forge_apply ;;
  help|-h|--help) usage ;;
  *) echo "docker.sh: commande inconnue: $1 (./docker.sh help)" >&2; exit 1 ;;
esac
