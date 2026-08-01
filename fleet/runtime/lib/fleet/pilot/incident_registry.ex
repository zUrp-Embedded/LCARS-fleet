defmodule Fleet.Pilot.IncidentRegistry do
  @moduledoc """
  PERSISTENT cross-session memory of system incidents — **resilient owner**.

  An error handler must be MORE reliable than what it watches: its memory cannot depend
  (synchronous, single copy, race-prone) on the substrate it watches. Hence this GenServer — the Iron Law is
  SATISFIED here (mutable state to buffer + serialized access + isolation of forge failure):

    - **recurrence check** (`seen_before?`) = MEMORY lookup → 0 I/O per fail → withstands a **burst** (N pods
      falling together = the very signature of an error-handler's job);
    - **write** (`note`) = serialized upsert + **local WAL** (JSON, atomic write tmp+rename →
      crash-survivable) THEN triggers an **ASYNC forge sync** → the dispatcher NEVER blocks on the forge.
      A FAILED WAL write is SURFACED, never swallowed: the WAL is the only durability of a
      1st occurrence (no escalation), so `note/3` returns `{:error, {:wal_write_failed,_}}` and
      `record_or_escalate/4` returns `{:recorded_volatile,_}` — never a lying `:ok`/`:recorded`;
    - **forge = durable cross-machine backing-store** (branch `work/ops`), debounced + retried async sync,
      **bidirectional merge** (incidents from other machines absorbed); forge unreachable = **fail-LOUD** log,
      never a loss (the WAL holds, re-sync on return) nor a silent re-roll.

  At boot: `merge(local WAL, forge)`. `signature/3` stays a pure function. The git history of the forge
  file = the incident timeline.

  The sysadmin ESCALATION (opening the `error_system` issue) lives in the sub-module
  `Escalation` (stateless act, no read of the GenServer) — `escalate/5` stays here as a
  facade (defdelegate) for WakeRecovery and the failure consumers.

  **Last revised**: 2026-08-01
  """
  use GenServer
  require Logger

  alias Fleet.Pilot.ForgeClient

  @forge_fail_threshold 3
  @sync_debounce_ms 2_000
  @retry_ms 30_000

  # ============================================================
  # API (signature unchanged for WakeRecovery)
  # ============================================================

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
  Records a failure, OR escalates it if recurrent (already seen). For the paths WITHOUT re-roll (e.g.
  `pod.failed` / `result_timeout`): 1st = `note` (tolerated, possibly random); recurrence = escalation
  (pattern → root-cause). EVERY occurrence updates the memory (count/last_seen — the timeline stays
  true even under cooldown).

  The registry HAS the escalation memory it is named for: an escalation stamps
  `last_escalated_at`/`escalated_issue` in the signature entry, and a recurrence under
  `:incident_escalation_cooldown_ms` (config `:fleet_pilot`, default 1 h) is SUPPRESSED instead of
  opening a new forge issue. Without this, a durable failure (workflow_map unreadable on a routed
  issue) would open ONE ISSUE PER TICK — ~2 880/day, self-amplified by the webhook kick.

  HONEST return — it carries what ACTUALLY happened, never an optimistic success:

    - `:recorded` — first time, incident recorded in memory + local WAL.
    - `{:recorded_volatile, reason}` — first time, incident in MEMORY but the WAL write FAILED:
      NOT durable cross-session until the async forge sync absorbs it. The caller
      must DISTINGUISH it from `:recorded` (LOUD log/telemetry), never reassure about an absent durability.
    - `{:escalated, issue_number}` — recurrence, sysadmin issue ACTUALLY opened (the number PROVES it).
    - `{:escalation_suppressed, issue_number | nil}` — recurrence NOTED (count/last_seen updated) but
      under cooldown of the previous escalation: NO new issue (the existing one carries the alarm).
    - `{:escalation_failed, reason}` — recurrence detected but opening the issue failed (forge down?):
      NO issue exists. The incident stays in memory/local WAL, but the sysadmin
      alarm did NOT go out → the caller must SHOUT it, not reassure.
    - `{:record_failed, reason}` — the owner (GenServer) is unavailable: the incident was NOT
      recorded at all (neither memory nor WAL) → a recurrence cannot be detected.
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
            _ = mark_escalated(sig, num, opts)
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

  @doc """
  Cat-5 facade: escalates through the registry's cooldown gate while PRESERVING
  "issue on the FIRST occurrence" (no recurrence gate — max severity, doctrine A-06): only the
  REPEATS of the same signature within `:incident_escalation_cooldown_ms` are suppressed (each
  suppressed repeat is still NOTED — the timeline stays true). `Escalation` itself stays
  stateless; the memory lives here. If the registry owner is down, we FAIL-OPEN to the
  escalation: the max-severity alarm must not be lost because its throttle is.

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
            _ = mark_escalated(sig, num, opts)
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
  defdelegate escalate(kind, subject, reason, sig, opts \\ []),
    to: Fleet.Pilot.IncidentRegistry.Escalation

  # ============================================================
  # GenServer
  # ============================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    wal = wal_path(opts)
    _ = File.mkdir_p(Path.dirname(wal))

    state = %{registry: %{}, wal_path: wal, forge_fails: 0, sync_pending: false, opts: opts}
    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    wal = read_wal(state.wal_path)

    case load_forge(state.opts) do
      {:ok, forge_reg} ->
        registry = merge(wal, forge_reg)
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
        Logger.error(
          "IncidentRegistry: forge backing UNREADABLE at boot (#{inspect(reason)}) — booting on WAL " <>
            "only (#{map_size(wal)} signature(s)); cross-machine memory is BLIND until a re-read. " <>
            "Scheduling a forge re-sync."
        )

        {:noreply, schedule_sync(%{state | registry: wal})}
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
    reply =
      case write_wal(state.wal_path, registry) do
        :ok -> :ok
        {:error, e} -> {:error, {:wal_write_failed, e}}
      end

    {:reply, reply, schedule_sync(%{state | registry: registry})}
  end

  # Memory transaction of `record_or_escalate`/`escalate_gated`: notes the occurrence (count/
  # last_seen — the timeline stays true even under cooldown) AND decides the escalation gate
  # in ONE serialized call (no race between the check and the note).
  def handle_call({:observe, sig, reason, now, cooldown_ms}, _from, state) do
    known? = Map.has_key?(state.registry, sig)
    cooldown = under_cooldown(state.registry[sig], now, cooldown_ms)

    registry = upsert(state.registry, sig, reason, now)
    wal = write_wal(state.wal_path, registry)
    state = schedule_sync(%{state | registry: registry})

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
  # carries the two fields cross-machine, otherwise every sync would erase the cooldown ~2s
  # after each note and the issue storm would resume.
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

    _ = write_wal(state.wal_path, registry)
    {:reply, :ok, schedule_sync(%{state | registry: registry})}
  end

  @impl true
  def handle_info(:sync_forge, state) do
    state = %{state | sync_pending: false}

    case sync_forge(state.registry, state.opts) do
      {:ok, merged} ->
        _ = write_wal(state.wal_path, merged)
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

  defp upsert(registry, sig, reason, now) do
    entry =
      registry
      |> Map.get(sig, %{"count" => 0, "first_seen" => now})
      |> Map.update("count", 1, &(&1 + 1))
      |> Map.put("last_seen", now)
      |> Map.put("last_reason", inspect(reason))

    registry |> Map.put(sig, entry) |> prune()
  end

  # PRUNE (E4): the registry would otherwise be the runtime's only structurally UNBOUNDED state (no eviction,
  # merge = monotone union, signatures with open cardinality via stringified reasons) — months
  # of varied incidents would mean endless growth of the WAL + of the forge file REWRITTEN IN FULL on each note.
  # Eviction by last_seen (ISO lexicographic = chronological) beyond `:max_entries`
  # (default 500 — well above nominal; the bound targets the anomaly). Applied to the upsert AND the
  # forge merge (both growth paths).
  defp prune(registry) do
    max = Application.get_env(:fleet_pilot, :incident_registry_max_entries, 500)

    if map_size(registry) <= max do
      registry
    else
      registry
      |> Enum.sort_by(fn {_sig, e} -> e["last_seen"] || "" end, :desc)
      |> Enum.take(max)
      |> Map.new()
    end
  end

  # Read-modify-write with MERGE: absorbs incidents posted by other machines since the last sync
  # (instead of overwriting). Same 3-case DISCIPLINE as `read_wal/1` below — an unreadable forge is NOT an
  # empty one:
  #   * read OK           → merge the real forge content, update it (with its sha);
  #   * genuine 404       → no file yet → CREATE from the local view (empty merge, nil sha);
  #   * unreadable (5xx/  → we do NOT know the forge's real content → pushing our LOCAL view would
  #     network/timeout)    OVERWRITE cross-machine incidents we could not read (data loss). Fail-closed:
  #                         `{:error, _}`, no PUT — the handler retries (data stays safe in the WAL).
  defp sync_forge(registry, opts) do
    getter = Keyword.get(opts, :get_file_fun, &ForgeClient.Files.get_file/3)
    putter = Keyword.get(opts, :put_file_fun, &ForgeClient.Files.put_file/4)

    case getter.(repo(opts), path(opts), ref: branch(opts)) do
      {:ok, %{content: content, sha: sha}} ->
        put_merged(registry, decode(content), sha, putter, opts)

      {:error, :not_found} ->
        put_merged(registry, %{}, nil, putter, opts)

      {:error, reason} ->
        Logger.error(
          "IncidentRegistry: sync_forge — forge registry UNREADABLE (#{inspect(reason)}) — NOT pushing " <>
            "(a push over an unread forge could overwrite cross-machine incidents); the sync will retry"
        )

        {:error, {:forge_unreadable, reason}}

      other ->
        {:error, {:forge_unexpected_shape, other}}
    end
  end

  defp put_merged(registry, forge_reg, sha, putter, opts) do
    merged = registry |> merge(forge_reg) |> prune()
    ident = author(opts)

    put_opts = [
      branch: branch(opts),
      message: "ops(incident): sync registre",
      sha: sha,
      author: ident,
      committer: ident
    ]

    case putter.(repo(opts), path(opts), encode_registry(merged), put_opts) do
      {:ok, _} -> {:ok, merged}
      {:error, _} = err -> err
    end
  end

  defp read_wal(path) do
    # DISTINGUISH the 3 cases: a MISSING WAL (`:enoent`) is a fresh install → empty is normal & silent.
    # A PRESENT-but-unreadable or unparseable WAL is DATA LOSS: the cross-session incident memory is wiped
    # → recurrences stop being detected → escalations never fire, while boot would otherwise report
    # "0 signatures" as if nominal. We still return `%{}` (never crash boot) but LOUD, not silent.
    # NB: `Jason.decode` DIRECTLY, not the local `decode/1` — the latter swallows a parse error into `%{}`
    # (so a corrupt WAL would look like a valid-empty one). Here we MUST see the `{:error, _}` to log it.
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, reg} when is_map(reg) ->
            drop_non_map_entries(reg, "WAL #{path}")

          other ->
            # A present-but-unparseable WAL is CORRUPTED CONTENT, and the next `write_wal` would
            # rename a fresh registry over it — erasing the only forensic trace of what corrupted the
            # cross-machine memory. QUARANTINE it aside first (never auto-replaced): the evidence is
            # kept, the fresh WAL lands on a clean path. Boot proceeds from empty, LOUD.
            quarantined = quarantine_corrupt_wal(path)

            Logger.error(
              "IncidentRegistry: WAL #{path} present but UNPARSEABLE (#{inspect(other)}) — cross-session " <>
                "incident memory LOST (recurrences won't be detected until it is rebuilt). Corrupt file " <>
                "quarantined at #{inspect(quarantined)}; starting from empty."
            )

            %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.error(
          "IncidentRegistry: WAL #{path} unreadable (#{inspect(reason)}) — cross-session incident " <>
            "memory unavailable this boot (recurrences won't be detected). Starting from empty."
        )

        %{}
    end
  end

  # Moves a corrupt WAL aside to `<path>.corrupt-<unix>` so the fresh registry never overwrites it
  # (the evidence of the corruption is preserved for inspection). `os_time` collides only within the
  # same second — acceptable for a forensic artifact; a rename failure is itself logged and returns nil
  # (boot must not crash on a quarantine hiccup — the corruption is already the reported condition).
  defp quarantine_corrupt_wal(path) do
    dest = "#{path}.corrupt-#{System.os_time(:second)}"

    case File.rename(path, dest) do
      :ok ->
        dest

      {:error, reason} ->
        Logger.error(
          "IncidentRegistry: could not quarantine corrupt WAL #{path} (#{inspect(reason)}) — " <>
            "the next write may overwrite it; move it aside by hand before it is lost"
        )

        nil
    end
  end

  defp write_wal(path, registry) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, encode_registry(registry)), :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.error("IncidentRegistry: WAL write failed (#{path}): #{inspect(reason)}")
        {:error, reason}
    end
  end

  # `{:ok, map}` on a readable file, `:absent` on a genuine 404 (never written yet — no memory to
  # lose), `{:error, reason}` on an UNREADABLE forge (down/transport). The caller must not turn an
  # unreadable backing into a silent empty registry: on a fresh node (no WAL) the forge IS the only
  # cross-machine memory, and `%{}` there would replay every past recurrence as a first occurrence.
  defp load_forge(opts) do
    getter = Keyword.get(opts, :get_file_fun, &ForgeClient.Files.get_file/3)

    case getter.(repo(opts), path(opts), ref: branch(opts)) do
      {:ok, %{content: content}} -> {:ok, decode(content)}
      {:error, :not_found} -> :absent
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(content) do
    case Jason.decode(content) do
      {:ok, reg} when is_map(reg) ->
        drop_non_map_entries(reg, "forge file")

      _ ->
        # The file EXISTED but its content is not a JSON map — real amnesia, not an absence.
        Logger.error(
          "IncidentRegistry: forge registry file CORRUPT (not a JSON map) — treated as empty; " <>
            "cross-machine memory is lost until the file is overwritten by the next sync"
        )

        %{}
    end
  end

  # The registry file lives on the SHARED forge (work/ops) and the WAL on local disk — both
  # hand-editable. A non-map VALUE under a signature ({"sig": "garbage"}) would enter RAM,
  # contaminate the WAL, then raise in merge_entry during handle_continue(:load) → boot-loop
  # REPRODUCIBLE at every reboot until the file is repaired by hand. Same doctrine as the
  # unparseable WAL above: visible memory loss (LOUD drop), never a boot crash.
  defp drop_non_map_entries(reg, origin) do
    {maps, bad} = Map.split_with(reg, fn {_sig, v} -> is_map(v) end)

    if map_size(bad) > 0 do
      Logger.error(
        "IncidentRegistry: #{map_size(bad)} non-map entrie(s) dropped from #{origin} " <>
          "(sigs: #{inspect(Map.keys(bad))}) — repair the file; the incident memory of these " <>
          "signatures is lost (their recurrences will look like first occurrences)."
      )
    end

    maps
  end

  # Encode the registry with ONE incident per line, sorted keys. The git diff of the file (committed on
  # work/ops AND the local WAL) then shows an added incident = an added line, instead of a single-line
  # JSON blob where the slightest addition rewrites everything. Stays valid JSON — `decode/1` reads it as
  # is; sorting by key guarantees a stable order (otherwise map order would make noise in the diff).
  defp encode_registry(registry) when map_size(registry) == 0, do: "{}\n"

  defp encode_registry(registry) do
    body =
      registry
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",\n", fn {k, v} -> "  #{Jason.encode!(k)}: #{Jason.encode!(v)}" end)

    "{\n" <> body <> "\n}\n"
  end

  defp merge(a, b), do: Map.merge(a, b, fn _sig, ea, eb -> merge_entry(ea, eb) end)

  defp merge_entry(a, b) do
    # Defensive net BEHIND drop_non_map_entries (decode/read_wal filter at both load points):
    # a non-map can only reach here through a NEW load path — coerce, never raise at boot.
    a = if is_map(a), do: a, else: %{}
    b = if is_map(b), do: b, else: %{}

    # Escalation memory: the LATEST escalation wins as a PAIR (stamp + its issue — a max on
    # each field separately could marry the new stamp with the old issue number). Old entries
    # (pre-cooldown WAL/forge) have neither field → nils, dropped below (back-compat).
    {esc_at, esc_issue} =
      if (a["last_escalated_at"] || "") >= (b["last_escalated_at"] || "") do
        {a["last_escalated_at"], a["escalated_issue"]}
      else
        {b["last_escalated_at"], b["escalated_issue"]}
      end

    base = %{
      "count" => max(a["count"] || 0, b["count"] || 0),
      "first_seen" => min_iso(a["first_seen"], b["first_seen"]),
      "last_seen" => max_iso(a["last_seen"], b["last_seen"]),
      "last_reason" => later_reason(a, b)
    }

    if is_nil(esc_at) do
      base
    else
      Map.merge(base, %{"last_escalated_at" => esc_at, "escalated_issue" => esc_issue})
    end
  end

  defp min_iso(nil, b), do: b
  defp min_iso(a, nil), do: a
  defp min_iso(a, b), do: min(a, b)

  defp max_iso(nil, b), do: b
  defp max_iso(a, nil), do: a
  defp max_iso(a, b), do: max(a, b)

  defp later_reason(a, b),
    do:
      if((a["last_seen"] || "") >= (b["last_seen"] || ""),
        do: a["last_reason"],
        else: b["last_reason"]
      )

  # --- config (opts > app env > default) ---
  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp now(opts), do: opts[:now] || DateTime.to_iso8601(DateTime.utc_now())

  # Recurrence cooldown of the sysadmin escalation: default 1 h (a durable failure keeps ONE
  # open issue as its alarm instead of one per tick — otherwise ~2 880 issues/day,
  # self-amplified by the webhook kick). Seam `:escalation_cooldown_ms` (tests) overrides the
  # config knob. Entries without a stamp (pre-cooldown WAL/forge, or escalation never done)
  # → nil → the gate lets the escalation through (back-compat = old behavior).
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
      Application.get_env(:fleet_pilot, :incident_escalation_cooldown_ms, @escalation_cooldown_ms)
  end

  defp debounce_ms(opts), do: opts[:sync_debounce_ms] || @sync_debounce_ms
  defp retry_ms(opts), do: opts[:retry_ms] || @retry_ms

  # SINGLE ops-repo authority (`:ops_repo`): the incident REGISTRY (this file, work/ops branch) and
  # the sysadmin ISSUES it opens (`Escalation`) must land on the SAME repo — they are two faces of
  # one incident. Two separate keys with two inline defaults would sit one edit away from
  # a registry on repo A and its issues on repo B, with nothing to catch it. `:incident_registry_repo`
  # survives as an explicit override for the rare split.
  defp repo(opts),
    do:
      opts[:repo] || Application.get_env(:fleet_pilot, :incident_registry_repo) ||
        Fleet.Pilot.IncidentRegistry.Escalation.ops_repo()

  defp branch(opts),
    do: opts[:branch] || Application.get_env(:fleet_pilot, :incident_registry_branch, "work/ops")

  defp path(opts),
    do:
      opts[:path] ||
        Application.get_env(:fleet_pilot, :incident_registry_path, "work/system-incidents.json")

  # HOME unresolvable = broken runtime → fail-loud (`System.user_home!()` raises), never a fabricated
  # path: the .lcars state must not silently scatter (e.g. orphaned under /tmp).
  defp wal_path(opts),
    do:
      opts[:wal_path] || Application.get_env(:fleet_pilot, :incident_registry_wal_path) ||
        Path.join(Fleet.Layout.state_dir(), "system-incidents.json")

  # The registry sync is a commit the RUNTIME makes: no human initiated it, no pod produced it, and
  # no pod could — a pod never holds the forge token. Its identity is therefore the SYSTEM one, like
  # the other two runtime-generated commits (`Workflow.OpsObject`, `Pilot.ProjectOnboard`), through
  # the single accessor rather than a literal retyped at the caller.
  #
  # Never a ROLE here: `ForgeIdentity` splits the three identities on purpose — author = the human,
  # role = a VERIFIED TRAILER, committer = the system. `role_email/1` builds that trailer (its only
  # other caller is `coauthor_trailer/1`); as an author email it would sign a system act under a pod
  # that does not touch the forge at all.
  defp author(opts),
    do:
      opts[:author] ||
        Application.get_env(
          :fleet_pilot,
          :incident_registry_author,
          Fleet.Credentials.ForgeIdentity.system_identity()
        )

  defp normalize(subject), do: Regex.replace(~r/\d+/, subject, "N")

  # The recurrence category IS the FIRST projection of the canonical
  # `Fleet.Event.reason_fields/1` (the single source of the atom/tuple/binary/other split, used on the
  # broadcast path). A local copy of the clauses would silently drift the incident dedup key from the
  # event category — same split, two owners. Consume the canonical projection instead.
  defp reason_category(reason), do: elem(Fleet.Event.reason_fields(reason), 0)
end
