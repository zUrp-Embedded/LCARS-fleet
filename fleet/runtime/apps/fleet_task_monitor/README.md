# Fleet.TaskMonitor

**Date** : 2026-06-02 (créé — dette README, convention CLAUDE.md:82)
**Dernière révision** : 2026-06-29 (R2b — migration consommation canon `%Fleet.Event{}`, `map_event/1`)
**Statut** : implémenté mais **dormant/inerte** — `:start_monitor` (défaut `false`) n'est posé `true` nulle part (ni runtime.exs ni service), et ses events mappés n'ont aucun producteur câblé. Rôle read-model couvert par `fleet_observation`. Candidat suppression/recâblage (ménage final d'observabilité)
**Dérivé de** : DN `ring1/fleet-task-monitor`

Détourne le tool natif **`TaskList`** de Claude Code (v2.1.x) pour le pod **architect-permanent** :
un GenServer subscribe le Bus `fleet.events`, mappe les events fleet en mutations `TaskCreate`/`TaskUpdate`
(format JSON V2 Anthropic), et les écrit dans un fichier **bind-monté partagé** avec le pod architect —
qui voit ainsi l'état de la fleet dans son panneau Tasks natif. **Core write-only ; l'agent observe.**

## Sous-modules

- `Fleet.TaskMonitor` — le GenServer (subscribe Bus + mappe + écrit FS). Démarrage gaté.
- `Fleet.TaskMonitor.Application` — superviseur : démarre `Fleet.TaskMonitor` ssi
  `:fleet_task_monitor, :start_monitor` (défaut `false`). Ce flag n'est posé `true` **nulle part** — ni
  `runtime.exs` ni aucun service (le modèle systemd `User=lcars` est retiré, chaque humain lance sa fleet
  via `bin/fleet_v2`) → le GenServer ne démarre jamais en prod. Tests/CI l'instancient en direct avec opts
  isolés (suite async-safe).

## API publique

- `Fleet.TaskMonitor.start_link/1` — démarre le monitor (opts test-seam : `tasks_root`, `list_id`, `subscribe`, `name`).
- `Fleet.TaskMonitor.prefix/0` / `statuses/0` — conventions de nommage / statuts exposés.
- `Fleet.TaskMonitor.map_event/1` — pur : `%Fleet.Event{} → mutation TaskList` (testable isolément).

## Contrat Bus (canon `%Fleet.Event{}`, D1 — R2b)

Consomme la **struct canon** `%Fleet.Event{source:, type:, payload:, correlation_id:, pod_id:}` (schéma
unique D1, BL-021). Dispatch sur `type` (consommateur dashboard multi-source) ; `correlation_id` porte le
ticket, `pod_id` le pod. La forme tuple legacy `{atom, %{"event_type" => …}}` est **retirée** (I-CBC, plus
représentable côté consommateur). Les events des producteurs migrés (`Fleet.TaskQueue`, `Fleet.Spawner.Pod`,
etc.) sont donc tous vus sous la même forme. ⚠️ Consommateur **dormant** : ses events (`:dispatch_started`,
`:gatekeeper_spawned`, `:ticket_*`, …) n'ont pas encore de producteur câblé (cf. DN §Intersections).

## OTP (Iron Law)

GenServer justifié : (1) état d'abonnement PubSub cross-message, (2) sérialise les writes FS concurrents
(1 écrivain). Pas un wrapper stateless. `:one_for_one`.

## Configuration

- `:fleet_task_monitor, :start_monitor` — bool, démarre le GenServer (défaut `false`).
- `:fleet_task_monitor, :tasks_root` — racine FS du fichier TaskList partagé (défaut `/var/lib/lcars/architect-tasks`).
- `:fleet_task_monitor, :list_id` — id de liste (défaut `fleet-monitor-v1`).

## Dépendances

- `fleet_event_router` (in_umbrella) — le Bus. `:jason`.
