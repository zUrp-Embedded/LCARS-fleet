defmodule Mix.Tasks.Lcars.Contracts.DerniersMursCheckTest do
  @moduledoc """
  Synthetic-tree regressions for contract checks, including directed boot/verifier
  inclusion, missing populations and explicit artifact exclusions. Fixtures test
  recognized source shapes; they do not execute the represented runtime behavior.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.{Artifact, Events, Runtime, SingleSource, Tools, Types}

  defp arbre(fichiers) do
    root = Fleet.TestEnv.tmp_path("derniers_murs")
    on_exit(fn -> File.rm_rf!(root) end)

    for {rel, contenu} <- fichiers do
      chemin = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(chemin))
      File.write!(chemin, contenu)
    end

    root
  end

  describe "boot.verifier_covers_rail — un vert qui precede un boot rouge" do
    defp pilot(boot, verif) do
      [
        {"lib/fleet/pilot/application.ex",
         "defmodule Fleet.Pilot.Application do\n" <>
           "  def step_children! do\n#{Enum.map_join(boot, "", &"    #{&1}(x)\n")}    []\n  end\n\n" <>
           "  def verify_cards_and_roles!(x) do\n#{Enum.map_join(verif, "", &"    #{&1}(x)\n")}    :ok\n  end\nend\n"}
      ]
    end

    @gardes ~w(validate_cards! validate_roles!)

    test "le verificateur couvre le boot → vert" do
      assert %{status: :pass, evidence: []} =
               Runtime.check_verifier_covers_rail(arbre(pilot(@gardes, @gardes)))
    end

    test "une garde du boot absente du verificateur est nommee" do
      assert %{status: :fail, evidence: [ev]} =
               Runtime.check_verifier_covers_rail(arbre(pilot(@gardes, ["validate_cards!"])))

      assert ev =~ "validate_roles!"
      assert ev =~ "absente du verificateur"
    end

    test "⚠ LE SENS EST ORIENTE — une garde EN PLUS chez le verificateur est CONSERVATRICE" do
      assert %{status: :pass, evidence: []} =
               Runtime.check_verifier_covers_rail(
                 arbre(pilot(["validate_cards!"], @gardes ++ ["validate_extra!"]))
               )
    end

    test "un verificateur VIDE → INSTRUMENT CASSE, jamais « le boot est couvert »" do
      assert %{status: :fail, evidence: [ev]} =
               Runtime.check_verifier_covers_rail(arbre(pilot(@gardes, [])))

      assert ev =~ "INSTRUMENT BROKEN"
    end
  end

  describe "eval_doors.transport_started — une porte qui meurt sur `unknown registry`" do
    test "une porte qui demarre son transport → vert" do
      root =
        arbre([
          {"lib/fleet/porte.ex",
           "defmodule P do\n  def eval_x do\n" <>
             "    Supervisor.start_link([Fleet.Forge.finch_spec()], strategy: :one_for_one)\n" <>
             "  end\nend\n"}
        ])

      assert %{status: :pass, evidence: []} = Runtime.check_eval_doors_start_transport(root)
    end

    test "une porte qui atteint la forge SANS demarrer son pool est nommee" do
      # Release eval loads the app without starting it; a Forge call needs its Finch transport.
      # This fixture tests recognition of startup text, not the transport itself.
      root =
        arbre([
          {"lib/fleet/porte.ex",
           "defmodule P do\n  def eval_x, do: Fleet.Forge.get(\"/x\")\nend\n"}
        ])

      assert %{status: :fail, evidence: ["lib/fleet/porte.ex"]} =
               Runtime.check_eval_doors_start_transport(root)
    end

    test "une porte qui n'atteint PAS la forge n'a rien a demarrer" do
      root = arbre([{"lib/fleet/porte.ex", "defmodule P do\n  def eval_x, do: :ok\nend\n"}])

      assert %{status: :fail, evidence: [ev]} = Runtime.check_eval_doors_start_transport(root)
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end

  describe "launch.backend_containment_coherent — la resurrection d'un mecanisme casse" do
    test "le module absent et la config muette → vert" do
      root = arbre([{"config/runtime.exs", "import Config\n"}])

      assert %{status: :pass, evidence: []} = Runtime.check_launch_backend_containment(root)
    end

    test "le module qui reapparait est nomme" do
      root =
        arbre([
          {"config/runtime.exs", "import Config\n"},
          {"lib/fleet/spawner/launch_backend/tmux_backend.ex", "defmodule TB do\nend\n"}
        ])

      assert %{status: :fail, evidence: [ev]} = Runtime.check_launch_backend_containment(root)
      assert ev =~ "must not reappear"
    end

    test "⚠ MEME EN COMMENTAIRE — dans la config, une mention est un signal de resurrection" do
      # This check deliberately scans raw config, including comments.
      root = arbre([{"config/runtime.exs", "# ancien: LaunchBackend.TmuxBackend\n"}])

      assert %{status: :fail, evidence: [ev]} = Runtime.check_launch_backend_containment(root)
      assert ev =~ "no longer reference TmuxBackend"
    end
  end

  describe "capprofile.modop_incompatible_path — un chemin qui n'existe pas dans le spec" do
    @deux ["lib/fleet/cap_profile.ex", "lib/fleet/cap_profile/invariants.ex"]

    test "aucun des deux fichiers ne lit le mauvais chemin → vert" do
      root =
        arbre(
          for f <- @deux,
              do:
                {f,
                 "defmodule M do\n  def c(s), do: get_in(s, [\"modop_set\", \"incompatible\"])\nend\n"}
        )

      assert %{status: :pass, evidence: []} =
               Runtime.check_capprofile_modop_incompatible_path(root)
    end

    test "⚠ LES DEUX FICHIERS SONT SURVEILLES — le mauvais chemin peut revenir dans l'un ou l'autre" do
      # Both the current invariants file and its former cap_profile location are scanned.
      for fautif <- @deux do
        root =
          arbre(
            for f <- @deux do
              corps =
                if f == fautif,
                  do: "  def c(s), do: Map.get(spec, \"modop_incompatible\", [])\n",
                  else: "  def c(s), do: get_in(s, [\"modop_set\", \"incompatible\"])\n"

              {f, "defmodule M do\n#{corps}end\n"}
            end
          )

        assert %{status: :fail, evidence: ev} =
                 Runtime.check_capprofile_modop_incompatible_path(root)

        assert Enum.any?(ev, &(&1 =~ Path.basename(fautif))), "non detecte dans #{fautif}"
      end
    end
  end

  describe "types.public_functions_spec — Dialyzer n'a rien a comparer" do
    test "une fonction publique avec son `@spec` → vert" do
      root =
        arbre([
          {"lib/a.ex",
           "defmodule A do\n  @spec f(integer()) :: integer()\n  def f(x), do: x\nend\n"}
        ])

      assert %{status: :pass, evidence: []} = Types.check_public_functions_spec(root)
    end

    test "une fonction publique SANS `@spec` est nommee, avec son fichier" do
      root = arbre([{"lib/a.ex", "defmodule A do\n  def f(x), do: x\nend\n"}])

      assert %{status: :fail, evidence: [ev]} = Types.check_public_functions_spec(root)
      assert ev =~ "lib/a.ex"
      assert ev =~ "f"
    end

    test "⚠ LES CALLBACKS DE BEHAVIOUR SONT EXEMPTES — leur contrat vit dans le behaviour" do
      # These callback names are exempted by the check's fixed list.
      root =
        arbre([
          {"lib/a.ex",
           "defmodule A do\n  use GenServer\n  def init(s), do: {:ok, s}\n" <>
             "  def handle_call(_m, _f, s), do: {:reply, :ok, s}\nend\n"}
        ])

      assert %{status: :pass, evidence: []} = Types.check_public_functions_spec(root)
    end

    test "aucune source lue → INSTRUMENT CASSE" do
      assert %{status: :fail, evidence: [ev]} = Types.check_public_functions_spec(arbre([]))
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end

  describe "forge.shape_contained — connaitre la forme de l'API hors du domaine forge" do
    test "un module hors domaine qui n'ouvre pas la charge → vert" do
      root =
        arbre([
          {"lib/fleet/pilot/x.ex", "defmodule X do\n  def f(p), do: Payload.head_sha(p)\nend\n"}
        ])

      assert %{status: :pass, evidence: []} = SingleSource.check_forge_shape_contained(root)
    end

    test "un acces direct a la charge hors du domaine est nomme" do
      root =
        arbre([
          {"lib/fleet/pilot/x.ex", "defmodule X do\n  def f(p), do: p[\"head\"][\"sha\"]\nend\n"}
        ])

      assert %{status: :fail, evidence: ev} = SingleSource.check_forge_shape_contained(root)
      assert ev != []
    end

    test "⚠ LE DOMAINE FORGE LUI-MEME EST EXEMPTE — c'est SA charge" do
      root =
        arbre([
          {"lib/fleet/forge/payload.ex",
           "defmodule Fleet.Forge.Payload do\n  def head_sha(p), do: p[\"head\"][\"sha\"]\nend\n"},
          {"lib/fleet/pilot/x.ex", "defmodule X do\n  def f(p), do: Payload.head_sha(p)\nend\n"}
        ])

      assert %{status: :pass, evidence: []} = SingleSource.check_forge_shape_contained(root)
    end
  end

  describe "site.build_inputs — le hors-perimetre se DIT, il ne se tait pas" do
    test "⚠ ARBRE DU SITE ABSENT → `:skip` QUI L'ANNONCE, et c'est la seule forme acceptee" do
      # Runtime-only images do not carry the site; the skip must be reported.
      #
      # ⚖ user 2026-09-20 : ce cas rendait `:pass`. La note disait « HORS PERIMETRE » pendant que le
      # statut disait « verifie » — deux mots contradictoires sur la meme ligne, et c'est le statut
      # qu'un lecteur pressé retient. `:skip` est desormais le troisieme mot du vocabulaire ; il ne
      # fait pas echouer la porte (une image runtime-only serait rouge par construction) mais il se
      # compte a part dans le resume.
      root = arbre([{"runtime/lib/a.ex", "defmodule A do\nend\n"}])

      assert %{status: :skip, note: note} =
               Artifact.check_site_build_inputs(Path.join(root, "runtime"))

      assert note =~ "HORS PERIMETRE"
      assert note =~ "assets/github.io"
    end

    defp source_site(cible),
      do:
        {"assets/github.io/src/lib/data.js",
         "const p = join(here, '..', '..', '..', '..', #{cible});\n"}

    defp workflow(chemins),
      do:
        {".github/workflows/site.yml",
         "on:\n  push:\n    paths:\n" <> Enum.map_join(chemins, "", &"      - '#{&1}'\n")}

    test "le filtre `paths:` couvre la source lue → vert MESURE" do
      root =
        arbre([
          source_site("'runtime', 'priv', 'catalogue.yaml'"),
          workflow(["assets/github.io/**", "runtime/priv/catalogue.yaml"])
        ])

      assert %{status: :pass, note: note} =
               Artifact.check_site_build_inputs(Path.join(root, "runtime"))

      refute note =~ "HORS PERIMETRE"
      assert note =~ "1 derivees"
    end

    test "⚠ UNE SOURCE LUE HORS DU FILTRE EST NOMMEE — le site decrirait la version d'avant" do
      # A missing workflow input can leave the site stale because no rebuild is triggered.
      root =
        arbre([
          source_site("'runtime', 'priv', 'catalogue.yaml'"),
          workflow(["assets/github.io/**"])
        ])

      assert %{status: :fail, evidence: [ev]} =
               Artifact.check_site_build_inputs(Path.join(root, "runtime"))

      assert ev =~ "HORS paths:"
      assert ev =~ "runtime/priv/catalogue.yaml"
    end

    test "⚠ UN SEGMENT DYNAMIQUE EXIGE UN GLOB — nommer trois fichiers ne ferme pas un repertoire" do
      # A dynamic filename needs directory coverage, not an enumeration of known files.
      root =
        arbre([
          {"assets/github.io/src/lib/data.js",
           "const p = join(here, '..', '..', '..', '..', 'runtime', 'priv', f);\n"},
          workflow(["assets/github.io/**", "runtime/priv/catalogue.yaml"])
        ])

      assert %{status: :fail, evidence: [ev]} =
               Artifact.check_site_build_inputs(Path.join(root, "runtime"))

      assert ev =~ "lecture dynamique"
    end

    test "⚠ ARBRE PRESENT MAIS AUCUNE ENTREE DERIVEE → fail-closed, pas un vert" do
      root =
        arbre([
          {"assets/github.io/src/lib/data.js", "export const x = 1;\n"},
          workflow(["assets/github.io/**"])
        ])

      assert %{status: :fail, evidence: [ev]} =
               Artifact.check_site_build_inputs(Path.join(root, "runtime"))

      assert ev =~ "fail-closed"
    end
  end

  describe "mcp.wire_inputschema — des pods muets, des outils rejetes en silence" do
    @acceptor "lib/fleet/mcp/pod_socket_acceptor.ex"
    @temoin "test/fleet/mcp/pod_socket_test.exs"

    defp wire(acceptor_corps, temoin_corps),
      do: [
        {@acceptor, "defmodule A do\n#{acceptor_corps}end\n"},
        {@temoin, "defmodule T do\n#{temoin_corps}end\n"}
      ]

    @projection "  def wire(t), do: %{\"inputSchema\" => t.schema}\n"
    @paire ~s|  test "x" do\n    assert Map.has_key?(t, "inputSchema")\n| <>
             "    refute Map.has_key?(t, \"input_schema\")\n  end\n"

    test "la projection et la paire assert/refute → vert" do
      assert %{status: :pass, evidence: []} =
               Tools.check_mcp_wire_inputschema(arbre(wire(@projection, @paire)))
    end

    test "la projection absente du code est nommee" do
      assert %{status: :fail, evidence: [ev]} =
               Tools.check_mcp_wire_inputschema(
                 arbre(wire("  def wire(t), do: %{\"input_schema\" => t.schema}\n", @paire))
               )

      assert ev =~ "projection absent"
    end

    test "⚠ LE JETON SUR UNE LIGNE DE CODE NE PROUVE RIEN — c'est la PAIRE qui est exigee" do
      # Require both assertion patterns; an attribute carrying the token is insufficient.
      # This does not establish that the assertions execute or inspect the projected value.
      sans_paire =
        "  @attendu \"inputSchema\"\n" <>
          "  test \"x\" do\n" <>
          "    assert t.wire == @attendu\n" <>
          "    refute Map.has_key?(t, \"input_schema\")\n" <>
          "  end\n"

      assert %{status: :fail, evidence: [ev]} =
               Tools.check_mcp_wire_inputschema(arbre(wire(@projection, sans_paire)))

      assert ev =~ "BND-111"
    end

    test "le fichier de temoin absent est un ECHEC, pas une absence de preuve" do
      root = arbre([{@acceptor, "defmodule A do\n#{@projection}end\n"}])

      assert %{status: :fail, evidence: [ev]} = Tools.check_mcp_wire_inputschema(root)
      assert ev =~ "absent"
    end
  end

  describe "template.gitea_expansion — un projet livre avec ses `${VAR}` litteraux" do
    defp face(fichiers, controle) do
      base = "priv/catalogue/project_template/main"

      [{"#{base}/.gitea/template", Enum.map_join(controle, "", &"#{&1}\n")}] ++
        for {rel, contenu} <- fichiers, do: {"#{base}/#{rel}", contenu}
    end

    test "la liste couvre exactement les fichiers porteurs → vert" do
      root =
        arbre(
          face(
            [
              {"README.md", "# ${REPO_NAME}\n"},
              {"LICENSE", "Copyright ${YEAR}\n"},
              {"x.txt", "rien\n"}
            ],
            ["README.md", "LICENSE"]
          )
        )

      assert %{status: :pass, evidence: []} = Artifact.check_gitea_template_expansion(root)
    end

    test "un fichier PORTEUR hors liste est nomme — il sort avec ses litteraux" do
      root =
        arbre(
          face([{"README.md", "# ${REPO_NAME}\n"}, {"CHANGELOG.md", "${MONTH}/${DAY}\n"}], [
            "README.md"
          ])
        )

      assert %{status: :fail, evidence: [ev]} = Artifact.check_gitea_template_expansion(root)
      assert ev =~ "porteur NON liste"
      assert ev =~ "CHANGELOG.md"
    end

    test "⚠ L'AUTRE SENS COMPTE AUSSI — une entree listee sans variable" do
      root =
        arbre(
          face([{"README.md", "# ${REPO_NAME}\n"}, {"x.txt", "rien\n"}], ["README.md", "x.txt"])
        )

      assert %{status: :fail, evidence: [ev]} = Artifact.check_gitea_template_expansion(root)
      assert ev =~ "liste mais sans variable"
    end

    test "⚠ UNE FACE ABSENTE ECHOUE, elle n'est pas « hors perimetre »" do
      # The template ships with runtime artifacts, so its absence is not a sibling-tree skip.
      assert %{status: :fail, evidence: [ev]} = Artifact.check_gitea_template_expansion(arbre([]))
      assert ev =~ "INSTRUMENT BROKEN"
    end

    test "la liste de controle absente est un ECHEC aussi" do
      root =
        arbre([
          {"priv/catalogue/project_template/main/README.md", "# ${REPO_NAME}\n"}
        ])

      assert %{status: :fail, evidence: [ev]} = Artifact.check_gitea_template_expansion(root)
      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "liste de controle"
    end
  end

  describe "tests.doctest_declarations_have_examples — un fichier qui a l'air couvert et ne joue rien" do
    alias Mix.Tasks.Lcars.Contracts.Check.Tests

    test "une declaration adossee a des exemples → vert" do
      root =
        arbre([
          {"lib/fleet/slug.ex",
           "defmodule Fleet.Slug do\n  @doc \"\"\"\n  iex> Fleet.Slug.f(1)\n  1\n  \"\"\"\n  def f(x), do: x\nend\n"},
          {"test/fleet/slug_test.exs", "defmodule T do\n  doctest Fleet.Slug\nend\n"}
        ])

      assert %{status: :pass, evidence: []} =
               Tests.check_doctest_declarations_have_examples(root)
    end

    test "une declaration sur un module SANS `iex>` est nommee" do
      root =
        arbre([
          {"lib/fleet/slug.ex", "defmodule Fleet.Slug do\n  def f(x), do: x\nend\n"},
          {"test/fleet/slug_test.exs", "defmodule T do\n  doctest Fleet.Slug\nend\n"}
        ])

      assert %{status: :fail, evidence: [ev]} =
               Tests.check_doctest_declarations_have_examples(root)

      assert ev =~ "NO `iex>` example"
      assert ev =~ "Fleet.Slug"
    end

    test "⚠ UN MODULE QUI NE RESOUT PAS N'EST PAS ACCUSE — ce serait le mur pleurant son angle mort" do
      root =
        arbre([
          {"lib/fleet/slug.ex",
           "defmodule Fleet.Slug do\n  @doc \"iex> x\"\n  def f(x), do: x\nend\n"},
          {"test/fleet/slug_test.exs",
           "defmodule T do\n  doctest Fleet.Slug\n  doctest Fleet.Ailleurs.Truc\nend\n"}
        ])

      assert %{status: :pass, note: note} =
               Tests.check_doctest_declarations_have_examples(root)

      assert note =~ "1 module(s) unresolved, not judged"
    end

    test "aucune declaration → INSTRUMENT CASSE" do
      assert %{status: :fail, evidence: [ev]} =
               Tests.check_doctest_declarations_have_examples(arbre([]))

      assert ev =~ "INSTRUMENT BROKEN"
    end

    test "⚠ AUCUN MODULE RESOLU → INSTRUMENT CASSE, meme si des declarations existent" do
      root =
        arbre([
          {"test/fleet/x_test.exs", "defmodule T do\n  doctest Fleet.Nulle.Part\nend\n"}
        ])

      assert %{status: :fail, evidence: [ev]} =
               Tests.check_doctest_declarations_have_examples(root)

      assert ev =~ "no declared module resolved"
    end
  end

  describe "declaration.max_fan_ceiling — un debit que le schema accepte et que le moteur ecrete" do
    defp plafonds(module, schema) do
      [
        {"lib/fleet/pilot/poller/admission.ex",
         "defmodule A do\n" <> if(module, do: "  @max_max_fan #{module}\n", else: "") <> "end\n"},
        {"priv/cap_profile/schema/declaration.json",
         Jason.encode!(%{
           "properties" =>
             if(schema, do: %{"max_fan" => %{"maximum" => schema}}, else: %{"max_fan" => %{}})
         })}
      ]
    end

    test "les deux plafonds egaux → vert" do
      assert %{status: :pass, evidence: []} =
               Runtime.check_declaration_max_fan_ceiling(arbre(plafonds(4, 4)))
    end

    test "une derive est nommee, avec les DEUX valeurs" do
      assert %{status: :fail, evidence: [ev]} =
               Runtime.check_declaration_max_fan_ceiling(arbre(plafonds(4, 8)))

      assert ev =~ "schema says 8"
      assert ev =~ "module says 4"
    end

    test "⚠ LA VALEUR SE LIT DANS LA SOURCE, PAS EN APPELANT LE MODULE" do
      # Read Admission's source attribute without widening its Pilot boundary export.
      # The fixture checks that a missing attribute fails; no Admission function is called.
      assert %{status: :fail, evidence: [ev]} =
               Runtime.check_declaration_max_fan_ceiling(arbre(plafonds(nil, 4)))

      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "@max_max_fan"
    end

    test "le plafond absent du schema est un INSTRUMENT CASSE aussi" do
      assert %{status: :fail, evidence: [ev]} =
               Runtime.check_declaration_max_fan_ceiling(arbre(plafonds(4, nil)))

      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "maximum"
    end
  end

  describe "roles.tool_grants_resolve — une carte qui accorde un outil qui n'existe pas" do
    defp outils(noms) do
      {"lib/fleet/mcp/pod_tools.ex",
       "defmodule Fleet.MCP.PodTools do\n" <>
         Enum.map_join(noms, "", &"  deftool \"#{&1}\", do: :ok\n") <> "end\n"}
    end

    defp carte_outils(nom, accordes) do
      {"priv/catalogue/cap_profile/cap-profiles/#{nom}.yaml",
       "kind: CapabilityProfile\nmetadata:\n  name: #{nom}\nspec:\n  scope:\n    allowedTools:\n" <>
         Enum.map_join(accordes, "", &"      - #{&1}\n")}
    end

    @douze for i <- 1..12, do: "outil_#{i}"

    test "tous les accords resolvent → vert" do
      root =
        arbre([
          outils(@douze),
          carte_outils("engineer", ["mcp__fleet__outil_1", "Bash", "mcp__fleet__outil_2"])
        ])

      assert %{status: :pass, evidence: []} = Tools.check_tool_grants_resolve(root)
    end

    test "un accord qui ne resout sur rien est nomme, avec le role" do
      root =
        arbre([outils(@douze), carte_outils("engineer", ["mcp__fleet__outil_disparu"])])

      assert %{status: :fail, evidence: [ev]} = Tools.check_tool_grants_resolve(root)
      assert ev =~ "engineer grants mcp__fleet__outil_disparu"
      assert ev =~ "no such tool"
    end

    test "⚠ LES OUTILS HORS PREFIXE NE SONT PAS DES ACCORDS MCP" do
      # Vendor tools are outside the mcp__fleet__ grant comparison.
      root = arbre([outils(@douze), carte_outils("engineer", ["Bash", "Read", "WebSearch"])])

      assert %{status: :fail, evidence: [ev]} = Tools.check_tool_grants_resolve(root)
      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "mcp__fleet__ grant"
    end

    test "⚠ TROP PEU DE `deftool` → INSTRUMENT CASSE : la forme n'est plus reconnue" do
      root =
        arbre([
          outils(["outil_1", "outil_2"]),
          carte_outils("engineer", ["mcp__fleet__outil_1"])
        ])

      assert %{status: :fail, evidence: [ev]} = Tools.check_tool_grants_resolve(root)
      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "expected 12+"
    end
  end

  describe "cap_profile.modop_tools_granted — un bundle qui ordonne un outil que le role n'a pas" do
    defp bundle_sp(nom, prose),
      do: {"priv/catalogue/cap_profile/modop-bundles/#{nom}/sp.md", prose}

    defp porteur(nom, modops, accordes) do
      {"priv/catalogue/cap_profile/cap-profiles/#{nom}.yaml",
       "kind: CapabilityProfile\nmetadata:\n  name: #{nom}\nspec:\n" <>
         "  scope:\n    allowedTools:\n" <>
         Enum.map_join(accordes, "", &"      - #{&1}\n") <>
         "  modop_set:\n    default:\n" <> Enum.map_join(modops, "", &"      - #{&1}\n")}
    end

    test "le bundle n'ordonne que ce que ses porteurs accordent → vert" do
      root =
        arbre([
          bundle_sp("brainstorming", "Utilise WebSearch pour explorer.\n"),
          porteur("engineer", ["brainstorming"], ["WebSearch"])
        ])

      assert %{status: :pass, evidence: []} = Tools.check_modop_tools_granted(root)
    end

    test "un outil ordonne et non accorde est nomme — le pod se COINCE sur un prompt" do
      root =
        arbre([
          bundle_sp("brainstorming", "Utilise WebSearch pour explorer.\n"),
          porteur("engineer", ["brainstorming"], ["Bash"])
        ])

      assert %{status: :fail, evidence: [ev]} = Tools.check_modop_tools_granted(root)
      assert ev =~ "orders WebSearch"
      assert ev =~ "engineer"
    end

    test "⚠ SEULS LES PORTEURS SONT JUGES — un role qui n'active pas le bundle n'a rien a accorder" do
      root =
        arbre([
          bundle_sp("brainstorming", "Utilise WebSearch pour explorer.\n"),
          porteur("engineer", ["brainstorming"], ["WebSearch"]),
          porteur("scribe", ["autre-bundle"], ["Bash"])
        ])

      assert %{status: :pass, evidence: []} = Tools.check_modop_tools_granted(root)
    end

    test "⚠ AUCUN NOM D'OUTIL CITE → INSTRUMENT CASSE, jamais « rien a signaler »" do
      root =
        arbre([
          bundle_sp("brainstorming", "reflechis posement, sans outil.\n"),
          porteur("engineer", ["brainstorming"], ["Bash"])
        ])

      assert %{status: :fail, evidence: [ev]} = Tools.check_modop_tools_granted(root)
      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "tool-shaped name"
    end
  end

  describe "reconciliation.pulled_states_declared — une dependance qui ne laisse aucune trace" do
    # Semantic dependencies expressed by @pulled_states citations must be declared by the provider.
    defp reconciliation(dependants) do
      {"lib/fleet/pilot/poller/reconciliation.ex",
       "defmodule R do\n  @pulled_states [:a, :b]\n" <>
         "  @pulled_states_dependents #{inspect(dependants)}\n  def f, do: @pulled_states\nend\n"}
    end

    defp dependant(rel), do: {rel, "defmodule D do\n  # raisonne sur @pulled_states\nend\n"}

    test "les dependants declares sont exactement ceux qui citent → vert" do
      root = arbre([reconciliation(["lib/fleet/pilot/x.ex"]), dependant("lib/fleet/pilot/x.ex")])

      assert %{status: :pass, evidence: []} = Events.check_pulled_states_declared(root)
    end

    test "⚠ UN DEPENDANT QUI APPARAIT SANS ETRE DECLARE — c'est le sens qui coute" do
      root =
        arbre([
          reconciliation(["lib/fleet/pilot/x.ex"]),
          dependant("lib/fleet/pilot/x.ex"),
          dependant("lib/fleet/pilot/y.ex")
        ])

      assert %{status: :fail, evidence: [ev]} = Events.check_pulled_states_declared(root)
      assert ev =~ "NON declare"
      assert ev =~ "y.ex"
    end

    test "une declaration FANTOME est nommee aussi — elle annonce une dependance morte" do
      root =
        arbre([
          reconciliation(["lib/fleet/pilot/x.ex", "lib/fleet/pilot/parti.ex"]),
          dependant("lib/fleet/pilot/x.ex")
        ])

      assert %{status: :fail, evidence: [ev]} = Events.check_pulled_states_declared(root)
      assert ev =~ "ne cite plus"
      assert ev =~ "parti.ex"
    end

    test "⚠ LE VERIFICATEUR LIT LA REGLE, IL N'EN DEPEND PAS — et c'est une REGLE, pas une liste" do
      # Checker source paths are exempt to avoid counting their own search patterns.
      root =
        arbre([
          reconciliation(["lib/fleet/pilot/x.ex"]),
          dependant("lib/fleet/pilot/x.ex"),
          dependant("lib/mix/tasks/lcars/contracts/check/faux.ex")
        ])

      assert %{status: :pass, evidence: []} = Events.check_pulled_states_declared(root)
    end

    test "aucun dependant declare → INSTRUMENT CASSE" do
      root = arbre([reconciliation([]), dependant("lib/fleet/pilot/x.ex")])

      assert %{status: :fail, evidence: [ev]} = Events.check_pulled_states_declared(root)
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end

  describe "mcp.vitrine_single_line — une presentation publique tronquee en silence" do
    # tools.js reads vitrine text to end of line; wrapping loses public text.
    # The corresponding credo line-length exemptions preserve this machine-readable format.
    defp outils_mcp(blocs) do
      corps =
        Enum.map_join(blocs, "\n", fn {nom, lignes} ->
          "  deftool \"#{nom}\" do\n" <> Enum.map_join(lignes, "", &"    #{&1}\n") <> "  end\n"
        end)

      [{"lib/fleet/mcp/pod_tools.ex", "defmodule Fleet.MCP.PodTools do\n#{corps}end\n"}]
    end

    @ok [
      {"run_probe", ["# vitrine: Fait jouer une sonde et rend son fait brut.", "meta(:x)"]},
      {"open_issue", ["# vitrine: Delegue une brique a la fleet.", "meta(:y)"]}
    ]

    test "une ligne de vitrine par outil, sans continuation → vert" do
      assert %{status: :pass, evidence: []} =
               Tools.check_vitrine_single_line(arbre(outils_mcp(@ok)))
    end

    test "un `deftool` sans vitrine est nomme — le build du site le refuserait" do
      root = arbre(outils_mcp([{"muet", ["meta(:x)"]} | @ok]))

      assert %{status: :fail, evidence: [ev]} = Tools.check_vitrine_single_line(root)
      assert ev =~ "muet"
      assert ev =~ "aucune ligne"
    end

    test "⚠ UNE CONTINUATION EST LE VRAI PIEGE — le texte reste entier dans le fichier" do
      root =
        arbre(
          outils_mcp([
            {"coupe",
             ["# vitrine: Une presentation qui deborde", "# et se poursuit ici.", "meta(:x)"]}
            | @ok
          ])
        )

      assert %{status: :fail, evidence: [ev]} = Tools.check_vitrine_single_line(root)
      assert ev =~ "coupe"
      assert ev =~ "perdu"
    end

    test "un commentaire ORDINAIRE apres la vitrine n'est pas une continuation… si" do
      # A blank line distinguishes a following ordinary comment from a vitrine continuation.
      root =
        arbre(
          outils_mcp([
            {"aere",
             ["# vitrine: Une presentation nette.", "", "# un commentaire de code", "meta(:x)"]}
            | @ok
          ])
        )

      assert %{status: :pass, evidence: []} = Tools.check_vitrine_single_line(root)
    end

    test "deux lignes `# vitrine:` : une seule est lue, donc c'est une faute" do
      root =
        arbre(
          outils_mcp([
            {"double", ["# vitrine: la premiere", "# vitrine: la seconde", "meta(:x)"]} | @ok
          ])
        )

      assert %{status: :fail, evidence: [ev]} = Tools.check_vitrine_single_line(root)
      assert ev =~ "2 lignes"
    end

    test "une vitrine VIDE est une faute — le site afficherait un nom nu" do
      root = arbre(outils_mcp([{"vide", ["# vitrine:", "meta(:x)"]} | @ok]))

      assert %{status: :fail, evidence: [ev]} = Tools.check_vitrine_single_line(root)
      assert ev =~ "VIDE"
    end

    test "aucun `deftool` lu → INSTRUMENT CASSE" do
      assert %{status: :fail, evidence: [ev]} = Tools.check_vitrine_single_line(arbre([]))
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end
end
