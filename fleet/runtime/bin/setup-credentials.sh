#!/usr/bin/env bash
# SOURCE: bin/setup-credentials.sh
# AUTHOR: engineer
# STARDATE: 2026-05-09
# STATUS: chantier #3 run #3.1 — bootstrap RT initial coffre LCARS v2
#
# bin/setup-credentials.sh — bootstrap RT initial coffre LCARS v2
#
# Procédure ops :
#   1. user exécute `claude /login` interactif (PTY user-side, F-MIX-PTY-PATTERN)
#   2. ce script appelle Fleet.Credentials.Bootstrap.Extractor.extract/1
#      qui lit ~/.claude/.credentials.json, valide schema PoC-23,
#      vérifie scope-coverage, écrit /var/lib/lcars/credentials/<role>/
#
# Voie auth canonique : CLAUDE_CODE_OAUTH_REFRESH_TOKEN +
# CLAUDE_CODE_OAUTH_SCOPES universellement. JAMAIS --bare, JAMAIS
# ANTHROPIC_API_KEY, JAMAIS claude setup-token (5 incompatibilités
# ERRATUM #380/#381).
#
# Usage : setup-credentials.sh <role> [<home>]
#
# Exit codes :
#   0 = coffre écrit OK
#   1 = arguments manquants ou invalides
#   2 = ~/.claude/.credentials.json absent (l'user doit lancer claude /login)
#   3 = scopes insuffisants ou plan invalide
#   4 = erreur infra (mix run, write coffre, ...)

set -euo pipefail

ROLE="${1:-}"
HOME_DIR="${2:-$HOME}"

if [[ -z "$ROLE" ]]; then
  echo "usage: $0 <role> [<home>]" >&2
  exit 1
fi

CREDS_FILE="$HOME_DIR/.claude/.credentials.json"

if [[ ! -r "$CREDS_FILE" ]]; then
  echo "ERREUR : $CREDS_FILE absent ou illisible." >&2
  echo "" >&2
  echo "Lance d'abord : claude /login" >&2
  echo "(plan Pro ou Max requis, scopes complets — full-scope OAuth)" >&2
  exit 2
fi

# On suppose que ce script est exécuté depuis le runtime root
# (fleet/runtime/) où mix.exs umbrella est défini.
RUNTIME_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RUNTIME_ROOT"

# Délégation extraction au module Elixir
mix run --no-start -e "
  case Fleet.Credentials.Bootstrap.Extractor.extract(role: \"$ROLE\", home: \"$HOME_DIR\") do
    {:ok, role} ->
      IO.puts(\"OK coffre écrit : #{Fleet.Credentials.coffre_path(role, \"\")}\")
      :ok
    {:error, {:insufficient_scopes, missing}} ->
      IO.puts(:stderr, \"ERREUR scopes insuffisants. Manquants : #{inspect(missing)}\")
      IO.puts(:stderr, \"Re-login avec un compte qui dispose des scopes complets.\")
      System.halt(3)
    {:error, {:schema_invalid, missing}} ->
      IO.puts(:stderr, \"ERREUR schema OAuth invalide. Champs manquants : #{inspect(missing)}\")
      System.halt(3)
    {:error, reason} ->
      IO.puts(:stderr, \"ERREUR : #{inspect(reason)}\")
      System.halt(4)
  end
"
