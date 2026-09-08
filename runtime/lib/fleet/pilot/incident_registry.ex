defmodule Fleet.Pilot.IncidentRegistry do
  @moduledoc """
  Cross-session incident memory: the POLICY of recurrence and cooldown, serialized in one process.
  The durable magasin (atomic local WAL + asynchronous bidirectional forge backing, one encoder
  and one merge for both) is `Store`; the sysadmin issue is `Escalation` — three concerns, three
  modules. WAL failure is surfaced as volatile state.
  """
  use GenServer
  require Logger

  alias Fleet.Pilot.IncidentRegistry.Store

  @forge_fail_threshold 3
  # THE SYNC WINDOW IS THE REGISTRY'S OPS-COMMIT BUDGET. Every sync rewrites the ops file in full
  # and lands as one commit on the ops branch, and a durable failure is noted at EVERY tick (see
  # `IncidentConsumer`: recurrent under cooldown = noted, count/last_seen). Per machine, at the
  # 30 s default tick, a window shorter than the tick coalesces nothing: one
  # « ops(incident): sync registre » per tick, ~2 880 a day burying every human commit of the
  # branch; 300 s caps it at 288, and the file's final state is the same (the merge keeps the
  # max count and the latest stamps). What the window costs, and to whom:
  #   * the OTHER machines read this one's memory up to a window later. That delays an
  #     escalation by at most one occurrence (recurrence is decided against the local memory
  #     first). A duplicate sysadmin issue is guarded by `Escalation`'s open-issue readback, not
  #     by this memory: as long as that readback succeeds no duplicate opens; unreadable, it
  #     creates and says so in the body;
  #   * durability is NOT traded: the WAL holds every note before the forge does. When the WAL
  #     write FAILED the forge is the only durability left, and that sync runs on the catch-up
  #     clock (`retry_ms`, `schedule_sync/2`), not on the window. Same clock for the boot re-read
  #     of an unreadable forge: a read that pushes nothing has no commit budget to respect.
  # Knob `:pilot_incident_registry_sync_debounce_ms` (`LCARS_PILOT_INCIDENT_REGISTRY_SYNC_DEBOUNCE_MS`);
  # the `:sync_debounce_ms` opt is the test seam.
  @sync_debounce_ms 300_000
  @retry_ms 30_000

  @doc """
  The recurrence KEY of an incident: `op:subject:reason_category`.

  Deliberately coarser than the reason itself — the subject is normalised and the reason folded to a
  category, so the same failure on the same object collapses to one signature instead of a new one
  per error message. A key that never repeats measures nothing.
  """
  @spec signature(String.t(), String.t(), term()) :: String.t()
  def signature(op, subject, reason) when is_binary(op) and is_binary(subject) do
    "#{op}:#{normalize(subject)}:#{reason_category(reason)}"
  end

  @doc "Recurrence? MEMORY lookup (0 I/O → burst-proof). fail-LOUD if the owner is unavailable (log + first-time)."
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
        # Memory OK, WAL KO → durability not proven (the caller is LOUD, never reassures).
        {:recorded_volatile, wal_reason}

      {:suppressed, issue} ->
        {:escalation_suppressed, issue}

      :should_escalate ->
        # `escalate_kind` (default `:recurrence`): the wake passes `:sp_suspect` (recurrence = SP, not the agent).
        # We PROPAGATE the escalation result: `{:escalated, num}` comes out ONLY if the issue was really
        # opened (the number proves it). Forge down → `{:escalation_failed, _}`; the incident stays in the
        # local WAL (observed above), only the ISSUE is missing — and NO cooldown stamp is written, so the
        # next recurrence retries the escalation.
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

  # Single memory transaction at the OWNER (upsert count/last_seen + WAL + sync schedule) that
  # ALSO decides the escalation gate — the cooldown check and the note must not race across
  # two calls, and the recurrence must be engraved even when suppressed.
  defp observe(sig, reason, opts) do
    # The cooldown is resolved CALLER-SIDE (opts > config > default) and travels in the message:
    # the handler does not re-read state.opts — the test seam and a per-call override both work.
    GenServer.call(server(opts), {:observe, sig, reason, now(opts), cooldown_ms(opts)})
  catch
    :exit, why ->
      Logger.error("IncidentRegistry: unavailable (observe #{sig}): #{inspect(why)} — fail-loud")
      {:error, :registry_unavailable}
  end

  # Stamps `last_escalated_at`/`escalated_issue` at the owner (WAL + forge sync — merge_entry
  # carries the fields cross-machine). Failure = log only: the issue EXISTS (the escalation
  # succeeded), losing the stamp costs at worst one redundant issue at the next recurrence.
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

  # `{:escalated, num}` RESTE VRAI — l'issue existe, son numero le prouve, et c'est ce que
  # l'appelant a besoin de savoir. Mais la GARDE de recurrence, elle, n'est pas durable :
  # `write_wal` journalise son echec sous un libelle generique qui ne dit pas ce qu'il coute ICI.
  # Cette ligne le dit, la ou la consequence se produira.
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
  The IMMEDIATE-gate facade: escalates through the registry's cooldown gate while PRESERVING
  "issue on the FIRST occurrence" (no recurrence gate — porte `immediate`, cf. `events.yaml`): only the
  REPEATS of the same signature within `:pilot_incident_escalation_cooldown_ms` are suppressed (each
  suppressed repeat is still NOTED — the timeline stays true). `Escalation` itself stays
  stateless; the memory lives here. If the registry owner is down, we FAIL-OPEN to the
  escalation: l'alarme ne doit pas etre perdue parce que son etrangleur l'est.

  Returns `{:ok, number}` | `{:suppressed, number | nil}` | `{:error, term}`.
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
  Opens a system issue for an incident — DELEGATED to `IncidentRegistry.Escalation`
  (STATELESS act: no read of the GenServer, everything comes from the arguments + config;
  the registry keeps the MEMORY). Facade kept: **shared** by WakeRecovery and
  the failure consumers (DRY). Returns `{:ok, number}` | `{:error, term}`.
  """
  @spec escalate(atom(), String.t(), term(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, term()}
  defdelegate escalate(kind, subject, reason, sig, opts \\ []),
    to: Fleet.Pilot.IncidentRegistry.Escalation

  # ============================================================
  # GenServer
  # ============================================================

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
        # UNREADABLE forge ≠ empty forge. Boot on the WAL, but say so LOUD (on a fresh node the WAL
        # is empty → this is blind cross-machine memory), and schedule a re-sync so the node catches
        # up when the forge returns — instead of silently believing there is nothing to remember.
        # On the catch-up clock: blindness is measured in ticks, not in commit windows.
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

    # Local crash-survivable WAL BEFORE the forge; the forge is async (never on the dispatcher's path).
    # The WAL is the ONLY durability of `note/3` (no escalation = no forge issue): a failed write
    # CANNOT be swallowed as `:ok`. Otherwise, memory updated + WAL failed + crash before
    # the async forge sync = incident never durable while the return said "recorded". We propagate
    # the typed failure; `WakeRecovery` handles it (`note OK → recorded`, else LOUD "anchor NOT recorded").
    wal = Store.write_wal(state.wal_path, registry)

    reply =
      case wal do
        :ok -> :ok
        {:error, e} -> {:error, {:wal_write_failed, e}}
      end

    {:reply, reply, schedule_sync(%{state | registry: registry}, wal)}
  end

  # Memory transaction of `record_or_escalate`/`escalate_gated`: notes the occurrence (count/
  # last_seen — the timeline stays true even under cooldown) AND decides the escalation gate
  # in ONE serialized call (no race between the check and the note).
  def handle_call({:observe, sig, reason, now, cooldown_ms}, _from, state) do
    known? = Map.has_key?(state.registry, sig)
    cooldown = under_cooldown(state.registry[sig], now, cooldown_ms)

    registry = upsert(state.registry, sig, reason, now)
    wal = Store.write_wal(state.wal_path, registry)
    state = schedule_sync(%{state | registry: registry}, wal)

    # BND-055 — on a FIRST occurrence (`:recorded_first` → `:recorded`, NO escalation), the WAL is
    # the only durability — a failed write must not come out as `:recorded`. We distinguish
    # `{:recorded_first_volatile, _}` (memory OK, WAL KO → durability suspended on the async forge sync).
    # On a RECURRENCE (`:should_escalate`/`:suppressed`), the durability = the forge ISSUE opened by
    # the escalation (the WAL write is already logged LOUD inside) → the escalation gate is untouched.
    reply =
      cond do
        not known? and match?({:error, _}, wal) -> {:recorded_first_volatile, elem(wal, 1)}
        not known? -> :recorded_first
        match?({:suppressed, _}, cooldown) -> cooldown
        true -> :should_escalate
      end

    {:reply, reply, state}
  end

  # Engraves the escalation memory (recurrence cooldown): WAL + forge sync — `merge_entry`
  # carries the two fields cross-machine, otherwise the sync that follows the next note would
  # erase the cooldown and the issue storm would resume.
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

    # LE MEME MOTIF TRI-ETAT QUE `{:observe, …}` PLUS HAUT DANS CE MODULE. Un `_ = Store.write_wal(...)`
    # jette le seul fait qui distingue « tampon grave » de « tampon perdu », et aucun appelant ne
    # peut alors le savoir : la reponse est `:ok` dans les deux cas.
    #
    # ⚠ La consequence n'est PAS celle du voisin, et c'est pour ca que le retour public de
    # `record_or_escalate/4` ne bouge pas : la-bas un WAL perdu perd l'INCIDENT (la chronologie
    # ment) ; ici il perd le TAMPON DE COOLDOWN, et le pire cout est une issue redondante a la
    # recurrence suivante — borne, et qui se repare tout seul. Ce qu'il faut n'est pas un nouveau
    # verdict, c'est que le fait EXISTE quelque part.
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

        # Throttle (E4): at the threshold THEN every 20 tries (~10 min at 30s retry) — a forge down
        # for a week does not generate ~86k identical lines/month, and the incident stays VISIBLE.
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

  # The window is a budget for a memory the WAL already holds. A note whose WAL write FAILED has
  # the forge as its only durability: it syncs on the catch-up clock, whatever is pending. A
  # window timer may then fire behind it; a registry the forge already holds pushes nothing
  # (`Store.sync_forge/2`), so the second sync costs one read.
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

  # Recurrence cooldown of the sysadmin escalation: default 1 h (a durable failure keeps ONE open issue as its alarm
  # instead of one per tick — otherwise ~2 880 issues/day, self-amplified by the webhook kick). Seam
  # `:escalation_cooldown_ms` (tests) overrides the config knob `:pilot_incident_escalation_cooldown_ms`. Entries
  # without a stamp (pre-cooldown WAL/forge, or escalation never done) → nil → the gate lets the escalation through
  # (back-compat = old behavior).
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

  # The recurrence category IS the FIRST projection of the canonical
  # `Fleet.Event.reason_fields/1` (the single source of the atom/tuple/binary/other split, used on the
  # broadcast path). A local copy of the clauses would silently drift the incident dedup key from the
  # event category — same split, two owners. Consume the canonical projection instead.
  defp reason_category(reason), do: elem(Fleet.Event.reason_fields(reason), 0)
end
