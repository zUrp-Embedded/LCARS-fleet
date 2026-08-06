defmodule Fleet.Spawner.PoolSlotTest do
  @moduledoc """
  The `pool` nibble stops being decorative: it is allocated, capped, and the ceiling is hit like
  a ceiling (a typed refusal the caller turns into a deferral) instead of like a bug (the
  `pool in 0..0xF` guard of `SessionId.encode/5` raising mid-spawn).

  Index **0 is reserved** and its occupant is DERIVED, not declared: a `slot_scope: project` pod is
  not a fan-out member, so it takes the seat and consumes no slot. That is what makes the
  reservation real — before, `0xF` was reserved for a meaning nobody ever wrote.

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
          holder_loop()
        end)

      Agent.update(holders, &[pid | &1])
      assert_receive {:registered, ^pool}, 1_000
    end
  end

  # A holder ANSWERS. It sits in `Fleet.Spawner.Registry`, so anything that enumerates pods
  # (`list_pods/0` → one `GenServer.call` per entry) reaches it. A mute holder is not a cheap stub:
  # it is a FIVE-SECOND timeout for every enumerator in the suite. Measured — it turned a later
  # test's 60 s budget into a red at the gate while every file stayed green in isolation, and the
  # first suspect was the wrong one.
  defp holder_loop do
    receive do
      {:"$gen_call", from, _request} ->
        GenServer.reply(from, %{phase: :monitoring})
        holder_loop()

      :stop ->
        :ok
    end
  end

  # The bucket is keyed on the forge REPO ID (an integer), not on `owner/name`: it is what the
  # session_id encodes, and it is the key the dispatch actually carries in its spawn_opts.
  defp uniq_repo, do: System.unique_integer([:positive])

  describe "instance keying — the fan-out members" do
    test "allocates the LOWEST free index, and fills the holes", %{holders: h} do
      repo = uniq_repo()
      occupy(h, "engineer", repo, [1, 2, 4])
      assert {:ok, 3} = PoolSlot.allocate("engineer", repo, "instance")
    end

    test "index 0 is NEVER handed out: allocation starts at 1", %{holders: h} do
      repo = uniq_repo()

      # Nothing occupied at all — the lowest free index in the whole nibble is 0, and it is skipped.
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
      TestEnv.put_env_restoring(:fleet_spawner, :max_pods_per_role, 3)
      repo = uniq_repo()
      occupy(h, "engineer", repo, [1, 2, 3])
      assert {:error, :role_at_capacity} = PoolSlot.allocate("engineer", repo, "instance")
    end
  end

  describe "project keying — the reserved seat" do
    test "takes seat 0 without reading the registry", %{holders: h} do
      repo = uniq_repo()
      # Even at capacity for the instance-keyed side, a project pod is unaffected: it does not
      # compete, it holds the seat nobody allocates.
      TestEnv.put_env_restoring(:fleet_spawner, :max_pods_per_role, 2)
      occupy(h, "architect", repo, [1, 2])

      assert {:ok, 0} = PoolSlot.allocate("architect", repo, "project")
      assert PoolSlot.has_free_slot?("architect", repo, "project")
    end

    test "a 0 in the bucket never eats an allocatable slot", %{holders: h} do
      TestEnv.put_env_restoring(:fleet_spawner, :max_pods_per_role, 2)
      repo = uniq_repo()

      # Seat 0 held, plus one of the two allocatable slots.
      occupy(h, "engineer", repo, [0, 1])

      # Slot 2 is still free. Counting the raw set size would say "2 taken, cap 2, full" and defer
      # a spawn that has room — capacity silently down by one for anything that lands on 0.
      # A bucket is homogeneous today (`slot_scope` is per role), which is precisely why neither
      # the allocation nor the pre-flight is allowed to DEPEND on it.
      assert {:ok, 2} = PoolSlot.allocate("engineer", repo, "instance")
      assert PoolSlot.has_free_slot?("engineer", repo, "instance")

      occupy(h, "engineer", repo, [2])
      refute PoolSlot.has_free_slot?("engineer", repo, "instance")
    end
  end

  describe "the format's own bounds" do
    test "the config cannot promise more than the nibble holds (15 allocatable, 0 reserved)" do
      TestEnv.put_env_restoring(:fleet_spawner, :max_pods_per_role, 99)
      assert PoolSlot.max_per_role() == 15

      TestEnv.put_env_restoring(:fleet_spawner, :max_pods_per_role, 0)
      assert PoolSlot.max_per_role() == 1
    end

    test "every index the allocator can hand out is encodable — the guard is never reached" do
      # 0 (the reserved seat, handed to project pods) through 15 (the last allocatable index):
      # the whole range the allocator can produce, proven encodable rather than assumed so.
      for pool <- 0..PoolSlot.max_per_role() do
        assert is_binary(Fleet.Spawner.SessionId.encode(3, 1, 1000, 42, pool))
      end
    end
  end
end
