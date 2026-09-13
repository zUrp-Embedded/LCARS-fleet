defmodule Fleet.Pilot.IncidentRegistry do
  @moduledoc """
  Incident recurrence and cooldown memory, serialized in a GenServer. `Store` owns
  local WAL writes and forge synchronization; `Escalation` creates or reuses the
  sysadmin issue. WAL failures leave memory updated and are logged or surfaced.

  Observation is serialized, but forge escalation and its later cooldown stamp
  run outside that transaction. Concurrent callers can both pass the gate.
  """
  use GenServer
  require Logger

  alias Fleet.Pilot.IncidentRegistry.Store

  @forge_fail_threshold 3
  # Coalesce normal notes into a 300-second forge-sync window to limit ops commits.
  # WAL failures and unreadable boot backing use the shorter retry clock instead.
  # Other machines see changes after synchronization; this is not a periodic pull.
  # Configure :pilot_incident_registry_sync_debounce_ms via
  # LCARS_PILOT_INCIDENT_REGISTRY_SYNC_DEBOUNCE_MS, or :sync_debounce_ms per instance.
  @sync_debounce_ms 300_000
  @retry_ms 30_000

  @doc """
  Builds `op:normalized_subject:reason_category`. Every digit run in the subject
  becomes N, grouping numbered instances; Event.reason_fields/1 supplies the
  category so variable diagnostic details do not split recurring incidents.
  """
  @spec signature(String.t(), String.t(), term()) :: String.t()
  def signature(op, subject, reason) when is_binary(op) and is_binary(subject) do
    "#{op}:#{normalize(subject)}:#{reason_category(reason)}"
  end

  @doc "Looks up recurrence in owner memory. A call exit logs and returns false; a busy owner can delay the lookup."
  @spec seen_before?(String.t(), keyword()) :: boolean()
  def seen_before?(sig, opts \\ []) when is_binary(sig) do
    GenServer.call(server(opts), {:seen_before?, sig})
  catch
    :exit, why ->
      Logger.error(
        "IncidentRegistry: unavailable (seen_before? #{sig}): #{inspect(why)} — fail-loud"
      )

      false
  end

  @doc "Records the incident: memory upsert + local WAL THEN async forge sync. fail-LOUD if owner unavailable."
  @spec note(String.t(), term(), keyword()) :: :ok | {:error, term()}
  def note(sig, reason, opts \\ []) when is_binary(sig) do
    GenServer.call(server(opts), {:note, sig, reason, now(opts)})
  catch
    :exit, why ->
      Logger.error("IncidentRegistry: unavailable (note #{sig}): #{inspect(why)} — fail-loud")
      {:error, :registry_unavailable}
  end

  @doc """
  Records a first occurrence or escalates a recurrence, updating the timeline in
  either case. Cooldown suppresses duplicate issues; return values distinguish
  durable, volatile, suppressed, and failed outcomes.
  """
  @spec record_or_escalate(String.t(), String.t(), term(), keyword()) ::
          :recorded
          | {:recorded_volatile, term()}
          | {:escalated, integer()}
          | {:escalation_suppressed, integer() | nil}
          | {:escalation_failed, term()}
          | {:record_failed, term()}
  def record_or_escalate(op, subject, reason, opts \\ [])
      when is_binary(op) and is_binary(subject) do
    sig = signature(op, subject, reason)

    case observe(sig, reason, opts) do
      :recorded_first ->
        :recorded

      {:recorded_first_volatile, wal_reason} ->
        {:recorded_volatile, wal_reason}

      {:suppressed, issue} ->
        {:escalation_suppressed, issue}

      :should_escalate ->
        # A successful create or reuse stamps cooldown. Errors leave it unstamped,
        # allowing a later recurrence to retry; the preceding WAL write may also fail.
        case escalate(Keyword.get(opts, :escalate_kind, :recurrence), subject, reason, sig, opts) do
          {:ok, num} ->
            warn_if_stamp_lost(mark_escalated(sig, num, opts), sig, num)
            {:escalated, num}

          {:error, e} ->
            {:escalation_failed, e}
        end

      {:error, e} ->
        {:record_failed, e}
    end
  end

  # Observe and decide the gate in one owner call; issue creation is a later step.
  defp observe(sig, reason, opts) do
    # Per-call cooldown overrides travel in the message, not the owner's startup opts.
    GenServer.call(server(opts), {:observe, sig, reason, now(opts), cooldown_ms(opts)})
  catch
    :exit, why ->
      Logger.error("IncidentRegistry: unavailable (observe #{sig}): #{inspect(why)} — fail-loud")
      {:error, :registry_unavailable}
  end

  # Persist the cooldown after successful escalation. Losing it may cause further
  # attempts after restart; it does not undo the issue.
  defp mark_escalated(sig, issue_number, opts) do
    GenServer.call(server(opts), {:mark_escalated, sig, issue_number, now(opts)})
  catch
    :exit, why ->
      Logger.error(
        "IncidentRegistry: unavailable (mark_escalated #{sig} ##{issue_number}): #{inspect(why)} " <>
          "— cooldown NOT engraved (next recurrence may open a redundant issue)"
      )

      {:error, :registry_unavailable}
  end

  # Preserve the successful issue result while reporting lost cooldown durability.
  defp warn_if_stamp_lost(:ok, _sig, _num), do: :ok

  defp warn_if_stamp_lost({:error, why}, sig, num) do
    Logger.error(
      "IncidentRegistry: issue ##{num} OPENED for #{sig} but the cooldown stamp is NOT durable " <>
        "(#{inspect(why)}) — the escalation HAPPENED; on a restart before the async forge sync " <>
        "the next recurrence may open a redundant issue"
    )

    :ok
  end

  @doc """
  Attempts escalation on the first occurrence; suppresses repeats within
  :pilot_incident_escalation_cooldown_ms while still updating their timeline.
  If the registry call exits, attempts escalation without its cooldown gate.
  Gate observation, issue creation and stamping are separate operations.
  """
  @spec escalate_gated(atom(), String.t(), term(), String.t(), keyword()) ::
          {:ok, integer()} | {:suppressed, integer() | nil} | {:error, term()}
  def escalate_gated(kind, subject, reason, sig, opts \\ []) do
    gate =
      try do
        GenServer.call(server(opts), {:observe, sig, reason, now(opts), cooldown_ms(opts)})
      catch
        :exit, why ->
          Logger.error(
            "IncidentRegistry: unavailable (escalate_gated #{sig}): #{inspect(why)} — " <>
              "FAIL-OPEN, escalating without cooldown gate"
          )

          :should_escalate
      end

    case gate do
      {:suppressed, issue} ->
        {:suppressed, issue}

      _first_or_should_escalate ->
        case escalate(kind, subject, reason, sig, opts) do
          {:ok, num} ->
            warn_if_stamp_lost(mark_escalated(sig, num, opts), sig, num)
            {:ok, num}

          {:error, e} ->
            {:error, e}
        end
    end
  end

  @doc """
  Delegates issue creation/reuse to Escalation without consulting recurrence
  memory or cooldown. Use escalate_gated/5 when that gate is required.
  """
  @spec escalate(atom(), String.t(), term(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, term()}
  defdelegate escalate(kind, subject, reason, sig, opts \\ []),
    to: Fleet.Pilot.IncidentRegistry.Escalation

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    wal = Store.wal_path(opts)
    _ = File.mkdir_p(Path.dirname(wal))

    state = %{registry: %{}, wal_path: wal, forge_fails: 0, sync_pending: false, opts: opts}
    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    wal = Store.read_wal(state.wal_path)

    case Store.load_forge(state.opts) do
      {:ok, forge_reg} ->
        registry = Store.merge(wal, forge_reg)
        Logger.info("IncidentRegistry: loaded #{map_size(registry)} signature(s) (WAL ∪ forge)")
        {:noreply, %{state | registry: registry}}

      :absent ->
        Logger.info(
          "IncidentRegistry: loaded #{map_size(wal)} signature(s) (WAL only — no forge file yet)"
        )

        {:noreply, %{state | registry: wal}}

      {:error, reason} ->
        # Boot from WAL and retry an unreadable forge on the catch-up clock.
        Logger.error(
          "IncidentRegistry: forge backing UNREADABLE at boot (#{inspect(reason)}) — booting on WAL " <>
            "only (#{map_size(wal)} signature(s)); cross-machine memory is BLIND until a re-read. " <>
            "Scheduling a forge re-sync."
        )

        {:noreply, schedule_catch_up(%{state | registry: wal})}
    end
  end

  @impl true
  def handle_call({:seen_before?, sig}, _from, state) do
    {:reply, Map.has_key?(state.registry, sig), state}
  end

  def handle_call({:note, sig, reason, now}, _from, state) do
    registry = upsert(state.registry, sig, reason, now)

    # Attempt WAL persistence before scheduling forge sync. Surface failure even
    # though in-memory recurrence detection remains available this session.
    wal = Store.write_wal(state.wal_path, registry)

    reply =
      case wal do
        :ok -> :ok
        {:error, e} -> {:error, {:wal_write_failed, e}}
      end

    {:reply, reply, schedule_sync(%{state | registry: registry}, wal)}
  end

  # Record even suppressed occurrences; serialize the note and gate decision.
  def handle_call({:observe, sig, reason, now, cooldown_ms}, _from, state) do
    known? = Map.has_key?(state.registry, sig)
    cooldown = under_cooldown(state.registry[sig], now, cooldown_ms)

    registry = upsert(state.registry, sig, reason, now)
    wal = Store.write_wal(state.wal_path, registry)
    state = schedule_sync(%{state | registry: registry}, wal)

    # Distinguish volatile first notes. Recurrence replies retain the escalation
    # decision despite WAL failure; they do not prove the updated timeline persisted.
    reply =
      cond do
        not known? and match?({:error, _}, wal) -> {:recorded_first_volatile, elem(wal, 1)}
        not known? -> :recorded_first
        match?({:suppressed, _}, cooldown) -> cooldown
        true -> :should_escalate
      end

    {:reply, reply, state}
  end

  # Keep the escalation timestamp and issue number together through later merges.
  def handle_call({:mark_escalated, sig, issue_number, now}, _from, state) do
    registry =
      Map.update(
        state.registry,
        sig,
        %{
          "count" => 1,
          "first_seen" => now,
          "last_seen" => now,
          "last_escalated_at" => now,
          "escalated_issue" => issue_number
        },
        fn entry ->
          entry
          |> Map.put("last_escalated_at", now)
          |> Map.put("escalated_issue", issue_number)
        end
      )

    # Surface lost stamp persistence separately from successful issue escalation.
    wal = Store.write_wal(state.wal_path, registry)

    reply =
      case wal do
        :ok -> :ok
        {:error, e} -> {:error, {:wal_write_failed, e}}
      end

    {:reply, reply, schedule_sync(%{state | registry: registry}, wal)}
  end

  @impl true
  def handle_info(:sync_forge, state) do
    state = %{state | sync_pending: false}

    case Store.sync_forge(state.registry, state.opts) do
      {:ok, merged} ->
        _ = Store.write_wal(state.wal_path, merged)
        {:noreply, %{state | registry: merged, forge_fails: 0}}

      {:error, reason} ->
        fails = state.forge_fails + 1

        # Log the third failure and every twentieth retry. WAL safety depends on
        # earlier writes succeeding, despite the unconditional wording of this log.
        if fails == @forge_fail_threshold or rem(fails, 20) == 0 do
          Logger.error(
            "IncidentRegistry: backing-store forge unreachable for #{fails} attempts (#{inspect(reason)}) " <>
              "— fail-LOUD. Data SAFE in the local WAL (#{state.wal_path}); re-sync when forge returns."
          )
        end

        Process.send_after(self(), :sync_forge, retry_ms(state.opts))
        {:noreply, %{state | forge_fails: fails, sync_pending: true}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ============================================================
  # Internal
  # ============================================================

  defp schedule_sync(%{sync_pending: true} = state), do: state

  defp schedule_sync(state) do
    Process.send_after(self(), :sync_forge, debounce_ms(state.opts))
    %{state | sync_pending: true}
  end

  # A failed WAL write schedules catch-up even with a window timer pending.
  # Extra timers may still fire; Store skips PUTs when encoded bytes match.
  defp schedule_sync(state, :ok), do: schedule_sync(state)
  defp schedule_sync(state, {:error, _}), do: schedule_catch_up(state)

  defp schedule_catch_up(state) do
    Process.send_after(self(), :sync_forge, retry_ms(state.opts))
    %{state | sync_pending: true}
  end

  defp upsert(registry, sig, reason, now) do
    entry =
      registry
      |> Map.get(sig, %{"count" => 0, "first_seen" => now})
      |> Map.update("count", 1, &(&1 + 1))
      |> Map.put("last_seen", now)
      |> Map.put("last_reason", inspect(reason))

    registry |> Map.put(sig, entry) |> Store.prune()
  end

  # --- config (opts > app env > default) ---
  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp now(opts), do: opts[:now] || DateTime.to_iso8601(DateTime.utc_now())

  # One-hour cooldown by default; :escalation_cooldown_ms overrides application config.
  # Missing or invalid stamps allow escalation, including pre-cooldown entries.
  @escalation_cooldown_ms 3_600_000

  defp under_cooldown(nil, _now_iso, _cooldown_ms), do: nil

  defp under_cooldown(entry, now_iso, cooldown_ms) do
    with last when is_binary(last) <- entry["last_escalated_at"],
         {:ok, last_dt, _} <- DateTime.from_iso8601(last),
         {:ok, now_dt, _} <- DateTime.from_iso8601(now_iso),
         true <- DateTime.diff(now_dt, last_dt, :millisecond) < cooldown_ms do
      {:suppressed, entry["escalated_issue"]}
    else
      _ -> nil
    end
  end

  defp cooldown_ms(opts) do
    opts[:escalation_cooldown_ms] ||
      Application.get_env(
        :lcars_fleet,
        :pilot_incident_escalation_cooldown_ms,
        @escalation_cooldown_ms
      )
  end

  defp debounce_ms(opts) do
    opts[:sync_debounce_ms] ||
      Application.get_env(
        :lcars_fleet,
        :pilot_incident_registry_sync_debounce_ms,
        @sync_debounce_ms
      )
  end

  defp retry_ms(opts), do: opts[:retry_ms] || @retry_ms

  defp normalize(subject), do: Regex.replace(~r/\d+/, subject, "N")

  # Use the event producer's category projection to keep dedup vocabulary aligned.
  defp reason_category(reason), do: elem(Fleet.Event.reason_fields(reason), 0)
end
