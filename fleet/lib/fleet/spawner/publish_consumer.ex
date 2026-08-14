defmodule Fleet.Spawner.PublishConsumer do
  @moduledoc """
  Consumes canonical `admin.spawn.request` events and dispatches
  `Fleet.Spawner.spawn_pod/3`. Every post-202 dispatch failure emits
  `spawn.failed`; malformed or failed requests never crash the consumer.

  It ALSO relays `github_publish.{done,failed}` back to the requesting pod (`requester_pod_id`
  in the payload) via `notify_pod`: the wake channel is the only server->pod path (MCP is
  pull-only), and the pod that asked to publish gets its own answer. This lives here because
  `notify_pod` is a Spawner act; the MCP worker only emits the outcome on the bus. Best-effort by
  design (the wake is a courtesy — the durable truth is the PR/MR on the forge), never a crash.
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
  def handle_info(
        %Fleet.Event{source: :api, type: :"admin.spawn.request", payload: payload},
        state
      )
      when is_map(payload) do
    try do
      handle_spawn_request(payload, state)
    rescue
      e ->
        reason = Exception.message(e)

        Logger.error(
          "PublishConsumer: handle_spawn_request RAISED — spawn DROPPED while the API already answered 202 " <>
            "\"queued\" (the admin believes the pod is queued) — #{reason}"
        )

        emit_spawn_failed(payload, reason)
    catch
      # F-06: exits and throws must alarm just like exceptions.
      kind, reason ->
        Logger.error(
          "PublishConsumer: handle_spawn_request #{kind} — spawn DROPPED while the API already " <>
            "answered 202 \"queued\" — #{inspect(reason)}"
        )

        emit_spawn_failed(payload, {kind, reason})
    end

    {:noreply, %{state | count: state.count + 1}}
  end

  # Relay a finished publish back to the pod that asked for it. Only when `requester_pod_id` is a
  # real pod (a caller without one falls through to the ignore clause).
  def handle_info(
        %Fleet.Event{type: :"github_publish.done", payload: %{"requester_pod_id" => pod} = p},
        state
      )
      when is_binary(pod) do
    repo = Map.get(p, "repo", "?")
    url = Map.get(p, "url", "")
    msg = if url == "", do: "publish #{repo}: rien a publier (deja a jour)", else: "publish #{repo} -> #{url}"
    notify_requester(state, pod, msg)
    {:noreply, state}
  end

  def handle_info(
        %Fleet.Event{type: :"github_publish.failed", payload: %{"requester_pod_id" => pod} = p},
        state
      )
      when is_binary(pod) do
    repo = Map.get(p, "repo", "?")
    reason = Map.get(p, "reason_detail") || Map.get(p, "reason", "?")
    notify_requester(state, pod, "publish #{repo} ECHEC: #{reason}")
    {:noreply, state}
  end

  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # Best-effort wake — a dead/absent pod yields {:error, _} (logged in notify_pod), and any raise is
  # swallowed: a failed courtesy notification must never take down the spawn-dispatch consumer.
  defp notify_requester(state, pod, msg) do
    state.spawner.notify_pod(pod, msg)
  rescue
    e ->
      Logger.warning("PublishConsumer: notify_pod #{pod} raised — #{Exception.message(e)}")
      :ok
  end

  defp handle_spawn_request(payload, state) do
    # Re-parse the unauthenticated bus payload at this dispatch boundary.
    name = Fleet.CapProfile.name_from_request(payload)

    issue_id = Map.get(payload, "issue_id") || ""

    opts = Map.get(payload, "opts", []) |> to_keyword()

    if is_nil(name) do
      Logger.warning(
        "PublishConsumer: admin.spawn.request invalid — name missing/empty " <>
          "(payload=#{inspect(payload)})"
      )

      # F-C044
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

              # F-C044
              emit_spawn_failed(payload, {:spawn_pod, reason})
          end

        {:error, reason} ->
          Logger.warning(
            "PublishConsumer: CapProfile.load fail name=#{name} reason=#{inspect(reason)}"
          )

          # F-C044
          emit_spawn_failed(payload, {:cap_profile_load, reason})
      end
    end
  end

  # Alarm loss is non-fatal but loud: the original request was already acknowledged.
  defp emit_spawn_failed(payload, reason) when is_map(payload) do
    # Keep the signature stable and JSON-safe; variable detail remains separate.
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
  Converts payload options to the closed admin-spawn allowlist without creating atoms.
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
