# Fleet.TaskQueue

**Date** : 2026-06-01
**Statut** : implémenté run #5 (beyond_#5 chantier 3 build 1, commit `f971d2b3`)
**Dérivé de** : DN `orchestration/task-queue` §C

Broker d'orchestration cross-pod LCARS (Ring 2). **Un seul écrivain** (GenServer),
distribution/collecte des mandats, complétion **event-driven**. Remplace le stub in-mem
`Fleet.MCP.TaskQueue` (supprimé au build 2, `58cf8d89`).

Flux : `fleet_spawner`/`fleet_pipeline` **enqueue** (source) → `fleet_task_queue` distribue/collecte
(broker) → `fleet_mcp` sert aux pods via tools `get_task`/`submit_result` (frontière vendor) →
`fleet_coord` oriente post-résultat.

## Sous-modules

- `Fleet.TaskQueue` — façade API publique. Chaque fonction a une variante test-seam (`server` explicite, ex. `enqueue/3`) pour l'isolation via serveur anonyme (`name: nil`).
- `Fleet.TaskQueue.Server` — le broker GenServer (un seul écrivain ; persistance `state.json` atomique v:1 ; recovery cross-restart fail-loud `:state_corrupt` ; deadline par tâche ; **rétention bornée** des tâches terminales, knob `:retention_terminal_max` défaut 500, F148).
- `Fleet.TaskQueue.Task` — struct tâche + `to_map/1` / `from_map/1` (sérialisation state.json).
- `Fleet.TaskQueue.Application` — superviseur (démarre le `Server` nommé).

## API publique (`Fleet.TaskQueue`)

- `enqueue/2` `(pod_id, attrs)` — pousse un mandat (`%{brief, role, metadata}`). Source.
- `get_for_pod/1` `(pod_id)` — rend le mandat actif du pod (**idempotent** : résiste à `/clear` / re-`get`).
- `submit_result/2` `(pod_id, result)` — livre (**idempotent** : double soumission ignorée ; rejette un `task_id` ≠ mandat actif, §A.70).
- `list_pending/0` — mandats en attente.
- `clear_for_pod/1` `(pod_id)` — purge le mandat d'un pod.
- `pod_status/1` `(pod_id)` — état courant côté broker.

(Variantes `*/N+1` avec `server` explicite = test-seam.)

## Invariants

- **Un mandat actif par pod**, tenu À L'ÉCRITURE (MA-27) : un enqueue frais **supersède** TOUTE active du pod (`supersede_active` — le `:pending` est droppé, l'`:assigned`/`:in_progress` passe `:cleared`) ; `clear_for_pod` purge TOUTES les actives. Le wake d'un pod long-lived reçoit donc l'unique mandat courant (le frais remplace l'ancien). `find_active` (tri `enqueued_at` DESC) reste la lecture mais ne masque plus de stale : par construction il y a au plus 1 active/pod.
- **Complétion event-driven** : émet `%Fleet.Event{source: :task_queue}` sur le bus `fleet.events` (topic `Fleet.PubSub`), `correlation_id = task.id`. Les 6 events couvrent enqueue/assign/complete/etc. (cf. DN §C). Plus de string-topic, plus de poll de fichier.
- **Rétention bornée** (F148) : les tâches terminales (`:completed`/`:failed`/`:cleared`) sont élaguées au-delà de `:retention_terminal_max` (défaut 500, les plus récentes conservées) → `tasks` en mémoire et `state.json` sont bornés. Les tâches **actives** ne sont jamais élaguées ; une tâche juste complétée (la plus récente) survit → la détection de double-submit (`has_completed?`) reste correcte.

## Dépendances

- `fleet_event_router` (in_umbrella) — `%Fleet.Event{}` + le bus.
- `phoenix_pubsub`, `jason`. `stream_data` (test).
