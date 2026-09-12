defmodule Fleet.Spawner.PoolSlotTest do
  @moduledoc """
  Pool allocation, capacity and reserved project slots. Holder processes populate Registry
  values without starting pods.
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.PoolSlot
  alias Fleet.TestEnv

  setup do
    # on_exit runs after the test process dies. An unlinked Agent keeps the holder list alive;
    # test-owned ETS or a linked Agent would disappear before cleanup, leaking Registry holders.
    {:ok, holders} = Agent.start(fn -> [] end)

    on_exit(fn ->
      # Belt and braces. The agent is unlinked now, so it is normally still alive here — but a
      # teardown must never be what fails a passed test: `Agent.get/2` and `Agent.stop/1` exit
      # `:noproc` if it did die, and an exit raised IN `on_exit` marks a PASSED test FAILED
      # (measured 2026-09-07: red in the full suite on a loaded machine, green alone, same
      # toolchain — an original flake, not a bump regression). We catch the exit instead of
      # predicting it with a probe that cannot close the race; a dead agent has nothing left to
      # stop anyway.
      try do
        holders |> Agent.get(& &1) |> Enum.each(&Process.exit(&1, :kill))
        Agent.stop(holders)
      catch
        :exit, _ -> :ok
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
          holder_loop()
        end)

      Agent.update(holders, &[pid | &1])
      assert_receive {:registered, ^pool}, 1_000
    end
  end

  # Other tests may enumerate pods via GenServer.call; mute holders cause five-second timeouts.
  defp holder_loop do
    receive do
      {:"$gen_call", from, _request} ->
        GenServer.reply(from, %{phase: :monitoring})
        holder_loop()

      :stop ->
        :ok
    end
  end

  defp uniq_repo, do: System.unique_integer([:positive])

  describe "instance keying — the fan-out members" do
    test "allocates the LOWEST free index, and fills the holes", %{holders: h} do
      repo = uniq_repo()
      occupy(h, "engineer", repo, [1, 2, 4])
      assert {:ok, 3} = PoolSlot.allocate("engineer", repo, "instance")
    end

    test "index 0 is NEVER handed out: allocation starts at 1", %{holders: h} do
      repo = uniq_repo()

      assert {:ok, 1} = PoolSlot.allocate("engineer", repo, "instance")

      occupy(h, "engineer", repo, [1])
      assert {:ok, 2} = PoolSlot.allocate("engineer", repo, "instance")
    end

    test "the cap is per (role, repo): another repo and another role start at 1", %{holders: h} do
      repo = uniq_repo()
      occupy(h, "engineer", repo, [1, 2, 3])
      assert {:ok, 1} = PoolSlot.allocate("engineer", uniq_repo(), "instance")
      assert {:ok, 1} = PoolSlot.allocate("qualifier", repo, "instance")
    end

    test "at the cap → TYPED refusal, never a raise (the ticket stacks and retries)", %{
      holders: h
    } do
      TestEnv.put_env_restoring(:lcars_fleet, :spawner_max_pods_per_role, 3)
      repo = uniq_repo()
      occupy(h, "engineer", repo, [1, 2, 3])
      assert {:error, :role_at_capacity} = PoolSlot.allocate("engineer", repo, "instance")
    end
  end

  describe "project keying — the reserved seat" do
    test "takes seat 0 without reading the registry", %{holders: h} do
      repo = uniq_repo()
      TestEnv.put_env_restoring(:lcars_fleet, :spawner_max_pods_per_role, 2)
      occupy(h, "architect", repo, [1, 2])

      assert {:ok, 0} = PoolSlot.allocate("architect", repo, "project")
      assert PoolSlot.has_free_slot?("architect", repo, "project")
    end

    test "a 0 in the bucket never eats an allocatable slot", %{holders: h} do
      TestEnv.put_env_restoring(:lcars_fleet, :spawner_max_pods_per_role, 2)
      repo = uniq_repo()

      occupy(h, "engineer", repo, [0, 1])

      # Counting the raw set size would incorrectly include reserved slot 0 and report full.
      assert {:ok, 2} = PoolSlot.allocate("engineer", repo, "instance")
      assert PoolSlot.has_free_slot?("engineer", repo, "instance")

      occupy(h, "engineer", repo, [2])
      refute PoolSlot.has_free_slot?("engineer", repo, "instance")
    end
  end

  describe "the format's own bounds" do
    test "the config cannot promise more than the nibble holds (15 allocatable, 0 reserved)" do
      TestEnv.put_env_restoring(:lcars_fleet, :spawner_max_pods_per_role, 99)
      assert PoolSlot.max_per_role() == 15

      TestEnv.put_env_restoring(:lcars_fleet, :spawner_max_pods_per_role, 0)
      assert PoolSlot.max_per_role() == 1
    end

    test "every index the allocator can hand out is encodable — the guard is never reached" do
      for pool <- 0..PoolSlot.max_per_role() do
        assert is_binary(Fleet.Spawner.SessionId.encode(3, 1, 1000, 42, pool))
      end
    end
  end
end
