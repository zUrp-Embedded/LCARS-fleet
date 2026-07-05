# Fleet.TaskQueue

**Date** : 2026-06-01
**Dernière révision** : 2026-07-05 (resync D2 contre le code : ring 1, broker éphémère en prod, API complète — `pod_active_issue_id`/`last_poll`, flux réel, section Configuration ; éclatement Server → Store + Broadcast)
**Statut** : implémenté run #5 (beyond_#5 chantier 3 build 1, commit `f971d2b3`)
**Dérivé de** : DN `orchestration/task-queue` §C

Broker d'orchestration cross-pod LCARS (Ring 1). **Un seul écrivain** (GenServer),
distribution/collecte des work items, complétion **event-driven**. Remplace le stub in-mem
`Fleet.MCP.TaskQueue` (supprimé au build 2, `58cf8d89`).

**AXIOME source-unique** : la forge est la vérité du travail (issues/routes/PR) ; le broker n'en
est que le FRONT en RAM. En prod il tourne **ÉPHÉMÈRE** (`persist: false`, posé par
`Fleet.TaskQueue.Application`) : aucun `state.json` écrit, pas de tâches stale persistées
cross-reboot — au restart la queue se re-dérive des polls forge. La persistance Store reste un
mécanisme **opt-in** (testé) pour un futur état broker-only-durable, inexistant à ce jour.

Flux : `fleet_spawner` (`Pod.Brief`) et `fleet_pilot` (StepDispatcher / escalade gatekeeper, seam
`:task_queue`) **enqueuent** (sources) → `fleet_task_queue` distribue/collecte (broker) →
`fleet_mcp` sert aux pods via tools `get_work_item`/`submit_result` (frontière vendor) →
`fleet_pilot` (`StepRunConsumer`) consomme `work_item.completed` post-résultat.

## Sous-modules

- `Fleet.TaskQueue` — façade API publique. Chaque fonction a une variante test-seam (`server` explicite, ex. `enqueue/3`) pour l'isolation via serveur anonyme (`name: nil`).
- `Fleet.TaskQueue.Server` — le broker GenServer (un seul écrivain ; command/query ; deadline par tâche ; **rétention bornée** des tâches terminales, knob `:retention_terminal_max` défaut 500, F148). Options par-instance : `:name` (nil = anonyme, tests), `:state_path`, `:persist`, `:topic`, `:bus` (seam), `:retention_terminal_max`. Garde l'ORCHESTRATION de la persistance et du broadcast (quand persister, quel régime de diffusion) ; la mécanique vit dans les deux modules ci-dessous. Deadline-watchdog et rétention/prune restent DANS le Server (refus argumentés au moduledoc : paire timer couplée au process, prune 20 LOC partageant l'autorité `@active_states`).
- `Fleet.TaskQueue.Store` — persistance `state.json` (sérialisation + FS, sans state GenServer) : écriture atomique tmp+rename v:1 best-effort loggée error, lecture fail-loud `{:corrupt, _}` (jamais de drop silencieux), `default_path/0` (config `:state_path`, défaut `~/.lcars/task-queue/state.json` — HOME irrésoluble = fail-loud). Inerte en prod tant que le broker boote `persist: false`.
- `Fleet.TaskQueue.Broadcast` — policy de broadcast (sans state GenServer) : `best_effort/3` (observabilité, échec avalé + loggé) vs `required/3` (lifecycle `work_item.completed`, échec propagé `{:error, {:broadcast_failed, _}}`) + enveloppe canon `event/3`. Hors `Bus.safe_emit` (les seams par-instance `:bus`/`:topic` doivent porter les deux chemins ; même exclusion que `Fleet.Spawner.Pod.Events`).
- `Fleet.TaskQueue.WorkItem` — struct tâche + `to_map/1` / `from_map/1` (sérialisation state.json).
- `Fleet.TaskQueue.Application` — superviseur (démarre le `Server` nommé **en `persist: false`** — le mode prod éphémère, cf. AXIOME ci-dessus ; `:one_for_one`, 3/60).

## API publique (`Fleet.TaskQueue`)

