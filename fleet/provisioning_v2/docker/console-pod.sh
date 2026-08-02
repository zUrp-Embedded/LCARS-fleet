#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/docker/console-pod.sh
# AUTHOR: consultant
# STARDATE: 2026-08-02
# STATUS: PROTO-V2 — la console D'UN pod, cible d'un ttyd `--url-arg` (UN port pour tous les pods)
#
# ttyd passe l'argument d'URL (`?arg=<pod_id>`) en argv. Ce script est la GARDE entre le monde
# et `lcars attach` : sans lui, un client choisit les arguments d'une commande locale.
#
# TROIS REFUS, ET ILS SE LISENT A L'ECRAN (l'humain est devant un terminal, pas devant un log) :
#   1. forme du pod_id (`[a-z0-9][a-z0-9-]*`) — rien d'autre ne peut ressembler a une option ;
#   2. UN seul argument — un second serait un argument passe a `lcars`, pas un pod ;
#   3. existence du socket tmux du pod — attacher un pod inconnu rend un message tmux illisible.
#
# UN PORT POUR N PODS : le bloc d'un humain n'a que 10 ports (base+0 API, +1 deck, +3 webhook,
# +4 console, +5 ici) — un ttyd par pod l'epuiserait a la sixieme mission. `--url-arg` est la
# seule forme qui tienne dans le bloc.

set -uo pipefail

POD_ID="${1:-}"
SOCK_BASE="${LCARS_TMUX_SOCK_BASE:-$HOME/.lcars/run/tmux-sock}"

die() { printf '\n  %s\n\n  (fermer cet onglet)\n' "$*"; sleep 5; exit 1; }

[[ $# -eq 1 ]] || die "console-pod: un seul argument attendu (le pod_id), recu $#."
[[ "$POD_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "console-pod: pod_id invalide."
[[ -S "$SOCK_BASE/$POD_ID/pod.sock" ]] || die "console-pod: pas de socket pour « $POD_ID » — pod inconnu ou deja mort."

exec lcars attach "$POD_ID"
