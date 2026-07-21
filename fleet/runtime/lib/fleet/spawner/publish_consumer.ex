defmodule Fleet.Spawner.PublishConsumer do
  @moduledoc """
  Consumer of the `admin.spawn.request` broadcast.

  Subscribes to `Fleet.EventRouter.Bus` topic `fleet.events`, filters
  `:"admin.spawn.request"`, dispatches `Fleet.Spawner.spawn_pod/3`.

  Expected payload (SpawnAdmission broadcasts the PARSED DTO):
    * `"cap_profile_name"` or `"role"` — non-empty string, canonical CapProfile name
      (loaded via `Fleet.CapProfile.load/1`)
    * `"issue_id"` — string (absent → defaults to `""`; no envelope fallback — the canonical
      `%Fleet.Event{}` carries issue_id in the payload)
    * `"opts"` — keyword map (optional)

  Errors (load fail / spawn fail) → log warning, **no crash**
  (the consumer stays alive, non-fatal fail-loud). The chain MUST be
  wired end-to-end: broadcast→consume→spawn is end-to-end; without the
  consumer, /api/admin/spawn returns HTTP 202 but spawns nothing
  (success shown, zero pods).

  Test-seam: `:subscribe` (default true) + `:spawner` backend
  (default `Fleet.Spawner`, overridable for a mock).

  **Last revised**: 2026-07-21
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()
    spawner = Keyword.get(opts, :spawner, Fleet.Spawner)
    {:ok, %{spawner: spawner, count: 0}}
  end

  @impl true
  # Strict canonical schema.
  def handle_info(
        %Fleet.Event{source: :api, type: :"admin.spawn.request", payload: payload},
        state
      )
      when is_map(payload) do
    try do
      handle_spawn_request(payload, state)
    rescue
      e ->
        # The dispatch RAISED → the spawn is dropped. BUT the REST API already answered HTTP 202 "queued"
        # to the client BEFORE this async processing (broadcast→consume→spawn): with no signal, the admin
        # believes the pod is queued when it does not exist (success shown, zero pods, zero alarm). We log ERROR
        # (load-bearing) AND emit `spawn.failed` on the Bus — spawn-cycle alarm, twin of
        # `pod.failed`. The consumer stays alive (non-fatal rescue): a drop does not kill the broker.
        reason = Exception.message(e)

        Logger.error(
          "PublishConsumer: handle_spawn_request RAISED — spawn DROPPED while the API already answered 202 " <>
            "\"queued\" (the admin believes the pod is queued) — #{reason}"
        )

        emit_spawn_failed(payload, reason)
    catch
      # Codex audit F-06 (2026-07-19): `rescue` covers exceptions ONLY — a backend that
      # `exit`s (plausible OTP path: GenServer.call on a dead/unstarted spawner) killed this
      # consumer, and the 202-acked request was lost WITHOUT the spawn.failed alarm (the
      # supervisor restart hid the drop). Same stance for exit and throw: normalize, alarm,
      # stay alive.
      kind, reason ->
        Logger.error(
          "PublishConsumer: handle_spawn_request #{kind} — spawn DROPPED while the API already " <>
            "answered 202 \"queued\" — #{inspect(reason)}"
        )

        emit_spawn_failed(payload, {kind, reason})
    end

    {:noreply, %{state | count: state.count + 1}}
  end

  # No legacy tuple clause `{:"admin.spawn.request", event}`: NO producer emits the
  # `{atom, map}` tuple (all use `%Fleet.Event{}`). The canonical path (the struct clause above)
  # receives the event; a tuple clause would be dead. The `_other` catch-all covers any
  # non-event message.

  # other events broadcast on fleet.events → ignore
  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # `payload` = application map (the canonical %Fleet.Event{} carries issue_id IN the payload).
  defp handle_spawn_request(payload, state) do
    # Single-source `cap_profile_name || role` resolution (C-04): the Bus is no-auth (SpawnAdmission
    # broadcasts a parsed DTO, but any process can emit on fleet.events) — this consumer is a REAL
    # boundary, not defensive re-validation, so it re-parses, but from the SAME authority as admission
    # (`CapProfile.name_from_request`, blank-normalized: a truthy "" never masks a valid `role`).
    name = Fleet.CapProfile.name_from_request(payload)

    issue_id = Map.get(payload, "issue_id") || ""

    opts = Map.get(payload, "opts", []) |> to_keyword()

    if is_nil(name) do
      Logger.warning(
        "PublishConsumer: admin.spawn.request invalid — name missing/empty " <>
          "(payload=#{inspect(payload)})"
      )

      # The API may have ACKed 202 before this async drop → same alarm as the other drop paths
      # (F-C044): the failure must reach the observation read-model, not just the server log.
      emit_spawn_failed(payload, :name_missing_or_empty)
    else
      case Fleet.CapProfile.resolve(Fleet.CapProfile, name) do
        {:ok, cap_profile} ->
          case state.spawner.spawn_pod(cap_profile, to_string(issue_id), opts) do
            {:ok, _pod_ref} ->
              Logger.info("PublishConsumer: spawn dispatched name=#{name} issue=#{issue_id}")

            {:error, reason} ->
              Logger.warning(
                "PublishConsumer: spawn_pod fail name=#{name} issue=#{issue_id} " <>
                  "reason=#{inspect(reason)}"
              )

              # F-C044 — the API already answered 202 "queued"; an ordinary `{:error}` (not only a raise)
              # also DROPS the spawn → emit `spawn.failed` so the drop reaches the read-model observation
              # the admin queries, not just the server log (same alarm as the rescue path).
              emit_spawn_failed(payload, {:spawn_pod, reason})
          end

        {:error, reason} ->
          Logger.warning(
            "PublishConsumer: CapProfile.load fail name=#{name} reason=#{inspect(reason)}"
          )

          # F-C044 — a load failure drops the spawn just as visibly as a spawn_pod failure: alarm it too.
          emit_spawn_failed(payload, {:cap_profile_load, reason})
      end
    end
  end

  # `spawn.failed` alarm (spawn cycle) — emitted when the dispatch of an `admin.spawn.request` RAISED and
  # the spawn is therefore dropped. The rescue protects the PROCESS only (a Bus down must not kill the
  # consumer), BUT the broadcast failure is NOT swallowed silently: Logger.error, because losing
  # the alarm would re-silence the drop we just made visible (consistent with `pod.failed` on the Pod side:
  # an observability signal whose loss never blocks, but is logged loudly when the broadcast breaks).
  # Strict canonical envelope
  # built + broadcast via `Bus.emit` (`source: :spawner`, type `:"spawn.failed"`, present in the events.yaml registry).
  defp emit_spawn_failed(payload, reason) when is_map(payload) do
    # JSON-safe + rail-reaching: "reason" = stable category (tuple reasons {:spawn_pod,_}/
    # {:cap_profile_load,_} would crash the WS edge AND leak variable detail into the
    # IncidentRegistry dedup signature if blindly inspected), detail aside. The subject falls
    # through presence/1 (a truthy "" would mask `role` — the same class handle_spawn_request
    # neutralizes) down to "unknown": the alarm must ALWAYS reach the
    # incident rail with a binary subject (IncidentConsumer guards is_binary(name)).
    {reason_cat, reason_detail} = Fleet.Event.reason_fields(reason)

    result =
      Bus.emit(:spawner, :"spawn.failed",
        payload: %{
          "cap_profile_name" => Fleet.CapProfile.name_from_request(payload) || "unknown",
          "issue_id" => Map.get(payload, "issue_id"),
          "reason" => reason_cat,
          "reason_detail" => reason_detail
        }
      )

    case result do
      :ok ->
        :ok

      {:error, broadcast_reason} ->
        Logger.error(
          "PublishConsumer: broadcast spawn.failed FAILED — dropped-spawn alarm NOT broadcast: " <>
            "#{inspect(broadcast_reason)}"
        )
    end
  rescue
    e ->
      Logger.error(
        "PublishConsumer: broadcast spawn.failed RAISED — dropped-spawn alarm NOT broadcast: " <>
          "#{Exception.message(e)}"
      )
  end

  @doc """
  Converts a payload map (string keys) into a keyword list for `spawn_pod`.

  (atom-leak DoS): `String.to_atom` on arbitrary POST keys
  would allow exhausting the BEAM's atom table. We accept ONLY keys already
  known as atoms (`to_existing_atom`); any unknown key is ignored.
  Public for direct testing (the path through the consumer requires `CapProfile.load` + global
  env → not async-safe).

  Defense in depth: a LIST is returned as-is only if it is already a clean keyword-list
  (`{atom, _}` pairs). A list coming from a decoded JSON array is never one (string keys → a list
  of maps/scalars) — so it would be filtered to `[]` rather than swallowed raw as spawner opts.

  ALLOWLIST (R1-30): beyond the atom-leak filter, only `@allowed_spawn_opts` keys are kept — the DROP
  of everything else is what actually doubles the `/api/admin/spawn` admission lock.
  The allowlist mirrors the SOLE producer
  (`Fleet.API.SpawnAdmission.build_admin_opts`, which emits `brief` + `pod_id` + `self_enqueue_brief`).
  The `self_enqueue_brief` flag authorizes the pod's own brief enqueue — legitimate on THIS
  (admin, no-dispatcher) rail; a forged bus event that set it would only make the pod self-enqueue its
  brief (the slot check still dedups), never an FS/backend escape. The infrastructure
  opts (`pod_dir_root`/`state_fs_root` = FS redirect out of the confined home, `containment` = host-native
  escape, `launch_backend`/`fleet_spawner` = backend override) are all existing atoms → they PASS the
  atom-leak filter, so without an allowlist a forged bus event could inject them. `pod_id` stays
  re-validated by `spawn_pod` itself (T1 `valid_pod_id?`).
  """
  @allowed_spawn_opts ~w(brief pod_id self_enqueue_brief)a

  def to_keyword(map) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      try do
        atom = String.to_existing_atom(to_string(k))
        if atom in @allowed_spawn_opts, do: [{atom, v}], else: []
      rescue
        ArgumentError -> []
      end
    end)
  end

  def to_keyword(list) when is_list(list) do
    if Keyword.keyword?(list), do: Keyword.take(list, @allowed_spawn_opts), else: []
  end

  def to_keyword(_), do: []
end
