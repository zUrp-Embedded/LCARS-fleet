defmodule Fleet.API.SpawnAdmission do
  @moduledoc """
  ADMISSION pipeline for `POST /api/admin/spawn` — the POLICY of the API's
  only write, separated from the HTTP routing:
  `Fleet.API.ControlRouter` (the write door) maps each verdict returned here onto its HTTP
  status, this module decides WHO passes. Pure functions + catalog reads (no process).

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
       out-of-band path (`bin/host_launch.sh`, an off-fleet interactive session).
       Fail-closed — a defensive guard even though no canon profile is host-native
       since the 2026-07-19 reorg (starfleet became an ordinary bwrap orchestrator).
    5. **Brief required for a one-shot** — MIRROR of `Fleet.Spawner.brief_guard`
       (`Fleet.Spawner.brief_guard`): a one-shot without `brief` would leave
       without work → the spawner would refuse it (ZERO pod), so the 202 would lie.
       `Fleet.Spawner.brief_required?/1` IS the shared authority (no copied
       rule, no possible divergence).

  `broadcast/1` (the post-admission step) emits the canonical schema
  `%Fleet.Event{source: :api}` — an out-of-registry or malformed event becomes
  `{:error, _}` (HTTP 400 surface on the ControlRouter side), never a handler crash.

  **Last revised**: 2026-07-31
  """

  alias Fleet.EventRouter.Bus

  @typedoc """
  Admission-refusal verdicts — each mapped onto ONE HTTP status by
  `Fleet.API.ControlRouter` (400 for `:missing_cap_profile`, 422 for the rest).
  """
  @type refusal ::
          {:forbidden_fields, [String.t()]}
          | {:invalid_pod_id, term()}
          | {:invalid_issue_id, term()}
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
  `{:error, refusal}` = nothing leaves, `Fleet.API.ControlRouter` translates to HTTP.

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
  ControlRouter side), never a handler crash.
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

    if extraneous != [] do
      {:error, {:forbidden_fields, extraneous}}
    else
      with {:ok, opts} <- build_admin_opts(raw),
           :ok <- validate_issue_id(raw) do
        # The broadcast payload carries the PARSED form, not the raw DTO: a blank
        # `cap_profile_name: ""` admitted here (presence/1 resolved the role instead) must NOT
        # travel to the Bus — PublishConsumer's `name || role` fallback would short-circuit on
        # the truthy "" → load("") → drop AFTER the 202 was ACKed (a lying 202, the exact class
        # this module exists to close). Parse once at this boundary; the Bus receives truth.
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

  # `issue_id` is an OPTIONAL forge/event correlation string (allowlisted but not required). Present → it
  # MUST be a binary, mirroring the `pod_id` guard in `build_admin_opts`: a raw JSON number/bool/list would
  # be `to_string`-d downstream (`PublishConsumer`) into the pod's issue correlation + spawn logs (e.g.
  # `to_string([1, 2, 3]) = <<1, 2, 3>>` control bytes) — a no-auth ingress must not admit an untyped
  # correlation key. Absent → OK (`PublishConsumer` defaults it to `""` — no envelope fallback, the
  # canonical %Fleet.Event{} carries issue_id in the payload). NOT path-bound (the FS path derives
  # from `pod_id`), so `is_binary` suffices — no `valid_pod_id?` needed.
  defp validate_issue_id(raw) do
    case Map.fetch(raw, "issue_id") do
      :error -> :ok
      {:ok, issue_id} when is_binary(issue_id) -> :ok
      {:ok, other} -> {:error, {:invalid_issue_id, other}}
    end
  end

  # Builds the spawn `opts` from the public fields only. `pod_id` is kept only if path-safe.
  defp build_admin_opts(raw) do
    # `self_enqueue_brief`: the admin spawn has NO dispatcher/orchestrator to enqueue its brief, so the
    # POD self-enqueues it (`Pod.Brief.maybe_enqueue_brief`). This flag is what AUTHORIZES that: a Fleet
    # dispatch/gatekeeper spawn ALSO carries `brief` in its opts
    # (for the pod's data), but the DISPATCHER owns the enqueue there — the flag is ABSENT, so the pod
    # never self-enqueues on those paths, killing the spawn→enqueue race structurally (not by slot-timing).
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

  # Same contract as `Fleet.Spawner`: a pod_id is interpolated into FS paths (`~/pods/pod_<id>`),
  # so only a path-safe charset without `..` traversal is admitted. The authority of this rule lives on
  # the spawner side, which owns the paths and sockets derived from the pod_id; the API does not copy the regex.
  defp valid_pod_id?(id), do: Fleet.Spawner.valid_pod_id?(id)

  # A usable name is a non-empty string; anything else (nil, "", non-string) counts as ABSENT
  # so the `||` fallback chain can reach the next candidate instead of short-circuiting on "".
  defp presence(v) when is_binary(v) and v != "", do: v
  defp presence(_), do: nil

  # Resolves the requested cap-profile (`cap_profile_name` or `role`, same keys as
  # `PublishConsumer.handle_spawn_request`). Absent → `{:error, :missing_cap_profile}`; load KO →
  # `{:error, {:cap_profile, name, reason}}`; HOST-NATIVE (`containment != bwrap`) →
  # `{:error, {:host_native_forbidden, name}}`; loaded + sandboxed → `{:ok, cap}` (admission
  # continues; the loaded cap feeds the one-shot brief guard (`Fleet.Spawner.brief_guard`), without a re-load). Same loader +
  # same containment read as the spawner (single source `Fleet.CapProfile`) → no
  # verdict divergence between the API and the real launch.
  defp validate_cap_profile(payload) do
    # `presence/1` normalizes "" (and any non-string) to nil BEFORE the fallback: in Elixir ""
    # is TRUTHY, so `Map.get(p, "cap_profile_name") || Map.get(p, "role")` returned "" for
    # `{cap_profile_name: "", role: "reviewer"}` — silently IGNORING the valid role and answering
    # `:missing_cap_profile`. Fail-closed by luck, wrong verdict by construction.
    case Fleet.CapProfile.name_from_request(payload) do
      name when is_binary(name) ->
        # validate the EFFECTIVE profile (`resolve` = base + default
        # modops), the SAME one `PublishConsumer` spawns — not the bare `load`. A structural modop overlay
        # that flipped `containment` to host-native would otherwise pass admission (base is bwrap) then
        # launch out-of-sandbox: admission must gate on what actually runs.
        case Fleet.CapProfile.resolve(Fleet.CapProfile, name) do
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

  # MIRROR of the one-shot brief guard (Fleet.Spawner.brief_guard) at ADMISSION: a one-shot cap-profile
  # (reviewer/qualifier/scoper) launched WITHOUT `brief` would leave without work → the spawner
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
