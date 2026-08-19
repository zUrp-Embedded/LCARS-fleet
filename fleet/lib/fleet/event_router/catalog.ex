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
  Returns the registry's event type strings. An empty registry yields `[]`; an UNPARSEABLE one
  raises, exactly like `load!/0` on the same fault.

  THE TWO READERS OF `events.yaml` NOW TREAT THE SAME FAULT THE SAME WAY. They did not: `load!/0`
  raised on an absent or invalid file while this one returned `[]` in silence — and `[]` was also
  what a legitimately empty registry returns, so the two were indistinguishable at the output.

  The silence was harmless on the nominal path (`load!/0` raises one line later, so the boot dies
  anyway) and NOT harmless where the registry is deliberately off
  (`event_router_load_event_registry: false`, the hermetic test baseline and any maintenance run):
  there `load!/0` is a no-op, this function is the ONLY source of pre-registered event atoms, and an
  unparseable file left the fleet with none. Every later `String.to_existing_atom/1` on a binary
  event type — `Bus.coerce_type/1`, the gitea webhook — then raises an ArgumentError naming the
  type, pointing at the consumer instead of at the file that could not be read.

  An EMPTY registry is a different fact and keeps its `[]`: there is genuinely nothing to
  pre-register, and `load!/0` is the one that decides whether emptiness is fatal.
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
    # THROUGH THE SHARED CACHE, like every other schema of the repo. This site inlined
    # `File.read! |> Jason.decode! |> resolve()` — the exact body of
    # `SchemaCache.resolve_json_schema!/2` — and was the ONLY one to do so without saying why.
    # Measured: three sites in `lib/` call `ExJsonSchema.Schema.resolve/1` — the shared mechanism,
    # ONE documented exception (`CapProfile.Schema`, whose `{:error, :schema_unavailable}` must stay
    # retryable and therefore uncacheable), and this one.
    #
    # Safe to cache here and NOT there: the variable artifact of this module is `events.yaml`, which
    # the tests rewrite under it; the SCHEMA is immutable `priv/` resolved through `:code.priv_dir`,
    # with no knob and nothing to swap.
    path =
      Path.join(to_string(:code.priv_dir(:lcars_fleet)), "event_router/schema/events-v1.json")

    schema = Fleet.SchemaCache.resolve_json_schema!({__MODULE__, :schema, path}, path)

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

      # THE MIRROR OF THE `cat5` CHECK ABOVE, AND IT RUNS THE OTHER WAY. `cat5` SYNTHESIZES the type
      # `starfleet.audit_cat5_<cat5_source>` and the check proves that key is registered.
      # `incident_cat5` CONSUMES that same naming: `IncidentConsumer.cat5_tag/1` derives the
      # incident tag by stripping the `starfleet.audit_cat5_` prefix off the type itself.
      #
      # `String.replace_prefix/3` IS A NO-OP WHEN THE PREFIX IS ABSENT, so a route that declares
      # `action: incident_cat5` on any other type does not fail — it escalates at MAXIMUM SEVERITY
      # under a tag that is the full type name, which no operator named and no dedup namespace
      # expects. Silent, and at the one severity where silence costs the most.
      #
      # The rule was already written twice — in this registry's own JSON schema ("the tag derives
      # from the starfleet.audit_cat5_<tag> type") and in `IncidentConsumer`'s moduledoc — and held
      # by nothing. Two prose statements of a constraint are not a constraint.
      #
      # NOT the completeness block the register's fiche asks for: an `incident_cat5` route admits
      # only `{source, action, threshold?}`. The schema is `additionalProperties: false` and the two
      # inverse checks below refuse `cat5_source` and `incident` on it, so there is no required
      # block left to omit. What CAN be malformed about such a route is its NAME.
      if action == "incident_cat5" and not String.starts_with?(type, "starfleet.audit_cat5_") do
        raise "Catalog: routing for #{type} declares action=incident_cat5, but the incident tag " <>
                "is derived by stripping the `starfleet.audit_cat5_` prefix off the type — which " <>
                "#{type} does not carry. It would escalate at maximum severity under the tag " <>
                "#{inspect(type)}. Rename the event, or route it as action=incident with an " <>
                "explicit incident block."
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
            # LA PORTE EST DECLARATIVE (brouette 2026-08-19) : `immediate` = issue des la PREMIERE
            # occurrence (escalate_gated, cooldown seul) ; `recurrence` (defaut) = 1re notee,
            # recidive escaladee (record_or_escalate). Le perimetre est borne : la porte
            # declarative vaut pour les evenements ROUTES PAR CETTE TABLE ; les kinds tires depuis
            # le code appellent leur porte au site — on ne re-decrit pas des chemins de code ici.
            gate =
              case inc["gate"] do
                nil -> :recurrence
                "recurrence" -> :recurrence
                "immediate" -> :immediate
                other -> raise "Catalog: #{type} declares incident gate=#{inspect(other)} " <>
                          "(expected \"immediate\" or \"recurrence\")"
              end

            # UNE PORTE IMMEDIATE EXIGE UN KIND NOMME : `Escalation.kind_describe/1` est une table
            # close, et un kind sans clause y CRASHE au lieu d'ouvrir l'issue — la panne exacte de
            # `:awaits_arch_stuck` (trouvee par revue, 2026-08-19). Refus au BOOT, pas au premier
            # incident.
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
