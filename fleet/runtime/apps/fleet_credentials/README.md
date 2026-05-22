# Fleet.Credentials

**Date** : 2026-05-09
**Dernière révision** : 2026-05-22
**Statut** : implémenté run #3.1 chantier #3 — design note PROMOTED
**Référencé par** : 04_design-notes/fleet_credentials.md

Coffre creds + injection ENV vars OAuth au boot pod LCARS v2 (Ring 2).

## API

- `Fleet.Credentials.resolve_env/2` — résout les env vars OAuth pour un
  rôle depuis le coffre `/var/lib/lcars/credentials/<role>/` ; consomme
  `cap_profile.spec["injects"][...]` flags.
- `Fleet.Credentials.ScopeValidator.validate/2` — gate scope-coverage,
  profils `default` / `bridge_enabled` / `mcp_oauth`.
- `Fleet.Credentials.PlanValidator.validate_plan/1` — validation plan
  Pro/Max via SDK backend swappable (F-AC-VALIDATE).
- `Fleet.Credentials.OAuthRefresher` — GenServer scheduler refresh
  PoC-23, lead time 30min, atomic write coffre, recovery `init/1`.
- `Fleet.Credentials.Bootstrap.Extractor.extract/1` — extraction
  post-`claude /login` user-side, valide schema PoC-23 6 champs.

## Voie auth canonique LCARS v2

- `CLAUDE_CODE_OAUTH_REFRESH_TOKEN` (universellement)
- `CLAUDE_CODE_OAUTH_SCOPES` (universellement)

JAMAIS `ANTHROPIC_API_KEY`, JAMAIS `--bare`, JAMAIS `claude setup-token`
(5 incompatibilités ERRATUM #380/#381). G24 invariants.

## Coffre layout

`/var/lib/lcars/credentials/<role>/{oauth_refresh_token,
oauth_access_token, oauth_scopes, expires_at}` — root:lcars 640 ro,
mount RO bwrap.

## Configuration

- `:fleet_credentials, :creds_root` — racine FS du coffre (default
  `/var/lib/lcars/credentials`).
- `:fleet_credentials, :plan_validator_backend` — module backend
  `PlanValidator.Backend` (default placeholder `:not_wired_yet`).
- `:fleet_credentials, :oauth_refresh_backend` — module backend
  `OAuthRefresher.Backend` (default placeholder `:not_wired_yet`).
- `:fleet_credentials, :auto_start_refreshers` — bool (default
  `false`) — si `true`, le supervisor scanne `creds_root/` et démarre
  un refresher par sous-répertoire.
- `:fleet_credentials, :refresh_retry_backoff_ms` — délai backoff sur
  erreur transitoire (default `5_000`).

## Procédure bootstrap

`bin/setup-credentials.sh <role> [<home>]` — invoque l'extracteur
Elixir post-`claude /login` user-side. Refuse l'install si scopes
insuffisants → re-login user requis.
