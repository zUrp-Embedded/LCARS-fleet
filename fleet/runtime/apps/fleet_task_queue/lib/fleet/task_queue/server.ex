defmodule Fleet.TaskQueue.Server do
  @moduledoc """
  GenServer porteur de la queue EN RAM (un seul écrivain). Persistence atomique `state.json`
  versionné `v: 1` (**opt-in**) ; events `%Fleet.Event{}` sur le bus.

  AXIOME source-unique : la **forge** est la vérité du travail (issues/routes/PR) ; le
  broker n'en est que le FRONT en RAM. Aucun champ du `WorkItem` n'est broker-only-durable (tout est
  re-dérivable au re-dispatch forge) → **en prod le broker tourne ÉPHÉMÈRE** (`persist: false`, cf.
  `Application`) : pas de `state.json`, donc pas de tâches stale persistées qui survivent aux reboots
  (cause des 1124 "en cours" accumulées). Au restart, la queue se re-dérive des polls forge (rail de
  réconciliation canonique). La persistance ci-dessous reste un mécanisme **opt-in** (testé) pour un
  futur état broker-only-durable — il n'en existe AUCUN à ce jour.

  Broadcast `%Fleet.Event{source: :task_queue, ...}` sur `Phoenix.PubSub`
  topic `fleet.events`, `correlation_id = work_item.id`. Recovery cross-restart via
  `state.json` (fail-loud `:state.corrupt` sur schema mismatch au READ, fallback
  non-bloquant). Côté WRITE : `persist/1` est best-effort — un échec d'écriture est
  loggé **error** (durabilité du point de recovery rompue), **non-fatal** (on
  ne crashe pas le broker sur un blip disque) ; la réconciliation passe par le rail
  forge-driven (re-dispatch depuis l'état forge), pas par cette persistance locale.

  ## Bottleneck assumé
  GenServer = sérialisation voulue des transitions d'état (idempotence + écriture
  atomique `state.json`). L'optimisation ETS-reads / pool est **différée** (critère
  de déclenchement : latence get_work_item/submit_result > 100ms). MVP : tout passe par `call`.

  ## Options
  `:name` (`nil` → anonyme, isolation tests), `:state_path`, `:persist`,
  `:topic` (défaut `"fleet.events"`), `:retention_terminal_max` (nombre max
  de tâches TERMINALES conservées, défaut 500 ; borne `work_items` en mémoire ET la taille
  de `state.json` réécrit à chaque mutation. Les tâches ACTIVES ne comptent pas),
  `:bus` (seam, défaut `Fleet.EventRouter.Bus` ; module `broadcast/2` — injecté en test pour
  exercer le chemin lifecycle non-avalé `work_item.completed`).

  ## Broadcast — load-bearing vs best-effort
  `work_item.completed` est LIFECYCLE load-bearing (le StepRunConsumer en dépend pour finir le step_run) →
  `required_broadcast` : un échec n'est PAS avalé, il propage `{:error, {:broadcast_failed, _}}` au caller
  de `submit_result` (plus de `:ok` muet qui laisse le verrou forge à vie). Les autres events
  (enqueued/assigned/cleared/failed-deadline/state.corrupt) = `best_effort_broadcast` (observabilité, rescue).

  ## Découpage — ce qui est sorti, ce qui reste (et pourquoi)

  Deux concerns extraits en modules sans state (le state GenServer ne les traverse plus) :

    * `Fleet.TaskQueue.Store` — persistence `state.json` (sérialisation + FS, écriture
      atomique, décodage fail-loud `:corrupt`). Le Server garde l'ORCHESTRATION :
      `persist/1` décide SI on persiste (`persist: false` / `state_path: nil`),
      `load_state/2` décide SI on recharge — Store ne sait que lire/écrire.
    * `Fleet.TaskQueue.Broadcast` — policy load-bearing vs best-effort + enveloppe
      `event/3`. Le Server garde des adaptateurs une-ligne qui dépaquettent
      `state.bus`/`state.topic` (les seams par-instance).

  Deux concerns REFUSÉS à l'extraction (2 découpes nettes > 4 forcées) :

    * **Deadline-watchdog** (`maybe_schedule_deadline/1` + `handle_info {:check_deadline}`) :
      la paire arme/vérifie est couplée au PROCESS (`Process.send_after(self(), ...)` →
      message reçu par CE GenServer). Extraire la moitié « armement » poserait un
      side-effect process-couplé dans un module feuille pendant que la moitié réceptrice
      (callback) resterait ici : aucun couplage levé, une indirection ajoutée.
    * **Rétention/prune** (`prune_terminal/2` + `recency/1`) : ~20 LOC pures, UN SEUL
      call-site (`put_work_item/2`), et le vocabulaire `@active_states` est PARTAGÉ avec
      la sélection (`find_active`), la supersession et la garde deadline — l'extraire
      forcerait soit une duplication de cette autorité, soit un module dédié pour 20 LOC.
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.TaskQueue.Broadcast
  alias Fleet.TaskQueue.Store
  alias Fleet.TaskQueue.WorkItem

  @active_states [:pending, :assigned, :in_progress]
  # Borne de rétention des tâches terminales (:completed/:failed/:cleared). Sans elle,
  # `work_items` croît sans borne et `persist/1` réécrit un `state.json` toujours plus gros à CHAQUE
  # mutation. On garde les N plus récentes ; les actives ne comptent pas (cf. prune_terminal/2).
  @default_retention_terminal 500

  # ============================================================
  # Lifecycle
  # ============================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    # `name: nil` → serveur anonyme (isolation tests). Absent → nom canonique.
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @impl GenServer
  def init(opts) do
    persist? = Keyword.get(opts, :persist, true)
    state_path = Keyword.get(opts, :state_path, Store.default_path())

    base = %{
      work_items: %{},
      # Last-poll par pod (l'agent a appelé get_for_pod = ACK in-band, MÊME sans work item → signal
      # bootstrap « l'agent est up + a tendu la main »). In-mem/éphémère : la récence vit en runtime, pas
      # persisté (un restart re-établit via les polls suivants).
      polls: %{},
      state_path: state_path,
      persist: persist?,
      topic: Keyword.get(opts, :topic, Bus.main_topic()),
      # Seam du bus (défaut = le vrai `Fleet.EventRouter.Bus`). Module avec `broadcast/2`. Permet
      # de tester le chemin lifecycle non-avalé (un bus stub qui rend `{:error,_}` / lève sur work_item.completed)
      # sans toucher le registry global `:persistent_term`.
      bus: Keyword.get(opts, :bus, Bus),
      retention_terminal_max:
        Keyword.get(opts, :retention_terminal_max) ||
          Application.get_env(
            :fleet_task_queue,
            :retention_terminal_max,
            @default_retention_terminal
          )
    }

    case load_state(state_path, persist?) do
      :empty ->
        {:ok, base}

      {:ok, work_items} ->
        {:ok, %{base | work_items: work_items}, {:continue, :reschedule_deadlines}}

      {:corrupt, found} ->
        {:ok, base, {:continue, {:corrupt, found}}}
    end
  end

  @impl GenServer
  def handle_continue(:reschedule_deadlines, state) do
    # Recovery : les deadlines ne sont armées qu'à l'enqueue. Après restart, on ré-arme
    # les tâches ACTIVES ; une deadline dépassée pendant le downtime → check immédiat (→ :"work_item.failed" via
    # handle_info), pas active-pour-toujours.
    for {_id, %WorkItem{state: s} = t} <- state.work_items, s in @active_states do
      maybe_schedule_deadline(t)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_continue({:corrupt, found}, state) do
    # Fallback non-bloquant : state vide + event de boot anomaly post-init.
    best_effort_broadcast(
      state,
      Fleet.Event.new(:task_queue, :"state.corrupt", payload: %{expected: 1, found: found})
    )

    {:noreply, state}
  end

  # ============================================================
  # Command Port
  # ============================================================

  @impl GenServer
  def handle_call({:enqueue, pod_id, attrs}, _from, state) do
    work_item = %WorkItem{
      id: UUID.uuid4(),
      pod_id: pod_id,
      issue_id: attrs[:issue_id] || attrs["issue_id"],
      role: attrs[:role] || attrs["role"],
      brief: attrs[:brief] || attrs["brief"],
      deadline: attrs[:deadline] || attrs["deadline"],
      enqueued_at: now(),
      state: :pending,
      metadata: attrs[:metadata] || attrs["metadata"] || %{}
    }

    # AXIOME « 1 work item ACTIF/pod » tenu À L'ÉCRITURE. Un work item FRAIS SUPERSÈDE TOUTE active du pod :
    # le `:pending` jamais pullé (drop) ET l'`:assigned`/`:in_progress` en cours (→ `:cleared`). Un re-brief
    # remplace l'ancien : le pod prendra le nouveau (seul actif restant) au prochain `get_for_pod`. L'unicité
    # DOIT être tenue ici, pas seulement à la lecture : garder une `:assigned` stale à côté du nouveau pending
    # la laisserait ACTIVE et invisible aux gardes (`find_active` = `max_by(enqueued_at)` sert la + récente mais
    # MASQUE la fuite → état « 2 actives/pod » non borné, invariant violé). Unicité tenue À L'ÉCRITURE →
    # `find_active`/`max_by` devient moot (au plus 1 active/pod par construction).
    {state, superseded} = supersede_active(state, pod_id)

    if superseded > 0,
      do: Logger.debug("TaskQueue: enqueue pod=#{pod_id} supersède #{superseded} active(s) stale")

    new_state = state |> put_work_item(work_item) |> persist()

    # payload = `%{work_item_id}` (cohérent avec tous les autres work_item.* events), PAS le `%WorkItem{}` brut —
    # WorkItem n'a pas de @derive Jason.Encoder, donc un `%{work_item: work_item}` ferait crasher `Jason.encode!`
    # chez tout consommateur d'events JSON (Fleet.API.WS à chaque enqueue). Aucun consommateur n'a
    # besoin du struct (deck = count, audit = pod_id/correlation_id).
    best_effort_broadcast(
      new_state,
      event(:"work_item.enqueued", work_item, %{work_item_id: work_item.id})
    )

    maybe_schedule_deadline(work_item)
    {:reply, {:ok, work_item}, new_state}
  end

  def handle_call({:get_for_pod, pod_id}, _from, state) do
    # last-poll AVANT le case : l'agent a tendu la main = ACK in-band, qu'il reçoive un work item ou non
    # (le cas `:no_work_item` est le signal bootstrap « l'agent est up + armé »).
    state = record_poll(state, pod_id)

    case find_active(state.work_items, pod_id) do
      nil ->
        {:reply, {:error, :no_work_item}, state}

      %WorkItem{state: :pending} = work_item ->
        assigned = %{work_item | state: :assigned, assigned_at: now()}
        new_state = state |> put_work_item(assigned) |> persist()

        best_effort_broadcast(
          new_state,
          event(:"work_item.assigned", assigned, %{work_item_id: assigned.id})
        )

        {:reply, {:ok, assigned}, new_state}

      %WorkItem{} = work_item ->
        # déjà :assigned/:in_progress → idempotent (pas de re-broadcast, pas de double dispatch)
        {:reply, {:ok, work_item}, state}
    end
  end

  def handle_call({:submit_result, pod_id, result}, _from, state) do
    case find_active(state.work_items, pod_id) do
      nil ->
        if has_completed?(state.work_items, pod_id),
          do: {:reply, {:error, :double_submit_ignored}, state},
          else: {:reply, {:error, :no_active_work_item}, state}

      %WorkItem{} = work_item ->
        case result["work_item_id"] || result[:work_item_id] do
          tid when tid != nil and tid != work_item.id ->
            # correlation_id du livrable ≠ work item actif du pod → rejet, aucune mutation. C'est le 2e verrou
            # anti-impersonation (le 1er = la capability côté fleet_mcp) : même un pod prouvé ne peut clôturer
            # qu'EXACTEMENT son work item actif, jamais « la dernière active » d'un autre. fleet_mcp rend le
            # work_item_id OBLIGATOIRE côté pod → ce corrélateur est toujours présent et vérifié.
            {:reply, {:error, :work_item_id_mismatch}, state}

          _ok ->
            # `work_item_id` retiré du livrable STOCKÉ : c'est un corrélateur de transport (preuve « je clôs CE
            # work item »), pas une donnée métier du résultat. Le work item est déjà identifié par `work_item.id` ; le
            # garder dans `result` ne ferait que dupliquer/polluer le livrable broadcasté.
            clean_result = result |> Map.delete("work_item_id") |> Map.delete(:work_item_id)

            completed = %{
              work_item
              | state: :completed,
                completed_at: now(),
                result: clean_result
            }

            new_state = state |> put_work_item(completed) |> persist()

            # `work_item.completed` est LIFECYCLE load-bearing : le StepRunConsumer en DÉPEND pour finir le
            # step_run (lever le verrou forge). Le broadcast passe par `required_broadcast` : son échec n'est PLUS
            # avalé en `:ok`. Si la diffusion échoue, on NE rend PAS `{:ok, completed}` (qui ferait croire au
            # pod « tâche close » alors que le step_run ne finira jamais → verrou conservé à vie) : on propage
            # `{:error, {:broadcast_failed, _}}`. La tâche RESTE `:completed`+persistée (le livrable n'est
            # pas perdu ; le rail forge-driven re-dérive au besoin), mais le pod voit un échec honnête.
            # role/issue_id additifs : le DeliveryPublisher stampe l'identité de l'agent d'origine
            # sur le commit forge. Les consumers existants ignorent les clés extra.
            # `metadata` additif : le verdict work_item.completed porte le metadata de la TÂCHE (qui
            # survit dans le broker au crash du StepRunConsumer seul). Pour une éval gatekeeper il porte le
            # contexte de reprise (`gate_eval`/`payload`/`pipeline`/…) → le StepRunConsumer redémarré (gate_evals
            # RAM vide) RECONSTRUIT l'eval_ctx du metadata au lieu d'un `{:noreply}` silencieux (wedge à vie).
            ev =
              event(:"work_item.completed", completed, %{
                work_item_id: completed.id,
                role: completed.role,
                issue_id: completed.issue_id,
                result: clean_result,
                metadata: completed.metadata
              })

            case required_broadcast(new_state, ev) do
              :ok ->
                {:reply, {:ok, completed}, new_state}

              {:error, _} = err ->
                {:reply, err, new_state}
            end
        end
    end
  end

  # Purge TOUTES les actives du pod (pas seulement la + récente via `find_active`). Avec l'invariant
  # « 1 active/pod » tenu à l'enqueue (`supersede_active`), il n'y en a normalement qu'une ; mais un clear doit
  # rester TOTAL (pas de stale `:assigned` résiduelle qui échapperait au clear et fuirait — symétrique de
  # l'enqueue). Un broadcast `:"work_item.cleared"` par tâche clearée ; aucune active → no-op idempotent.
  def handle_call({:clear_for_pod, pod_id}, _from, state) do
    # Le clear décommissionne le pod → on retire AUSSI son last-poll de `state.polls` (symétrique de
    # la purge des `work_items` ci-dessous). Sans ça, `polls` (un timestamp par pod, JAMAIS persisté) accumule
    # indéfiniment les pod_id morts : `record_poll` n'ajoute que des entrées, et `prune_terminal` n'élague
    # que `work_items`. `clear_for_pod` est le point de purge canonique du pod → c'est ici qu'un poll devient
    # obsolète. `Map.delete` idempotent : no-op si le pod n'a jamais pollé ou n'a aucune active.
    state = %{state | polls: Map.delete(state.polls, pod_id)}

    active =
      state.work_items
      |> Map.values()
      |> Enum.filter(&(&1.pod_id == pod_id and &1.state in @active_states))

    case active do
      [] ->
        {:reply, :ok, state}

      work_items ->
        cleared = Enum.map(work_items, &%{&1 | state: :cleared})
        new_state = Enum.reduce(cleared, state, &put_work_item(&2, &1)) |> persist()

        for t <- cleared,
            do:
              best_effort_broadcast(
                new_state,
                event(:"work_item.cleared", t, %{work_item_id: t.id})
              )

        {:reply, :ok, new_state}
    end
  end

  # ============================================================
  # Query Port (aucun side-effect, aucun broadcast)
  # ============================================================

  def handle_call(:list_pending, _from, state) do
    pending = state.work_items |> Map.values() |> Enum.filter(&(&1.state == :pending))
    {:reply, pending, state}
  end

  def handle_call({:pod_status, pod_id}, _from, state) do
    status =
      case latest_for_pod(state.work_items, pod_id) do
        nil -> nil
        %WorkItem{state: s} -> s
      end

    {:reply, {:ok, status}, state}
  end

  # SLOT-FREEZE : issue de la DERNIERE tache du pod (couvre :completed = fenetre de publication). Le
  # poller s'en sert pour qu'un eng pipe project-scoped possede le verrou de sa brique active/en-cours.
  def handle_call({:pod_active_issue_id, pod_id}, _from, state) do
    issue =
      case latest_for_pod(state.work_items, pod_id) do
        nil -> nil
        %WorkItem{issue_id: t} -> t
      end

    {:reply, {:ok, issue}, state}
  end

  # Last-poll du pod (`DateTime | nil`) = l'ACK in-band du bootstrap (« l'agent a tendu la main »,
  # même sans work item). Le consommateur réel (`Pod.TaskProbe.polled?`) teste la PRÉSENCE (!= nil),
  # il ne compare PAS d'instants (E3 : si une comparaison de récence naît un jour, la faire en
  # monotonic/jeton, jamais DateTime-vs-DateTime — sauts NTP).
  def handle_call({:last_poll, pod_id}, _from, state) do
    {:reply, Map.get(state.polls, pod_id), state}
  end

  # ============================================================
  # Deadline (transition :failed)
  # ============================================================

  @impl GenServer
  def handle_info({:check_deadline, work_item_id}, state) do
    case Map.get(state.work_items, work_item_id) do
      %WorkItem{state: s} = work_item when s in @active_states ->
        failed = %{work_item | state: :failed}
        new_state = state |> put_work_item(failed) |> persist()

        # `:"work_item.failed"` (deadline) = watchdog de l'IRRÉDUCTIBLE, pas une complétion
        # caller-facing : best-effort (un handle_info n'a personne à qui propager). La garde reste, honnête.
        best_effort_broadcast(
          new_state,
          event(:"work_item.failed", failed, %{work_item_id: failed.id, reason: :deadline_expired})
        )

        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================
  # Helpers — sélection
  # ============================================================

  defp find_active(work_items, pod_id) do
    work_items
    |> Map.values()
    |> Enum.filter(&(&1.pod_id == pod_id and &1.state in @active_states))
    |> Enum.max_by(& &1.enqueued_at, DateTime, fn -> nil end)
  end

  defp latest_for_pod(work_items, pod_id) do
    work_items
    |> Map.values()
    |> Enum.filter(&(&1.pod_id == pod_id))
    |> Enum.max_by(& &1.enqueued_at, DateTime, fn -> nil end)
  end

  # Supersède TOUTE active du pod (un work item frais à l'enqueue remplace l'ancien) : chaque active
  # (`:pending` | `:assigned` | `:in_progress`) est transitionnée `:cleared` — y compris le `:pending`
  # jamais pullé (MÊME transition que les autres, il reste traçable dans la map ; rien n'est droppé).
  # Le pod abandonne l'ancien : `submit_result` du vieux work item tombera sur `find_active`
  # = nil → `:no_active_work_item`/`:double_submit_ignored`, jamais une mutation du nouveau. Garde tout le reste
  # (autres pods, terminaux du pod). Borne la queue à 1 active/pod À L'ÉCRITURE. Retourne
  # `{state, n_superseded}`.
  defp supersede_active(state, pod_id) do
    work_items =
      Map.new(state.work_items, fn {id, t} ->
        if t.pod_id == pod_id and t.state in @active_states do
          {id, %{t | state: :cleared}}
        else
          {id, t}
        end
      end)

    superseded =
      Enum.count(state.work_items, fn {_id, t} ->
        t.pod_id == pod_id and t.state in @active_states
      end)

    {%{state | work_items: work_items}, superseded}
  end

  defp has_completed?(work_items, pod_id) do
    Enum.any?(Map.values(work_items), &(&1.pod_id == pod_id and &1.state == :completed))
  end

  defp record_poll(state, pod_id) when is_binary(pod_id),
    do: %{state | polls: Map.put(state.polls, pod_id, now())}

  defp put_work_item(state, %WorkItem{} = work_item) do
    work_items = Map.put(state.work_items, work_item.id, work_item)
    %{state | work_items: prune_terminal(work_items, state.retention_terminal_max)}
  end

  # Garde au plus `max` tâches TERMINALES (les plus récentes), élague les plus vieilles.
  # No-op tant qu'on est sous le cap. Les tâches ACTIVES ne comptent pas et ne sont JAMAIS coupées
  # (work items en cours). L'ordre par récence (≠ ordre d'enqueue) protège la détection double-submit :
  # une tâche juste complétée est la plus récente → jamais élaguée en premier (has_completed?/1).
  defp prune_terminal(work_items, max) do
    terminal = for {_id, t} <- work_items, t.state not in @active_states, do: t

    if length(terminal) <= max do
      work_items
    else
      drop_ids =
        terminal
        |> Enum.sort_by(&recency/1, {:desc, DateTime})
        |> Enum.drop(max)
        |> MapSet.new(& &1.id)

      Map.reject(work_items, fn {id, _t} -> MapSet.member?(drop_ids, id) end)
    end
  end

  # Récence pour l'ordre de rétention : completed_at si complétée, sinon assigned_at, sinon
  # enqueued_at (toujours présent — @enforce_keys). Toujours un %DateTime{}, jamais nil.
  defp recency(%WorkItem{} = t), do: t.completed_at || t.assigned_at || t.enqueued_at

  defp maybe_schedule_deadline(%WorkItem{deadline: %DateTime{} = dl, id: id}) do
    ms = DateTime.diff(dl, DateTime.utc_now(), :millisecond)

    # ms>0 : arme à l'échéance. ms<=0 (deadline DÉJÀ dépassée, ex. au recovery) : check immédiat → fail
    # via handle_info, au lieu de l'ignorer silencieusement (= tâche active pour toujours).
    if ms > 0,
      do: Process.send_after(self(), {:check_deadline, id}, ms),
      else: send(self(), {:check_deadline, id})

    :ok
  end

  defp maybe_schedule_deadline(_), do: :ok

  # ============================================================
  # Helpers — events (policy dans Fleet.TaskQueue.Broadcast)
  # ============================================================
  #
  # Adaptateurs une-ligne : le state GenServer ne traverse PAS le module de policy —
  # on dépaquette ici les seams par-instance (`state.bus`, `state.topic`) et on passe
  # des arguments explicites. La classification load-bearing vs best-effort (le POURQUOI
  # des deux régimes) vit dans le moduledoc de `Fleet.TaskQueue.Broadcast`.

  defp event(type, %WorkItem{} = work_item, payload),
    do: Broadcast.event(type, work_item, payload)

  defp best_effort_broadcast(state, %Fleet.Event{} = ev),
    do: Broadcast.best_effort(state.bus, state.topic, ev)

  defp required_broadcast(state, %Fleet.Event{} = ev),
    do: Broadcast.required(state.bus, state.topic, ev)

  defp now, do: DateTime.utc_now()

  # ============================================================
  # Helpers — persistence (sérialisation + FS dans Fleet.TaskQueue.Store)
  # ============================================================
  #
  # Le Server garde l'ORCHESTRATION (persiste-t-on ? recharge-t-on ?) — les décisions
  # dépendent de ses options de boot (`persist: false` = mode prod éphémère,
  # `state_path: nil`). Store ne connaît que le format du fichier.

  defp persist(%{persist: false} = state), do: state
  defp persist(%{state_path: nil} = state), do: state

  defp persist(%{state_path: path, work_items: work_items} = state) do
    Store.save(path, work_items)
    state
  end

  defp load_state(_path, false), do: :empty
  defp load_state(nil, _persist), do: :empty
  defp load_state(path, true), do: Store.load(path)

  # UUID v4 (`correlation_id = work_item.id`) via la dép `:uuid` (déjà shippée dans l'umbrella) —
  # source unique, pas de génération hand-rolled `:crypto` en parallèle.
end
