defmodule Fleet.API.SpawnAdmission do
  @moduledoc """
  ADMISSION pipeline for `POST /api/admin/spawn` — the POLICY of the API's
  only write, separated from the HTTP routing (C4 2026-07-05 split):
  `Fleet.API.Rest` maps each verdict returned here onto its HTTP status, this
  module decides WHO passes. Pure functions + catalog reads (no process).

  ## Why a strict admission on a no-auth surface

  `/api/admin/spawn` is no-auth (boundary = network isolation, cf. moduledoc
  `Fleet.API.Rest` § Auth). The `PublishConsumer` THEN converts
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
       out-of-band path (starfleet / `bin/host_launch.sh`). Fail-closed.
    5. **Brief required for a one-shot** — MIRROR of R18
       (`Fleet.Spawner.brief_guard`): a one-shot without `brief` would leave
       without work → the spawner would refuse it (ZERO pod), so the 202 would lie.
       `Fleet.Spawner.brief_required?/1` IS the shared authority (no copied
       rule, no possible divergence).

  `broadcast/1` (the post-admission step) emits the canonical schema
  `%Fleet.Event{source: :api}` — an out-of-registry or malformed event becomes
  `{:error, _}` (HTTP 400 surface on the Rest side), never a handler crash.
  """

  alias Fleet.EventRouter.Bus

  @typedoc """
  Admission-refusal verdicts — each mapped onto ONE HTTP status by
  `Fleet.API.Rest` (400 for `:missing_cap_profile`, 422 for the rest).
  """
  @type refusal ::
          {:forbidden_fields, [String.t()]}
          | {:invalid_pod_id, term()}
          | :missing_cap_profile
          | {:cap_profile, String.t(), term()}
          | {:host_native_forbidden, String.t()}
          | :brief_required

  # Public fields admitted at the top-level of the `/api/admin/spawn` DTO. Everything else is REFUSED.
  #   * `cap_profile_name` / `role` — the capability profile (one of the two, required; validated below)
  #   * `issue_id` — forge/event correlation (free string)
  #   * `brief` — the pod's work (string); placed back into the internal `opts` built by the API
  #   * `pod_id` — imposed pod id (rare, admin); accepted ONLY if it is path-safe
  #     (same rule as `Fleet.Spawner`: `[A-Za-z0-9._-]`, no `..`), otherwise refused
  @admin_spawn_public_fields ~w(cap_profile_name role issue_id brief pod_id)

  @doc """
  Full admission of a `POST /api/admin/spawn` body (the 5 steps of the
  moduledoc, fixed order, first refusal returned). `{:ok, payload}` = the
  CANONICAL payload ready to broadcast (the only thing that will reach the consumer/spawner);
  `{:error, refusal}` = nothing leaves, `Fleet.API.Rest` translates to HTTP.

  A non-map body (JSON parser returning something else) is treated as an empty
  DTO → `{:error, :missing_cap_profile}` (the required field is missing).
  """
  @spec admit(term()) :: {:ok, map()} | {:error, refusal()}
  def admit(raw) do
    with {:ok, payload} <- parse_admin_spawn_dto(raw),
         {:ok, cap} <- validate_cap_profile(payload),
         :ok <- check_brief_required(payload, cap) do
      {:ok, payload}
    end
  end

  @doc """
  Broadcast of the ADMITTED payload: canonical schema `%Fleet.Event{source: :api}`
  built + broadcast via `Bus.emit` (source validated against the enum,
  DateTime timestamp guaranteed). The construction AND the broadcast are INSIDE the
  rescue: the API's POLICY is to surface as HTTP — an out-of-registry event
  (`UnregisteredError`) or a malformed one (`ArgumentError`/
  `FunctionClauseError` from the constructor) becomes `{:error, _}` (→ 400 on the
  Rest side), never a handler crash.
  """
  @spec broadcast(map()) :: :ok | {:error, term()}
  def broadcast(payload) do
    Bus.emit(:api, :"admin.spawn.request", payload: payload)
  rescue
    e in Fleet.Event.UnregisteredError -> {:error, e.message}
    e in [ArgumentError, FunctionClauseError] -> {:error, inspect(e)}
  end

  # Parses the incoming payload into an allowlisted public DTO. The spawner's internal `opts` is NEVER taken
  # from the client: the API (re)builds it from the public fields only (`brief`, `pod_id`). Any unknown
  # or forbidden top-level key (including a raw `opts`) → `{:error, {:forbidden_fields, ...}}`.
  defp parse_admin_spawn_dto(raw) when is_map(raw) do
    extraneous = Map.keys(raw) -- @admin_spawn_public_fields

    cond do
      extraneous != [] ->
        {:error, {:forbidden_fields, extraneous}}

      true ->
        with {:ok, opts} <- build_admin_opts(raw) do
          payload =
            raw
            |> Map.take(["cap_profile_name", "role", "issue_id"])
            |> maybe_put_opts(opts)

          {:ok, payload}
        end
    end
  end

  defp parse_admin_spawn_dto(_), do: {:ok, %{}}

  # Builds the spawn `opts` from the public fields only. `pod_id` is kept only if path-safe.
  defp build_admin_opts(raw) do
    opts = if is_binary(raw["brief"]), do: %{"brief" => raw["brief"]}, else: %{}

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

  # Same contract as `Fleet.Spawner`: a pod_id is interpolated into FS paths (`~/pods/pod_<id>`),
  # so only a path-safe charset without `..` traversal is admitted. The authority of this rule lives on
  # the spawner side, which owns the paths and sockets derived from the pod_id; the API does not copy the regex.
  defp valid_pod_id?(id), do: Fleet.Spawner.valid_pod_id?(id)

  # Resolves the requested cap-profile (`cap_profile_name` or `role`, same keys as
  # `PublishConsumer.handle_spawn_request`). Absent → `{:error, :missing_cap_profile}`; load KO →
  # `{:error, {:cap_profile, name, reason}}`; HOST-NATIVE (`containment != bwrap`) →
  # `{:error, {:host_native_forbidden, name}}`; loaded + sandboxed → `{:ok, cap}` (admission
  # continues; the loaded cap feeds the R18 one-shot brief guard, without a re-load). Same loader +
  # same containment read as the spawner (single source `Fleet.CapProfile`) → no
  # verdict divergence between the API and the real launch.
  defp validate_cap_profile(payload) do
    case Map.get(payload, "cap_profile_name") || Map.get(payload, "role") do
      name when is_binary(name) and name != "" ->
        case Fleet.CapProfile.load(name) do
          {:ok, cap} ->
            if Fleet.CapProfile.bwrap?(cap),
              do: {:ok, cap},
              else: {:error, {:host_native_forbidden, name}}

          {:error, reason} ->
            {:error, {:cap_profile, name, reason}}
        end

      _ ->
        {:error, :missing_cap_profile}
    end
  end

  # MIRROR of R18 (Fleet.Spawner.brief_guard) at ADMISSION: a one-shot cap-profile
  # (reviewer/qualifier/consultant) launched WITHOUT `brief` would leave without work → the spawner
  # refuses it (`brief_required`, ZERO pod). Without this guard, the "queued" 202 would be a
  # lying 202 (exact twin of the lying cap-profile). `Fleet.Spawner.brief_required?/1` IS
  # the shared authority (same nil-aware `get_in` read as `brief_guard`) → we did NOT copy
  # the rule (no possible divergence). A LEGITIMATE one-shot carries its `brief` in the DTO
  # (allowlist) → `has_brief?` true → it passes.
  defp check_brief_required(payload, cap) do
    brief = get_in(payload, ["opts", "brief"])
    has_brief? = is_binary(brief) and brief != ""

    if Fleet.Spawner.brief_required?(cap) and not has_brief?,
      do: {:error, :brief_required},
      else: :ok
  end
end