- `enqueue/2` `(pod_id, attrs)` — pousse un work item (`%{brief, role, issue_id, deadline, metadata}`). Source. Génère `id` (UUID v4 = correlation_id).
- `get_for_pod/1` `(pod_id)` — rend le work item actif du pod (**idempotent** : résiste à `/clear` / re-`get`).
- `submit_result/2` `(pod_id, result)` — livre (**idempotent** : double soumission ignorée). Le `result` porte le `work_item_id` du work item clôturé (corrélateur) : ≠ work item actif du pod → rejet `:work_item_id_mismatch`, aucune mutation (§A.70). C'est le 2e verrou anti-impersonation après l'identité-par-canal côté `fleet_mcp` (socket AF_UNIX per-pod — l'ancienne capability du transport HTTP partagé est RETIRÉE avec lui) : un pod ne peut clôturer qu'EXACTEMENT son work item actif, jamais « la dernière active » d'un autre (côté `fleet_mcp`, `submit_result` rend ce `work_item_id` **OBLIGATOIRE**). Le `work_item_id` est un corrélateur de transport → **retiré du `result` stocké/broadcasté** (pas de pollution du livrable métier). **MA-04** : le broadcast `work_item.completed` est lifecycle load-bearing → un échec de diffusion rend `{:error, {:broadcast_failed, _}}` (PAS un `:ok` muet ; le step_run ne finirait pas).
- `list_pending/0` — work items en attente.
- `clear_for_pod/1` `(pod_id)` — purge le work item d'un pod (et oublie son last-poll : le clear décommissionne le pod, donc son entrée dans la map `polls` interne ne doit pas survivre).
- `pod_status/1` `(pod_id)` — état courant côté broker.
- `pod_active_issue_id/1` `(pod_id)` — issue de la DERNIÈRE tâche du pod (couvre `:completed` = fenêtre de publication submit → push). Sert au poller (slot-freeze) : un engineer PIPE project-scoped (`<repo>-engineer`, sans `-issue-N-`) ne porte pas sa brique dans son pod_id — le verrou se dérive de sa tâche. Query.
- `last_poll/1` `(pod_id)` — dernier `get_for_pod` du pod (`DateTime | nil`) = **ACK in-band** (l'agent est up + armé, même sans work item). In-mem, jamais persisté ; purgé par `clear_for_pod`. Consommé par la boucle wake ack-driven (`Fleet.Spawner.Pod.TaskProbe` teste la seule PRÉSENCE). Query.

(Variantes `*/N+1` avec `server` explicite = test-seam.)

## Invariants

- **Un work item actif par pod**, tenu À L'ÉCRITURE (MA-27) : un enqueue frais **supersède** TOUTE active du pod (`supersede_active` — toute active, `:pending` compris, passe `:cleared` ; le `submit_result` du vieux work item tombe alors sur `:no_active_work_item`/`:double_submit_ignored`, jamais une mutation du nouveau) ; `clear_for_pod` purge TOUTES les actives. Le wake d'un pod long-lived reçoit donc l'unique work item courant (le frais remplace l'ancien). `find_active` (tri `enqueued_at` DESC) reste la lecture mais ne masque plus de stale : par construction il y a au plus 1 active/pod.
- **Complétion event-driven** : émet `%Fleet.Event{source: :task_queue}` sur le topic `fleet.events` du PubSub `Fleet.PubSub`, `correlation_id = work_item.id`. Les 6 events : `work_item.enqueued`/`assigned`/`completed`/`cleared`/`failed` (deadline) + `state.corrupt` — `completed` seul est load-bearing (`Broadcast.required`), le reste best-effort. Plus de string-topic, plus de poll de fichier.
- **Rétention bornée** (F148) : les tâches terminales (`:completed`/`:failed`/`:cleared`) sont élaguées au-delà de `:retention_terminal_max` (défaut 500, les plus récentes conservées) → `tasks` en mémoire et `state.json` sont bornés. Les tâches **actives** ne sont jamais élaguées ; une tâche juste complétée (la plus récente) survit → la détection de double-submit (`has_completed?`) reste correcte.

## Configuration (`:fleet_task_queue`)

- `:retention_terminal_max` — borne des tâches terminales conservées (défaut 500 ; surchargeable aussi par-instance via l'opt de `Server.start_link/1`).
- `:state_path` — chemin de `state.json` (défaut `~/.lcars/task-queue/state.json` ; env `LCARS_STATE_PATH` dans `config/runtime.exs`). Sans effet en prod tant que le broker boote `persist: false`.

## Dépendances

- `fleet_event_router` (in_umbrella) — `%Fleet.Event{}` + le bus.
- `phoenix_pubsub`, `jason`, `uuid` (UUID v4 des work items). `stream_data` (test).
