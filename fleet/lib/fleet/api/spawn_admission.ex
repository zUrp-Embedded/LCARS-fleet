defmodule Fleet.API.SpawnAdmission do
  @moduledoc """
  ADMISSION pipeline for `POST /api/admin/spawn` — the POLICY of the API's
  only write, separated from the HTTP routing:
  `Fleet.API.ControlRouter` (the write door) maps each verdict returned here onto its HTTP
  status, this module decides WHO passes. Pure functions + catalog reads (no process).

  ## Why a strict admission on a no-auth surface

  `/api/admin/spawn` is no-auth (boundary = the AF_UNIX socket's `0600` mode and container
  isolation, cf. `Fleet.API.ControlRouter` — la surface TCP qui portait cette doctrine a ete
  supprimee le 2026-08-14). The `PublishConsumer` THEN converts
  `payload["opts"]` into internal spawner opts via `to_keyword/1` — without a
  filter, privileged opts (`pod_dir_root`, `state_fs_root`, `human`,
  `project` → clone of an attacker repo into the pod, `recall_seed_jsonl`,
  `resume`, `session_id`, `rc_name`, `allow_no_brief`, module/fun seams…)
  would become drivable from the API. The pipeline (fixed order):

    1. **DTO allowlist** (`@admin_spawn_public_fields`) — only a FLAT public
       DTO is admitted; any unknown key (including a raw `opts`) →
       `{:error, {:forbidden_fields, …}}` BEFORE the slightest broadcast. The
       canonical payload rebuilt here is the ONLY thing broadcast — the API
       builds the internal `opts` itself.
    2. **path-safe `pod_id`** — a pod_id is interpolated into FS paths
       (`~/pods/pod_<id>`): only the charset `[A-Za-z0-9._-]` without `..` passes
       (authority `Fleet.Spawner.valid_pod_id?/1`, not a copied regex).
    3. **Loadable cap-profile** — validated BEFORE the ACK: if the 202 left as
       soon as the broadcast happened, a non-existent `cap_profile_name` would
       be detected ONLY in `PublishConsumer` (mere warning, ZERO pod) → lying
       202. Same loader as the consumer (single source `Fleet.CapProfile.load/1`).
    4. **Host-native refused** — a `containment: none` cap-profile would launch
       a pod OUT-OF-SANDBOX on the host *as* the human (the strongest power
       of the fleet) via this generic no-auth door. Made UNREPRESENTABLE
       by this path: refusal at admission, host-native keeps its dedicated
       out-of-band path (`bin/host_launch.sh`, an off-fleet interactive session).
       Fail-closed — a defensive guard even though no canon profile is host-native
       since the 2026-07-19 reorg (starfleet became an ordinary bwrap orchestrator).
    5. **Fleet-scope singleton already alive** — `role_index: 0` is the fleet-level slot: ONE per
       fleet, by construction (the reaper spares it, its session UUID carries no project). The door
       did not know, so `lcars spawn starfleet` next to a running permanent was ADMITTED: a second
       pod, a random UUID, nothing ever addressed to it, twelve wake attempts and an incident whose
       message says the agent never acked — the symptom, never the cause. Refused here, naming the
       pod that holds the slot and the gesture that works, because the operator who typed the
       obvious command has no way to learn it otherwise.
    6. **Brief required for a one-shot** — MIRROR of `Fleet.Spawner.brief_guard`
       (`Fleet.Spawner.brief_guard`): a one-shot without `brief` would leave
       without work → the spawner would refuse it (ZERO pod), so the 202 would lie.
       `Fleet.Spawner.brief_required?/1` IS the shared authority (no copied
       rule, no possible divergence).

  `broadcast/1` (the post-admission step) emits the canonical schema
  `%Fleet.Event{source: :api}` — an out-of-registry or malformed event becomes
  `{:error, _}` (HTTP 400 surface on the ControlRouter side), never a handler crash.
  """

  alias Fleet.EventRouter.Bus

  @typedoc """
  Admission-refusal verdicts — each mapped onto ONE HTTP status by
  `Fleet.API.ControlRouter`: 400 for `:missing_cap_profile` (the request is malformed), 409 for
  `{:fleet_scope_occupied, …}` (the request is well-formed and the fleet's state says no — retrying
  it later can succeed, which is exactly what 409 means and 422 does not), 422 for the rest.
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

  @admin_spawn_public_fields ~w(cap_profile_name role issue_id brief pod_id)

  @doc """
  Validates a request body and returns its canonical broadcast payload or the
  first refusal. Non-map bodies are treated as empty DTOs.
  """
  @spec admit(term()) :: {:ok, map()} | {:error, refusal()}
  def admit(raw) do
    with {:ok, payload} <- parse_admin_spawn_dto(raw),
         {:ok, cap} <- validate_cap_profile(payload),
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
          |> Map.reject(fn {k, v} ->
            k in ["cap_profile_name", "role"] and presence(v) == nil
          end)
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

  defp presence(v) when is_binary(v) and v != "", do: v
  defp presence(_), do: nil

  # `catalogued?/1` first: `role_index/1` RAISES on a profile without a valid one, and an admission
  # gate is the wrong place to discover that a catalogue is malformed — the image refuses that at
  # boot. Here, no valid index simply means "not the fleet-scope slot".
  defp check_fleet_scope_free(cap) do
    name = Fleet.CapProfile.name(cap)

    if Fleet.CapProfile.catalogued?(cap) and Fleet.CapProfile.role_index(cap) == 0 do
      # `Map.get`, never dot access: `list_pods/0` is specced `[map()]` and makes no promise about
      # the keys. A pod whose `:info` lacks `:role` raised a KeyError THROUGH the router — the whole
      # spawn door answering 500 because one unrelated pod answered a short map. A guard that can
      # crash the door it guards is worse than the hole it closes.
      case Enum.find(Fleet.Spawner.list_pods(), &(Map.get(&1, :role) == name)) do
        nil -> :ok
        pod -> {:error, {:fleet_scope_occupied, name, Map.get(pod, :pod_id, "unknown")}}
      end
    else
      :ok
    end
  end

  defp validate_cap_profile(payload) do
    case Fleet.CapProfile.name_from_request(payload) do
      name when is_binary(name) ->
        # Admission gates the effective profile, including default modops.
        case Fleet.CapProfile.resolve(Fleet.CapProfile, name) do
          {:ok, cap} ->
            if Fleet.CapProfile.bwrap?(cap),
              do: {:ok, cap},
              else: {:error, {:host_native_forbidden, name}}

          # A ReservedSeat is its OWN refusal (BL-6-45), not an "unknown cap_profile": the seat
          # exists, the box is closed — wrapped as {:cap_profile, ...} the router would render
          # a declared state as an unknown-name error.
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
