defmodule Mix.Tasks.Lcars.Contracts.Check.Events do
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Checks event source shapes and shared vocabularies. These inspections can catch
  stale consumers or mismatched declarations, but do not prove delivery or that
  a handler executes. Individual checks use AST, raw text or decoded YAML.

  Set comparisons establish membership, not severity order or runtime reachability.
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Support

  import Mix.Tasks.Lcars.Contracts.Check.Support

  # Search lib/ for residual event_type map syntax; the pattern does not identify actual consumers.
  @doc false
  @spec check_event_consumers_canon(String.t()) :: Support.result()
  def check_event_consumers_canon(root) do
    residue_check(root, %{
      id: "event.consumers.canon",
      remediation:
        "migrate the flagged consumer(s) off the legacy `event_type` tuple to `%Fleet.Event{}` matching",
      files:
        Path.wildcard(Path.join(root, "lib/**/*.ex"))
        |> Enum.map(&Path.relative_to(&1, root)),
      pattern: ~r/"event_type"\s*=>/,
      confirm: ~r/"event_type"\s*=>/,
      note: "a consumer on the legacy \"event_type\" tuple (canon = %Fleet.Event{} matching)"
    })
  end

  # Require the envelope-normalizer clause and call spellings used by the loader.
  @doc false
  @spec check_pipeline_envelope_normalized(String.t()) :: Support.result()
  def check_pipeline_envelope_normalized(root) do
    rel = "lib/fleet/workflow/loader.ex"
    loader = Path.join(root, rel)

    # Strip line comments before confirming the source patterns; no data-flow proof is made.
    unwrap_clause? =
      loader
      |> grep_lines(~r/defp normalize\(%\{"spec"/)
      |> Enum.any?(fn {_l, line} -> Regex.match?(~r/defp normalize/, strip_comment(line)) end)

    called? =
      loader
      |> grep_lines(~r/normalize\(yaml\)/)
      |> Enum.any?(fn {_l, line} -> Regex.match?(~r/normalize\(yaml\)/, strip_comment(line)) end)

    ok? = unwrap_clause? and called?

    %{
      id: "pipeline.envelope.normalized",
      remediation:
        "add the `normalize` unwrap clause for spec.steps so a workflow_map consumer does not read steps=nil",
      status: if(ok?, do: :pass, else: :fail),
      evidence:
        cond do
          not unwrap_clause? ->
            [
              "#{rel}: `defp normalize(%{\"spec\" => %{\"steps\" => ...}})` clause (envelope unwrap) missing → a workflow_map consumer reads steps=nil"
            ]

          not called? ->
            ["#{rel}: `normalize(yaml)` never called at load → envelope not unwrapped"]

          true ->
            []
        end,
      note:
        "Loader UNWRAPS spec.steps via the CODE CLAUSE (`defp normalize(%{\"spec\"…})`) AND calls it at load — matches the code, not a comment (hardened anti-hollow-green)"
    }
  end

  # Check binary handler names in the decoded events map against available modules.
  # Empty maps pass here; module existence does not prove subscription.
  @doc false
  @spec check_events_handlers_exist(String.t()) :: Support.result()
  def check_events_handlers_exist(root) do
    yaml = Path.join(root, "priv/event_router/events.yaml")

    missing =
      case YamlElixir.read_from_file(yaml) do
        {:ok, %{"events" => events}} when is_map(events) ->
          events
          |> Map.values()
          |> List.flatten()
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()
          |> Enum.reject(&module_exists?/1)

        _ ->
          [
            "events.yaml absent or invalid at #{yaml} — handlers unverifiable (hollow-green guard)"
          ]
      end

    %{
      id: "events.handlers.exist",
      remediation:
        "remove the phantom handler ref(s) from events.yaml, or add the missing subscriber(s)",
      status: if(missing == [], do: :pass, else: :fail),
      evidence: Enum.map(missing, &"events.yaml → #{&1} (missing)"),
      note: "phantom handlers referenced in events.yaml (dispatch table vs direct subscribers)"
    }
  end

  # Compare declared ownership-rule dependents with textual @pulled_states citations.
  # A dependency that never names the rule is invisible; both sets must be nonempty.
  @doc false
  @spec check_pulled_states_declared(String.t()) :: Support.result()
  def check_pulled_states_declared(root) do
    rel = "lib/fleet/pilot/poller/reconciliation.ex"

    declared =
      root
      |> quoted!(rel)
      |> collect(fn
        {:@, _, [{:pulled_states_dependents, _, [list]}]} when is_list(list) -> list
        _ -> nil
      end)
      |> List.flatten()
      |> collect_strings()
      |> MapSet.new()

    citing =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(&String.contains?(File.read!(&1), "@pulled_states"))
      |> Enum.map(&Path.relative_to(&1, root))
      # Exclude the provider and checker sources, which inspect rather than rely on the rule.
      |> Enum.reject(&(&1 == rel or checker_source?(&1)))
      |> MapSet.new()

    cond do
      measured_nothing?(MapSet.to_list(declared)) ->
        broken_result(
          "reconciliation.pulled_states_declared",
          "@pulled_states_dependents in #{rel}"
        )

      measured_nothing?(MapSet.to_list(citing)) ->
        broken_result("reconciliation.pulled_states_declared", "files citing @pulled_states")

      true ->
        non_declares = citing |> MapSet.difference(declared) |> Enum.sort()
        fantomes = declared |> MapSet.difference(citing) |> Enum.sort()

        %{
          id: "reconciliation.pulled_states_declared",
          remediation:
            "`@pulled_states` porte une garantie pour des modules qui ne l'appellent pas — le " <>
              "fournisseur doit les nommer, sinon le changer casse leur raisonnement en silence",
          status: if(non_declares == [] and fantomes == [], do: :pass, else: :fail),
          evidence:
            Enum.map(non_declares, &"cite @pulled_states, NON declare: #{&1}") ++
              Enum.map(fantomes, &"declare, ne cite plus: #{&1}"),
          note: "provider declares the dependents of its ownership rule (nature 4)"
        }
    end
  end

  # Compare severity membership in code and both schema enums, not ordering.
  # severity_max additionally permits the explicit empty-result sentinel none.
  @severity_max_empty "none"

  @doc false
  @spec check_findings_severities_aligned(String.t()) :: Support.result()
  def check_findings_severities_aligned(root) do
    rel_ex = "lib/fleet/findings_wire.ex"
    rel_json = "priv/workflow/schema/findings.json"

    from_code =
      root
      |> quoted!(rel_ex)
      |> collect(fn
        {:def, _, [{:severities, _, nil} | rest]} -> rest
        {:def, _, [{:severities, _, []} | rest]} -> rest
        _ -> nil
      end)
      |> List.flatten()
      |> collect_strings()
      |> MapSet.new()

    json =
      with {:ok, raw} <- File.read(Path.join(root, rel_json)),
           {:ok, decoded} <- Jason.decode(raw) do
        decoded
      else
        _ -> %{}
      end

    enum = fn path ->
      case get_in(json, path) do
        l when is_list(l) -> MapSet.new(l)
        _ -> MapSet.new()
      end
    end

    from_schema = enum.(["properties", "findings", "items", "properties", "severity", "enum"])

    max_expected = MapSet.put(from_code, @severity_max_empty)
    from_max = enum.(["properties", "severity_max", "enum"])

    cond do
      measured_nothing?(MapSet.to_list(from_code)) ->
        broken_result("findings.severities_aligned", "severities/0 in #{rel_ex}")

      measured_nothing?(MapSet.to_list(from_schema)) ->
        broken_result("findings.severities_aligned", "severity enum in #{rel_json}")

      measured_nothing?(MapSet.to_list(from_max)) ->
        broken_result("findings.severities_aligned", "severity_max enum in #{rel_json}")

      true ->
        code_only = from_code |> MapSet.difference(from_schema) |> Enum.sort()
        schema_only = from_schema |> MapSet.difference(from_code) |> Enum.sort()
        max_missing = max_expected |> MapSet.difference(from_max) |> Enum.sort()
        max_extra = from_max |> MapSet.difference(max_expected) |> Enum.sort()

        measured_verdict("findings.severities_aligned", %{
          remediation:
            "une severite ecrite d'un seul cote est soit refusee au fil (le juge perd sa charge " <>
              "entiere, cf. le cas `none`), soit acceptee et jamais comparee au `block_at`",
          findings:
            Enum.map(code_only, &"absente de l'enum severity: #{inspect(&1)}") ++
              Enum.map(schema_only, &"absente de severities/0: #{inspect(&1)}") ++
              Enum.map(max_missing, &"absente de l'enum severity_max: #{inspect(&1)}") ++
              Enum.map(max_extra, &"en trop dans severity_max: #{inspect(&1)}"),
          note:
            "findings severity vocabulary: severities/0 == enum severity, " <>
              "et == enum severity_max prive de #{inspect(@severity_max_empty)}"
        })
    end
  end

  defp collect_strings(ast) do
    collect(ast, fn
      s when is_binary(s) -> s
      _ -> nil
    end)
  end

  # Compare literal kind_describe clauses with recognised code and YAML producers.
  # Dynamic kinds and unrecognised call shapes are invisible; neither set proves reachability.
  @doc false
  @spec check_escalation_kinds_closed(String.t()) :: Support.result()
  def check_escalation_kinds_closed(root) do
    rel = "lib/fleet/pilot/incident_registry/escalation.ex"

    declared =
      root
      |> quoted!(rel)
      |> collect(fn
        {:defp, _, [{:kind_describe, _, [k]} | _]} when is_atom(k) -> k
        _ -> nil
      end)
      |> MapSet.new()

    from_code =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn f ->
        f |> File.read!() |> Code.string_to_quoted!() |> escalated_kinds()
      end)
      |> MapSet.new()

    from_yaml =
      case File.read(Path.join(root, "priv/event_router/events.yaml")) do
        {:ok, y} ->
          # Ignore line comments before reading YAML kind spellings.
          ~r/escalate_kind:\s*([a-z_]+)/
          |> Regex.scan(y |> String.split("\n") |> Enum.map_join("\n", &strip_comment/1))
          |> Enum.map(fn [_, k] -> String.to_atom(k) end)
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    emitted = MapSet.union(from_code, from_yaml)

    sans_clause = emitted |> MapSet.difference(declared) |> Enum.sort()
    mortes = declared |> MapSet.difference(emitted) |> Enum.sort()

    cond do
      measured_nothing?(MapSet.to_list(declared)) ->
        broken_result("incident.kinds_closed", "defp kind_describe/1 in #{rel}")

      measured_nothing?(MapSet.to_list(emitted)) ->
        broken_result("incident.kinds_closed", "escalate_kind producers (events.yaml + lib/)")

      true ->
        %{
          id: "incident.kinds_closed",
          remediation:
            "tout kind emis doit avoir sa clause `kind_describe/1` (sinon l'escalade CRASHE au " <>
              "lieu d'ouvrir l'issue) et toute clause doit avoir un producteur (sinon la table " <>
              "annonce une remontee que personne ne declenche)",
          status: if(sans_clause == [] and mortes == [], do: :pass, else: :fail),
          evidence:
            Enum.map(sans_clause, &"emis SANS clause: #{inspect(&1)}") ++
              Enum.map(mortes, &"clause MORTE (aucun producteur): #{inspect(&1)}"),
          note: "escalation kinds: emitted set == kind_describe/1 clause set"
        }
    end
  end

  # Recognise five-argument escalation calls, keyword entries and literal Keyword defaults.
  defp escalated_kinds(ast) do
    collect(ast, fn
      {callee, _, [k | rest]} when is_atom(k) and length(rest) == 4 ->
        n = callee_name(callee)
        if n && String.contains?(Atom.to_string(n), "escalate"), do: k, else: nil

      # record_or_escalate/4 carries the kind in opts, not its first argument.
      {:escalate_kind, k} when is_atom(k) and k not in [nil, true, false] ->
        k

      {{:., _, [{:__aliases__, _, [:Keyword]}, g]}, _, [_, :escalate_kind, d]}
      when g in [:get, :get_lazy] and is_atom(d) and d not in [nil, true, false] ->
        d

      _ ->
        nil
    end)
  end

  defp callee_name({:., _, [{n, _, _}]}) when is_atom(n), do: n
  defp callee_name({:., _, [_mod, n]}) when is_atom(n), do: n
  defp callee_name(n) when is_atom(n), do: n
  defp callee_name(_), do: nil

  # Count destination clauses and entries; require names used by the derivation and no strings.
  # Equal counts do not establish matching destinations or distinct returned types.
  @doc false
  @spec check_visual_types_derived(String.t()) :: Support.result()
  def check_visual_types_derived(root) do
    rel = "lib/fleet/labels.ex"
    ast = quoted!(root, rel)

    clauses =
      collect(ast, fn
        {:def, _, [{:type_for_destination, _, [_arg]} | _]} -> :clause
        _ -> nil
      end)

    destinations =
      collect(ast, fn
        {:@, _, [{:destinations, _, [list]}]} when is_list(list) -> length(list)
        _ -> nil
      end)

    body =
      collect(ast, fn
        {:def, _, [{:visual_types, _, a}, [do: b]]} when a in [nil, []] -> b
        _ -> nil
      end)

    cond do
      measured_nothing?(clauses) ->
        broken_result("labels.visual_types_derived", "def type_for_destination/1 in #{rel}")

      measured_nothing?(destinations) ->
        broken_result("labels.visual_types_derived", "@destinations in #{rel}")

      measured_nothing?(body) ->
        broken_result("labels.visual_types_derived", "def visual_types/0 in #{rel}")

      true ->
        visual_types_verdict(rel, length(clauses), hd(destinations), hd(body))
    end
  end

  defp visual_types_verdict(rel, n_clauses, n_dest, body) do
    derived? = reads_name?(body, :destinations) and reads_name?(body, :type_for_destination)
    literals = body |> collect_strings() |> Enum.sort()

    measured_verdict("labels.visual_types_derived", %{
      remediation:
        "une clause de `type_for_destination/1` sans sa destination dans `@destinations` " <>
          "produit un type visuel que `visual_types/0` ne seme pas — il naitra gris et sans " <>
          "description, comme `type:workshop` pendant seize jours",
      findings:
        if(n_clauses == n_dest,
          do: [],
          else: [
            "#{rel}: #{n_clauses} clause(s) type_for_destination/1 pour #{n_dest} @destinations"
          ]
        ) ++
          if(derived?,
            do: [],
            else: ["#{rel}: visual_types/0 ne lit pas @destinations via type_for_destination/1"]
          ) ++
          Enum.map(literals, &"#{rel}: visual_types/0 ecrit un type en dur: #{inspect(&1)}"),
      note: "visual_types derives from type_for_destination over @destinations"
    })
  end

  # Recognise attribute, call and capture references by name, without evaluating them.
  defp reads_name?(body, name) do
    [] !=
      collect(body, fn
        {:@, _, [{^name, _, _}]} -> :ref
        {^name, _, _} -> :ref
        {:/, _, [{^name, _, _}, _]} -> :ref
        _ -> nil
      end)
  end

  # Compare raw-text %Fleet.Event{type: ...} literals with registry keys.
  # Docs, strings and producer structs can match too; generic consumers inspecting type later cannot.
  @doc false
  @spec check_events_registry_keys_aligned(String.t()) :: Support.result()
  def check_events_registry_keys_aligned(root) do
    registry = registry_event_keys(root)

    consumed =
      Path.wildcard(Path.join(root, "lib/**/*.ex"))
      |> Enum.flat_map(&consumed_event_types/1)
      |> Enum.uniq()

    unregistered = Enum.reject(consumed, &MapSet.member?(registry, &1))

    # Require a registry and source files, but not a nonempty set of matched type literals.
    cond do
      measured_nothing?(registry) ->
        broken_result("events.registry.keys_aligned", "key in events.yaml")

      measured_nothing?(Path.wildcard(Path.join(root, "lib/**/*.ex"))) ->
        broken_result("events.registry.keys_aligned", "source under lib/")

      true ->
        %{
          id: "events.registry.keys_aligned",
          remediation:
            "add the consumed type(s) to events.yaml (every handle_info %Fleet.Event{type:} must be a registry key)",
          status: if(unregistered == [], do: :pass, else: :fail),
          evidence: Enum.map(unregistered, &"consumed type outside registry: #{&1}"),
          note: "every consumed type (handle_info %Fleet.Event{type:}) must be an events.yaml key"
        }
    end
  end

  defp registry_event_keys(root) do
    yaml = Path.join(root, "priv/event_router/events.yaml")

    case YamlElixir.read_from_file(yaml) do
      {:ok, %{"events" => events}} when is_map(events) -> MapSet.new(Map.keys(events))
      _ -> MapSet.new()
    end
  end

  # Cross newlines and preceding fields up to a closing brace; nested braces can stop the match.
  defp consumed_event_types(file) do
    case File.read(file) do
      {:ok, content} ->
        ~r/%Fleet\.Event\{[^}]*?type:\s*:"?([a-z_][a-z0-9_.]*)"?/
        |> Regex.scan(content)
        |> Enum.map(fn [_, type] -> type end)

      _ ->
        []
    end
  end
end
