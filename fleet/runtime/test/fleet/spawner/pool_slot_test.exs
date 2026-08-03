defmodule Fleet.Spawner.PoolSlotTest do
  @moduledoc """
  The `pool` nibble stops being decorative: it is allocated, capped, and the ceiling is hit like
  a ceiling (a typed refusal the caller turns into a deferral) instead of like a bug (the
  `pool in 0..0xF` guard of `SessionId.encode/5` raising mid-spawn).

  The allocation reads Registry VALUES, so these tests seed live slots with short-lived holder
  processes — no pod is started, and no pod is ever called.
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.PoolSlot
  alias Fleet.TestEnv

  setup do
    # An Agent, not ETS: an ETS table owned by the test process is already gone when `on_exit`
    # runs in its own process — the cleanup would crash on a dead table.
    {:ok, holders} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      if Process.alive?(holders) do
        holders |> Agent.get(& &1) |> Enum.each(&Process.exit(&1, :kill))
        Agent.stop(holders)
      end
    end)

    {:ok, holders: holders}
  end

  defp occupy(holders, role, repo, pools) do
    me = self()

    for pool <- pools do
      key = "#{role}-#{repo}-#{pool}"

      pid =
        spawn(fn ->
          {:ok, _} =
            Registry.register(Fleet.Spawner.Registry, key, %{role: role, repo: repo, pool: pool})

          send(me, {:registered, pool})
          receive do: (:stop -> :ok)
        end)

      Agent.update(holders, &[pid | &1])
      assert_receive {:registered, ^pool}, 1_000
    end
  end

  defp uniq_repo, do: "fleet/p#{System.unique_integer([:positive])}"

  test "allocates the LOWEST free index, and fills the holes", %{holders: h} do
    repo = uniq_repo()
    occupy(h, "engineer", repo, [0, 1, 3])
    assert {:ok, 2} = PoolSlot.allocate("engineer", repo)
  end

  test "the cap is per (role, repo): another repo and another role start at zero", %{holders: h} do
    repo = uniq_repo()
    occupy(h, "engineer", repo, [0, 1, 2])
    assert {:ok, 0} = PoolSlot.allocate("engineer", uniq_repo())
    assert {:ok, 0} = PoolSlot.allocate("qualifier", repo)
  end

  test "at the cap → TYPED refusal, never a raise (the ticket stacks and retries)", %{holders: h} do
    TestEnv.put_env_restoring(:fleet_spawner, :max_pods_per_role, 3)
    repo = uniq_repo()
    occupy(h, "engineer", repo, [0, 1, 2])
    assert {:error, :role_at_capacity} = PoolSlot.allocate("engineer", repo)
  end

  test "the config cannot promise more than the nibble holds (15 max, 0xF reserved)" do
    TestEnv.put_env_restoring(:fleet_spawner, :max_pods_per_role, 99)
    assert PoolSlot.max_per_role() == 15

    TestEnv.put_env_restoring(:fleet_spawner, :max_pods_per_role, 0)
    assert PoolSlot.max_per_role() == 1
  end

  test "every allocatable index is encodable — the format guard is never reached" do
    for pool <- 0..(PoolSlot.max_per_role() - 1) do
      assert is_binary(Fleet.Spawner.SessionId.encode(3, 1, 1000, 42, pool))
    end
  end

  test "the brake states an incoherent pair of ceilings instead of letting it wedge a fleet" do
    TestEnv.put_env_restoring(:fleet_spawner, :max_pods, 2)
    TestEnv.put_env_restoring(:fleet_spawner, :max_pods_per_role, 10)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = PoolSlot.check_ceilings!()
      end)

    assert log =~ "EXCEEDS max_pods"
  end
end
