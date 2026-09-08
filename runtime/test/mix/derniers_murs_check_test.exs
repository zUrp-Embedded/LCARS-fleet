defmodule Mix.Tasks.Lcars.Contracts.DerniersMursCheckTest do
  @moduledoc """
  Les derniers murs sans fixture rouge, prouves contre des arbres FABRIQUES.

  `boot.verifier_covers_rail`, `eval_doors.transport_started`,
  `launch.backend_containment_coherent`, `capprofile.modop_incompatible_path`,
  `types.public_functions_spec`, `forge.shape_contained`, `site.build_inputs`,
  `mcp.wire_inputschema`, `roles.tool_grants_resolve`.

  ## Trois formes que ce fichier exerce, et qu'aucune autre tranche ne portait

  1. **La couverture ORIENTEE.** `boot.verifier_covers_rail` ne compare pas deux ensembles egaux :
     le verificateur autonome doit CONTENIR le boot, jamais l'inverse. Une garde qu'il joue en plus
     est conservatrice ; une garde qui manque rend un vert qui precede un boot rouge.
  2. **La residue-absence.** `launch.backend_containment_coherent` et
     `capprofile.modop_incompatible_path` gardent qu'une chose N'EST PAS la. Zero occurrence et
     « je n'ai pas regarde » sortent identiques, et ces deux-la n'ont pas le meme garde.
  3. **Le hors-perimetre EXPLICITE.** `site.build_inputs` rend `pass` en le DISANT quand l'arbre du
     site n'est pas la — un fail-closed y ferait echouer la construction de l'image sur une
     plaquette qu'elle n'embarque pas. C'est la seule forme de vert que ce depot accepte sur du
     terrain non mesure, et elle se distingue d'un vert muet.
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
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
      # Une egalite stricte ferait rougir un verificateur plus severe que le boot : un rouge de
      # trop, jamais un vert menteur. Sans ce temoin, quelqu'un « simplifierait » en egalite et
      # rendrait le mur hostile a la seule direction qui ne coute rien.
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
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
      # Un `eval` de release CHARGE l'app sans la DEMARRER : le premier appel forge meurt sur
      # `unknown registry: Fleet.Forge.Finch`, sous la ligne d'erreur que la porte imprime pour une
      # forge qui n'a pas repondu — donc en accusant la forge.
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
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
      # Ce cote-la lit la source BRUTE, sans depouiller les commentaires, et c'est ecrit dans le
      # mur. La regle inverse de ses voisins, et delibere : `containment: none` est servi par
      # `host_launch.sh`, et voir le nom revenir dans la config du runtime suffit a alerter.
      root = arbre([{"config/runtime.exs", "# ancien: LaunchBackend.TmuxBackend\n"}])

      assert %{status: :fail, evidence: [ev]} = Runtime.check_launch_backend_containment(root)
      assert ev =~ "no longer reference TmuxBackend"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
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
      # La fonction gardee vit dans `invariants.ex`, mais elle a vecu dans `cap_profile.ex` : un
      # mur d'un seul fichier laisserait la faute revenir la ou elle etait deja.
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
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
      # Le restater par implementation est la duplication que ce depot refuse ailleurs. Sans cette
      # exemption, chaque GenServer du corpus rougirait, et un mur qui accuse le nominal se
      # desactive.
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "forge.shape_contained — connaitre la forme de l'API hors du domaine forge" do
    test "un module hors domaine qui n'ouvre pas la charge → vert" do
      root =
        arbre([
          {"lib/fleet/pilot/x.ex", "defmodule X do\n  def f(p), do: Payload.head_sha(p)\nend\n"}
        ])

      assert %{status: :pass, evidence: []} = SingleSource.check_forge_shape_contained(root)
    end

    test "un acces direct a la charge hors du domaine est nomme" do
      # Une montee de version de la forge devient indetectable au gate des qu'un module hors
      # domaine connait la forme de sa reponse.
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "site.build_inputs — le hors-perimetre se DIT, il ne se tait pas" do
    test "⚠ ARBRE DU SITE ABSENT → `pass` QUI L'ANNONCE, et c'est la seule forme acceptee" do
      # Un fail-closed ici ferait echouer la construction de l'image sur une plaquette qu'elle
      # n'embarque pas — le stage `build` ne copie que `runtime/`. Et un `pass` muet serait un vert
      # sur du terrain non mesure. La note porte donc la difference.
      root = arbre([{"runtime/lib/a.ex", "defmodule A do\nend\n"}])

      assert %{status: :pass, note: note} =
               Artifact.check_site_build_inputs(Path.join(root, "runtime"))

      assert note =~ "HORS PERIMETRE"
      assert note =~ "assets/github.io"
    end

    # Une source du site qui LIT le runtime : `join(here, '..', …)` remonte depuis
    # `assets/github.io/src/lib/` jusqu'a la racine du depot, puis redescend.
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
      # Le mode de panne est MUET DANS LA MAUVAISE DIRECTION : les gardes du build sont ecrits pour
      # echouer plutot que servir du perime, et ils ne servent a rien quand le build NE TOURNE PAS.
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
      # `join(dir, f)` nomme un fichier dont le dernier segment est inconnu : ce qui est lu est le
      # REPERTOIRE. Une entree `paths:` fichier par fichier laisserait passer le quatrieme.
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
      # Distinct du hors-perimetre : ici l'arbre EST la, donc l'instrument devait mesurer quelque
      # chose. Zero derivee veut dire que le deriveur ne reconnait plus la forme des sources, et un
      # filtre `paths:` ne peut pas etre declare correct contre un ensemble vide.
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "mcp.wire_inputschema — des pods muets, des outils rejetes en silence" do
    @acceptor "lib/fleet/mcp/pod_socket_acceptor.ex"
    @temoin "test/fleet/mcp/pod_socket_test.exs"

    defp wire(acceptor_corps, temoin_corps),
      do: [
        {@acceptor, "defmodule A do\n#{acceptor_corps}end\n"},
        {@temoin, "defmodule T do\n#{temoin_corps}end\n"}
      ]

    @projection "  def wire(t), do: %{\"inputSchema\" => t.schema}\n"
    @paire "  test \"x\" do\n    assert Map.has_key?(t, \"inputSchema\")\n" <>
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
      # BND-111 cote temoin, et la forme qui discrimine vraiment. Un `code_match?` sur le seul
      # jeton est satisfait par n'importe quelle ligne de code qui le porte — un attribut, une
      # constante, une comparaison — alors que ce qui protege la regression F1 (pods muets, outils
      # rejetes en silence) est le COUPLE : `assert Map.has_key?(… "inputSchema")` ET
      # `refute Map.has_key?(… "input_schema")`, chacun sur sa ligne.
      #
      # Ici le `refute` est bien la, mais le jeton camelCase ne vit que dans un attribut. Le mur
      # doit rougir ; un mur relache passerait.
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
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
      # Une liste qui nomme un fichier sans variable n'est pas inoffensive : elle apprend au
      # prochain lecteur que ce fichier est expanse, et il ecrira un `${VAR}` ailleurs en croyant
      # que la liste suit.
      root =
        arbre(
          face([{"README.md", "# ${REPO_NAME}\n"}, {"x.txt", "rien\n"}], ["README.md", "x.txt"])
        )

      assert %{status: :fail, evidence: [ev]} = Artifact.check_gitea_template_expansion(root)
      assert ev =~ "liste mais sans variable"
    end

    test "⚠ UNE FACE ABSENTE ECHOUE, elle n'est pas « hors perimetre »" do
      # `priv/catalogue` part avec CHAQUE artefact — le stage image copie tout sauf `deploy`,
      # `git-hooks` et `system-prompt`. Une face absente n'est donc pas un contexte, c'est une face
      # perdue. Mesure a la pose du garde : sans lui, renommer la face rendait « 0 fail ».
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
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
      # La derivation nom → chemin peut simplement etre fausse pour un module qui ne suit pas la
      # convention. L'accuser ferait rougir un contrat sain, et la note le compte a part.
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
      # Le cas ou la derivation entiere est cassee : des declarations, aucune cible lue. « Zero
      # module sans exemple » serait alors vrai et vide de sens.
      root =
        arbre([
          {"test/fleet/x_test.exs", "defmodule T do\n  doctest Fleet.Nulle.Part\nend\n"}
        ])

      assert %{status: :fail, evidence: [ev]} =
               Tests.check_doctest_declarations_have_examples(root)

      assert ev =~ "no declared module resolved"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
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
      # Un projet declare alors un debit que le schema ACCEPTE et que le moteur ecrete en silence :
      # une declaration qui valide et ne s'applique pas, le pire des trois resultats possibles.
      assert %{status: :fail, evidence: [ev]} =
               Runtime.check_declaration_max_fan_ceiling(arbre(plafonds(4, 8)))

      assert ev =~ "schema says 8"
      assert ev =~ "module says 4"
    end

    test "⚠ LA VALEUR SE LIT DANS LA SOURCE, PAS EN APPELANT LE MODULE" do
      # Deux raisons, et la premiere mord : `Admission` n'est pas exporte par la boundary
      # `Fleet.Pilot`, et elargir un export pour qu'un lint y accede est le reflexe que la boundary
      # existe pour refuser. La seconde est la regle du fichier : un instrument de gate MESURE
      # l'arbre, il ne joue pas le produit — un check qui exige l'app compilee ne peut rien dire
      # d'un arbre qui ne construit pas.
      #
      # Le corollaire testable : l'attribut disparu est un INSTRUMENT CASSE, pas un accord.
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
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
      # Une carte qui accorde un outil inexistant ne casse rien au boot : le pod se coince sur un
      # prompt, et le nom manquant n'apparait nulle part.
      root =
        arbre([outils(@douze), carte_outils("engineer", ["mcp__fleet__outil_disparu"])])

      assert %{status: :fail, evidence: [ev]} = Tools.check_tool_grants_resolve(root)
      assert ev =~ "engineer grants mcp__fleet__outil_disparu"
      assert ev =~ "no such tool"
    end

    test "⚠ LES OUTILS HORS PREFIXE NE SONT PAS DES ACCORDS MCP" do
      # `Bash`, `Read`, `Edit` sont des outils du vendor : les compter ferait accuser chaque carte
      # du corpus d'accorder des outils que `pod_tools.ex` ne declare evidemment pas.
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
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
      # Laisser l'outil hors de `allowedTools` ne le ferme pas : ca coince le pod sur une invite
      # qu'il ne peut pas satisfaire. Le mur nomme le bundle ET le porteur.
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
      # Sans cette borne, tout bundle exigerait ses outils de TOUS les roles du catalogue, et le
      # mur reclamerait des accords que personne ne veut donner.
      root =
        arbre([
          bundle_sp("brainstorming", "Utilise WebSearch pour explorer.\n"),
          porteur("engineer", ["brainstorming"], ["WebSearch"]),
          porteur("scribe", ["autre-bundle"], ["Bash"])
        ])

      assert %{status: :pass, evidence: []} = Tools.check_modop_tools_granted(root)
    end

    test "⚠ AUCUN NOM D'OUTIL CITE → INSTRUMENT CASSE, jamais « rien a signaler »" do
      # Un bundle de prose pure rend `cited_anywhere` vide : chaque comparaison porte alors sur
      # l'ensemble vide, et « aucun outil non accorde » est vrai et sans contenu.
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "reconciliation.pulled_states_declared — une dependance qui ne laisse aucune trace" do
    # `@pulled_states` dit qu'un work-item enfile mais jamais TIRE ne possede AUCUN verrou. Des
    # modules raisonnent sur cette regle sans jamais l'appeler : ils la CITENT. Le fournisseur
    # ignore donc qu'il porte une garantie pour eux, et la changer casse leur raisonnement en
    # silence. Aucune trace executable : la seule forme verifiable est que le fournisseur DECLARE.
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
      # Le gate cite `@pulled_states` (il le mesure) : s'auto-compter ferait rougir le mur sur sa
      # propre pose. L'exemption porte sur l'ARBRE du verificateur, pas sur des chemins en dur —
      # une liste de chemins grossit a chaque coupe et rougit la fois ou on l'oublie.
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
end
