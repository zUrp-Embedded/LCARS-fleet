defmodule Fleet.Coord.Policies do
  @moduledoc """
  Module of pure functions: a declarative routing table
  `{verdict, reason} → {action, escalation_path}`.

  Lookup table loaded once at boot via `init_policies!/0`
  from `priv/config/coord-policies.yaml` (or the configured path) and
  persisted in `:persistent_term` (key
  `{__MODULE__, :policies}`): O(1) read with no process, table frozen
  at boot (same pattern as the read-only caches loaded once).

  **No LLM reasoning logic** in this module: a pure declarative lookup
  table (meta-axiom — all LLM judgment is consolidated on
  the gatekeeper, spawned on the workflow side, never here).

  ## `coord-policies.yaml` format

      mappings:
        "halt.gatekeeper.refuse":
          action: notify_dashboard
          escalation_path: [dashboard, issue_comment]
        "escalate.pod_drift":
          action: escalate_human
          escalation_path: [dashboard, starfleet_alert]

  ## Emission (delegated)

  A lookup that matches is translated into a canonical `%Fleet.Event{source: :coord}` and
  broadcast by `Fleet.Coord.Emitter` (emission pass extracted — the table
  lookup and the wire-event construction share no helper). The
  actions → event-types table lives over there.
  """

  alias Fleet.Coord.Emitter

  @policies_key {__MODULE__, :policies}

  require Logger

  @doc """
  Loads the YAML policies and persists them in `:persistent_term`.
  Fail-fast at boot if the file is absent or the YAML is malformed.
  """
  @spec init_policies!() :: :ok
  def init_policies! do
    path = Application.get_env(:fleet_coord, :policies_path, default_policies_path())

    # FAIL-LOUD at boot: an absent/malformed policies file = a broken deploy artifact, not a
    # runtime state to tolerate. We `raise` (propagated by `Application.start`) rather than degrade
    # to an EMPTY routing table — that degradation would boot coord "green" while EVERY
    # decision/escalation would then fall through to `:not_found` (a "wounded thing kept alive").
    # Intended consequence: fleet_coord does not start → the BEAM exits non-zero → the launcher
    # redeploys/escalates (dead-man's switch). The @doc's "Fail-fast at boot" contract is thereby
    # held literally. General rule: an announced fail-loud load failure MUST crash the
    # boot, never log-and-continue behind a green status.
    policies =
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = data} ->
          validate_against_schema!(data, path)
          data

        {:ok, other} ->
          raise "fleet_coord: policies #{path} malformed (not a map: #{inspect(other)}) — " <>
                  "broken deploy, fail-loud at boot (check LCARS_COORD_POLICIES_PATH)"

        {:error, reason} ->
          raise "fleet_coord: policies #{path} missing/unreadable (#{inspect(reason)}) — " <>
                  "broken deploy, fail-loud at boot (check LCARS_COORD_POLICIES_PATH)"
      end

    # Direct put (NOT `Fleet.SchemaCache.cached/2`): `init_policies!/0` must ALWAYS
    # re-read the YAML — the tests call it again with different paths and rely on
    # "the raise precedes the put" (boot table intact). The put stays boot-time-unique,
    # `:persistent_term` profile respected; reads go through `resolved_policies/0`.
    :persistent_term.put(@policies_key, policies)
    :ok
  end

  # STRUCTURAL validation of the parsed YAML against `priv/schema/coord-policies-v1.json` (ExJsonSchema). The
  # schema advertised itself as "Validated by ex_json_schema at init_policies!/0" but was NOT: the code
  # only accepted "is a map" → a malformed coord-policies (mapping without `action`, non-array
  # `escalation_path`, key outside the pattern, additional property…) passed silently and then broke every
  # lookup. Now FAIL-LOUD at boot, the SAME dead-man's-switch contract as an absent/unreadable file (the BEAM
  # exits non-zero, the launcher escalates) rather than a structurally broken routing table kept alive.
  # The schema is STRUCTURAL-ONLY (cf. its `$id`): the resolvability of action handlers and the existence of
  # escalation targets stay verified at runtime by Fleet.Coord, not here.
  defp validate_against_schema!(data, path) do
    schema_path =
      :code.priv_dir(:fleet_coord)
      |> to_string()
      |> Path.join("schema/coord-policies-v1.json")

    # IMMUTABLE priv schema, resolved ONCE via the Ring 0 authority `Fleet.SchemaCache`
    # (dedup: before, re-read+decode+resolve of the file on EACH call, no cache).
    schema =
      Fleet.SchemaCache.resolve_json_schema!({__MODULE__, :schema, schema_path}, schema_path)

    case ExJsonSchema.Validator.validate(schema, data) do
      :ok ->
        :ok

      {:error, errors} ->
        raise "fleet_coord: policies #{path} INVALID vs coord-policies-v1.json (#{inspect(errors)}) — " <>
                "broken deploy, fail-loud at boot (check LCARS_COORD_POLICIES_PATH)"
    end
  end

  @doc """
  Dispatch of a validated Gatekeeper decision.

  Extended arity: explicit `correlation_id` (task.id UUID v4 of the work item
  that produced the verdict, may be nil outside a work item).

  Lookup `{decision, reason}` → policies table → broadcast of the canonical schema
  `%Fleet.Event{source: :coord, type, correlation_id, …}`.
  The `handle_decision/1` compat shim (without correlation_id) is removed.

  Returns:
    * `:ok` — policy match + broadcast done
    * `{:error, {:no_policy_match, {decision, reason}}}` — no policy match.
      STRUCTURED tuple (pattern-matchable by consumers — the old string
      `"no policy match for …"` was not); the human message lives in the
      consumers' logs (`DriftMonitor`), not in the tuple.
  """
  @spec handle_decision(
          Fleet.Starfleet.Decision.t() | map(),
          correlation_id :: String.t() | nil
        ) :: :ok | {:error, {:no_policy_match, {term(), term()}}}
  def handle_decision(%{decision: decision, reason: reason} = dec, correlation_id) do
    case lookup({decision, reason}) do
      {:ok, %{"action" => action, "escalation_path" => path}} ->
        Emitter.dispatch_action(action, path, dec, correlation_id)

      :not_found ->
        {:error, {:no_policy_match, {decision, reason}}}
    end
  end

  @doc """
  Dispatch of a Cat 5 escalation.

  Extended arity: explicit `correlation_id` (extracted from the upstream event
  that triggered the escalation, may be nil outside a work item). The
  `handle_escalation/2` compat shim (without correlation_id) is removed.

  Returns:
    * `:ok` — policy match + broadcast done
    * `{:error, {:no_escalation_policy, source}}` — no policy for this
      source (`source` normalized to a string = the lookup key). STRUCTURED tuple,
      pattern-matchable; the human message lives in the consumers' logs
      (`Cat5Escalator`), not in the tuple.
  """
  @spec handle_escalation(
          source :: atom() | String.t(),
          payload :: map(),
          correlation_id :: String.t() | nil
        ) :: :ok | {:error, {:no_escalation_policy, String.t()}}
  def handle_escalation(source, payload, correlation_id) do
    source_str = to_string(source)

    case lookup({:escalate, source_str}) do
      {:ok, %{"action" => action, "escalation_path" => path}} ->
        Emitter.dispatch_action(action, path, payload, correlation_id)

      :not_found ->
        {:error, {:no_escalation_policy, source_str}}
    end
  end

  defp lookup({verdict, reason}) do
    policies = resolved_policies()
    key = "#{verdict}.#{reason}"

    case get_in(policies, ["mappings", key]) do
      nil -> :not_found
      match -> {:ok, match}
    end
  end

  defp resolved_policies do
    Fleet.SchemaCache.fetch!(@policies_key, "Fleet.Coord.Policies.init_policies!/0")
  end

  defp default_policies_path do
    :code.priv_dir(:fleet_coord)
    |> to_string()
    |> Path.join("config/coord-policies.yaml")
  end
end
