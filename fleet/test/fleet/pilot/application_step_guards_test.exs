defmodule Fleet.Pilot.ApplicationStepGuardsTest do
  # async: false — mutates the global :fleet_pilot config (step_dispatch?/poll_repo/...).
  use ExUnit.Case, async: false

  @keys [:step_dispatch?, :poll_repo, :hop_remote, :forge]

  setup do
    # Tests set these keys themselves; we only register their restoration here.
    Enum.each(@keys, &Fleet.TestEnv.restore_env_on_exit(:fleet_pilot, &1))
    Fleet.TestEnv.restore_env_on_exit(:fleet_workflow, :workflow_maps_root)
    # step_children! publishes the catalogue image; :persistent_term outlives the test —
    # erase every image so no test serves another test's proven catalogue.
    on_exit(fn -> Fleet.Workflow.Loader.unpublish_all_images() end)
    :ok
  end

  # F-027 + F-037: with `step_dispatch?: true` + incomplete config, a `step_children` returning `[]`
  # in SILENCE would boot the pilot app "green" without Poller/StepRunConsumer (forge rail dead, zero
  # log). Instead: the operator ASKED for step mode → incomplete config = broken deploy → raise at
  # boot. F-037 re-targeted the guard: it is not `:poll_repo` (the poller DISCOVERS via
  # org-membership, WS3) nor a frozen remote (per-step-run), but the forge `base_url` — without it,
  # neither discovery (`list_org_repos`) nor push (per-step-run remote) work.

  test "F-037: step_dispatch? true without forge base_url (:forge absent) → raise (dead rail avoided)" do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    Application.delete_env(:fleet_pilot, :forge)

    assert_raise RuntimeError, ~r/base_url/, fn ->
      Fleet.Pilot.Application.init([])
    end
  end

  test "F-037: step_dispatch? true but :forge without :base_url → raise" do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    Application.put_env(:fleet_pilot, :forge, token: "x")

    assert_raise RuntimeError, ~r/base_url/, fn ->
      Fleet.Pilot.Application.init([])
    end
  end

  test "F-037: :poll_repo is NOT required anymore (org-membership discovery) — no raise on its absence alone" do
    # The guard no longer depends on :poll_repo. With a forge base_url present, a missing :poll_repo
    # triggers NOTHING (we verify via step_children! that no "base_url" RuntimeError is raised).
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    Application.put_env(:fleet_pilot, :forge, base_url: "http://forge.local")
    Application.delete_env(:fleet_pilot, :poll_repo)

    # We exercise child-spec resolution (without starting the supervisor, which would register the
    # singletons under their global names and conflict). `:poll_repo` absent → no raise.
    children = Fleet.Pilot.Application.step_children_for_test()
    assert Enum.any?(children, &match?({Fleet.Pilot.Poller, _}, &1))
    assert Enum.any?(children, &match?({Fleet.Pilot.StepRunConsumer, _}, &1))
  end

  test "step_status probes EXACTLY the rail step_children! starts (no hollow-green drift)" do
    # The readiness rail (step_rail_processes) must equal the processes actually started (step_children!):
    # a started-but-unprobed process reads operational while dead; a probed-but-unstarted one reads
    # degraded forever. A new rail child added to step_children! without step_rail_processes fails HERE.
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    Application.put_env(:fleet_pilot, :forge, base_url: "http://forge.local")

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

  # F-C061 Vector 2, re-seated on the CARDS: the jury lives in each workflow map
  # (spec.jury — no engine config). The schema guards the shape, the boot guard the
  # CONTENT: every jury role of every canon card must resolve to a judge cap-profile —
  # else the card would lay a non-judging reviewer on PRs and wedge at dispatch.
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

    Application.put_env(:fleet_workflow, :workflow_maps_root, tmp)
  end

  # A missing/empty workflow catalogue used to enumerate to `[]`, turning both card
  # guards into vacuous truths: the rail booted green with zero loadable card and the
  # first route raised far from the deploy fault. The boot now refuses both states —
  # and step mode OFF keeps its zero-card-by-design semantics (no enumeration at all).

  test "step rail boot: MISSING workflow maps root → raise (no vacuous green)", %{tmp_dir: tmp} do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    Application.put_env(:fleet_pilot, :forge, base_url: "http://forge.local")
    Application.put_env(:fleet_workflow, :workflow_maps_root, Path.join(tmp, "nowhere"))

    assert_raise RuntimeError, ~r/does not exist/, fn ->
      Fleet.Pilot.Application.step_children_for_test()
    end
  end

  test "step rail boot: EMPTY workflow catalogue → raise (no vacuous green)", %{tmp_dir: tmp} do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    Application.put_env(:fleet_pilot, :forge, base_url: "http://forge.local")
    Application.put_env(:fleet_workflow, :workflow_maps_root, tmp)

    assert_raise RuntimeError, ~r/no \*\.yaml card/, fn ->
      Fleet.Pilot.Application.step_children_for_test()
    end
  end

  test "step mode OFF: zero card stays BY DESIGN — no enumeration, no raise, no children", %{
    tmp_dir: tmp
  } do
    Application.put_env(:fleet_pilot, :step_dispatch?, false)
    Application.put_env(:fleet_workflow, :workflow_maps_root, Path.join(tmp, "nowhere"))

    assert Fleet.Pilot.Application.step_children_for_test() == []
  end

  test "the rail boot PUBLISHES the image the guards proved — a post-boot disk edit is inert", %{
    tmp_dir: tmp
  } do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    Application.put_env(:fleet_pilot, :forge, base_url: "http://forge.local")

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

    Application.put_env(:fleet_workflow, :workflow_maps_root, tmp)

    assert [_ | _] = Fleet.Pilot.Application.step_children_for_test()

    # The catalogue mutates after boot: the runtime keeps serving the PROVEN card.
    File.rm!(Path.join(tmp, "proven.yaml"))
    assert %{"name" => "proven"} = Fleet.Workflow.Loader.load!("proven")
    assert Fleet.Workflow.Loader.canon_names() == ["proven"]
  end

  test "F-C061 V2 (cards): a card jury with a NON-role login (human) → raise at boot",
       %{tmp_dir: tmp} do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    Application.put_env(:fleet_pilot, :forge, base_url: "http://forge.local")
    canon_with_jury(tmp, "[qualifier, lordzurp]")

    assert_raise RuntimeError, ~r/does NOT resolve/, fn ->
      Fleet.Pilot.Application.step_children_for_test()
    end
  end

  test "F-C061 V2 (cards): a card jury with a NON-judge role (worker) → raise at boot",
       %{tmp_dir: tmp} do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    Application.put_env(:fleet_pilot, :forge, base_url: "http://forge.local")
    # engineer resolves (cap-profile) but brief_kind: worker → not a valid juror.
    canon_with_jury(tmp, "[qualifier, engineer]")

    assert_raise RuntimeError, ~r/NOT a judge/, fn ->
      Fleet.Pilot.Application.step_children_for_test()
    end
  end
end
