defmodule Mix.Tasks.Lcars.Contracts.Check.Tools do
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Checks selected relationships between catalogue grants, MCP declarations,
  dispatch clauses and forge operations.

  These inspections use AST, YAML and text heuristics with different scopes.
  They can detect missing declarations and known source patterns; they do not
  prove authorization, call reachability or actual tool effects. Read each
  check's population guards and exclusions.
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Catalogue
  alias Mix.Tasks.Lcars.Contracts.Check.Support

  import Mix.Tasks.Lcars.Contracts.Check.Support

  @doc """
  Rejects same-line pairs of declared tool names separated by comma or slash
  in visible files of both bundled catalogue trees. Ordered step sequences
  remain allowed: tools/list supplies the inventory, protocols supply the order.

  The regex is punctuation-based, without token boundaries or prose interpretation.
  Other list forms, hidden files and names not declared by deftool are not covered.
  Both trees, some files and at least twelve declared tools must be present.
  """
  @spec check_catalogue_enumerates_no_tools(String.t()) :: Support.result()
  def check_catalogue_enumerates_no_tools(root) do
    id = "catalogue.enumerates_no_tools"
    tools_rel = "lib/fleet/mcp/pod_tools.ex"

    remediation =
      "name the tool of a step, or name none and let `tools/list` answer — a hand-kept inventory " <>
        "of the tool surface is a second list, and the second list is the one that lies"

    declared = deftool_names(quoted!(root, tools_rel))

    trees =
      ["priv/catalogue", "priv/catalogue-system"]
      |> Enum.map(&Path.join(root, &1))
      |> Enum.filter(&File.dir?/1)

    files =
      Enum.flat_map(trees, fn dir ->
        dir |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1)
      end)

    cond do
      MapSet.size(declared) < 12 ->
        broken_result(id, "deftool in #{tools_rel} (only #{MapSet.size(declared)}, expected 12+)")

      length(trees) < 2 ->
        broken_result(id, "catalogue tree under #{root} (found #{length(trees)} of 2)")

      files == [] ->
        broken_result(id, "file under the catalogue trees")

      true ->
        names = declared |> MapSet.to_list() |> Enum.map_join("|", &Regex.escape/1)
        rx = Regex.compile!("`?(#{names})`?[ \t]*[,/][ \t]*`?(#{names})`?")

        offenders =
          for path <- files,
              {:ok, body} = File.read(path),
              {line, n} <- Enum.with_index(String.split(body, "\n"), 1),
              [_, a, b | _] <- [Regex.run(rx, line)],
              do: "#{Path.relative_to(path, root)}:#{n} — #{a} and #{b} enumerated"

        %{
          id: id,
          remediation: if(offenders == [], do: "—", else: remediation),
          status: if(offenders == [], do: :pass, else: :fail),
          evidence: Enum.sort(offenders),
          note:
            if(offenders == [],
              do: "#{length(files)} catalogue file(s) scanned; none enumerates the tool surface",
              else: "#{length(offenders)} line(s) carry an inventory of tools"
            )
        }
    end
  end

  @doc """
  Checks exact mcp__fleet__ grants from the shared catalogue reader against
  literal deftool names. Renaming a tool also requires updating its grants.

  Unlike capabilities_exercisable, this checks every matching grant, not whether
  one tool remains for a capability. Wildcards are treated as literal names;
  the reader's YAML exclusions and scope apply. This does not verify dispatch
  or effective permission behaviour.
  """
  @spec check_tool_grants_resolve(String.t()) :: Support.result()
  def check_tool_grants_resolve(root) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)
    id = "roles.tool_grants_resolve"
    tools_rel = "lib/fleet/mcp/pod_tools.ex"

    declared = deftool_names(quoted!(root, tools_rel))
    roles = Catalogue.scan_catalogue_roles(root)

    grants =
      for role <- roles,
          tool <- role.allowed_tools,
          String.starts_with?(tool, "mcp__fleet__"),
          do: {role.name, String.replace_prefix(tool, "mcp__fleet__", "")}

    broken =
      cond do
        MapSet.size(declared) < 12 ->
          "deftool in #{tools_rel} (only #{MapSet.size(declared)}, expected 12+)"

        grants == [] ->
          "mcp__fleet__ grant across #{length(roles)} cap-profile(s)"

        true ->
          nil
      end

    if broken do
      broken_result(id, broken)
    else
      dangling =
        grants
        |> Enum.reject(fn {_role, tool} -> MapSet.member?(declared, tool) end)
        |> Enum.map(fn {role, tool} -> "#{role} grants mcp__fleet__#{tool} — no such tool" end)
        |> Enum.uniq()
        |> Enum.sort()

      %{
        id: id,
        remediation:
          if(dangling == [],
            do: "—",
            else:
              "rename the grant with the tool, or drop it — a whitelist entry that matches nothing " <>
                "takes the tool away from the role without a word"
          ),
        status: if(dangling == [], do: :pass, else: :fail),
        evidence: dangling,
        note:
          if(dangling == [],
            do: "#{length(grants)} grant(s) across #{length(roles)} roles, all resolving",
            else: "#{length(dangling)} grant(s) name a tool that does not exist"
          )
      }
    end
  end

  @doc """
  Flags snake_case tokens whose normalised segment multiset matches a declared
  tool but whose spelling differs. Strip one trailing s per segment; this is lexical
  (e.g. status becomes statu), not grammatical plural handling.

  Read literal strings within description calls inside deftool AST nodes, joining
  fragments with spaces rather than evaluating expressions. Names split across
  fragments or built dynamically can be missed. Empty descriptions are not a
  population failure.

  Invented names with a different shape pass; legitimate snake_case can also
  collide. Declared shape collisions fail before indexing to avoid losing coverage.
  """
  @spec check_tool_descriptions_no_permuted_names(String.t()) :: Support.result()
  def check_tool_descriptions_no_permuted_names(root) do
    id = "mcp.tool_descriptions_no_permuted_names"
    tools_rel = "lib/fleet/mcp/pod_tools.ex"

    remediation =
      "write the tool's REAL name in the description — an agent reads it as an instruction, and " <>
        "a name that does not resolve is a call it cannot make"

    ast = quoted!(root, tools_rel)
    declared = deftool_names(ast)
    shapes = Enum.map(declared, &tool_shape/1)

    cond do
      MapSet.size(declared) < 12 ->
        broken_result(id, "deftool in #{tools_rel} (only #{MapSet.size(declared)}, expected 12+)")

      # Equal normalised shapes would overwrite a tool in by_shape.
      length(Enum.uniq(shapes)) != length(shapes) ->
        broken_result(
          id,
          "distinct shapes among the #{length(shapes)} deftool names (two collide)"
        )

      true ->
        by_shape = Map.new(declared, fn name -> {tool_shape(name), name} end)

        offenders =
          ast
          |> description_texts()
          |> Enum.flat_map(&permuted_names(&1, by_shape))
          |> Enum.uniq()
          |> Enum.sort()

        %{
          id: id,
          remediation: if(offenders == [], do: "—", else: remediation),
          status: if(offenders == [], do: :pass, else: :fail),
          evidence: offenders,
          note:
            if(offenders == [],
              do:
                "#{MapSet.size(declared)} tools declared; no description names a permutation of " <>
                  "one of them that is not the tool itself",
              else: "descriptions name #{length(offenders)} tool(s) that do not exist"
            )
        }
    end
  end

  defp permuted_names(text, by_shape) do
    ~r/\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b/
    |> Regex.scan(text)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn token ->
      case Map.get(by_shape, tool_shape(token)) do
        nil -> []
        ^token -> []
        real -> ["#{token} → the tool is #{real}"]
      end
    end)
  end

  defp tool_shape(name) do
    name
    |> String.split("_")
    |> Enum.map(&String.replace_suffix(&1, "s", ""))
    |> Enum.sort()
  end

  # Limit description collection to literal-name deftool nodes.
  defp description_texts(ast) do
    ast
    |> collect(fn
      {:deftool, _, [name | _]} = node when is_binary(name) -> node
      _ -> nil
    end)
    |> Enum.flat_map(&description_calls/1)
  end

  defp description_calls(tool) do
    collect(tool, fn
      {:description, _, [arg]} -> Enum.join(collect(arg, &if(is_binary(&1), do: &1)), " ")
      _ -> nil
    end)
  end

  @doc """
  Requires one nonempty vitrine line in each recognised deftool block.
  The site reads only that line, which also motivates its line-length lint exemption.

  The scanner depends on two-space deftool/end formatting and lowercase/underscore
  names. It rejects an immediately following nonempty comment except vitrine/credo
  markers. Text inside strings can match; this is not tokenizer classification.
  At least one recognised block is required, not coverage of every AST declaration.
  """
  @spec check_vitrine_single_line(String.t()) :: Support.result()
  def check_vitrine_single_line(root) do
    id = "mcp.vitrine_single_line"
    rel = "lib/fleet/mcp/pod_tools.ex"

    lignes =
      case File.read(Path.join(root, rel)) do
        {:ok, src} -> String.split(src, "\n")
        _ -> []
      end

    outils = deftool_blocs(lignes)

    fautes = Enum.flat_map(outils, &vitrine_faute(&1, rel))

    if measured_nothing?(outils) do
      broken_result(id, "deftool bloc in #{rel}")
    else
      %{
        id: id,
        remediation:
          "poser UNE ligne `# vitrine: <texte FR>` par `deftool`, sans continuation — le build du " <>
            "site la lit jusqu'a la fin de la ligne et n'en lit pas une seconde",
        status: if(fautes == [], do: :pass, else: :fail),
        evidence: Enum.sort(fautes),
        note: "#{length(outils)} deftool(s), chacun avec sa ligne `# vitrine:` unique"
      }
    end
  end

  defp vitrine_faute({nom, debut, corps}, rel) do
    vitrines =
      for {l, k} <- Enum.with_index(corps),
          [_, texte] <- [Regex.run(~r/#\s*vitrine:\s*(.*)$/, l)],
          do: {k, String.trim(texte)}

    case vitrines do
      [] ->
        ["#{rel}:#{debut} #{nom} : aucune ligne `# vitrine:` — le build du site refuserait"]

      [_, _ | _] ->
        [
          "#{rel}:#{debut} #{nom} : #{length(vitrines)} lignes `# vitrine:` — une seule est lue"
        ]

      [{_k, ""}] ->
        ["#{rel}:#{debut} #{nom} : ligne `# vitrine:` VIDE"]

      [{k, _texte}] ->
        vitrine_continuation(nom, rel, Enum.at(corps, k + 1, ""), debut + k + 1)
    end
  end

  defp vitrine_continuation(nom, rel, suite, ligne) do
    if Regex.match?(~r/^\s*#\s*\S/, suite) and
         not Regex.match?(~r/#\s*(vitrine:|credo:)/, suite) do
      [
        "#{rel}:#{ligne} #{nom} : la ligne `# vitrine:` est SUIVIE d'un commentaire — le site ne " <>
          "lit que la premiere ligne, le reste est perdu en silence"
      ]
    else
      []
    end
  end

  # Vitrine is a source comment, absent from the ordinary AST; this scanner uses line shape.
  defp deftool_blocs(lignes) do
    {blocs, _} =
      Enum.reduce(Enum.with_index(lignes, 1), {[], nil}, fn {l, n}, {acc, courant} ->
        cond do
          match = Regex.run(~r/^  deftool "([a-z_]+)" do\s*$/, l) ->
            {acc, {Enum.at(match, 1), n, []}}

          is_nil(courant) ->
            {acc, nil}

          Regex.match?(~r/^  end\s*$/, l) ->
            {nom, debut, corps} = courant
            {acc ++ [{nom, debut, Enum.reverse(corps)}], nil}

          true ->
            {nom, debut, corps} = courant
            {acc, {nom, debut, [l | corps]}}
        end
      end)

    blocs
  end

  @doc false
  @spec check_mcp_wire_inputschema(String.t()) :: Support.result()
  def check_mcp_wire_inputschema(root) do
    acceptor = "lib/fleet/mcp/pod_socket_acceptor.ex"
    test = "test/fleet/mcp/pod_socket_test.exs"

    # MCP uses inputSchema while ExMCP uses input_schema; require the wire-key source marker.
    projection? = code_match?(root, acceptor, ~r/"inputSchema"/)

    # Require both assertion spellings on their respective lines; this does not run the socket test.
    asserts? =
      code_match?(root, test, ~r/"inputSchema"/, [~r/assert\s+Map\.has_key\?/, ~r/"inputSchema"/]) and
        code_match?(root, test, ~r/"input_schema"/, [
          ~r/refute\s+Map\.has_key\?/,
          ~r/"input_schema"/
        ])

    %{
      id: "mcp.wire_inputschema",
      remediation:
        "restore the MCP-wire projection (inputSchema camelCase) at the socket frontier " <>
          "(PodSocketAcceptor) + the assert/refute pair of pod_socket_test (regression F1: " <>
          "mute pods, tools silently rejected)",
      status: if(projection? and asserts?, do: :pass, else: :fail),
      evidence:
        cond do
          not projection? ->
            ["#{acceptor}: \"inputSchema\" projection absent from the code (F1 reopened)"]

          not asserts? ->
            [
              "#{test}: EXECUTABLE pair assert Map.has_key?(inputSchema) / refute Map.has_key?(input_schema) absent (BND-111: a comment is not proof)"
            ]

          true ->
            []
        end,
      note:
        "socket frontier = wire (camelCase); ExMCP internal shape = snake — F1 locked at the gate"
    }
  end

  # tools/list discovery is not authorization; each dispatch path needs its own gate.
  # Compare declared names with literal-name dispatch clauses and recognised gate forms.
  # Pod binding/use and role-gate recognition are syntactic heuristics, not a security proof.
  @doc false
  @spec check_mcp_tools_gated(String.t()) :: Support.result()
  def check_mcp_tools_gated(root) do
    tools_rel = "lib/fleet/mcp/pod_tools.ex"

    tools_ast = quoted!(root, tools_rel)
    declared = deftool_names(tools_ast)
    clauses = dispatch_clauses(tools_ast)
    table = alias_table(tools_ast)

    gated_fns =
      root
      |> delegation_asts()
      |> Enum.map(&role_gated_functions/1)
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    ungated =
      declared
      |> Enum.reject(&tool_gated?(Map.get(clauses, &1, []), gated_fns, table))
      |> Enum.sort()

    undeclared = clauses |> Map.keys() |> Enum.reject(&(&1 in declared)) |> Enum.sort()

    broken =
      cond do
        MapSet.size(declared) < 12 ->
          "only #{MapSet.size(declared)} deftool found (expected 12+)"

        map_size(clauses) < 12 ->
          "only #{map_size(clauses)} dispatch clauses found (expected 12+)"

        MapSet.size(gated_fns) < 10 ->
          "only #{MapSet.size(gated_fns)} gated delegations (10+)"

        true ->
          nil
      end

    measured_verdict("mcp.tools_gated", %{
      remediation:
        "give the tool a gate: bind the channel identity in its handle_tool_call head " <>
          "(%{pod_id: pod_id}) AND derive the tool's subject from it in the body, or route it " <>
          "through a Delegation function guarded by require_architect/require_onboarder — " <>
          "tools/call does not re-check tools/list, and receiving pod_id is not using it",
      broken: broken && "#{tools_rel}: #{broken}",
      findings:
        if(ungated == [], do: [], else: ["#{tools_rel}: ungated tools #{inspect(ungated)}"]) ++
          if(undeclared == [],
            do: [],
            else: ["#{tools_rel}: dispatched without a deftool #{inspect(undeclared)}"]
          ),
      note:
        "#{MapSet.size(declared)} tools, each pod-scoped or role-gated; " <>
          "#{MapSet.size(gated_fns)} delegations carry a require_* gate"
    })
  end

  # Require equality of deftool names and literal @tool_effects keys.
  # Effect values and actual mutation behaviour are not checked here.
  @doc false
  @spec check_mcp_tool_effects(String.t()) :: Support.result()
  def check_mcp_tool_effects(root) do
    tools_rel = "lib/fleet/mcp/pod_tools.ex"

    declared = deftool_names(quoted!(root, tools_rel))
    classified = tool_effect_names(quoted!(root, tools_rel))

    unclassified = declared |> Enum.reject(&(&1 in classified)) |> Enum.sort()
    orphan = classified |> Enum.reject(&(&1 in declared)) |> Enum.sort()

    broken =
      cond do
        MapSet.size(declared) < 12 ->
          "only #{MapSet.size(declared)} deftool found (expected 12+)"

        MapSet.size(classified) < 12 ->
          "@tool_effects has #{MapSet.size(classified)} entries (12+)"

        true ->
          nil
      end

    measured_verdict("mcp.tool_effects", %{
      remediation:
        "declare the tool's world-effect in `@tool_effects` of Fleet.MCP.PodTools, next to its " <>
          "deftool: `:mutation` (changes the world → single-flight), `:protocol` (the pod's own " <>
          "IN/OUT channel, whose re-emission is designed and owned by the TaskQueue) or `:read`",
      broken: broken && "#{tools_rel}: #{broken}",
      findings:
        if(unclassified == [],
          do: [],
          else: ["#{tools_rel}: tools with no declared effect #{inspect(unclassified)}"]
        ) ++
          if(orphan == [],
            do: [],
            else: ["#{tools_rel}: @tool_effects names no tool declares #{inspect(orphan)}"]
          ),
      note: "#{MapSet.size(declared)} tools, each with a declared world-effect"
    })
  end

  # Missing grants can leave unattended pods waiting for a permission prompt.
  # Check tool-shaped bundle citations against exact allowedTools entries of carriers.
  # DisallowedTools is read but not applied; optional and default bundles both count.
  # Keep non-tool exemptions with their reasons and reject exemptions no bundle cites.
  @modop_not_tools %{}

  @doc false
  @spec check_modop_tools_granted(String.t()) :: Support.result()
  def check_modop_tools_granted(root) do
    profiles = catalogue_profiles(root)
    bundles = catalogue_modop_bundles(root)

    missing =
      for {bundle, path, cited} <- bundles,
          {rname, allowed, _denied, modops} <- profiles,
          bundle in modops,
          tool <- cited,
          not Map.has_key?(@modop_not_tools, tool),
          tool not in allowed,
          do: "#{path}: orders #{tool}, which #{rname} (a carrier) does not grant"

    cited_anywhere = bundles |> Enum.flat_map(fn {_b, _p, cited} -> cited end) |> MapSet.new()

    dead_exemptions =
      @modop_not_tools |> Map.keys() |> Enum.reject(&(&1 in cited_anywhere)) |> Enum.sort()

    cond do
      measured_nothing?(profiles) ->
        broken_result("cap_profile.modop_tools_granted", "cap-profile under the catalogue roots")

      measured_nothing?(bundles) ->
        broken_result("cap_profile.modop_tools_granted", "modop bundle under the catalogue roots")

      measured_nothing?(cited_anywhere) ->
        broken_result("cap_profile.modop_tools_granted", "tool-shaped name cited by any bundle")

      true ->
        %{
          id: "cap_profile.modop_tools_granted",
          remediation:
            "add the tool to `allowedTools` of every role that activates the bundle (the list must " <>
              "cover what a role may LEGITIMATELY reach for — leaving it out does not close it, it " <>
              "wedges the pod on a prompt), stop ordering it in the bundle's sp.md, or declare it " <>
              "in @modop_not_tools with the reason it is not a tool",
          status: if(missing == [] and dead_exemptions == [], do: :pass, else: :fail),
          evidence:
            Enum.sort(missing) ++
              for(
                n <- dead_exemptions,
                do: "@modop_not_tools: #{n} is cited by no bundle — purge it"
              ),
          note:
            "#{length(bundles)} bundles x #{length(profiles)} profiles, " <>
              "#{MapSet.size(cited_anywhere)} tool-shaped names cited, " <>
              "#{map_size(@modop_not_tools)} declared non-tools"
        }
    end
  end

  @tool_cite_re ~r/\b(?:mcp__[a-z0-9_]+|[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+)\b/

  # Read top-level profiles from the two bundled roots, without override merging.
  defp catalogue_profiles(root) do
    root
    |> catalogue_roots()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "cap_profile/cap-profiles/*.yaml")))
    |> Enum.map(fn path ->
      spec = path |> YamlElixir.read_from_file!() |> Map.get("spec", %{})
      scope = Map.get(spec, "scope", %{})
      ms = Map.get(spec, "modop_set", %{})

      {Path.basename(path, ".yaml"), string_list(scope["allowedTools"]),
       string_list(scope["disallowedTools"]),
       string_list(Map.get(ms, "default")) ++ string_list(Map.get(ms, "optional"))}
    end)
  end

  defp catalogue_modop_bundles(root) do
    root
    |> catalogue_roots()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "cap_profile/modop-bundles/*/sp.md")))
    |> Enum.map(fn path ->
      cited = @tool_cite_re |> Regex.scan(File.read!(path)) |> List.flatten() |> Enum.uniq()
      {path |> Path.dirname() |> Path.basename(), Path.relative_to(path, root), cited}
    end)
  end

  # Bundles and carriers can live in different bundled trees.
  defp catalogue_roots(root),
    do: [Path.join(root, "priv/catalogue"), Path.join(root, "priv/catalogue-system")]

  defp string_list(nil), do: []
  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_), do: []

  # Resolver-written project keys must belong to schema or runtime declarations, never both.
  # Runtime keys come from the loaded CapProfile module; this is not schema validation.
  @doc false
  @spec check_cap_profile_project_keys(String.t()) :: Support.result()
  def check_cap_profile_project_keys(root) do
    resolver_rel = "lib/fleet/pilot/step_dispatcher/project_resolver.ex"
    schema_rel = "priv/cap_profile/schema/cap-profile.json"

    schema_keys = schema_project_keys(root, schema_rel)
    runtime_keys = MapSet.new(Fleet.CapProfile.runtime_project_keys())
    written = resolver_project_keys(quoted!(root, resolver_rel))

    undeclared = written |> Enum.reject(&(&1 in schema_keys or &1 in runtime_keys)) |> Enum.sort()
    both = schema_keys |> Enum.filter(&(&1 in runtime_keys)) |> Enum.sort()

    cond do
      measured_nothing?(schema_keys) ->
        broken_result(
          "cap_profile.project_keys_declared",
          "property under spec.project in #{schema_rel}"
        )

      measured_nothing?(written) ->
        broken_result("cap_profile.project_keys_declared", "key written into the project map")

      true ->
        measured_verdict("cap_profile.project_keys_declared", %{
          remediation:
            "declare the new `spec.project` key in the catalogue schema (an operator may set it) " <>
              "or in `Fleet.CapProfile.runtime_project_keys/0` (the pilot injects it) — never both, " <>
              "never neither",
          findings:
            if(undeclared == [],
              do: [],
              else: ["#{resolver_rel}: project keys declared nowhere #{inspect(undeclared)}"]
            ) ++
              if(both == [],
                do: [],
                else: [
                  "#{schema_rel}: keys declared as BOTH catalogue and runtime #{inspect(both)}"
                ]
              ),
          note:
            "#{MapSet.size(schema_keys)} catalogue keys + #{MapSet.size(runtime_keys)} runtime-injected, disjoint"
        })
    end
  end

  defp schema_project_keys(root, rel) do
    root
    |> Path.join(rel)
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["properties", "spec", "properties", "project", "properties"])
    |> Kernel.||(%{})
    |> Map.keys()
    |> MapSet.new()
  end

  # Collect string keys of every AST map containing repo_path, not only returned project maps.
  defp resolver_project_keys(ast) do
    ast
    |> collect(fn
      {:%{}, _, pairs} when is_list(pairs) ->
        keys = for {k, _v} <- pairs, is_binary(k), do: k
        if "repo_path" in keys, do: keys, else: nil

      _ ->
        nil
    end)
    |> List.flatten()
    |> MapSet.new()
  end

  defp tool_effect_names(ast) do
    ast
    |> collect(fn
      {:@, _, [{:tool_effects, _, [{:%{}, _, pairs}]}]} when is_list(pairs) ->
        for {k, _v} <- pairs, is_binary(k), do: k

      _ ->
        nil
    end)
    |> List.flatten()
    |> MapSet.new()
  end

  # For each capability derived from delegation/dispatch syntax, require at least one granted tool.
  # Card-selected and runtime-resolved capabilities are outside this comparison.
  # Only bundled roles are read; there is no nonempty-role guard or runtime authorization proof.
  @doc false
  @spec check_capabilities_exercisable(String.t()) :: Support.result()
  def check_capabilities_exercisable(root) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)
    tools_rel = "lib/fleet/mcp/pod_tools.ex"

    asts = delegation_asts(root)
    gates = asts |> Enum.map(&capability_gates/1) |> Enum.reduce(%{}, &Map.merge/2)

    gated_delegations =
      asts |> Enum.map(&delegation_capabilities(&1, gates)) |> Enum.reduce(%{}, &Map.merge/2)

    tools_by_capability = capability_tools(quoted!(root, tools_rel), gated_delegations)

    inert =
      for role <- Catalogue.scan_catalogue_roles(root),
          cap <- role.capabilities,
          tools = Map.get(tools_by_capability, cap),
          tools != nil,
          not Enum.any?(tools, &(("mcp__fleet__" <> &1) in role.allowed_tools)),
          do: "#{role.name} declares #{cap} and carries none of its tools"

    broken =
      cond do
        map_size(gates) < 2 -> "only #{map_size(gates)} require_* gate(s) derived (expected 2+)"
        map_size(tools_by_capability) < 2 -> "only #{map_size(tools_by_capability)} capability"
        true -> nil
      end

    measured_verdict("roles.capabilities_exercisable", %{
      remediation:
        "either drop the capability from the cap-profile, or add at least one of the tools it " <>
          "gates to that role's allowedTools — a capability that opens no reachable tool " <>
          "authorizes nothing and misdescribes the role",
      broken: broken && "delegation family: #{broken}",
      findings: Enum.sort(inert),
      note:
        "#{map_size(tools_by_capability)} tool-gated capabilities derived from the AST; " <>
          "card-selected and runtime-resolved capabilities are out of scope by nature"
    })
  end

  # Recognise public/private bodies with one distinct literal capability in a local predicate call.
  # The function name need not start with require_; multiple capabilities are skipped.
  defp capability_gates(ast) do
    ast
    |> collect(fn
      {d, _, [head, [do: body]]} when d in [:def, :defp] ->
        with name when not is_nil(name) <- def_name(head),
             [cap] <- body |> collect(&capability_asked/1) |> Enum.uniq() do
          {name, to_string(cap)}
        else
          _ -> nil
        end

      _ ->
        nil
    end)
    |> Map.new()
  end

  defp capability_asked({:role_has_capability?, _, [_role, cap]}) when is_atom(cap), do: cap
  defp capability_asked(_), do: nil

  # Associate public functions by gate-name occurrence, not resolved module or arity.
  defp delegation_capabilities(ast, gates) do
    ast
    |> collect(fn
      {:def, _, [head, [do: body]]} ->
        caps =
          body
          |> collect(fn
            {fun, _, _} when is_atom(fun) -> Map.get(gates, fun)
            {{:., _, [{:__aliases__, _, _}, fun]}, _, _} when is_atom(fun) -> Map.get(gates, fun)
            _ -> nil
          end)
          |> Enum.uniq()

        case {def_name(head), caps} do
          {nil, _} -> nil
          {_name, []} -> nil
          {name, caps} -> {name, caps}
        end

      _ ->
        nil
    end)
    |> Map.new()
  end

  # Include aliased Delegation submodules, not just a final segment named Delegation.
  defp capabilities_of_clause(%{body: body}, gated_delegations, table) do
    collect(body, fn
      {{:., _, [{:__aliases__, _, aliases}, fun]}, _, _} ->
        if delegation_call?(aliases, table), do: Map.get(gated_delegations, fun), else: nil

      _ ->
        nil
    end)
  end

  defp capability_tools(tools_ast, gated_delegations) do
    table = alias_table(tools_ast)

    tools_ast
    |> dispatch_clauses()
    |> Enum.flat_map(fn {tool, clauses} ->
      clauses
      |> Enum.flat_map(&capabilities_of_clause(&1, gated_delegations, table))
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.map(&{&1, tool})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # Compare variable-target calls with the union of the listed loaded behaviours' callbacks.
  # This does not establish which behaviour covers each injected target or its execution path.
  @seam_behaviours [
    Fleet.MCP.PodTools.Delegation.ForgeClient,
    Fleet.MCP.PodTools.Delegation.EscalationForge,
    Fleet.MCP.PodTools.Delegation.DependencyForge,
    Fleet.MCP.PodTools.Delegation.ForgeWriter,
    Fleet.MCP.PodTools.Delegation.ProjectOnboard
  ]

  @seam_reflection [behaviour_info: 1]

  @doc false
  @spec check_mcp_seam_surface(String.t(), [module()]) :: Support.result()
  def check_mcp_seam_surface(root, behaviours \\ @seam_behaviours) do
    called = root |> delegation_asts() |> Enum.flat_map(&seam_calls/1) |> Enum.uniq()

    declared =
      behaviours
      |> Enum.flat_map(fn b ->
        Code.ensure_loaded!(b)
        b.behaviour_info(:callbacks)
      end)
      |> MapSet.new()

    undeclared =
      called
      |> Enum.reject(fn {fun, arity} ->
        MapSet.member?(declared, {fun, arity}) or {fun, arity} in @seam_reflection
      end)
      |> Enum.sort()

    broken =
      cond do
        length(called) < 15 -> "only #{length(called)} seam calls found (expected 15+)"
        MapSet.size(declared) < 20 -> "only #{MapSet.size(declared)} callbacks declared (20+)"
        true -> nil
      end

    measured_verdict("mcp.seam_surface_declared", %{
      remediation:
        "declare the op as a @callback of the behaviour that covers its path " <>
          "(ForgeClient / EscalationForge / DependencyForge / ProjectOnboard) — " <>
          "conforming/2 vouches only for what a behaviour declares",
      broken: broken && "delegation family: #{broken}",
      findings:
        if(undeclared == [],
          do: [],
          else: [
            "delegation family: called through a seam, declared nowhere: #{inspect(undeclared)}"
          ]
        ),
      note:
        "#{length(called)} seam calls covered by #{MapSet.size(declared)} callbacks " <>
          "over #{length(behaviours)} behaviours"
    })
  end

  # Variable-target calls count; no_parens field access is excluded.
  defp seam_calls(ast) do
    ast
    # Expand pipes before counting arguments.
    |> unpipe()
    |> collect(fn
      {{:., _, [{var, _, nil}, fun]}, meta, args} when is_atom(var) and is_atom(fun) ->
        if meta[:no_parens] == true, do: nil, else: {fun, length(args)}

      _ ->
        nil
    end)
    |> Enum.uniq()
  end

  # Frozen inventory: require quoted field-name mentions or a recorded unread decision.
  # The grep does not distinguish reads from writes, docs or strings; it excludes directories named tasks.
  # New forge response fields are not discovered automatically.
  @forge_read_fields ~w(state merged number title body labels commit_id dismissed login head base
                        sha assignees full_name submitted_at created_at updated_at)

  @forge_unread_fields %{
    "merged_at" =>
      "the merge is PROVEN by the `stage/merged` label (WS1, set by the seal at merge); a " <>
        "timestamp would be a second source of the same fact, and the two can disagree",
    "closed_at" =>
      "no decision recorded — not read, no reason established. A candidate for the next pass, " <>
        "not a justification",
    "html_url" =>
      "a forge-supplied URL carries whatever host ANSWERED, which is not necessarily the one we " <>
        "address — the container reaches `http://gitea:3000` where a browser reaches a published " <>
        "port, so handing it on as-is would propagate the wrong host. No reader today: that is " <>
        "the state, not a plan"
  }

  @doc false
  @spec check_forge_fields_read(String.t()) :: Support.result()
  def check_forge_fields_read(root) do
    lib = Path.join(root, "runtime/lib")
    lib = if File.dir?(lib), do: lib, else: Path.join(root, "lib")

    unread = Enum.reject(@forge_read_fields, &field_read?(lib, &1))
    resurrected = Enum.filter(Map.keys(@forge_unread_fields), &field_read?(lib, &1))

    broken =
      cond do
        not File.dir?(lib) -> "lib/ not found under #{root}"
        length(@forge_read_fields) < 10 -> "inventory shrank to #{length(@forge_read_fields)}"
        true -> nil
      end

    measured_verdict("forge.payload_fields_read", %{
      remediation:
        "either read the field where it answers a real question, or move it to " <>
          "@forge_unread_fields WITH what is known about why — including \"no reason recorded\" " <>
          "when that is the truth",
      broken: broken,
      findings:
        if(unread == [],
          do: [],
          else: ["fields that LOST their last reader: #{inspect(Enum.sort(unread))}"]
        ) ++
          if(resurrected == [],
            do: [],
            else: ["now read, remove from the allowlist: #{inspect(resurrected)}"]
          ),
      note:
        "#{length(@forge_read_fields)} fields read, #{map_size(@forge_unread_fields)} deliberately " <>
          "not (1 of them with no reason recorded — that is a queue, not an answer)"
    })
  end

  # Match a manual mutation inventory against delegation seam names or runtime-only decisions.
  # Calls lose module/arity identity here and need not be tool-reachable; this is not an exclusive split.
  # merged_pr_of_issue is a read, so it is excluded from the mutation inventory.
  @forge_mutations ~w(add_issue_dependency add_label close_issue close_pr create_branch
                      create_issue merge_pr post_comment post_review post_route
                      remove_issue_dependency remove_label)

  @forge_mutations_runtime_only %{
    "create_branch" =>
      "the feature branch is cut by the dispatch, from the base the card decided; an agent " <>
        "choosing where to cut would decide the face, which is not its call",
    "merge_pr" =>
      "the merge is the gatekeeper seal's, behind branch protection and the jury; a tool would " <>
        "put a second door on the one gesture the whole rail exists to guard",
    "post_review" =>
      "a native review carries a VERDICT and the merge gate counts approvals; the judge posts " <>
        "through its step, never as a tool it could call twice",
    "post_route" =>
      "the route is engraved by the burn from the project card — an agent writing it would " <>
        "choose its own pipeline",
    "add_label" =>
      "labels are the forge-side state machine (`stage/*`, `wait/*`); a tool would let an actor " <>
        "write the state instead of reaching it",
    "remove_label" => "same reason as `add_label` — the state is reached, never set"
  }

  @doc false
  @spec check_forge_mutations_exposed(String.t()) :: Support.result()
  def check_forge_mutations_exposed(root) do
    called =
      root
      |> delegation_asts()
      |> Enum.flat_map(&seam_calls/1)
      |> MapSet.new(&elem(&1, 0))

    undecided =
      Enum.reject(@forge_mutations, fn m ->
        MapSet.member?(called, String.to_atom(m)) or
          Map.has_key?(@forge_mutations_runtime_only, m)
      end)

    stale = Enum.filter(Map.keys(@forge_mutations_runtime_only), &(&1 not in @forge_mutations))

    broken =
      cond do
        delegation_sources(root) == [] -> "no delegation source found under #{root}"
        length(@forge_mutations) < 8 -> "inventory shrank to #{length(@forge_mutations)}"
        MapSet.size(called) < 5 -> "only #{MapSet.size(called)} seam calls parsed"
        true -> nil
      end

    measured_verdict("forge.mutations_exposed", %{
      remediation:
        "expose the capability through a gated delegation tool, or record it in " <>
          "@forge_mutations_runtime_only with WHY it stays runtime-only",
      broken: broken,
      findings:
        if(undecided == [],
          do: [],
          else: ["mutations with no door and no decision: #{inspect(undecided)}"]
        ) ++
          if(stale == [],
            do: [],
            else: ["listed runtime-only but no longer a mutation: #{inspect(stale)}"]
          ),
      note:
        "#{length(@forge_mutations)} forge mutations — " <>
          "#{length(@forge_mutations) - map_size(@forge_mutations_runtime_only)} reachable by a " <>
          "tool, #{map_size(@forge_mutations_runtime_only)} runtime-only ON RECORD"
    })
  end

  # Exclude task directories so the checker's own field inventory cannot count as a reader.
  # Nonzero grep status, including an error, is treated as no match.
  defp field_read?(lib, field) do
    args = ["-rq", "--include=*.ex", "--exclude-dir=tasks", ~s("#{field}"), lib]

    case System.cmd("grep", args, stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp deftool_names(ast) do
    ast
    |> collect(fn
      {:deftool, _, [name | _]} when is_binary(name) -> name
      _ -> nil
    end)
    |> MapSet.new()
  end

  # Resolve written aliases across the file; lexical scopes and alias chains are not modelled.
  defp alias_table(ast) do
    {_, table} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, segs}]} = n, acc ->
          {n, Map.put(acc, List.last(segs), segs)}

        {:alias, _, [{:__aliases__, _, segs}, opts]} = n, acc when is_list(opts) ->
          court =
            case opts[:as] do
              {:__aliases__, _, x} -> List.last(x)
              _ -> List.last(segs)
            end

          {n, Map.put(acc, court, segs)}

        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, enfants}]} = n, acc ->
          {n,
           Enum.reduce(enfants, acc, fn {:__aliases__, _, s}, a ->
             Map.put(a, List.last(s), base ++ s)
           end)}

        n, acc ->
          {n, acc}
      end)

    table
  end

  defp delegation_call?(aliases, table) do
    resolus =
      case Map.fetch(table, hd(aliases)) do
        {:ok, plein} -> plein ++ tl(aliases)
        :error -> aliases
      end

    :Delegation in resolus
  end

  defp dispatch_clauses(ast) do
    ast
    |> collect(fn
      {:def, _, [head, [do: body]]} -> dispatch_clause(head, body)
      _ -> nil
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp dispatch_clause({:when, _, [inner, _guard]}, body), do: dispatch_clause(inner, body)

  defp dispatch_clause({:handle_tool_call, _, [name, _args, state]}, body) when is_binary(name),
    do: {name, %{state: state, body: body}}

  defp dispatch_clause(_head, _body), do: nil

  # Search rendered body text for require_architect/onboarder; same names merge across modules.
  defp role_gated_functions(ast) do
    ast
    |> collect(fn
      {:def, _, [head, [do: body]]} ->
        name = def_name(head)

        if name && Macro.to_string(body) =~ ~r/require_(architect|onboarder)\(/,
          do: name,
          else: nil

      _ ->
        nil
    end)
    |> MapSet.new()
  end

  # Every recognised clause must qualify, and at least one must be more than an error tuple.
  defp tool_gated?([], _gated_fns, _table), do: false

  defp tool_gated?(clauses, gated_fns, table) do
    Enum.all?(clauses, &clause_ok?(&1, gated_fns, table)) and
      Enum.any?(clauses, &(pod_scoped?(&1) or role_gated?(&1, gated_fns, table)))
  end

  defp clause_ok?(clause, gated_fns, table),
    do: pod_scoped?(clause) or role_gated?(clause, gated_fns, table) or inert?(clause)

  # Match a non-discard pod_id binding and the same name in rendered body text.
  # A textual mention does not prove the tool derives its subject from that identity.
  defp pod_scoped?(%{state: state, body: body}) do
    case Regex.run(~r/pod_id:\s*([a-z][a-zA-Z0-9_]*)/, Macro.to_string(state)) do
      [_, var] -> Macro.to_string(body) =~ ~r/\b#{Regex.escape(var)}\b/
      nil -> false
    end
  end

  defp role_gated?(%{body: body}, gated_fns, table) do
    body
    |> collect(fn
      {{:., _, [{:__aliases__, _, aliases}, fun]}, _, _} ->
        if delegation_call?(aliases, table), do: fun, else: nil

      _ ->
        nil
    end)
    |> Enum.any?(&MapSet.member?(gated_fns, &1))
  end

  # Error-tuple syntax is accepted as inert without inspecting element expressions.
  defp inert?(%{body: {:{}, _, [:error | _]}}), do: true
  defp inert?(_), do: false

  # Scan delegation.ex and recursive delegation sources so extracted channels remain visible.
  @doc false
  @spec delegation_sources(String.t()) :: [String.t()]
  def delegation_sources(root) do
    racine = "lib/fleet/mcp/pod_tools/delegation.ex"

    sous =
      root
      |> Path.join("lib/fleet/mcp/pod_tools/delegation/**/*.ex")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    # Omit absent paths so callers can report their population guard.
    Enum.filter([racine | sous], &File.exists?(Path.join(root, &1)))
  end

  # Existing unreadable or invalid sources raise through quoted!.
  defp delegation_asts(root), do: Enum.map(delegation_sources(root), &quoted!(root, &1))
end
