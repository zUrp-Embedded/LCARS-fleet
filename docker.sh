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
#   runner-token     imprime un jeton d'enregistrement pour TON runner CI (usage unique)
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

# ⚠ CE SCRIPT FAISAIT 494 LIGNES ET DOUZE VERBES. C'est la première chose que lit quelqu'un qui
# découvre le dépôt, et un script d'entrée qui ne se lit pas en trente secondes ne DIT pas ce qu'il
# va faire — il le fait. Les douze verbes vivent maintenant dans `fleet/deploy/box`, jumeau de
# `fleet/deploy/provision` : la racine détecte où on est, refuse en nommant ce qui manque, et
# délègue avec l'argv VERBATIM. Aucun verbe n'a changé de nom.
#
# CE QUI RESTE ICI, ET RIEN D'AUTRE :
#   1. l'aide — elle marche SANS docker, c'est le seul geste qui n'a aucune condition ;
#   2. le préflight NOMMÉ — chaque manque avec le geste exact qui le comble ;
#   3. l'exec du délégué.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOX="$SCRIPT_DIR/fleet/deploy/box"

# L'aide se DELIMITE par son contenu, pas par des numeros de ligne : la forme `sed -n '6,35p'`
# tronque en silence des qu'on insere une ligne dans l'en-tete, et une aide amputee ne se signale
# jamais. Ancrage sur la premiere et la derniere ligne du bloc.
usage() {
  sed -n '/^# LCARS fleet v2 en conteneur/,/^# EXIT :/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ─── L'AIDE N'A AUCUNE CONDITION ─────────────────────────────────────────────────────────────────
# Elle passe AVANT le préflight, délibérément : quelqu'un qui n'a pas encore docker doit pouvoir
# lire ce que ce dépôt propose. Un `--help` qui exige l'outil qu'il documente est une porte fermée.
case "${1:-help}" in
  help|-h|--help) usage; exit 0 ;;
esac

# ─── LE PRÉFLIGHT, NOMMÉ ─────────────────────────────────────────────────────────────────────────
# ⚠ ON SONDE UN ENDPOINT QUI RÉPOND, PAS UN BINAIRE, et la nuance a coûté une mesure pour être vue.
# `command -v docker` se trompe DANS LES DEUX SENS : sa présence ne prouve pas que le daemon tourne
# (Docker Desktop éteint après un reboot Windows), et son ABSENCE ne prouve pas qu'il manque — sur
# WSL la CLI et les sockets vivent dans le montage `/mnt/wsl/docker-desktop`, présent pour toute
# distro même sans intégration activée. Mesuré le 2026-08-19 : aucun binaire dans le PATH, et le
# daemon répond. La sonde est partagée avec le rail de provisionnement, un seul exemplaire.
# shellcheck source=fleet/deploy/lib/docker-endpoint.sh
. "$SCRIPT_DIR/fleet/deploy/lib/docker-endpoint.sh"

fail() { printf 'docker.sh: %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '   %s\n' "$2" >&2; exit 1; }

docker_endpoint || fail "$PROV_DOCKER_WHY" \
  "Rien n'a été construit, rien n'a été démarré. « ./docker.sh help » marche sans docker."

# `docker compose` (plugin) ou `docker-compose` (standalone) : les deux existent dans la nature, et
# une install récente n'a que le premier. On NOMME celui qu'on a trouvé au délégué plutôt que de
# le laisser re-chercher — deux détections pour un fait donneraient deux réponses possibles.
if "$PROV_DOCKER_BIN" compose version >/dev/null 2>&1; then
  export LCARS_COMPOSE_CMD="$PROV_DOCKER_BIN compose"
elif command -v docker-compose >/dev/null 2>&1; then
  export LCARS_COMPOSE_CMD="docker-compose"
else
  fail "docker répond, mais compose est absent (ni le plugin « docker compose », ni « docker-compose »)" \
       "Sur Docker Desktop il est inclus ; sur linux : apt install docker-compose-plugin"
fi

# Le délégué fait partie du checkout. S'il manque, ce n'est pas une panne d'environnement — c'est
# un arbre incomplet, et le dire évite une enquête sur docker qui n'y est pour rien.
[[ -x "$BOX" ]] || fail "délégué introuvable : $BOX" \
  "Checkout incomplet ou tronqué — « git status » dans $SCRIPT_DIR"

# ─── DÉLÉGUER, ARGV VERBATIM ─────────────────────────────────────────────────────────────────────
# `exec` et pas un appel : le délégué HÉRITE du terminal, du code de sortie et des signaux. Un
# wrapper qui relaie à la main finit toujours par perdre l'un des trois — le plus souvent le code
# de sortie, celui qui compte.
exec "$BOX" "$@"
