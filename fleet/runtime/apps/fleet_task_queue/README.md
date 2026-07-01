# Fleet.TaskQueue

**Date** : 2026-06-01
**Statut** : implémenté run #5 (beyond_#5 chantier 3 build 1, commit `f971d2b3`)
**Dérivé de** : DN `orchestration/task-queue` §C

Broker d'orchestration cross-pod LCARS (Ring 2). **Un seul écrivain** (GenServer),
distribution/collecte des work items, complétion **event-driven**. Remplace le stub in-mem
`Fleet.MCP.TaskQueue` (supprimé au build 2, `58cf8d89`).

Flux : `fleet_spawner`/`fleet_pipeline` **enqueue** (source) → `fleet_task_queue` distribue/collecte
(broker) → `fleet_mcp` sert aux pods via tools `get_work_item`/`submit_result` (frontière vendor) →
`fleet_coord` oriente post-résultat.

## Sous-modules

- `Fleet.TaskQueue` — façade API publique. Chaque fonction a une variante test-seam (`server` explicite, ex. `enqueue/3`) pour l'isolation via serveur anonyme (`name: nil`).
- `Fleet.TaskQueue.Server` — le broker GenServer (un seul écrivain ; persistance `state.json` atomique v:1 ; recovery cross-restart fail-loud `:"state.corrupt"` ; deadline par tâche ; **rétention bornée** des tâches terminales, knob `:retention_terminal_max` défaut 500, F148).
- `Fleet.TaskQueue.WorkItem` — struct tâche + `to_map/1` / `from_map/1` (sérialisation state.json).
- `Fleet.TaskQueue.Application` — superviseur (démarre le `Server` nommé).

## API publique (`Fleet.TaskQueue`)

- `enqueue/2` `(pod_id, attrs)` — pousse un work item (`%{brief, role, metadata}`). Source.
- `get_for_pod/1` `(pod_id)` — rend le work item actif du pod (**idempotent** : résiste à `/clear` / re-`get`).
- `submit_result/2` `(pod_id, result)` — livre (**idempotent** : double soumission ignorée). Le `result` porte le `work_item_id` du work item clôturé (corrélateur) : ≠ work item actif du pod → rejet `:work_item_id_mismatch`, aucune mutation (§A.70). C'est le 2e verrou anti-impersonation après la capability `fleet_mcp` : un pod ne peut clôturer qu'EXACTEMENT son work item actif, jamais « la dernière active » d'un autre (côté `fleet_mcp`, `submit_result` rend ce `work_item_id` **OBLIGATOIRE**). Le `work_item_id` est un corrélateur de transport → **retiré du `result` stocké/broadcasté** (pas de pollution du livrable métier). **MA-04** : le broadcast `work_item.completed` est lifecycle load-bearing → un échec de diffusion rend `{:error, {:broadcast_failed, _}}` (PAS un `:ok` muet ; le step_run ne finirait pas).
- `list_pending/0` — work items en attente.
- `clear_for_pod/1` `(pod_id)` — purge le work item d'un pod (et oublie son last-poll : le clear décommissionne le pod, donc son entrée dans la map `polls` interne ne doit pas survivre).
- `pod_status/1` `(pod_id)` — état courant côté broker.

(Variantes `*/N+1` avec `server` explicite = test-seam.)

## Invariants

- **Un work item actif par pod**, tenu À L'ÉCRITURE (MA-27) : un enqueue frais **supersède** TOUTE active du pod (`supersede_active` — le `:pending` est droppé, l'`:assigned`/`:in_progress` passe `:cleared`) ; `clear_for_pod` purge TOUTES les actives. Le wake d'un pod long-lived reçoit donc l'unique work item courant (le frais remplace l'ancien). `find_active` (tri `enqueued_at` DESC) reste la lecture mais ne masque plus de stale : par construction il y a au plus 1 active/pod.
- **Complétion event-driven** : émet `%Fleet.Event{source: :task_queue}` sur le bus `fleet.events` (topic `Fleet.PubSub`), `correlation_id = task.id`. Les 6 events couvrent enqueue/assign/complete/etc. (cf. DN §C). Plus de string-topic, plus de poll de fichier.
- **Rétention bornée** (F148) : les tâches terminales (`:completed`/`:failed`/`:cleared`) sont élaguées au-delà de `:retention_terminal_max` (défaut 500, les plus récentes conservées) → `tasks` en mémoire et `state.json` sont bornés. Les tâches **actives** ne sont jamais élaguées ; une tâche juste complétée (la plus récente) survit → la détection de double-submit (`has_completed?`) reste correcte.

## Dépendances

- `fleet_event_router` (in_umbrella) — `%Fleet.Event{}` + le bus.
- `phoenix_pubsub`, `jason`. `stream_data` (test).
