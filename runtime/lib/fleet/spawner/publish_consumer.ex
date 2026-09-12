defmodule Fleet.Spawner.PublishConsumer do
  @moduledoc """
  Dispatches canonical API `admin.spawn.request` events to `Fleet.Spawner.spawn_pod/3`.
  Dispatch errors, exceptions and exits trigger `spawn.failed` after the API's 202;
  failed alarm emission is logged.

  Relays `project_publish.{done,failed}` to `requester_pod_id` through `notify_pod`.
  This notification is best-effort; the durable publish outcome lives on the forge.
  Spawner owns the notification, while the MCP worker emits the outcome on the Bus.
  """

  use GenServer
  require Logger

  alias Fleet.Event
  alias Fleet.EventRouter.Bus

  @spec start_link(keyword()) :: GenServer.on_start()
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
        %Event{source: :api, type: :"admin.spawn.request", payload: payload},
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
      kind, reason ->
        Logger.error(
          "PublishConsumer: handle_spawn_request #{kind} — spawn DROPPED while the API already " <>
            "answered 202 \"queued\" — #{inspect(reason)}"
        )

        emit_spawn_failed(payload, {kind, reason})
    end

    {:noreply, %{state | count: state.count + 1}}
  end

  def handle_info(
        %Event{type: :"project_publish.done", payload: %{"requester_pod_id" => pod} = p},
        state
      )
      when is_binary(pod) do
    repo = Map.get(p, "repo", "?")
    url = Map.get(p, "url", "")
    manual = Map.get(p, "manual", false)

    msg =
      cond do
        url == "" -> "publish #{repo}: rien a publier (deja a jour)"
        manual -> "publish #{repo}: pousse, ouvre la PR/MR -> #{url}"
        true -> "publish #{repo} -> #{url}"
      end

    notify_requester(state, pod, msg)
    {:noreply, state}
  end

  def handle_info(
        %Event{type: :"project_publish.failed", payload: %{"requester_pod_id" => pod} = p},
        state
      )
      when is_binary(pod) do
    repo = Map.get(p, "repo", "?")
    reason = Map.get(p, "reason_detail") || Map.get(p, "reason", "?")
    notify_requester(state, pod, "publish #{repo} ECHEC: #{reason}")
    {:noreply, state}
  end

  def handle_info(%Event{}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # Notification exceptions must not interrupt spawn dispatch.
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

      emit_spawn_failed(payload, :name_missing_or_empty)
    else
      Fleet.CapProfile.resolve(Fleet.CapProfile, name)
      |> spawn_resolved(payload, state, {name, issue_id, opts})
    end
  end

  # Distinguish profile-resolution errors from failures to start a resolved profile.
  defp spawn_resolved({:ok, cap_profile}, payload, state, {name, issue_id, opts}) do
    case state.spawner.spawn_pod(cap_profile, to_string(issue_id), opts) do
      {:ok, _pod_ref} ->
        Logger.info("PublishConsumer: spawn dispatched name=#{name} issue=#{issue_id}")

      {:error, reason} ->
        Logger.warning(
          "PublishConsumer: spawn_pod fail name=#{name} issue=#{issue_id} " <>
            "reason=#{inspect(reason)}"
        )

        emit_spawn_failed(payload, {:spawn_pod, reason})
    end
  end

  defp spawn_resolved({:error, reason}, payload, _state, {name, _issue_id, _opts}) do
    Logger.warning("PublishConsumer: CapProfile.load fail name=#{name} reason=#{inspect(reason)}")

    emit_spawn_failed(payload, {:cap_profile_load, reason})
  end

  defp emit_spawn_failed(payload, reason) when is_map(payload) do
    # Keep the signature stable and JSON-safe; variable detail remains separate.
    {reason_cat, reason_detail} = Event.reason_fields(reason)

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

  @spec to_keyword(term()) :: keyword()
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
