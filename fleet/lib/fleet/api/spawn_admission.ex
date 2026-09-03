defmodule Fleet.API.SpawnAdmission do
  @moduledoc """
  ADMISSION pipeline for `POST /api/admin/spawn` — the POLICY of the API's
  only write, separated from the HTTP routing:
  `Fleet.API.ControlRouter` (the write door) maps each verdict returned here onto its HTTP
  status, this module decides WHO passes. Pure functions + catalog reads (no process).

  ## Why a strict admission on a no-auth surface

  `/api/admin/spawn` is no-auth (boundary = the AF_UNIX socket's `0600` mode and container
  isolation, cf. `Fleet.API.ControlRouter`). The `PublishConsumer` THEN converts
  `payload["opts"]` into internal spawner opts via `to_keyword/1` — without a
  filter, privileged opts would become drivable from the API: FS roots, identity,
  session/resume seams, and `project`, which clones an ATTACKER repo into the pod.
  The pipeline (fixed order):

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
    4. **Host-native refused SAUF acquittement explicite** ([BL-6-101]) — a
       `containment: none` cap-profile would launch a pod OUT-OF-SANDBOX on the host *as* the
       human (the strongest power of the fleet) via this generic no-auth door: 422 at admission.
       L'OUVERTURE NOMMÉE : `host_native_ack: true` dans le DTO — le GESTE de l'opérateur
       (`lcars admiral`), jamais un chemin automatique (le dispatcher ne passe pas par cette
       porte et n'a pas le champ). L'ack ne part PAS dans le payload broadcast (un fait
       d'ADMISSION, pas un ordre de spawn). UN canon profile est host-native — `admiral`, le
       siège machine — et l'unicité est tenue par le témoin anti-bitrot du control_router : un
       second profil hors sandbox exige son propre arbitrage.
    5. **Fleet-scope singleton already alive** — `role_index: 0` is the fleet-level slot: ONE per
       fleet, by construction (the reaper spares it, its session UUID carries no project). Admitting
       a second one costs a pod with a random UUID that nothing will ever address, and the incident
       it eventually raises accuses the agent of never acking — the symptom, never the cause. So the
       refusal names the pod holding the slot AND the gesture that works: the operator who typed the
       obvious command has no other way to learn it.
    6. **Brief required for a one-shot** — MIRROR of `Fleet.Spawner.brief_guard`:
       a one-shot without `brief` would leave
       without work → the spawner would refuse it (ZERO pod), so the 202 would lie.
       `Fleet.Spawner.brief_required?/1` IS the shared authority (no copied
       rule, no possible divergence).

  `broadcast/1` (the post-admission step) emits the canonical schema
  `%Fleet.Event{source: :api}` — an out-of-registry or malformed event becomes
  `{:error, _}` (HTTP 400 surface on the ControlRouter side), never a handler crash.
  """

  alias Fleet.CapProfile
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

  @admin_spawn_public_fields ~w(cap_profile_name role issue_id brief pod_id host_native_ack)

  @doc """
  Validates a request body and returns its canonical broadcast payload or the
  first refusal. Non-map bodies are treated as empty DTOs.
  """
  @spec admit(term()) :: {:ok, map()} | {:error, refusal()}
  def admit(raw) do
    with {:ok, payload} <- parse_admin_spawn_dto(raw),
         # L'ack ne fait PAS partie du payload broadcast (Map.take le jette, et c'est voulu : c'est
         # un fait d'ADMISSION, pas un ordre de spawn) — il se lit sur le DTO brut.
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
    name = CapProfile.name(cap)

    if CapProfile.catalogued?(cap) and CapProfile.role_index(cap) == 0 do
      # `Map.get`, never dot access: `list_pods/0` is specced `[map()]` and makes no promise about
      # the keys. A pod whose `:info` lacks `:role` then raises a KeyError THROUGH the router, and
      # THE WHOLE SPAWN DOOR ANSWERS 500 because one unrelated pod returned a short map. A guard
      # that can crash the door it guards is worse than the hole it closes.
      case Enum.find(Fleet.Spawner.list_pods(), &(Map.get(&1, :role) == name)) do
        nil -> :ok
        pod -> {:error, {:fleet_scope_occupied, name, Map.get(pod, :pod_id, "unknown")}}
      end
    else
      :ok
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
            cond do
              CapProfile.bwrap?(cap) ->
                {:ok, cap}

              # L'OUVERTURE NOMMÉE du verrou (BL-6-101). Un profil `containment: none`
              # reste REFUSÉ sur ce chemin générique — sauf si l'opérateur le dit EXPLICITEMENT
              # (`host_native_ack: true`, posé par `lcars admiral`, jamais par un chemin auto : le
              # dispatcher ne passe pas par cette porte et n'a pas le champ). C'est la doctrine de
              # la fiche : *« une décision de posture, qui se rouvre en la nommant »* — on nomme le
              # GESTE (l'acquittement), jamais un nom de rôle (`00` §5 : rien ne se key sur une
              # chaîne de rôle).
              ack? ->
                {:ok, cap}

              true ->
                {:error, {:host_native_forbidden, name}}
            end

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
