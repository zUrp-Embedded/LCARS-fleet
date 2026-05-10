# Fleet.IpcFilter

**Date** : 2026-05-09
**Dernière révision** : 2026-05-09
**Statut** : implémenté run #3.1 chantier #9 — design note PROMOTED
**Référencé par** : work/beyond_#3.1/design-notes/promoted/fleet_ipc_filter.md

Filtre REFUSE_PATTERNS pre-tool-call LCARS v2 (Ring 3 gates sécurité).
Refactor canon `ipc-reception-filter §3` v1 → Elixir natif v2 +
extension F-CONT-RISK observable. Couche sécurité irréductible —
refus par défaut canon LCARS v1 §0 #1.

## API

- `Fleet.IpcFilter.init_patterns!/0` — boot init (lit catalogue JSON,
  valide schema, compile regex, peuple ETS)
- `Fleet.IpcFilter.filter_tool_call/2` — `:allow | {:deny, reason}`
- `Fleet.IpcFilter.drift_for/1` — lecture compteur drift par pod_id
- `Fleet.IpcFilter.reset_drift/0` — reset (helper test)

## Architecture

- Pure functions stateless + ETS read-only cache `:fleet_ipc_filter_patterns`
- Drift counter ETS `:fleet_ipc_filter_drift` (atomic via `:ets.update_counter`)
- Schema JSON strict `/etc/fleet/refuse-patterns-v1.json` validé
  `ex_json_schema` au boot (fail-fast)
- Regex Erlang `:re.compile/2` PCRE2 stdlib
- Log audit append-only NDJSON `/var/log/fleet-audit.jsonl`
- `EventBackend` behaviour swappable (default `NotWiredYet`, câblage
  chantier 11 `fleet_event_router`)

## Patterns initiaux v2 (priv/refuse-patterns-v1.json)

**v1.5 git-related (11 patterns)** : force-push, push-no-verify,
force-with-lease, reset-hard-main, rebase-main, branch-D-main, rm-git,
rm-git-hooks, update-ref, history-rewrite-filter-branch,
history-rewrite-filter-repo.

**v2 F-CONT-RISK observable (6 patterns)** : web-search-attempted,
web-fetch-attempted, code-execution-attempted,
bash-code-execution-attempted, text-editor-code-execution-attempted,
tool-search-attempted. Server tools natifs Anthropic bypass
`can_use_tool` callback — bloqués au boot par `fleet_capprofile.G24-9`,
log si tentative observable (défense en profondeur).

## Configuration

- `:fleet_ipc_filter, :refuse_patterns_path` — path catalogue JSON
  (default `/etc/fleet/refuse-patterns-v1.json`)
- `:fleet_ipc_filter, :audit_log_path` — path log NDJSON (default
  `/var/log/fleet-audit.jsonl`)
- `:fleet_ipc_filter, :event_backend` — module `EventBackend` (default
  `EventBackend.NotWiredYet`, câblage chantier 11)
- `:fleet_ipc_filter, :drift_threshold` — seuil escalade `:pod_drift`
  (default 3)
- `:fleet_ipc_filter, :auto_init` — boot init automatique (default
  `false` — caller appelle `init_patterns!/0` explicitement)

## Liste extensible jamais réductible

Canon `ipc-reception-filter §3` : ajout = PR avec justification
écrite, retrait = ADR explicite + amendement design note.

## Cohérence cross-design-notes

- `fleet_capprofile` (chantier 1, PROMOTED) G24-9 gate boot pod
  bloque `disallowed_tools` minimum F-CONT-RISK — complémentaire.
- `fleet_permission_router` (chantier 10) invoque step 1 du flow
  `can_use_tool` decisions.
- `fleet_event_router` (chantier 11) PubSub bus `Fleet.PubSub` topic
  `fleet.events` reçoit `:refuse_pattern_match` + `:pod_drift`.
- `fleet_starfleet` (chantier 13) subscribe `:pod_drift` → escalade
  Cat 5 si drift ≥3.
