defmodule Fleet.EventRouter.Catalog do
  @moduledoc """
  Loads `events.yaml` at boot as the authorized event registry and routing table.

  With :event_router_load_event_registry enabled, missing, invalid, empty or inconsistent
  registries raise. :event_router_events_yaml_path overrides the default under priv/.
  The trusted file supplies atom names; it must not be populated from unbounded external input.
  """

  require Logger

  @doc """
  Validates and loads types then routing when enabled; disabling leaves previous state intact.
  Updates are not atomic: routing validation can raise after replacing authorized types.
  """
  @spec load!() :: :ok
  def load! do
    if Application.get_env(:lcars_fleet, :event_router_load_event_registry, true) do
      do_load()
    else
      :ok
    end
  end

  defp do_load do
    case parse_events() do
      {:ok, events} when map_size(events) > 0 ->
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
        raise "Catalog: events.yaml EMPTY (events: {}) at #{events_yaml_path()} — an " <>
                "empty registry would let the Bus broadcast EVERY type without validation (broken deploy). " <>
                "Fail-loud at boot, same as an absent/invalid events.yaml."

      :error ->
        raise "Catalog: events.yaml absent or invalid at #{events_yaml_path()} — " <>
                "event registry not loadable (broken deploy). Fail-loud at boot: a Bus without a " <>
                "registry would validate any type. Repair/redeploy priv/event_router/events.yaml."
    end
  end

  @doc """
  Returns keys from the parsed events map, without schema validation or a loading-switch check.
  Empty maps yield []; missing/unparseable files or a non-map events value raise. This remains
  active for atom preregistration when load!/0 is disabled, so a bad file is diagnosed here
  rather than later at a to_existing_atom consumer. Malformed key types are not rejected here.
  """
  @spec event_type_strings() :: [String.t()]
  def event_type_strings do
    case parse_events() do
      {:ok, events} ->
        Map.keys(events)

      :error ->
        raise "Catalog: events.yaml absent or invalid at #{events_yaml_path()} — no event atom " <>
                "could be pre-registered. Fail-loud here, same as load!/0 on the same fault: with " <>
                "the registry disabled nothing else would say it, and the fault would surface " <>
                "later as an ArgumentError on String.to_existing_atom/1 at a consumer."
    end
  end

  defp parse_events do
    path = events_yaml_path()

    case File.exists?(path) && YamlElixir.read_from_file(path) do
      {:ok, %{"events" => events}} when is_map(events) -> {:ok, events}
      _ -> :error
    end
  end

  defp validate_against_schema!(events) do
    # Re-read mutable events YAML, but cache the bundled schema by path. Disk schema edits
    # do not invalidate that cache automatically; publication assumes deployed schema stability.
    path =
      Path.join(to_string(:code.priv_dir(:lcars_fleet)), "event_router/schema/events.json")

    schema = Fleet.SchemaCache.resolve_json_schema!({__MODULE__, :schema, path}, path)

    case ExJsonSchema.Validator.validate(schema, %{"events" => events}) do
      :ok ->
        :ok

      {:error, errors} ->
        raise "Catalog: events.yaml INVALID against events.json: #{inspect(errors)} — " <>
                "the registry carries the routing table (load-bearing); fail-loud at boot."
    end
  end

  defp build_routing!(events) do
    for {type, %{"source" => source, "action" => action} = route} <- events, into: %{} do
      source_atom = canonical_source!(type, source)

      {{source_atom, String.to_atom(type)},
       %{action: String.to_atom(action), incident: incident_route!(type, action, route)}}
    end
  end

  defp canonical_source!(type, source) do
    atom = String.to_atom(source)

    unless Fleet.Event.valid_source?(atom) do
      raise "Catalog: #{type} declares source=#{source}, not a canonical source " <>
              "(expected one of #{inspect(Fleet.Event.canonical_sources())})"
    end

    atom
  end

  defp incident_route!(type, action, route) do
    if route["incident"] && action != "incident" do
      raise "Catalog: #{type} carries incident block but action=#{action} is not incident"
    end

    case route["incident"] do
      %{"op" => op, "subject" => subject} = inc ->
        gate = incident_gate!(type, inc["gate"])

        # Immediate escalation needs a named kind before reaching the consumer's closed table.
        # This guard checks presence, not that the named kind has a handler there.
        if gate == :immediate and is_nil(inc["escalate_kind"]) do
          raise "Catalog: #{type} declares gate=immediate without escalate_kind — the " <>
                  "immediate path calls Escalation.escalate/5 whose kind table is closed; " <>
                  "an unnamed kind would crash at the first incident instead of at boot"
        end

        %{
          op: op,
          subject: subject,
          gate: gate,
          escalate_kind: inc["escalate_kind"] && String.to_atom(inc["escalate_kind"]),
          forward: Enum.map(inc["forward"] || [], &String.to_atom/1)
        }

      nil ->
        nil
    end
  end

  # For table-routed incidents: immediate requests first-occurrence escalation subject to
  # cooldown; recurrence records before escalating repeats. Direct code callers choose separately.
  defp incident_gate!(_type, nil), do: :recurrence
  defp incident_gate!(_type, "recurrence"), do: :recurrence
  defp incident_gate!(_type, "immediate"), do: :immediate

  defp incident_gate!(type, other) do
    raise "Catalog: #{type} declares incident gate=#{inspect(other)} " <>
            "(expected \"immediate\" or \"recurrence\")"
  end

  @doc "Returns the configured registry path or its default under `priv/`."
  @spec events_yaml_path() :: String.t()
  def events_yaml_path do
    Application.get_env(
      :lcars_fleet,
      :event_router_events_yaml_path,
      Path.join(to_string(:code.priv_dir(:lcars_fleet)), "event_router/events.yaml")
    )
  end
end
