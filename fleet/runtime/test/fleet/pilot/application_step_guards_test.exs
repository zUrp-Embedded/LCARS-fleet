defmodule Fleet.Pilot.ApplicationStepGuardsTest do
  # async: false — mutates the global :fleet_pilot config (step_dispatch?/poll_repo/...).
  use ExUnit.Case, async: false

  @keys [:step_dispatch?, :poll_repo, :hop_remote, :forge, :reviewer_roles]

  setup do
    # Tests set these keys themselves; we only register their restoration here.
    Enum.each(@keys, &Fleet.Pilot.TestEnv.restore_env_on_exit(:fleet_pilot, &1))
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

  # F-C061 Vector 2 (config own-goal): `:reviewer_roles` is fail-loud on ABSENCE but not on absurd
  # content. A non-role login would be set on PRs + bump required_approvals, then wedge silently at
  # dispatch. The boot guard validates that each juror resolves to a judge cap-profile.
  test "F-C061 V2: :reviewer_roles with a NON-role login (human) → raise at boot" do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    Application.put_env(:fleet_pilot, :forge, base_url: "http://forge.local")
    Application.put_env(:fleet_pilot, :reviewer_roles, ["qualifier", "lordzurp"])

    assert_raise RuntimeError, ~r/does NOT resolve/, fn ->
      Fleet.Pilot.Application.step_children_for_test()
    end
  end

  test "F-C061 V2: :reviewer_roles with a NON-judge role (worker) → raise at boot" do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    Application.put_env(:fleet_pilot, :forge, base_url: "http://forge.local")
    # engineer resolves (cap-profile) but brief_kind: worker → not a valid juror.
    Application.put_env(:fleet_pilot, :reviewer_roles, ["qualifier", "engineer"])

    assert_raise RuntimeError, ~r/NOT a judge/, fn ->
      Fleet.Pilot.Application.step_children_for_test()
    end
  end
end
