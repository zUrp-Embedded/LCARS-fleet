#!/usr/bin/env bash
# SOURCE: fleet/services/console-pod.sh
# AUTHOR: consultant
# STARDATE: 2026-08-02
# STATUS: PROTO-V2 — la console D'UN pod, cible d'un ttyd `--url-arg` (UN serveur pour tous les pods)
#
# ttyd passe l'argument d'URL (`?arg=<pod_id>`) en argv. Ce script est la GARDE entre le monde
# et `lcars attach` : sans lui, un client choisit les arguments d'une commande locale.
#
# ⚠ POURQUOI `--url-arg` ET PAS UN TTYD PAR POD : UN SEUL serveur sert tous les pods, et c'est
# l'argument d'URL qui les discrimine. Un ttyd par pod voudrait dire un processus, une socket et
# une unite de plus a chaque mission.

set -uo pipefail          # PAS -e : `die()` fait `exec sleep infinity` pour que l'humain LISE le
                          # message dans son onglet ttyd. Une sortie non nulle fermerait l'onglet
                          # et escamoterait la cause du refus.

POD_ID="${1:-}"
SOCK_BASE="${LCARS_TMUX_SOCK_BASE:-$HOME/.lcars/run/tmux-sock}"

die() { printf '\n  %s\n\n  (fermer cet onglet)\n' "$*"; exec sleep infinity; }

[[ $# -eq 1 ]] || die "console-pod: un seul argument attendu (le pod_id), recu $#."
[[ "$POD_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "console-pod: pod_id invalide."
[[ -S "$SOCK_BASE/$POD_ID/pod.sock" ]] || die "console-pod: pas de socket pour « $POD_ID » — pod inconnu ou deja mort."

exec lcars attach "$POD_ID"
