#!/usr/bin/env bash
# SOURCE: docker.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — entrée Docker user-facing : wrapper mince sur compose (le compose est un détail d'implémentation)
#
# LCARS fleet v2 en conteneur. Modèle : l'image embarque le runtime déployé (release RO) + sshd
# comme login-manager ; l'humain SSH dans le conteneur EN TANT QUE LUI puis `fleet_v2 start`.
# Le fichier compose vit dans fleet/provisioning_v2/docker/ — l'humain ne le touche pas.
#
# USAGE : ./docker.sh <commande>
#   build            construit l'image (labels OCI : sha git + date stampés ici)
#   up               démarre le conteneur fleet (détaché) — `--forge` ajoute forge Gitea + runner CI
#   doctor           sonde l'état DANS le conteneur (le même doctor que le chemin WSL)
#   shell            shell dans le conteneur, en tant que l'humain (LCARS_HUMAN)
#   logs             logs du conteneur (suivi)
#   down             arrête et retire lcars SEUL (`down --forge` inclut forge+runner ; volumes gardés)
#   reset            détruit lcars : conteneur + image + volume /home — la forge et ses REPOS
#                    restent intacts (`reset --forge` détruit AUSSI forge+runner et leurs volumes)
#   source-push [DIR] copie TON clone LCARS dans la boîte (/home/projects/LCARS) — la jambe
#                     source du triangle, sans laquelle la fleet ne peut pas se maintenir
#   forge-bootstrap  affiche les 3 gestes d'identité d'une forge vierge (admin, tofu, runner)
#   help             cette aide
#
# ENV (tous optionnels) :
#   LCARS_HUMAN                login de l'humain dans le conteneur (défaut lcars)
#   LCARS_UID                  uid de l'humain (défaut 1000)
#   LCARS_SSH_AUTHORIZED_KEYS  clés publiques SSH (contenu authorized_keys)
#   LCARS_SSH_PORT             bind du port SSH (défaut 127.0.0.1:2222)
#   LCARS_FORGE_PORT           bind du port forge (défaut 127.0.0.1:3300)
#   LCARS_RUNNER_TOKEN         token d'enregistrement du runner CI (cf. forge-bootstrap)
#   FORGE_BASE_URL             forge cible (défaut http://forge:3000 avec --forge)
#
# EXIT : 0 succès · 1 erreur/commande inconnue

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/fleet/provisioning_v2/docker/docker-compose.yml"
PROJECT=lcars

# ─── Préflight (sauté pour help : l'aide doit marcher SANS docker) ────────────────────────────────
case "${1:-help}" in
  help|-h|--help) sed -n '6,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# La vérité de révision : stampée au build dans les labels OCI (le worktree/clone HÔTE a git ;
# le contexte, lui, n'embarque pas .git — cf. Dockerfile).
build_env() {
  LCARS_GIT_SHA="$(git -C "$SCRIPT_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
  LCARS_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  export LCARS_GIT_SHA LCARS_BUILD_DATE
}

cmd_build() { build_env; compose build "$@"; }

cmd_up() {
  local profiles=()
  if [[ "${1:-}" == "--forge" ]]; then profiles=(--profile forge); shift; fi
  build_env
  # --no-build : up ne builde JAMAIS implicitement — le run de validation a montré un `up`
  # qui masquait un build --no-cache raté en repartant du cache de layers. Un build, c'est
  # « ./docker.sh build », et son verdict est le sien ; image absente → up échoue en le disant.
  compose "${profiles[@]}" up -d --no-build "$@"
  echo ""
  echo "LCARS fleet up. Accès :"
  echo "  ssh ${LCARS_HUMAN:-lcars}@127.0.0.1 -p ${LCARS_SSH_PORT##*:}    # puis : fleet_v2 start"
  echo "  ./docker.sh doctor                                   # état provisionné ?"
}

cmd_doctor() {
  # -T (B8) : pas d'allocation TTY — le doctor doit tourner depuis un script/CI/cron, pas
  # seulement depuis un terminal interactif.
  compose exec -T lcars /opt/lcars/fleet/provisioning_v2/provision doctor --substrate docker \
    --human "${LCARS_HUMAN:-lcars}" "$@"
}

cmd_shell() { compose exec -it -u "${LCARS_HUMAN:-lcars}" lcars bash; }
cmd_logs()  { compose logs -f "$@"; }
cmd_down() {
  # Par défaut : lcars SEUL. La forge (et son runner) a un cycle de vie INDÉPENDANT — on ne
  # descend pas la forge parce qu'on redémarre la fleet.
  local profiles=()
  if [[ "${1:-}" == "--forge" ]]; then profiles=(--profile forge); shift; fi
  compose "${profiles[@]}" down "$@"
}

