defmodule Fleet.EventRouter.Catalog do
  @moduledoc """
  Boot-time loader of the **event registry** (`priv/event_router/events.yaml`).

  Pure boot-time function (NOT a GenServer — Iron Law: we do not wrap a
  stateless write-once function in a process). Called by
  `Fleet.EventRouter.Application.init/1`.

  Role: `events.yaml` is a **pure registry** — its keys are the authorized event
  types. Consumption happens through **direct subscribers** (`Bus.subscribe` +
  `handle_info`); there is NO dispatch table. `load!/0` **populates
  `authorized_event_types`** (`Bus.set_authorized_event_types/1`) → `Bus.broadcast/2`
  fails loud on any type outside the registry: an emitted, unregistered event crashes
  its emitter. The dynamic emitters (`WebhooksGitea`, `Coord.Emitter`,
  `Pod.Events.lossy_broadcast`) rescue `UnregisteredError` so as not to die
  on an unexpected type; the `pod.completed` lifecycle, on the other hand, goes through
  `Pod.Events.required_broadcast` which PROPAGATES the failure instead of swallowing it (a
  load-bearing event swallowed would mask the end of step_run and leave the lock held).

  The **atom pre-registration** (`String.to_existing_atom` on the dynamic-emitter
  side) is done separately by `Application.preregister_event_atoms/0`
  (includes the `os.signal.*` extras + `gitea.*` variants outside the registry).

  ## Config

    * `:fleet_event_router, :load_event_registry` — bool, default `true`. Set to
      `false` in `:test` (hermeticity: empty registry → escape-hatch
      `assert_authorized!` `MapSet.size == 0` → broadcast not validated in test).
    * `:fleet_event_router, :events_yaml_path` — path override (default `priv/event_router/events.yaml`).

  **Last revised**: 2026-07-22
  """

  require Logger

  @doc """
  Populates `authorized_event_types` from events.yaml if `:load_event_registry`
  is true. No-op otherwise (test → escape-hatch, validation off). Idempotent.
  """
  @spec load!() :: :ok
  def load! do
    if Application.get_env(:fleet_event_router, :load_event_registry, true) do
      do_load()
    else
      :ok
    end
  end

  defp do_load do
    case parse_events() do
      {:ok, events} when map_size(events) > 0 ->
        # The registry is LOAD-BEARING since it carries the routing table (the classification
        # chain acts on it) → the WHOLE file is schema-validated at boot, fail-loud: a malformed
        # routing entry silently dropped would un-wire an escalation chain with a green deploy.
        validate_against_schema!(events)

        set = events |> Map.keys() |> Enum.map(&String.to_atom/1) |> MapSet.new()
        Fleet.EventRouter.Bus.set_authorized_event_types(set)

        routing = build_routing!(events)
        Fleet.EventRouter.Bus.set_event_routing(routing)

        Logger.info(
          "Catalog: events.yaml registry loaded (#{MapSet.size(set)} types, " <>
            "#{map_size(routing)} routed)"
        )

        :ok

      {:ok, events} when map_size(events) == 0 ->
        # events.yaml VALID but EMPTY (`events: {}`) in a real regime: setting this empty MapSet via
        # set_authorized_event_types would leave the Bus (permissive on an empty registry by default)
        # broadcasting EVERY type WITHOUT validation — exactly the same silent fail-open as the
        # absent/invalid case below, a "green" deploy but a dead registry. `do_load` is reached only
        # in a real boot (`load_event_registry: true`; test sets `false`) → an empty registry here =
        # a broken deploy. Fail-loud at boot, like an absent/invalid events.yaml.
        raise "Catalog: events.yaml EMPTY (events: {}) at #{events_yaml_path()} — an " <>
                "empty registry would let the Bus broadcast EVERY type without validation (broken deploy). " <>
                "Fail-loud at boot, same as an absent/invalid events.yaml."

      :error ->
        # Deliberate crash-boot ("broken deploy ⇒ we do not boot"): an absent/invalid events.yaml
        # that would WARN then return `:ok` would leave `authorized_event_types` empty →
        # `assert_authorized!` escape-hatch (empty MapSet) → the Bus would broadcast EVERY type
        # WITHOUT validation, a "green" deploy but a dead registry. `do_load` is reached only in
        # prod/dev (`load_event_registry: true`; test sets `false`) → here we are necessarily in a
        # real boot that wants the registry. Fail-loud: raise in `Application.start` → the BEAM does
        # not come up, the launcher redeploys. We do NOT start a Bus without validation.
        raise "Catalog: events.yaml absent or invalid at #{events_yaml_path()} — " <>
                "event registry not loadable (broken deploy). Fail-loud at boot: a Bus without a " <>
                "registry would validate any type. Repair/redeploy priv/event_router/events.yaml."
    end
  end

  @doc """
  Type-keys of the events.yaml registry (strings). **Single parse source** — reused
  by `do_load/0` AND `Application.preregister_event_atoms/0`: the file is located/
  parsed in a SINGLE place at boot, so no risk of shape drift between the two. Returns `[]`
  if events.yaml is absent/invalid.
  """
  @spec event_type_strings() :: [String.t()]
  def event_type_strings do
    case parse_events() do
      {:ok, events} -> Map.keys(events)
      :error -> []
    end
  end

  # The events.yaml parse in ONE single place: locates + reads + validates the shape.
  # `{:ok, events_map}` if present and `events:` is a map (EMPTY map included — `parse_events` does
  # NOT decide the verdict on emptiness, it just returns `{:ok, %{}}`); `:error` if absent/invalid.
  # It is the TWO callers that decide on emptiness:
  #   * do_load → FAIL-LOUD (raise) on an empty map in a real regime — an empty registry would open
  #     the Bus to EVERY type without validation — AND on `:error` (same reason).
  #   * event_type_strings → `[]` on an empty map (preregister has nothing to pre-register) as on :error.
  defp parse_events do
    path = events_yaml_path()

    case File.exists?(path) && YamlElixir.read_from_file(path) do
      {:ok, %{"events" => events}} when is_map(events) -> {:ok, events}
      _ -> :error
    end
  end

  # Boot-time schema validation of the parsed registry (events-v1.json, same ExJsonSchema idiom as
  # coord-policies). Raise = crash-boot, consistent with the absent/empty cases above.
  defp validate_against_schema!(events) do
    schema =
      Path.join(to_string(:code.priv_dir(:lcars_fleet)), "event_router/schema/events-v1.json")
      |> File.read!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    case ExJsonSchema.Validator.validate(schema, %{"events" => events}) do
      :ok ->
        :ok

      {:error, errors} ->
        raise "Catalog: events.yaml INVALID against events-v1.json: #{inspect(errors)} — " <>
                "the registry carries the routing table (load-bearing); fail-loud at boot."
    end
  end

  # The routing table: `{source_atom, type_atom} => %{action:, cat5_source:, threshold:}`. Atoms are
  # safe here: the values come from the schema-validated canon (bounded patterns), post-validation.
  # The anti-spoof key is the PAIR — a routed type broadcast under another source misses the table.
  # A `cat5` route whose synthesized broadcast type (`starfleet.audit_cat5_<tag>`) is NOT itself a
  # registered event key would fail at emit (unregistered type) — refused HERE at boot instead.
  defp build_routing!(events) do
    for {type, %{"source" => source, "action" => action} = route} <- events, into: %{} do
      cat5_source = route["cat5_source"]

      if action == "cat5" do
        cat5_source ||
          raise "Catalog: routing for #{type} declares action=cat5 without cat5_source"

        audit_key = "starfleet.audit_cat5_#{cat5_source}"

        Map.has_key?(events, audit_key) ||
          raise "Catalog: routing for #{type} synthesizes #{audit_key}, which is NOT a " <>
                  "registered event key — the Cat-5 broadcast would be refused at emit"
      end

      if action == "incident" and not match?(%{"op" => _, "subject" => _}, route["incident"]) do
        raise "Catalog: routing for #{type} declares action=incident without a complete " <>
                "incident block ({op, subject} required)"
      end

      threshold =
        case route["threshold"] do
          %{"counter" => counter, "min" => min} -> %{counter: counter, min: min}
          nil -> nil
        end

      incident =
        case route["incident"] do
          %{"op" => op, "subject" => subject} = inc ->
            %{
              op: op,
              subject: subject,
              # escalate_kind/forward atoms are canon-bounded (schema patterns), post-validation.
              escalate_kind: inc["escalate_kind"] && String.to_atom(inc["escalate_kind"]),
              forward: Enum.map(inc["forward"] || [], &String.to_atom/1)
            }

          nil ->
            nil
        end

      {{String.to_atom(source), String.to_atom(type)},
       %{
         action: String.to_atom(action),
         cat5_source: cat5_source && String.to_atom(cat5_source),
         threshold: threshold,
         incident: incident
       }}
    end
  end

  @doc "Resolves the path of the events.yaml registry (env override or priv/). Public: reused by `Application.preregister_event_atoms/0` (single parse source)."
  def events_yaml_path do
    Application.get_env(
      :fleet_event_router,
      :events_yaml_path,
      Path.join(to_string(:code.priv_dir(:lcars_fleet)), "event_router/events.yaml")
    )
  end
end
