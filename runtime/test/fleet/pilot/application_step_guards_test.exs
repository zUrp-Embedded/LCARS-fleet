defmodule Fleet.Pilot.ApplicationStepGuardsTest do
  alias Fleet.Workflow.Loader

  # async: false — mutates the global `:lcars_fleet` config (pilot_step_dispatch?/pilot_poll_repo/...).
  use ExUnit.Case, async: false

  @keys [:pilot_step_dispatch?, :pilot_poll_repo, :pilot_hop_remote, :pilot_forge]

  setup do
    # Tests set these keys themselves; we only register their restoration here.
    Enum.each(@keys, &Fleet.TestEnv.restore_env_on_exit(:lcars_fleet, &1))
    Fleet.TestEnv.restore_env_on_exit(:lcars_fleet, :workflow_workflow_maps_root)
    # step_children! publishes the catalogue image; :persistent_term outlives the test —
    # erase every image so no test serves another test's proven catalogue.
    on_exit(fn -> Loader.unpublish_all_images() end)
    :ok
  end

  # Step mode requires a forge base_url. Repositories are discovered and remotes
  # resolved per run, so neither needs a fixed boot setting.

  test "F-037: step_dispatch? true without forge base_url (:forge absent) → raise (dead rail avoided)" do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.delete_env(:lcars_fleet, :pilot_forge)

    assert_raise RuntimeError, ~r/base_url/, fn ->
      Fleet.Pilot.Application.init([])
    end
  end

  test "F-037: step_dispatch? true but :forge without :base_url → raise" do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, token: "x")

    assert_raise RuntimeError, ~r/base_url/, fn ->
      Fleet.Pilot.Application.init([])
    end
  end

  test "F-037: :poll_repo is NOT required anymore (org-membership discovery) — no raise on its absence alone" do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")
    Application.delete_env(:lcars_fleet, :pilot_poll_repo)

    # Resolve specs without starting globally named supervisor children.
    children = Fleet.Pilot.Application.step_children_for_test()
    assert Enum.any?(children, &match?({Fleet.Pilot.Poller, _}, &1))
    assert Enum.any?(children, &match?({Fleet.Pilot.StepRunConsumer, _}, &1))
  end

  test "step_status probes EXACTLY the rail step_children! starts (no hollow-green drift)" do
    # Started and probed names must match: missing probes hide dead children;
    # extra probes report permanent degradation.
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")

    started =
      Fleet.Pilot.Application.step_children_for_test()
      |> Enum.map(&child_name/1)
      |> MapSet.new()

    probed =
      Fleet.Pilot.Application.step_rail_processes()
      |> Enum.map(fn {_key, name} -> name end)
      |> MapSet.new()

    assert started == probed,
           "readiness drift — started but not probed: #{inspect(MapSet.difference(started, probed) |> MapSet.to_list())}; " <>
             "probed but not started: #{inspect(MapSet.difference(probed, started) |> MapSet.to_list())}"
  end

  # Registered name of a supervisor child-spec (the name step_status probes via Process.whereis).
  defp child_name({Task.Supervisor, opts}) when is_list(opts), do: Keyword.fetch!(opts, :name)
  defp child_name({mod, _opts}) when is_atom(mod), do: mod
  defp child_name(mod) when is_atom(mod), do: mod

  # Beyond schema shape, every card juror must resolve to a judge profile.
  @moduletag :tmp_dir

  defp canon_with_jury(tmp, jury) do
    File.write!(Path.join(tmp, "bad-card.yaml"), """
    kind: WorkflowMap
    metadata:
      name: bad-card
    spec:
      jury: #{jury}
      ci: ignore
      max_rework_rounds: 1
      steps:
        only:
          role: engineer
    """)

    Application.put_env(:lcars_fleet, :workflow_workflow_maps_root, tmp)
  end

  # Missing or empty catalogues must fail boot instead of passing vacuous guards.
  # Disabled step mode does not enumerate cards.

  test "step rail boot: MISSING workflow maps root → raise (no vacuous green)", %{tmp_dir: tmp} do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")
    Application.put_env(:lcars_fleet, :workflow_workflow_maps_root, Path.join(tmp, "nowhere"))

    assert_raise RuntimeError, ~r/does not exist/, fn ->
      Fleet.Pilot.Application.step_children_for_test()
    end
  end

  test "step rail boot: EMPTY workflow catalogue → raise (no vacuous green)", %{tmp_dir: tmp} do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")
    Application.put_env(:lcars_fleet, :workflow_workflow_maps_root, tmp)

    assert_raise RuntimeError, ~r/no \*\.yaml card/, fn ->
      Fleet.Pilot.Application.step_children_for_test()
    end
  end

  test "step mode OFF: zero card stays BY DESIGN — no enumeration, no raise, no children", %{
    tmp_dir: tmp
  } do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, false)
    Application.put_env(:lcars_fleet, :workflow_workflow_maps_root, Path.join(tmp, "nowhere"))

    assert Fleet.Pilot.Application.step_children_for_test() == []
  end

  test "the rail boot PUBLISHES the image the guards proved — a post-boot disk edit is inert", %{
    tmp_dir: tmp
  } do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")

    File.write!(Path.join(tmp, "proven.yaml"), """
    kind: WorkflowMap
    metadata:
      name: proven
    spec:
      max_rework_rounds: 1
      jury: []
      ci: ignore
      steps:
        only:
          role: engineer
    """)

    Application.put_env(:lcars_fleet, :workflow_workflow_maps_root, tmp)

    assert [_ | _] = Fleet.Pilot.Application.step_children_for_test()

    # The catalogue mutates after boot: the runtime keeps serving the PROVEN card.
    File.rm!(Path.join(tmp, "proven.yaml"))
    assert %{"name" => "proven"} = Loader.load!("proven")
    assert Loader.canon_names() == ["proven"]
  end

  test "F-C061 V2 (cards): a card jury with a NON-role login (human) → raise at boot",
       %{tmp_dir: tmp} do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")
    canon_with_jury(tmp, "[qualifier, lordzurp]")

    assert_raise RuntimeError, ~r/does NOT resolve/, fn ->
      Fleet.Pilot.Application.step_children_for_test()
    end
  end

  test "F-C061 V2 (cards): a card jury with a NON-judge role (worker) → raise at boot",
       %{tmp_dir: tmp} do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")
    # engineer resolves (cap-profile) but brief_kind: worker → not a valid juror.
    canon_with_jury(tmp, "[qualifier, engineer]")

    assert_raise RuntimeError, ~r/NOT a judge/, fn ->
      Fleet.Pilot.Application.step_children_for_test()
    end
  end

  @tag :tmp_dir
  test "DEUX cartes revendiquant le rail atelier : le publish refuse, et il les NOMME", %{
    tmp_dir: tmp
  } do
    # This fixture changes global configuration, hence this serialized test file.
    # Two workshop producers are ambiguous; alphabetical order must not choose one.
    for name <- ~w(atelier-un atelier-deux) do
      File.write!(Path.join(tmp, "#{name}.yaml"), """
      kind: WorkflowMap
      metadata:
        name: #{name}
        description: "carte de fixture"
      spec:
        jury: []
        ci: ignore
        max_rework_rounds: 1
        steps:
          build:
            role: engineer
            face: workshop
            needs: []
            inputs:
              - ticket.body
      """)
    end

    Application.put_env(:lcars_fleet, :workflow_workflow_maps_root, tmp)
    on_exit(&Loader.unpublish_all_images/0)

    err = assert_raise RuntimeError, fn -> Loader.publish_image!() end
    assert err.message =~ "atelier-deux, atelier-un"
    assert err.message =~ "One card per catalogue"
  end

  # Pair fatal provisioning failure with authority unavailability: either case
  # alone would accept a guard that always raises or never raises.
  describe "signataires de merge : la cause decide, pas l'absence" do
    @tag :tmp_dir
    test "provisionnement manquant (no_role_token) → RAISE : le conteneur ne demarre pas", %{
      tmp_dir: tmp
    } do
      Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
      Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")
      # Un repertoire de jetons VIDE : le service repond, et il repond qu'il n'y a rien a servir.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)

      assert_raise RuntimeError, ~r/merge signer/, fn ->
        Fleet.Pilot.Application.step_children_for_test()
      end
    end

    @tag :tmp_dir
    test "forge injoignable → PAS de raise, mais un journal qui NOMME la porte", %{tmp_dir: tmp} do
      Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
      Application.put_env(:lcars_fleet, :pilot_forge, base_url: "http://forge.local")
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)

      Fleet.Test.AuthorityDouble.force_fail(:forge_unreachable)
      on_exit(fn -> Fleet.Test.AuthorityDouble.force_fail(nil) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert [_ | _] = Fleet.Pilot.Application.step_children_for_test()
        end)

      # Continuing boot must still log the unavailable authority, so the operator
      # does not mistake it for missing provisioning.
      assert log =~ "forge_unreachable"
      assert log =~ "PAS un defaut de provisionnement"
      assert log =~ "TOUT SCELLEMENT ECHOUERA"
    end
  end
end