cmd_reset() {
  # Destructif pour LCARS seulement : les volumes forge (les REPOS) et runner ne sont JAMAIS
  # dans le rayon d'un reset par défaut — « reset --forge » l'assume explicitement.
  local with_forge=0
  [[ "${1:-}" == "--forge" ]] && { with_forge=1; shift; }
  if [[ "$with_forge" -eq 1 ]]; then
    echo "docker.sh: RESET --forge — TOUT : lcars + forge + runner, images + VOLUMES (les REPOS de la forge seront DÉTRUITS)."
  else
    echo "docker.sh: RESET — conteneur lcars + image + volume /home (la forge et ses repos restent intacts)."
  fi
  read -r -p "Confirmer (yes/N) ? " a < /dev/tty || a=""
  [[ "$a" == "yes" ]] || { echo "docker.sh: annulé."; exit 1; }
  if [[ "$with_forge" -eq 1 ]]; then
    compose --profile forge down --rmi local -v
  else
    compose down --rmi local
    docker volume rm -f "${PROJECT}_lcars-home" >/dev/null 2>&1 || true
  fi
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
  # Deux pièges payés en vrai ici : `mv src dst` NICHE dans dst quand dst est un dossier existant
  # (d'où `mv -T`), et `[ -e x ] && mv … || true` AVALE l'échec du mv (un ancien LCARS qui est un
  # point de montage rend EBUSY) — la copie se rapportait alors verte en ayant imbriqué l'arbre.
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

cmd_forge_bootstrap() {
  local port="${LCARS_FORGE_PORT##*:}"
  cat <<EOF
docker.sh: bootstrap d'une forge VIERGE — 3 gestes d'IDENTITÉ (le provisioning les sonde et
les instruit, il ne les exécute jamais — même famille que « claude /login ») :

  1. L'admin de bootstrap (l'œuf-et-la-poule : l'API exige un token, un token exige un compte) :
       docker exec -it lcars-forge-1 gitea admin user create \\
         --username lcars-bootstrap --password '<choisis-le>' \\
         --email bootstrap@lcars.local --admin
     puis son token (éphémère — à révoquer une fois 2 et 3 faits) :
       curl -su 'lcars-bootstrap:<pwd>' -X POST -H 'Content-Type: application/json' \\
         -d '{"name":"bootstrap","scopes":["all"]}' \\
         http://127.0.0.1:${port}/api/v1/users/lcars-bootstrap/tokens

  2. La STRUCTURE (comptes, org fleet, teams, hardening) — OpenTofu, rejouable à l'infini :
       cd fleet/provisioning/deps && tofu init && \\
       TF_VAR_gitea_url=http://127.0.0.1:${port} TF_VAR_gitea_token='<token-du-1>' \\
       TF_VAR_seed_password='<seed>' TF_VAR_human_username='<ton-login-DANS-la-boite>' \\
       TF_VAR_human_email='<ton-email>' tofu apply
     (⚠ human_username = le login DE L'HUMAIN DU CONTENEUR — LCARS_HUMAN, défaut « lcars » :
      c'est LUI que le runtime vérifie à l'onboarding, pas ton login hôte)
     puis pose le SEED dans le conteneur lcars — c'est le handoff vers la jambe tokens, qui
     converge ensuite TOUTE SEULE à chaque apply/boot (plus aucun geste) :
       printf '%s' '<le-même-seed>' > /tmp/.forge-seed
       docker cp /tmp/.forge-seed lcars-lcars-1:/home/private/forge-seed.pass
       docker exec lcars-lcars-1 chmod 600 /home/private/forge-seed.pass
       rm /tmp/.forge-seed

  3. Le RUNNER CI :
       docker exec lcars-forge-1 gitea actions generate-runner-token
       LCARS_RUNNER_TOKEN='<token-du-3>' ./docker.sh up --forge
     (une fois enregistré, son identité vit dans le volume runner-data — plus jamais de token)

  Sonde à tout moment : ./docker.sh doctor — la forge convergée = 50-forge sans drift.
EOF
}

usage() { sed -n '6,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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
  forge-bootstrap) cmd_forge_bootstrap ;;
  help|-h|--help) usage ;;
  *) echo "docker.sh: commande inconnue: $1 (./docker.sh help)" >&2; exit 1 ;;
esac
