defmodule Mix.Tasks.Lcars.Contracts.Check.Tools do
  # Z4 — classe dans la boundary de son sujet, comme la tache qui l'utilise.
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  La surface d'outils : ce que le catalogue accorde, ce que le serveur MCP expose, ce que le client
  forge sait faire.

  Ces murs gardent une chaine dont chaque maillon est ecrit dans un langage different et dont aucun
  maillon ne peut lire le suivant : un profil de capacite en YAML accorde un bundle, une carte
  declare un outil, le serveur MCP le cable, le client forge l'execute. Rien dans la chaine ne
  verifie qu'elle est continue.

  ⚠ LA PANNE TYPE N'EST PAS UNE ERREUR, C'EST UN SILENCE. Un outil accorde mais non cable ne
  produit aucune exception : il produit une capacite qui n'existe pas. Un outil cable mais non garde
  par role ne produit rien non plus : il produit une capacite que n'importe qui peut appeler. Un
  `{:error, …}` rendu sans garde SE LIT comme un refus poli. D'ou la forme commune de ces murs : ils
  lisent l'AST des deux cotes et comparent les ENSEMBLES, au lieu de verifier qu'un appel « marche ».
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Catalogue
  alias Mix.Tasks.Lcars.Contracts.Check.Support

  import Mix.Tasks.Lcars.Contracts.Check.Support

  @doc """
  A catalogue may not ENUMERATE tools. It may name the tool of a step.

  ⚖ user : *"les catalogues ne doivent pas citer d'outil : les agents ont `tools/list`
  pour voir ce qui existe, on n'a pas besoin de refaire une liste qui mentira."*

  ## The defect is the LIST, not the name

  A catalogue is material an agent reads to know how to work. When it carries an inventory of the
  tool surface, that inventory is a second copy of `tools/list` — hand-kept, never regenerated, and
  wrong the day a tool is added, renamed or withdrawn. `agent-starfleet-base.md` wrote it plainly:
  *"tes skills (`project_create`, `project_install`…)"* — the ellipsis is the list admitting, in its
  own punctuation, that it does not know what it contains.

  Naming the tool of a STEP is the opposite gesture: `runtime-contract.md` saying the wake leads to
  one tool and the completion to another is the protocol's ORDER, not a catalogue of what exists. It
  cannot go stale by omission, because it never claimed to be complete.

  ## The discriminant is PUNCTUATION, and it derives

  Two tool names joined by a comma or a slash is an inventory. Joined by an arrow, it is a sequence.
  Nothing else is read — not the file kind, not the surrounding words.

  Two shapes are excluded by the rule itself rather than by an exception:

    * an `allowedTools:` grant carries ONE name per line, so no pair is ever adjacent;
    * a cross-reference (`- mcp__fleet__project_install  # twin of project_create`) separates its two
      names with prose, not with enumeration punctuation.

  A line-based "one name per line" rule was tried first and rejected: a markdown TABLE ROW cannot be
  split, so the worker protocol's own cycle would have had to lose a name — and the rule would have
  depended on where a paragraph happens to wrap.

  ## Scope

  `priv/catalogue` and `priv/catalogue-system` — the material that ships as a catalogue. Nine
  enumerations were removed the day this was written, across SP drafts, cap-profile comments, a brief
  and a project template.
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

      # Deux arbres, et les DEUX doivent etre la : n'en scanner qu'un rendrait le meme vert propre
      # que n'en scanner aucun.
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
  Every `mcp__fleet__*` grant in every cap-profile must resolve to a declared tool.

  ## What it prevents, and what did NOT prevent it

  A tool's id is written twice: at its `deftool`, and in the `allowedTools` of every role allowed to
  call it. Rename the first and forget the second, and the role silently loses the tool — the
  whitelist simply stops matching. No error, no log: the agent is handed a smaller toolbox and
  discovers it by not having what its own system prompt tells it to call.

  `roles.capabilities_exercisable` does NOT cover this. It fails only when a role carries NONE of a
  capability's tools, so the architect — who holds four delegation tools — stays green after losing
  one. Measured by renaming three ids granted by name: that wall does not move.

  A hand check protects the rename that prompted it and nothing after — a rename missing a copy
  in silence is a recurring shape in this file. The mechanical answer (`@tool_effects` by AST,
  `mcp.tool_descriptions_no_permuted_names`) is the same answer for the same shape.

  Derived from the authority, so there is nothing to maintain: `deftool` declares, cap-profiles copy,
  and a tool added or renamed tomorrow moves the wall by itself.
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

    # INSTRUMENT GUARD, the shape its siblings use: a `deftool` reshape or a cap-profile layout move
    # would empty either side, and an empty side reports the same clean absence as full agreement.
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
  No tool description may name a tool by a PERMUTATION of a real tool's name.

  ## The same rename, missing the same way, twice

  Tool names are object-first (`create_project` → `project_create`). A rename of that shape moves
  the `deftool` names and the `mcp__fleet__` citations, and NOT the bare names written INSIDE the
  description strings — and those strings are the tool catalogue an agent reads. Measured
  (2026-08-21): THIRTEEN occurrences across six descriptions, naming four tools that do not exist;
  `project_import` referring to itself by its old name.

  This is worse than a stale comment. A comment misleads a human who can check; a description is an
  INSTRUCTION to an agent, delivered at the moment it chooses what to call. `card_list`
  told every architect to call `create_project` twice, in the one paragraph that exists to guide
  project framing.

  The scar next to `@tool_effects` already drew the lesson for a list of five bare words: *"a list
  that is not written like the others is a list a rename misses"*, and the answer there was to make
  exhaustiveness MECHANICAL. Prose is the same shape — it just looks like it could not be checked.

  ## The rule DERIVES from the authority, so there is nothing to maintain

  For every declared tool, any PERMUTATION of its own segments that is not the tool itself is
  refused inside a description: `project_create` makes `create_project` illegal, and adding a tool
  tomorrow extends the wall by itself. A trailing `s` is normalised, so `list_projects` is caught as
  a permutation of `project_list`.

  It reads by AST, not by line, so a description split across a `<>` chain is one text — the shape
  that let these thirteen sit under a grep for years.

  ## What it does NOT catch, and why the name says so

  Its name says PERMUTED, not "real tools": *"no description may name a tool that does not exist"*
  would be a claim wider than the code.
  An INVENTED name that is not a reordering passes: `project_import_external`,
  `issue_open`, `project_list_all`. A guard whose name promises more than it measures is green
  exactly where a reader trusts it most, which is this repo's own definition of a bad wall.

  Widening it is not free and not obviously right: a description legitimately carries snake_case
  that is not a tool — `workflow_map`, `declared_name`, `full_name`, `default_branch` — so refusing
  every unknown token needs a hand-kept allow-list, and a hand-kept list is what this whole file
  exists to avoid. The permutation rule is the part that DERIVES, and it is the failure mode that
  actually happened, twice. The rest is named here rather than silently implied.

  ⚠ THE `s` NORMALISATION IS LEXICAL, NOT GRAMMATICAL. `status` normalises to `statu`, so a
  description writing `status_issue` about a concept would be flagged as a permutation of
  `issue_status`. One such stem exists today; the cost grows with the catalogue, and a tool whose
  segment ends in a non-plural `s` is the shape to avoid.
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
        # Same population guard as its siblings: a `deftool` shape change would empty this set and
        # the wall would pass by measuring nothing.
        broken_result(id, "deftool in #{tools_rel} (only #{MapSet.size(declared)}, expected 12+)")

      # ⚠ L'INDEXATION PAR FORME EST NON-INJECTIVE, ET ELLE SE TAIT. Deux outils de meme forme (meme
      # multiset de segments normalises) s'ecrasent dans la map : le survivant garde sa couverture,
      # le perdant n'est plus jamais mesure, et rien dans la sortie ne le dit. Les autres gardes de
      # ce fichier comptent leur population ; celui-ci verifie aussi qu'elle survit a l'indexation.
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

  # Les jetons snake_case d'UN texte qui sont une permutation d'un outil declare sans etre cet outil.
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

  # The MULTISET of a tool name's segments, trailing `s` normalised — so `project_list` and
  # `list_projects` share a shape while `project_create` and `project_close` do not.
  defp tool_shape(name) do
    name
    |> String.split("_")
    |> Enum.map(&String.replace_suffix(&1, "s", ""))
    |> Enum.sort()
  end

  # Every `description(...)` body of a `deftool`, ONE text per call: a description written as a `<>`
  # chain is a single instruction to the agent, and reading it line by line is what hid thirteen of
  # them.
  #
  # ⚠ BORNE AU BLOC `deftool`, ET PAS AU FICHIER. Ramasser tout appel `description/1` de l'AST
  # tiendrait tant que `pod_tools.ex` n'est fait que de `deftool` — donc
  # tant que personne n'y ecrit une fonction d'aide du meme nom, ou n'importe un `description/1`
  # etranger. Le jour ou ca arrive, le mur mesure une population qu'il ne pretend pas mesurer, dans
  # un sens comme dans l'autre.
  defp description_texts(ast) do
    ast
    |> collect(fn
      {:deftool, _, [name | _]} = node when is_binary(name) -> node
      _ -> nil
    end)
    |> Enum.flat_map(&description_calls/1)
  end

  # UN TEXTE PAR APPEL `description/1`, chaine `<>` recollee : c'est la lecture ligne a ligne qui
  # en avait cache treize.
  defp description_calls(tool) do
    collect(tool, fn
      {:description, _, [arg]} -> Enum.join(collect(arg, &if(is_binary(&1), do: &1)), " ")
      _ -> nil
    end)
  end

  # Z7 (F1 / F-C138-format) — the MCP wire requires inputSchema (camelCase) where the
  # ExMCP internal shape is input_schema (snake): missing the projection makes ALL pods
  # mute (tools silently rejected by the vendor CLI — regression F1). The fix lives at the
  # socket frontier (PodSocketAcceptor projects to MCP-wire) + a non-regression test. THIS
  # check locks the CONTRACT at the gate: the projection exists in the code AND the
  # anti-regression test exists (deleting the test is visible to the gate — belt over
  # the ExUnit net).
  @doc """
  Chaque `deftool` porte UNE ligne `# vitrine:`, et elle tient sur une seule ligne.

  ## Pourquoi un mur, et pourquoi de ce cote-ci

  Le build du site lit cette ligne par une regex qui capture jusqu'a la fin de la ligne
  (`assets/github.io/src/lib/tools.js`, `extractVitrine/1`) et refuse un `deftool` qui n'en porte
  pas. Deux raisons de la garder AUSSI ici :

    * cette porte-la est un AUTRE gate (GitHub Actions), et `site.build_inputs` existe justement
      parce que ses gardes ne servent a rien quand le build ne se declenche pas ;
    * c'est cette contrainte qui justifie les `credo:disable-for-next-line` sur la longueur des
      lignes `# vitrine:` de `pod_tools.ex`. Une exemption de lint adossee a un commentaire est une
      exemption que le prochain lecteur retire ; adossee a un mur, elle est tenue.

  ## Ce qu'il mesure

  Pour chaque `deftool "<nom>" do … end` : exactement une ligne `# vitrine:` dans le corps, un
  texte non vide, et RIEN apres elle sur une ligne de continuation (`#` suivi de texte
  immediatement en dessous), qui serait perdue en silence sur la page publique.
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

  # Le verdict d'UN `deftool`. A part de son appelant : le mur enchaine trois questions
  # (presence, unicite, continuation) et les melanger a la construction du resultat rend une
  # fonction que personne ne relit.
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

  # ⚠ LA CONTINUATION EST LE VRAI PIEGE, ET ELLE EST INVISIBLE : le texte reste complet dans le
  # fichier, la page n'en montre que la premiere moitie.
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

  # `{nom, ligne_de_debut, lignes_du_corps}` par `deftool`. Lecture ligne a ligne et non a l'AST :
  # une ligne `# vitrine:` est un COMMENTAIRE, donc absente de l'AST — c'est tout le point (elle ne
  # part jamais dans la charge MCP de l'agent).
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

    # Projection code-side: the camelCase wire key on an EXECUTABLE line (`code_match?` excludes
    # @doc/@moduledoc heredocs + `#` comments — BND-111: a prose mention of "inputSchema" is not a proof).
    projection? = code_match?(root, acceptor, ~r/"inputSchema"/)

    # Test-side proof: the EXECUTABLE assert/refute PAIR, NOT a bare full-file string presence (BND-111:
    # the test's own COMMENT names BOTH tokens → a raw `=~` would stay green even if the asserts were
    # deleted). We require `assert Map.has_key?(… "inputSchema")` AND `refute Map.has_key?(… "input_schema")`
    # each on its own code line (absent test file → code_match? false → fail, hollow-green guard).
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

  # ── Tool authorization (A1) ──────────────────────────────────────────
  # ⚠ `tools/list` IS DISCOVERY, NOT AUTHORIZATION: `tools/call` re-verifies nothing against it, and
  # every pod is handed the SAME catalogue. What stops a producer from calling a destructive op is
  # never the catalogue — it is the gate on that tool's own dispatch path, and nothing refused a new
  # tool wired to an ungated body.
  #
  # Two admissible forms, and no third:
  #   * POD-SCOPED — the clause BINDS the channel identity and its body USES it, so the subject
  #     comes from the SOCKET and never from the wire. Merely receiving the identity is not the
  #     property: the acceptor hands it to every tool alike.
  #   * ROLE-GATED — the body reaches a function that resolves role AND repo from the spawn binding.
  # A clause whose body is a bare argument error is inert: it neither needs nor supplies a gate.
  #
  # ⚠ INVERSE TWIN, AND IT IS THE SHARPER HALF: a dispatch clause with NO schema is not dead code —
  # it is absent from `tools/list` and still dispatched by `tools/call`. A tool that works and that
  # no catalogue admits.
  #
  # Read from the AST, never from a grep: a COMMENT naming a gate must not be able to green this.
  #
  # ⚠ PUBLIC ON PURPOSE: this check reports ABSENCES, and a broken parser reports the same absences
  # as a clean tree. Its refusals must be provable against CRAFTED fixtures, not merely observed
  # green on the real tree — a whole-repo smoke test can never distinguish "nothing wrong" from
  # "nothing measured". It takes its root as an argument precisely so a test can hand it one.
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

    # INSTRUMENT GUARD. Every finding below is an ABSENCE, and an absence is what a broken parser
    # produces too: a `deftool` shape change would empty `declared`, and this check would pass by
    # measuring nothing. The floors are set under the state of the day, not at it — they catch a
    # blind instrument, they do not freeze the tool count.
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

  # 6-106 — L'EXHAUSTIVITE DE LA CLASSIFICATION DES OUTILS, MECANIQUE OU RIEN.
  #
  # Une liste de mots nus posee LOIN des definitions (mesure a la pose : cinq outils proteges sur
  # ~17 contre le double effet) se rate a chaque renommage. `@tool_effects` a cote des `deftool` est
  # traversable par un renommage, mais pas par l'oubli : rien n'oblige celui qui ajoute un `deftool`
  # a le classer.
  #
  # Ce check est ce qui l'oblige, et il porte dans les DEUX sens :
  #   * un outil declare sans effet → le prochain mutateur ajoute est protege par defaut
  #     (`:unknown` → single-flight) et le gate NOMME l'omission au lieu de la laisser dormir ;
  #   * un effet declare pour un outil qui n'existe plus → le residu d'un renommage, exactement la
  #     forme du bug d'origine, vue de l'autre cote.
  #
  # Meme posture d'instrument que son voisin : les findings sont des ABSENCES, et un parseur casse
  # produit les memes. Le plancher attrape un instrument aveugle, il ne fige pas le nombre d'outils.
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
      # ⚠ LES DEUX SENS SONT RAPPORTES ENSEMBLE, et c'est un changement volontaire : le `cond`
      # d'avant taisait les orphelins des qu'un outil n'etait pas classe. Deux desaccords opposes
      # d'une meme table se lisent mieux cote a cote que l'un apres l'autre, en deux passes.
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

  # 6-136 — UN MODOP QUI ORDONNE UN OUTIL QUE SON PORTEUR N'A PAS **GELE LE POD**, ET RIEN NE LE
  # DISAIT NULLE PART.
  #
  # Ce n'est pas une gene de prompt. Mesure de banc, ecrite dans `architect.yaml` et
  # dans `launch_env.ex` : sous `--permission-mode default`, un outil absent d'`allowedTools` ne se
  # saute PAS, il PROMPTE (« Do you want to… 1. Yes 2. Yes, allow all 3. No ») — et un pod n'a
  # personne pour repondre. Il reste vivant, tient son creneau et le verrou `lcars-in-flight` du
  # ticket, et ne produit rien ; la chaine de reprise redispatche alors un pod qui se bloque au meme
  # endroit (mesure : le bundle `brainstorming` ordonnant un `TodoWrite` que ni `architect` ni
  # `starfleet` ne declarent, les deux l'activant).
  #
  # LA CHARGE DE LA PREUVE EST RENVERSEE, ET C'EST CE QUI FAIT TENIR LE MUR. Borner le vocabulaire
  # aux noms deja declares par un cap-profile serait exact, sans faux positif… et MUET sur le defaut
  # qui motive le mur : un outil declare NULLE PART n'est reconnu comme outil par personne. Un
  # mur qu'on desarme en retirant la derniere declaration ne protege rien.
  #
  # Donc : tout nom EN FORME D'OUTIL cite par un bundle doit etre accorde par chacun de ses
  # porteurs, ou figurer ci-dessous avec sa raison. La liste se PURGE quand son sujet disparait
  # (lecon 6-091 : une exemption qui ne correspond plus a rien n'exempte rien et masque la
  # suivante) — et elle le fait.
  #
  # ⚠ UNE EXEMPTION QUE PLUS AUCUN BUNDLE NE CITE EST VIDE, ET LA GARDE LE DIT. Un nom de module
  # cite par le seul exemple d'un bundle disparait avec lui : l'exemption ne designe plus rien, et
  # le check demande sa purge de lui-meme (« … is cited by no bundle — purge it »). Une exemption
  # survivante laisserait un
  # trou nomme dans un mur, pret a couvrir le prochain nom homonyme.
  #
  # La map reste, VIDE : c'est la porte par ou une future exemption entre AVEC sa raison, et son
  # absence forcerait la prochaine a s'inventer un mecanisme.
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

  # `{name, allowedTools, disallowedTools, modops}` per cap-profile of EVERY installed catalogue root.
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

  # `{bundle_name, relative_path, cited_names}` per modop bundle.
  defp catalogue_modop_bundles(root) do
    root
    |> catalogue_roots()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "cap_profile/modop-bundles/*/sp.md")))
    |> Enum.map(fn path ->
      cited = @tool_cite_re |> Regex.scan(File.read!(path)) |> List.flatten() |> Enum.uniq()
      {path |> Path.dirname() |> Path.basename(), Path.relative_to(path, root), cited}
    end)
  end

  # BOTH shipped catalogues, and the plural is the point: `brainstorming` lives in the SYSTEM one
  # while the business roles live in the other, so a check reading a single root would have found
  # the bundle and none of its carriers — or the reverse — and passed on an empty intersection.
  defp catalogue_roots(root),
    do: [Path.join(root, "priv/catalogue"), Path.join(root, "priv/catalogue-system")]

  defp string_list(nil), do: []
  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_), do: []

  # `spec.project` CARRIES TWO POPULATIONS IN ONE SLOT and only one of them was ever written down.
  # The catalogue schema declares four keys with `additionalProperties: false`; the pilot injects
  # four MORE at dispatch (`repo`, `base_sha`, `gate_base_sha`, `pr_base_branch`), read by live code
  # and validated by nothing. The contradiction was silent in both directions: a reader of the
  # schema concluded a catalogue could not pin a base, a reader of the code concluded the schema
  # allowed one.
  #
  # The two halves stay APART deliberately (a card that set `base_sha` would validate and then be
  # overwritten at every dispatch — a knob that reads as configuration and does nothing). What must
  # not happen is the two lists drifting, which is why this wall exists: every key the resolver
  # WRITES must be declared on one side or the other, and no key may be on both.
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
          # « declaree nulle part » et « declaree des deux cotes » sont les deux moities de « jamais
          # les deux, jamais aucun » : elles se rapportent ensemble.
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

  # Keys of the map literal the resolver returns — from the AST, so a key named only in a comment
  # cannot green this, and a key added to the map cannot hide from it.
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

  # Keys of the `@tool_effects` module attribute, read from the AST — never from a grep, for the
  # same reason as `deftool_names/1`: a comment quoting a tool name must not be able to green this.
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

  # ── A declared capability must be EXERCISABLE ────────────────────────
  # A capability is a permission the runtime resolves — `require_onboarder` asks "does this role
  # carry `onboarder`?" and opens the portfolio verbs. So a role can declare one and carry NONE of
  # the tools it opens: the gate would admit the pod, and no call ever reaches the gate. The
  # declaration then grants nothing and describes nothing, which is worse than absent — measured on
  # `architect`, which declared `onboarder` for a transition that had ended, and whose own
  # `allowedTools` comment said the portfolio belonged to starfleet. It stayed green for weeks and
  # made `onboarder` look like a capability with two carriers, which is the fact the cardinality
  # regimes were reasoned from.
  #
  # DERIVED END TO END — no table of capability names lives here, which is the point. Three reads
  # of the AST chain together: a `require_*` gate is a `defp` whose body calls
  # `role_has_capability?(role, :cap)`; a Delegation function is gated by whichever `require_*` its
  # body calls; a tool carries a capability when its dispatch clause reaches such a function. Add a
  # gate for a new capability and this check covers it with no edit.
  #
  # Only TOOL-GATED capabilities are checkable, and the others are silently out of scope on purpose:
  # `producer` is selected by a card, `exception_judge` and `conflict_resolver` are resolved by the
  # runtime to spawn someone. Nothing about them is exercised by the role reaching for a tool, so
  # there is no allow-list to compare against.
  #
  # LIMIT, named rather than papered over: this proves the BUNDLED catalogues, because half its
  # evidence is the runtime's own source and a release has no AST. A third-party catalogue declaring
  # an inert capability is not covered — its boot refuses an unresolvable capability, never a
  # useless one.
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

    # INSTRUMENT GUARD, same reasoning as `mcp.tools_gated`: every finding here is an ABSENCE, and
    # an AST shape change would empty the derivation and report the same clean absence. Two gates
    # exist today; the floor is set under that, not at it.
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

  # `require_x(...)` whose body asks `role_has_capability?(_, :cap)` — the gate, and the
  # capability it gates, read from the tree so a mention in a comment cannot answer for it. A gate
  # asking about several capabilities is skipped rather than guessed: there would be no single
  # answer to "which tools does this capability open".
  #
  # ⚠ `def` AUTANT QUE `defp` : les gates vivent dans `Delegation.Gate`, publiques (`@doc false`)
  # pour que les canaux les appellent. Une lecture des seuls `defp` rend INSTRUMENT BROKEN (le
  # plancher tient) — une derivation attachee a la VISIBILITE d'une fonction mesure son rangement,
  # pas son role.
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

  # A `Delegation` function is gated by whichever `require_*` its own body calls — appele NU quand
  # la gate vit dans le meme module, QUALIFIE (`Gate.require_architect(state)`) quand elle vit
  # dans le socle de la famille. Les deux formes designent la meme gate et doivent compter pareil.
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

  # Les capabilities qu'une clause de dispatch atteint.
  #
  # LA FAMILLE, pas le dernier segment : un canal extrait s'appelle
  # `Delegation.Scratchpad.scratch(...)`, et un test sur `List.last/1` cesserait de le voir — un mur
  # rouge sur « ungated tools [escalation_list, scratch] » pour des canaux pourtant gardes.
  defp capabilities_of_clause(%{body: body}, gated_delegations, table) do
    collect(body, fn
      {{:., _, [{:__aliases__, _, aliases}, fun]}, _, _} ->
        if delegation_call?(aliases, table), do: Map.get(gated_delegations, fun), else: nil

      _ ->
        nil
    end)
  end

  # capability => the tool names that reach it, inverted from the dispatch clauses.
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

  # ── Seam surface ─────────────────────────────────────────────────────
  # The `conforming/2` guard turns a misconfigured seam into a named error instead of an
  # UndefinedFunctionError raised deep inside a half-finished gesture. It can only see what a
  # behaviour DECLARES — so a seam op nobody wrote down is a call the guard vouches for without
  # having checked it. Every seam call must be covered by a @callback of the behaviour on its path
  # (measured 2026-08-04: three dependency ops running inside the supersede retirement, past the
  # point where the live PR is already closed, guarded by nothing).
  #
  # `Delegation` reaches its seams ONLY through a variable holding a resolved module (the guard
  # hands it over). So every remote call on a variable in that file is a seam call and must be
  # declared by one of the four behaviours. One exception, named rather than pattern-matched away:
  # `behaviour.behaviour_info/1` is the guard reflecting ON a behaviour module, not a call THROUGH
  # a seam.
  @seam_behaviours [
    Fleet.MCP.PodTools.Delegation.ForgeClient,
    Fleet.MCP.PodTools.Delegation.EscalationForge,
    Fleet.MCP.PodTools.Delegation.DependencyForge,
    Fleet.MCP.PodTools.Delegation.ForgeWriter,
    Fleet.MCP.PodTools.Delegation.ProjectOnboard
  ]

  # Reflection on a behaviour module, not a seam op. The ONLY admitted exception.
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

    # INSTRUMENT GUARD: both sides of the comparison can go empty on their own. An AST shape change
    # empties `called` and everything is declared; a behaviour that stops resolving empties
    # `declared` and everything is undeclared — the second is loud, the first is silent.
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

  # Remote calls on a VARIABLE (`forge.close_pr(...)`), which in `Delegation` are seam calls and
  # nothing else. `no_parens` nodes are field access (`identity.token`), not calls.
  defp seam_calls(ast) do
    ast
    # ⚠ DEPLIE AVANT DE COMPTER. Un `repo |> forge.post_comment(n, body, opts)` se lit TROIS
    # arguments sur le noeud d'appel : le mur accusait alors une op parfaitement declaree, et
    # aurait manque une op tubee reellement absente du behaviour.
    |> unpipe()
    |> collect(fn
      {{:., _, [{var, _, nil}, fun]}, meta, args} when is_atom(var) and is_atom(fun) ->
        if meta[:no_parens] == true, do: nil, else: {fun, length(args)}

      _ ->
        nil
    end)
    |> Enum.uniq()
  end

  # ── Forge payload fields: received, and read? ────────────────────────
  # PROBE N°1 of the pattern hunt, promoted from a one-off command to a wall.
  #
  # The forge hands back whole objects. The code picks what it needs and the rest is dropped
  # silently — which is correct, right up until the dropped part is the answer to a question someone
  # is reconstructing from the outside. Measured that day: `submitted_at`, `merged_at`, `closed_at`
  # and `html_url` arrived in payloads already fetched (`get_pull`, `issue_get`, `reviews`) and NO
  # line of `lib/` touched them. That list was EXACTLY what the architect had spent three campaigns
  # rebuilding — and one command produced it, with no bench and no agent.
  #
  # `submitted_at` is READ (the reviews carry their substance to the
  # arch), which is the probe having already paid for itself.
  #
  # WHAT THIS IS NOT: a demand that every field be consumed. Most have no business being read. The
  # wall is on the DECISION: a field is read, or it is listed below with what we know about why. An
  # entry with no recorded reason says so in those words — an allowlist that invents rationales is
  # worse than one that admits it is a queue.
  #
  # FROZEN at the current state, per the arbitration: this catches a field that LOSES its last
  # reader, and a new field added to the inventory without a decision. It does not re-litigate the
  # past.
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

    # INSTRUMENT GUARD: the whole check is a set of greps over a tree. A wrong root, a moved lib/,
    # and every field reads as unread — a loud failure, which is survivable — or the inventory goes
    # empty and everything passes, which is not.
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

  # ── Forge mutations: which have a door, and for whom ─────────────────
  # PROBE N°4 of the pattern hunt — "a gesture with no door". A CAPABILITY the runtime can execute
  # with no tool exposing it (`issue_retire`, `project_list`, `emergency_stop` were the measured
  # cases) gets disguised as something else, or stays unreachable. An absence raises no error, which
  # is why it survives: nothing fails, the gesture is just performed sideways.
  #
  # THE SYMMETRIC FAULT: a door nobody holds the key to (a `publish_doc` that no canon cap-profile
  # grants, into the one tree that must stay read-only for every agent) is not harmless — it is an
  # opening that reads as a decision. Such a door is removed, not kept.
  #
  # Mechanised as a two-column table the gate holds: every mutating op of the forge client is either
  # REACHED from a delegation tool, or listed here with why it is runtime-only. The runtime-only
  # answer is the common and correct one — the point is that it becomes a decision on record rather
  # than an omission nobody looked at.
  #
  # `merged_pr_of_issue` is not in the inventory: its name reads like a mutation and it is a READ
  # (it finds the merged PR of an issue). Named here because the next reader will wonder.
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
    # ⚠ PAS DE `File.exists?` SUR LA SOURCE DES MUTATIONS : il rendrait un ensemble VIDE sur un
    # fichier absent — donc `undecided` vaudrait toutes les mutations, un rouge bruyant plutot qu'un
    # vert muet, mais un rouge qui ne dit pas la vraie cause. `quoted!/2` leve : une source illisible est nommee pour
    # ce qu'elle est.
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

  # A quoted key anywhere in `lib/`, MINUS `lib/mix/tasks/`. Deliberately coarse on the pattern: the
  # question is "does anything in this code touch that name", and a stricter parse would answer a
  # narrower one.
  #
  # THE EXCLUSION IS THE LOAD-BEARING PART: the allowlist below LIVES in this file, so without it
  # `"closed_at" =>` counts as a reader and all three deliberately-unread fields report themselves
  # as read (measured on the first run). The instrument measuring its own declaration is the exact
  # defect class this check exists to catch, arriving first in the check itself.
  #
  # Gate tooling is excluded on its own merit too: a field named in a mix task is named by the
  # machinery that audits the product, not by the product answering a question with it.
  defp field_read?(lib, field) do
    args = ["-rq", "--include=*.ex", "--exclude-dir=tasks", ~s("#{field}"), lib]

    case System.cmd("grep", args, stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  # `deftool "name" do … end` — the schemas advertised by `tools/list`.
  defp deftool_names(ast) do
    ast
    |> collect(fn
      {:deftool, _, [name | _]} when is_binary(name) -> name
      _ -> nil
    end)
    |> MapSet.new()
  end

  # `def handle_tool_call("name", args, state)` clauses, grouped by tool name. The catch-all
  # (`handle_tool_call(_unknown, …)`) has no literal name and is skipped: it refuses by definition.
  # ⚠ ON RESOUT L'ALIAS, ON NE COMPARE PAS UNE ORTHOGRAPHE. Chercher le segment `:Delegation` dans
  # le nom TEL QU'ECRIT tient tant que `pod_tools.ex` ecrit `Delegation.Issues.create_issue(...)`.
  # Le jour ou quelqu'un pose `alias Fleet.MCP.PodTools.Delegation.Issues` et appelle
  # `Issues.create_issue(...)` — la forme idiomatique — le segment disparait, les murs cesseraient
  # de voir un outil pourtant garde, et rougiraient sur du code CORRECT. Un mur faux-positif est un
  # mur qu'on desarme.
  #
  # La table d'alias du fichier donne le module REEL ; c'est lui qu'on interroge.
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

  # Le nom d'appel appartient-il a la famille `Delegation` une fois l'alias resolu ?
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

  # A `Delegation` function whose own body reaches a role gate. `Macro.to_string/1` on the BODY AST,
  # so a `require_architect` written in a comment is not in the tree and cannot answer for it.
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

  # Gated = every clause is pod-scoped, role-gated or inert, AND at least one actually carries a
  # gate. A tool made only of refusals is not "safe by absence" — it is a tool that does nothing,
  # and it should not be advertised.
  defp tool_gated?([], _gated_fns, _table), do: false

  defp tool_gated?(clauses, gated_fns, table) do
    Enum.all?(clauses, &clause_ok?(&1, gated_fns, table)) and
      Enum.any?(clauses, &(pod_scoped?(&1) or role_gated?(&1, gated_fns, table)))
  end

  defp clause_ok?(clause, gated_fns, table),
    do: pod_scoped?(clause) or role_gated?(clause, gated_fns, table) or inert?(clause)

  # POD-SCOPED = THE CLAUSE USES THE CHANNEL IDENTITY, not merely receives it. `PodSocketAcceptor`
  # builds `%{pod_id: pod_id}` for EVERY `tools/call`, unconditionally and identically for every
  # tool — so the presence of that key in a clause head says nothing about authorization. Matching
  # `\bpod_id:` alone would accept `%{pod_id: _}`: a clause that pattern-matches the identity and
  # throws it away, then acts globally, reported as gated — a wall one underscore wide.
  #
  # Two conditions, and the second is the one that carries the meaning: the head must BIND the
  # identity to a real variable (`_` and `_pod_id` are discards, and a discard is the tell), and the
  # BODY must mention that variable — the tool's subject is then derived from the channel rather
  # than from the wire, which is the whole property.
  #
  # MEASURED before tightening, because a wall may only be born green: 23 of the 25 tools are
  # ROLE-gated (`require_architect`/`require_onboarder`), every mutator among them, and the only two
  # admitted by this predicate are `get_work_item` and `submit_result` — both bind and both use.
  # The hole was real and nothing was standing in it.
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

  # A bare `{:error, reason, state}` return: no gate, no work.
  defp inert?(%{body: {:{}, _, [:error | _]}}), do: true
  defp inert?(_), do: false

  # LA FAMILLE DE LA DELEGATION, ET NON UN CHEMIN.
  #
  # Un mur attache a une ADRESSE (`pod_tools/delegation.ex` nomme en dur) cesse de voir ce qui
  # demenage : mesure sur le garde d'enumeration des contrats, qui a cesse de voir huit murs au
  # premier decoupage pendant que le gate restait VERT.
  #
  # La famille est lue en entier — `delegation.ex` et tout `delegation/**/*.ex` — donc ces quatre
  # murs sont indifferents a son decoupage, present et futur.
  @doc false
  @spec delegation_sources(String.t()) :: [String.t()]
  def delegation_sources(root) do
    racine = "lib/fleet/mcp/pod_tools/delegation.ex"

    sous =
      root
      # ⚠ `**`, PAS `*` : un glob mono-niveau redevient une ADRESSE des que la famille gagne un
      # sous-dossier. C'est le meme defaut que celui-ci corrige, un cran plus bas — et il serait
      # silencieux, puisque les quatre murs continueraient de rendre un verdict sur une population
      # amputee. `**` couvre le niveau courant a l'identique (verifie : 17 fichiers des deux
      # facons), donc la generalisation ne coute rien aujourd'hui et tient demain.
      |> Path.join("lib/fleet/mcp/pod_tools/delegation/**/*.ex")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    # ⚠ SEULES LES SOURCES QUI EXISTENT. `probe n°4` de `forge_fields_check_test` exige qu'une
    # delegation absente rende un INSTRUMENT CASSE NOMME, pas une exception : un mur doit rendre un
    # verdict lisible, pas tuer la tache qui l'appelle. Laisser `quoted!/2` lever ici serait un gain
    # de lisibilite, pas de contrat.
    Enum.filter([racine | sous], &File.exists?(Path.join(root, &1)))
  end

  # L'AST de chaque source de la famille. Une source illisible fait LEVER `quoted!/2` — un mur qui
  # avalerait l'erreur rendrait une population amputee, donc un vert sur moins que le sujet.
  defp delegation_asts(root), do: Enum.map(delegation_sources(root), &quoted!(root, &1))
end
