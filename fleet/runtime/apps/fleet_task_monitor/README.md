# Fleet.TaskMonitor

**Date** : 2026-06-02 (créé — dette README, convention CLAUDE.md:82)
**Statut** : implémenté, **config-gated** (`:start_monitor` défaut `false`)
**Dérivé de** : DN `ring1/fleet-task-monitor`

Détourne le tool natif **`TaskList`** de Claude Code (v2.1.x) pour le pod **architect-permanent** :
un GenServer subscribe le Bus `fleet.events`, mappe les events fleet en mutations `TaskCreate`/`TaskUpdate`
(format JSON V2 Anthropic), et les écrit dans un fichier **bind-monté partagé** avec le pod architect —
qui voit ainsi l'état de la fleet dans son panneau Tasks natif. **Core write-only ; l'agent observe.**

## Sous-modules

- `Fleet.TaskMonitor` — le GenServer (subscribe Bus + mappe + écrit FS). Démarrage gaté.
- `Fleet.TaskMonitor.Application` — superviseur : démarre `Fleet.TaskMonitor` ssi
  `:fleet_task_monitor, :start_monitor` (défaut `false` ; activé par `lcars-fleet.service` en prod ;
  tests/CI l'instancient en direct avec opts isolés, suite async-safe).

## API publique

- `Fleet.TaskMonitor.start_link/1` — démarre le monitor (opts test-seam : `tasks_root`, `list_id`, `subscribe`, `name`).
- `Fleet.TaskMonitor.prefix/0` / `statuses/0` — conventions de nommage / statuts exposés.
- `Fleet.TaskMonitor.map_event/2` — pur : `(event_atom, event) → mutation TaskList` (testable isolément).

## Contrat Bus (réel, pas le pseudo-code DN)

Consomme les events **tuple legacy** `{event_type_atom, %{"event_type", "payload", "ticket_id"?, "pod_id"?}}`
(format `Fleet.EventRouter.Bus` + `dispatch.ex`). ⚠️ Comme `Dispatch`, il ne voit donc PAS les events
**struct `%Fleet.Event{}`** du broker `Fleet.TaskQueue` (cf. dual-stack, audit deep-02) — il ne reflète
les tâches que via les events tuple tant que le canon n'est pas unifié (rework).

## OTP (Iron Law)

GenServer justifié : (1) état d'abonnement PubSub cross-message, (2) sérialise les writes FS concurrents
(1 écrivain). Pas un wrapper stateless. `:one_for_one`.

## Configuration

- `:fleet_task_monitor, :start_monitor` — bool, démarre le GenServer (défaut `false`).
- `:fleet_task_monitor, :tasks_root` — racine FS du fichier TaskList partagé (défaut `/var/lib/lcars/architect-tasks`).
- `:fleet_task_monitor, :list_id` — id de liste (défaut `fleet-monitor-v1`).

## Dépendances

- `fleet_event_router` (in_umbrella) — le Bus. `:jason`.
