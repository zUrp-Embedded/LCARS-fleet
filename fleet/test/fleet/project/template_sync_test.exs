defmodule Fleet.Project.TemplateSyncTest do
  # async: false — mutates global Application env (the git-runner seam + :forge_auth).
  use ExUnit.Case, async: false

  # Le sujet a DEMENAGE : le corps de la projection vit dans un module ordinaire, parce qu'une
  # tache Mix n'existe pas dans l'image runtime — donc le seul poseur du template ne pouvait pas
  # tourner sur une boite deployee. Ce temoin suit le corps, pas la porte.
  alias Fleet.Project.TemplateSync, as: Sync

  @token "s3cr3t-forge-token-should-never-touch-argv"

  test "the forge token rides the git ENV, never the push argv (no secret in /proc/<pid>/cmdline)" do
    test_pid = self()

    # Capture every git invocation instead of running git.
    Application.put_env(:lcars_fleet, :template_sync_git_runner, fn args, opts ->
      send(test_pid, {:git, args, opts})
      {:ok, {"", 0}}
    end)

    on_exit(fn ->
      Application.delete_env(:lcars_fleet, :template_sync_git_runner)
      Application.delete_env(:lcars_fleet, :credentials_forge_auth)
    end)

    assert :ok =
             Sync.push_template(
               "fleet/project-template",
               Fleet.Catalogue.project_template_root(),
               base_url: "https://forge.test",
               token: @token
             )

    calls = drain_git_calls([])
    # 4 ops (init/add/commit/push) × 2 faces (main + ops).
    assert length(calls) == 8

    push_calls = Enum.filter(calls, fn {args, _opts} -> "push" in args end)
    assert length(push_calls) == 2

    for {args, opts} <- push_calls do
      # The secret is NOWHERE in the argv — no token-in-URL, no `-c extraheader` arg.
      refute Enum.any?(args, &String.contains?(&1, @token)),
             "forge token leaked into the git push argv: #{inspect(args)}"

      # The remote is the PLAIN url (no userinfo / oauth2:), matched by git on the url_prefix.
      assert "https://forge.test/fleet/project-template.git" in args
      refute Enum.any?(args, &String.contains?(&1, "oauth2:"))
      refute Enum.any?(args, &String.contains?(&1, "@forge.test"))

      # The token DOES ride the env (owner-only /proc/<pid>/environ), via the ForgeAuth single source.
      env = Keyword.fetch!(opts, :env)
      header = Enum.find_value(env, fn {k, v} -> if k == "GIT_CONFIG_VALUE_0", do: v end)
      assert header == "Authorization: token #{@token}"

      # …and the network push is BOUNDED (no infinite deploy hang).
      assert is_integer(Keyword.get(opts, :timeout_ms))
    end
  end

  defp drain_git_calls(acc) do
    receive do
      {:git, args, opts} -> drain_git_calls([{args, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "le modele de projet est celui DU CATALOGUE" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "tpl-#{System.unique_integer([:positive])}")
      cache = Path.join(tmp, "catalogues")
      File.mkdir_p!(cache)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [cache])
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, cache: cache}
    end

    defp catalogue(cache, name, template?) do
      dir = Path.join(cache, name)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "catalogue.yaml"), "api_version: 1\nname: #{name}\n")

      if template? do
        for face <- ~w(main ops) do
          File.mkdir_p!(Path.join([dir, "project_template", face]))
        end
      end

      dir
    end

    test "un catalogue qui livre un `project_template` a le SIEN", %{cache: cache} do
      # LE DEFAUT QUE CE TEMOIN GARDE, ET IL A VECU : `project_template/1` rendait le litteral
      # `fleet/project-template` pour TOUT projet de la boite. `web-demo` livrait treize fichiers
      # que rien ne lisait, et ses projets partaient du catalogue de reference — sans un mot.
      catalogue(cache, "web-demo", true)

      assert Fleet.Project.Onboard.project_template(org: "web-demo") ==
               "web-demo/project-template"
    end

    test "un catalogue SANS `project_template` retombe sur celui de reference", %{cache: cache} do
      # ⚖ user, 2026-08-16 : c'est le SEUL arbre qui a le droit de replier. Tout le reste d'un
      # catalogue est nomme PAR NOM — une carte nomme un role, un role nomme son profil — donc
      # replier resoudrait un nom dans un catalogue qui ne l'a jamais declare. Un modele de projet
      # ne nomme rien et n'est nomme par rien.
      catalogue(cache, "minimal", false)
      assert Fleet.Project.Onboard.project_template(org: "minimal") == "fleet/project-template"
    end

    test "un catalogue INCONNU de cette boite retombe aussi, sans lever", %{cache: _} do
      assert Fleet.Project.Onboard.project_template(org: "jamais-installe") ==
               "fleet/project-template"
    end

    test "sans org nomme, c'est le modele de reference — le comportement d'avant" do
      assert Fleet.Project.Onboard.project_template() == "fleet/project-template"
    end

    test "sync/2 ne pousse RIEN pour un catalogue sans arbre — l'absence rend le repli visible",
         %{
           cache: cache
         } do
      # ⚠ POUSSER LE MODELE LIVRE DANS L'ORG DU CATALOGUE SERAIT PIRE QUE DE NE RIEN FAIRE : la
      # forge porterait alors `<catalogue>/project-template`, `Onboard` s'y resoudrait, et le repli
      # cesserait d'etre observable. Un catalogue servirait le materiel d'un voisin sous son nom.
      catalogue(cache, "minimal", false)

      Application.put_env(:lcars_fleet, :template_sync_git_runner, fn _args, _opts ->
        flunk("aucun git ne doit etre lance pour un catalogue sans project_template")
      end)

      on_exit(fn -> Application.delete_env(:lcars_fleet, :template_sync_git_runner) end)

      assert {:ok, :no_template} =
               Sync.sync([base_url: "https://forge.test", token: @token], "minimal")
    end
  end
end
