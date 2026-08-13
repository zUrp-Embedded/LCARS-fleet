defmodule Fleet.EventRouter.Catalog do
  @moduledoc """
  Loads `events.yaml` at boot as the authorized event registry and routing table.

  With `:load_event_registry` enabled, absent, invalid, empty, or inconsistent
  registries raise. `:events_yaml_path` overrides the default file under `priv/`.
  """

  require Logger

  @doc """
  Loads the authorized types and routing table when registry loading is enabled.
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
  Returns the registry's event type strings, or `[]` when it cannot be parsed.
  """
  @spec event_type_strings() :: [String.t()]
  def event_type_strings do
    case parse_events() do
      {:ok, events} -> Map.keys(events)
      :error -> []
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

      if cat5_source && action != "cat5" do
        raise "Catalog: #{type} carries cat5_source but action=#{action} is not cat5"
      end

      if route["incident"] && action != "incident" do
        raise "Catalog: #{type} carries incident block but action=#{action} is not incident"
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
              escalate_kind: inc["escalate_kind"] && String.to_atom(inc["escalate_kind"]),
              forward: Enum.map(inc["forward"] || [], &String.to_atom/1)
            }

          nil ->
            nil
        end

      source_atom = String.to_atom(source)

      unless Fleet.Event.valid_source?(source_atom) do
        raise "Catalog: #{type} declares source=#{source}, not a canonical source " <>
                "(expected one of #{inspect(Fleet.Event.canonical_sources())})"
      end

      {{source_atom, String.to_atom(type)},
       %{
         action: String.to_atom(action),
         cat5_source: cat5_source && String.to_atom(cat5_source),
         threshold: threshold,
         incident: incident
       }}
    end
  end

  @doc "Returns the configured registry path or its default under `priv/`."
  def events_yaml_path do
    Application.get_env(
      :lcars_fleet,
      :event_router_events_yaml_path,
      Path.join(to_string(:code.priv_dir(:lcars_fleet)), "event_router/events.yaml")
    )
  end
end
