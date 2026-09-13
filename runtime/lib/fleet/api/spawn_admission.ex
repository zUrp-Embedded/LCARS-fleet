defmodule Fleet.API.SpawnAdmission do
  @moduledoc """
  Admission for POST /api/admin/spawn before asynchronous event emission.
  The flat allowlist prevents clients supplying internal spawner opts (roots,
  identity, project cloning or resume seams); only reconstructed opts are emitted.

  Order: allowlist and pod-id/issue-id checks, effective profile resolution including
  default modops, containment, fleet-slot check, then the shared brief-required guard.
  Non-bwrap profiles require the literal host_native_ack:true; this acknowledgment
  is not broadcast. It is request data, not proof of who supplied it.

  Fleet role_index:0 is checked against a snapshot of matching live roles, without
  reserving the slot. Admission and dispatch are not atomic and do not prove launch.
  ControlRouter maps refusals to HTTP status; this module has no HTTP authentication.
  """

  alias Fleet.CapProfile
  alias Fleet.EventRouter.Bus

  @typedoc """
  ControlRouter maps missing profile to 400, occupied fleet slot to 409, others to 422.
  """
  @type refusal ::
          {:forbidden_fields, [String.t()]}
          | {:invalid_pod_id, term()}
          | {:invalid_issue_id, term()}
          | :missing_cap_profile
          | {:cap_profile, String.t(), term()}
          | {:role_reserved, String.t()}
          | {:host_native_forbidden, String.t()}
          | {:fleet_scope_occupied, String.t(), String.t()}
          | :brief_required

  @admin_spawn_public_fields ~w(cap_profile_name role issue_id brief pod_id host_native_ack)

  @doc """
  Validates a request body and returns its canonical broadcast payload or the
  first refusal. Non-map bodies are treated as empty DTOs.
  """
  @spec admit(term()) :: {:ok, map()} | {:error, refusal()}
  def admit(raw) do
    with {:ok, payload} <- parse_admin_spawn_dto(raw),
         {:ok, cap} <- validate_cap_profile(payload, host_native_ack?(raw)),
         :ok <- check_fleet_scope_free(cap),
         :ok <- check_brief_required(payload, cap) do
      {:ok, payload}
    end
  end

  @doc """
  Emits an admitted payload as `admin.spawn.request`, translating event
  construction and registry errors into error tuples.
  """
  @spec broadcast(map()) :: :ok | {:error, term()}
  def broadcast(payload) do
    Bus.emit(:api, :"admin.spawn.request", payload: payload)
  rescue
    e in Fleet.Event.UnregisteredError -> {:error, e.message}
    e in [ArgumentError, FunctionClauseError] -> {:error, inspect(e)}
  end

  defp parse_admin_spawn_dto(raw) when is_map(raw) do
    extraneous = Map.keys(raw) -- @admin_spawn_public_fields

    if extraneous != [] do
      {:error, {:forbidden_fields, extraneous}}
    else
      with {:ok, opts} <- build_admin_opts(raw),
           :ok <- validate_issue_id(raw) do
        payload =
          raw
          |> Map.take(["cap_profile_name", "role", "issue_id"])
          |> Map.reject(&blank_identity_key?/1)
          |> maybe_put_opts(opts)

        {:ok, payload}
      end
    end
  end

  defp parse_admin_spawn_dto(_), do: {:ok, %{}}

  defp validate_issue_id(raw) do
    case Map.fetch(raw, "issue_id") do
      :error -> :ok
      {:ok, issue_id} when is_binary(issue_id) -> :ok
      {:ok, other} -> {:error, {:invalid_issue_id, other}}
    end
  end

  defp build_admin_opts(raw) do
    # Admin spawns self-enqueue; dispatched spawns leave enqueue ownership to the dispatcher.
    opts =
      if is_binary(raw["brief"]),
        do: %{"brief" => raw["brief"], "self_enqueue_brief" => true},
        else: %{}

    case Map.fetch(raw, "pod_id") do
      :error ->
        {:ok, opts}

      {:ok, pod_id} when is_binary(pod_id) ->
        if valid_pod_id?(pod_id),
          do: {:ok, Map.put(opts, "pod_id", pod_id)},
          else: {:error, {:invalid_pod_id, pod_id}}

      {:ok, other} ->
        {:error, {:invalid_pod_id, other}}
    end
  end

  defp maybe_put_opts(payload, opts) when map_size(opts) == 0, do: payload
  defp maybe_put_opts(payload, opts), do: Map.put(payload, "opts", opts)

  defp valid_pod_id?(id), do: Fleet.Spawner.valid_pod_id?(id)

  # Empty/nonbinary profile names must not shadow the role fallback.
  defp blank_identity_key?({k, v}), do: k in ["cap_profile_name", "role"] and presence(v) == nil

  defp presence(v) when is_binary(v) and v != "", do: v
  defp presence(_), do: nil

  # Check catalogued? before role_index, which raises without a valid index.
  defp check_fleet_scope_free(cap) do
    name = CapProfile.name(cap)

    if CapProfile.catalogued?(cap) and CapProfile.role_index(cap) == 0 do
      # A pod info map may omit :role; an unrelated short map must not crash admission.
      case Enum.find(Fleet.Spawner.list_pods(), &(Map.get(&1, :role) == name)) do
        nil -> :ok
        pod -> {:error, {:fleet_scope_occupied, name, Map.get(pod, :pod_id, "unknown")}}
      end
    else
      :ok
    end
  end

  defp admit_containment(cap, name, ack?) do
    cond do
      CapProfile.bwrap?(cap) -> {:ok, cap}
      ack? -> {:ok, cap}
      true -> {:error, {:host_native_forbidden, name}}
    end
  end

  defp host_native_ack?(raw) when is_map(raw), do: raw["host_native_ack"] == true
  defp host_native_ack?(_), do: false

  defp validate_cap_profile(payload, ack?) do
    case CapProfile.name_from_request(payload) do
      name when is_binary(name) ->
        # Admission gates the effective profile, including default modops.
        case CapProfile.resolve(CapProfile, name) do
          {:ok, cap} ->
            admit_containment(cap, name, ack?)

          # Preserve reserved-seat refusal separately from an unresolved profile.
          {:error, {:role_reserved, _} = reserved} ->
            {:error, reserved}

          {:error, reason} ->
            {:error, {:cap_profile, name, reason}}
        end

      _ ->
        {:error, :missing_cap_profile}
    end
  end

  defp check_brief_required(payload, cap) do
    brief = get_in(payload, ["opts", "brief"])
    has_brief? = is_binary(brief) and brief != ""

    if Fleet.Spawner.brief_required?(cap) and not has_brief?,
      do: {:error, :brief_required},
      else: :ok
  end
end
