defmodule Mix.Tasks.Lcars.Contracts.BootArtifactCheckTest do
  @moduledoc """
  Synthetic-tree tests for boot order, artifact residues, listener construction,
  anti-root markers, MCP provisioning shapes and eval-door names.

  Missing anchors and source populations exercise scanner failures separately
  from violations. No fixture boots a fleet, executes Bats or provisions a pod;
  passing source patterns are not execution proofs.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.{Artifact, Boot, Runtime}

  defp arbre(fichiers) do
    root = Fleet.TestEnv.tmp_path("murs_boot")
    on_exit(fn -> File.rm_rf!(root) end)

    for {rel, contenu} <- fichiers do
      chemin = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(chemin))
      File.write!(chemin, contenu)
    end

    root
  end

  describe "boot.order_f8 — le Bus est le substrat de tout abonne" do
    defp application(enfants) do
      [
        {"lib/fleet/application.ex",
         """
         defmodule Fleet.Application do
           def start(_, _) do
             children = [
               # l'ordre EST l'invariant
         #{Enum.map_join(enfants, "\n", &"      #{&1},")}
             ]

             Supervisor.start_link(children, strategy: :one_for_one)
           end
         end
         """}
      ]
    end

    @ordre_ok [
      "Fleet.EventRouter.Application",
      "Fleet.MCP.Supervisor",
      "Fleet.Spawner.Application"
    ]

    test "event_router premier, mcp avant spawner → vert" do
      assert %{status: :pass} = Boot.check_boot_order_f8(arbre(application(@ordre_ok)))
    end

    test "spawner avant mcp → rouge : son PublishConsumer recevrait un spawn sans substrat MCP" do
      inverse = [
        "Fleet.EventRouter.Application",
        "Fleet.Spawner.Application",
        "Fleet.MCP.Supervisor"
      ]

      assert %{status: :fail, evidence: [ev]} =
               Boot.check_boot_order_f8(arbre(application(inverse)))

      assert ev =~ "er<mcp, mcp<spw"
    end

    test "le bus n'est plus premier → rouge" do
      apres = [
        "Fleet.MCP.Supervisor",
        "Fleet.EventRouter.Application",
        "Fleet.Spawner.Application"
      ]

      assert %{status: :fail} = Boot.check_boot_order_f8(arbre(application(apres)))
    end

    test "⚠ UN REPERE DISPARU FERME LE MUR AVANT DE COMPARER" do
      sans_mcp = ["Fleet.EventRouter.Application", "Fleet.Spawner.Application"]

      assert %{status: :fail, evidence: [ev]} =
               Boot.check_boot_order_f8(arbre(application(sans_mcp)))

      assert ev =~ "extraction impossible"
    end
  end

  describe "boot.catalogue_before_freeze — une image gelee depuis un catalogue non verifie" do
    defp start(corps),
      do: [
        {"lib/fleet/application.ex",
         "defmodule Fleet.Application do\n  def start(_, _) do\n#{corps}  end\nend\n"}
      ]

    @gel_ok """
        Fleet.Catalogue.verify!()
        Fleet.CapProfile.publish_image!()
        Fleet.SPBuilder.publish_image!()
    """

    test "verify avant les deux gels → vert" do
      assert %{status: :pass} = Boot.check_catalogue_before_freeze(arbre(start(@gel_ok)))
    end

    test "un gel AVANT la verification → rouge : la faute part sous un nom prouve-bon" do
      apres = """
          Fleet.CapProfile.publish_image!()
          Fleet.Catalogue.verify!()
          Fleet.SPBuilder.publish_image!()
      """

      assert %{status: :fail, evidence: [ev]} =
               Boot.check_catalogue_before_freeze(arbre(start(apres)))

      assert ev =~ "offsets"
    end

    test "⚠ UN APPEL ABSENT EST FAIL-CLOSED, pas « ordre correct »" do
      sans = String.replace(@gel_ok, "    Fleet.SPBuilder.publish_image!()\n", "")

      assert %{status: :fail, evidence: [ev]} =
               Boot.check_catalogue_before_freeze(arbre(start(sans)))

      assert ev =~ "fail-closed"
    end
  end

  describe "bats.descriptions_inert — le nom d'un test bats est EVALUE par le shell" do
    test "une description sobre → vert" do
      root = arbre([{"test/x.bats", "@test \"le pod refuse un brief vide\" {\n  true\n}\n"}])
      assert %{status: :pass, evidence: []} = Artifact.check_bats_descriptions_inert(root)
    end

    test "un accent grave NU exécute la commande citée — nommé" do
      root = arbre([{"test/x.bats", "@test \"la sortie de `id -u` est 0\" {\n  true\n}\n"}])

      assert %{status: :fail, evidence: [ev]} = Artifact.check_bats_descriptions_inert(root)
      assert ev =~ "accent grave"
    end

    test "`$(` nu et `$VAR` nu sont refuses aussi" do
      for {desc, attendu} <- [{"resultat de $(whoami)", "$("}, {"sous $HOME", "$VAR"}] do
        root = arbre([{"test/x.bats", "@test \"#{desc}\" {\n  true\n}\n"}])

        assert %{status: :fail, evidence: [ev]} = Artifact.check_bats_descriptions_inert(root)
        assert ev =~ attendu
      end
    end

    test "⚠ L'ECHAPPEMENT EST RESPECTE — un backtick echappe est inerte, donc licite" do
      root =
        arbre([{"test/x.bats", "@test \"refuse un \\` nu dans la description\" {\n  true\n}\n"}])

      assert %{status: :pass, evidence: []} = Artifact.check_bats_descriptions_inert(root)
    end

    test "⚠ L'ARBRE SE BALAIE — un `.bats` hors des dossiers connus est vu aussi" do
      # Exercise an additional directory under the supplied root, not a sibling checkout.
      root = arbre([{"git-hooks/tests/y.bats", "@test \"sortie de `pwd`\" {\n  true\n}\n"}])

      assert %{status: :fail, evidence: [ev]} = Artifact.check_bats_descriptions_inert(root)
      assert ev =~ "git-hooks/tests/y.bats"
    end
  end

  describe "config.no_legacy_namespace — deux services sur le port l'un de l'autre" do
    test "la config prefixee sous :lcars_fleet → vert" do
      root =
        arbre([
          {"lib/a.ex",
           "defmodule A do\n  def p, do: Application.get_env(:lcars_fleet, :api_http_port)\nend\n"}
        ])

      assert %{status: :pass, evidence: []} = Artifact.check_no_legacy_config_namespace(root)
    end

    test "un namespace `:fleet_<domaine>` survivant est nomme" do
      # Build the legacy atom in pieces: the real-tree scan includes raw test source and comments.
      mort = ":fleet_" <> "observation"

      root = arbre([{"config/config.exs", "config #{mort}, http_port: 4001\n"}])

      assert %{status: :fail, evidence: ev} = Artifact.check_no_legacy_config_namespace(root)
      assert "config/config.exs" in ev
    end

    test "⚠ UN ARBRE VIDE NE VAUT PAS « aucun namespace mort »" do
      assert %{status: :fail, evidence: [ev]} =
               Artifact.check_no_legacy_config_namespace(arbre([]))

      assert ev =~ "INSTRUMENT BROKEN"
    end
  end

  describe "listener.no_cowboy_bypass — un listener qui ne serait pas en loopback" do
    @listener {"lib/fleet/event_router/listener.ex",
               "defmodule L do\n  def cowboy_child(o), do: {Plug.Cowboy, o}\nend\n"}

    test "le seul constructeur est le listener → vert" do
      assert %{status: :pass, evidence: []} =
               Runtime.check_no_cowboy_bypass(
                 arbre([@listener, {"lib/fleet/autre.ex", "defmodule A do\nend\n"}])
               )
    end

    test "un child-spec Cowboy bati ailleurs est nomme, avec sa ligne" do
      root =
        arbre([
          @listener,
          {"lib/fleet/api.ex",
           "defmodule Api do\n  def child, do: {Plug.Cowboy, scheme: :http}\nend\n"}
        ])

      assert %{status: :fail, evidence: [ev]} = Runtime.check_no_cowboy_bypass(root)
      assert ev =~ "api.ex:2"
      assert ev =~ "loopback"
    end

    test "⚠ LE CONSTRUCTEUR FAIT PARTIE DE LA POPULATION — s'il a bouge, la phrase ne parle de rien" do
      root = arbre([{"lib/fleet/autre.ex", "defmodule A do\nend\n"}])

      assert %{status: :fail, evidence: [ev]} = Runtime.check_no_cowboy_bypass(root)
      assert ev =~ "INSTRUMENT BROKEN"
    end

    test "un `{Plug.Cowboy,` en COMMENTAIRE ne compte pas" do
      root =
        arbre([
          @listener,
          {"lib/fleet/api.ex",
           "defmodule Api do\n  # ancien: {Plug.Cowboy, scheme: :http}\nend\n"}
        ])

      assert %{status: :pass, evidence: []} = Runtime.check_no_cowboy_bypass(root)
    end
  end

  describe "runtime.no_root_boot_guard — root resout ~/.gitea_token vers le jeton admin" do
    test "la garde presente et ancree → vert" do
      root =
        arbre([
          {"config/runtime.exs",
           "if :os.getuid() == 0,\n" <>
             "  do: raise(\"R-no-root-runtime: refusing to boot as root\")\n"}
        ])

      assert %{status: :pass, evidence: []} = Runtime.check_no_root_runtime_guard(root)
    end

    test "⚠ L'ANCRE EN COMMENTAIRE NE COMPTE PAS — la garde doit etre du CODE" do
      root =
        arbre([
          {"config/runtime.exs", "# R-no-root-runtime : refuser un boot en root\nimport Config\n"}
        ])

      assert %{status: :fail, evidence: [ev]} = Runtime.check_no_root_runtime_guard(root)
      assert ev =~ "anti-root"
    end

    test "l'ancre absente est nommee" do
      root = arbre([{"config/runtime.exs", "import Config\n"}])

      assert %{status: :fail, evidence: [ev]} = Runtime.check_no_root_runtime_guard(root)
      assert ev =~ "anti-root"
    end
  end

  describe "mcp.required_for_real_backend — deux niveaux, et il faut les deux" do
    @pod {"lib/fleet/spawner/pod.ex",
          "defmodule P do\n  def go(o), do: McpProvision.maybe_provision_mcp_config(o)\nend\n"}
    @prov {"lib/fleet/spawner/pod/mcp_provision.ex",
           "defmodule M do\n  def check(nil) do\n    {:error, :mcp_server_spec_required}\n  end\nend\n"}

    test "les deux niveaux presents → vert" do
      assert %{status: :pass, evidence: []} =
               Runtime.check_mcp_required_real_backend(arbre([@pod, @prov]))
    end

    test "le cablage du niveau 1 manquant est nomme" do
      root =
        arbre([{"lib/fleet/spawner/pod.ex", "defmodule P do\n  def go(o), do: o\nend\n"}, @prov])

      assert %{status: :fail, evidence: [ev]} = Runtime.check_mcp_required_real_backend(root)
      assert ev =~ "unwired"
    end

    test "⚠ CONFIRMATION CONJOINTE — le jeton doit vivre sur la ligne QUI EST le tuple d'erreur" do
      en_prose =
        {"lib/fleet/spawner/pod/mcp_provision.ex",
         "defmodule M do\n  @moduledoc \"rend :mcp_server_spec_required si le backend est reel\"\n" <>
           "  def check(_), do: :ok\nend\n"}

      assert %{status: :fail, evidence: [ev]} =
               Runtime.check_mcp_required_real_backend(arbre([@pod, en_prose]))

      assert ev =~ "fail-loud"
    end
  end

  describe "runtime.eval_doors_resolve — une porte qui nomme une fonction qui n'existe plus" do
    # Supply three valid doors so a missing export, rather than the population floor, is measured.
    defp socle do
      [
        {"lib/fleet/roster.ex",
         "defmodule Fleet.Roster do\n  def eval_main(r), do: r\n  def eval_tfvars(r), do: r\nend\n"},
        {"lib/fleet/verif.ex", "defmodule Fleet.Verif do\n  def eval_main(r), do: r\nend\n"},
        {"bin/socle",
         ~S|eval "Fleet.Roster.eval_main(\"/c\")"| <>
           "\n" <>
           ~S|eval "Fleet.Roster.eval_tfvars(\"/c\")"| <>
           "\n" <>
           ~S|eval "Fleet.Verif.eval_main(\"/c\")"| <> "\n"}
      ]
    end

    defp avec(sujet_script, sujet_lib \\ nil) do
      base = [{"bin/sujet", sujet_script} | socle()]
      if sujet_lib, do: [sujet_lib | base], else: base
    end

    test "les portes nommees par les scripts resolvent toutes → vert" do
      assert %{status: :pass, evidence: []} = Runtime.check_eval_doors_resolve(arbre(socle()))
    end

    test "une fonction que le module n'exporte pas est nommee" do
      root = arbre(avec(~S|eval "Fleet.Roster.eval_disparu(\"/c\")"| <> "\n"))

      assert %{status: :fail, evidence: [ev]} = Runtime.check_eval_doors_resolve(root)
      assert ev =~ "eval_disparu"
      assert ev =~ "ne l'exporte pas"
    end

    test "un module introuvable se distingue d'une fonction manquante" do
      root = arbre(avec(~S|eval "Fleet.Fantome.eval_main(\"/c\")"| <> "\n"))

      assert %{status: :fail, evidence: [ev]} = Runtime.check_eval_doors_resolve(root)
      assert ev =~ "module introuvable"
    end

    test "un `defdelegate` compte comme un export" do
      root =
        arbre(
          avec(
            ~S|eval "Fleet.Delegue.eval_main(\"/c\")"| <> "\n",
            {"lib/fleet/delegue.ex",
             "defmodule Fleet.Delegue do\n  defdelegate eval_main(r), to: Autre\nend\n"}
          )
        )

      assert %{status: :pass, evidence: []} = Runtime.check_eval_doors_resolve(root)
    end
  end
end
