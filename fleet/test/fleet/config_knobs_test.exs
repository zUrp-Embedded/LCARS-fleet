defmodule Fleet.ConfigKnobsTest do
  use ExUnit.Case, async: false

  @moduledoc """
  BL-6-42.5 — the LOAD-BEARING config knobs, exercised.

  ~50 knobs are documented in moduledocs as though they worked; none was ever set, in config or in
  a test. Most are cosmetic and carry no debt at their default. These are not: each one BOUNDS A
  SAFETY, and for those, a documented-but-unexercised knob is a lie waiting for the day an operator
  needs it — the day a fleet is drowning and someone lowers `max_pods`, or a WAN push hangs and
  someone shortens the timeout.

  The failure mode is specific and silent: nothing breaks when a reader stops consulting its key
  (an inlined constant, a renamed key, a `get_env` moved behind a branch that no longer runs). The
  DEFAULT still applies, everything looks healthy, and the knob answers to nobody. A test that only
  checks the default value would pass through that regression untouched — so each test here sets a
  DISTINCTIVE value and requires it to come back.

  Not covered, and named rather than left implied: `:lcars_fleet, :workflow_git_push_timeout_ms`. Its
  only reader is private (`Git.push_timeout_ms/0`) and reachable solely through a real `git push`,
  so exercising it means a network-bound test. It stays an untested promise, deliberately — the
  honest state, written here instead of inferred from a missing file.
  """

  alias Fleet.Pilot.IncidentRegistry

  describe "the knobs that bound a safety are actually READ" do
    test ":lcars_fleet, :spawner_max_pods — the fleet-wide FUSE (not a policy)" do
      # 128 is the documented default; 7 is a value nothing else could produce. The knob still has
      # to answer: an operator on a small machine lowers the fuse deliberately, and it is the one
      # ceiling nothing else can substitute for.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_max_pods, 7)
      assert Fleet.Spawner.max_pods() == 7
    end

    test ":lcars_fleet, :spawner_publish_deadline_ms — the fail-safe that lifts a DESTRUCTIVE reset" do
      # This one earns its place above the others: when the deadline fires, the flag is lifted
      # blind and the lift re-opens `reset --hard` + `clean -fdx`. An operator lengthening this
      # window is buying time against a destructive path, and must actually get it.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_publish_deadline_ms, 4_242)
      assert Fleet.Spawner.Pod.Publishing.publish_deadline_ms() == 4_242
    end
  end

  describe ":lcars_fleet, :pilot_incident_registry_max_entries — bounds unbounded growth" do
    setup do
      # The knob's reader is private (`prune/1`), so it is exercised through BEHAVIOUR, which is
      # the stronger test anyway: it proves the bound holds, not merely that a value is read back.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_incident_registry_max_entries, 3)

      tmp = Fleet.TestEnv.tmp_path("knobs")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      wal_path = Path.join(tmp, "wal.json")

      pid =
        start_supervised!(
          {IncidentRegistry,
           name: :"knobs_registry_#{System.unique_integer([:positive])}",
           wal_path: wal_path,
           sync_forge: false}
        )

      {:ok, registry: pid, wal_path: wal_path}
    end

    test "beyond the cap, the OLDEST entries are evicted and the newest survive", %{
      registry: registry,
      wal_path: wal_path
    } do
      # Five distinct incidents against a cap of 3. Eviction is by `last_seen` descending, so the
      # last three noted must be the ones left. Without the knob being read, all five would stay
      # and the registry would grow with the WAL and the fully-rewritten forge file behind it.
      for i <- 1..5 do
        :ok = IncidentRegistry.note("sig-#{i}", "reason #{i}", server: registry)

        # ISO `last_seen` has second granularity in the stored entries; the sleep-free way to get a
        # deterministic order is to let each note land in its own call, which the GenServer
        # serialises. Ordering ties are broken by insertion in `Enum.sort_by` (stable).
      end

      # Read back through the WAL, which `note/3` writes on every upsert AFTER the prune: the
      # registry has no listing API, and the WAL is the durable artifact the bound exists to keep
      # from growing. Checking it proves the cap where it actually costs.
      kept = wal_path |> File.read!() |> Jason.decode!()

      assert map_size(kept) == 3,
             "the cap was not applied — the knob is documented but not read (#{map_size(kept)} entries)"

      # And it kept the RIGHT three: eviction is by `last_seen` descending, so the survivors are
      # the most recent. A cap that trimmed the newest would bound the size and lose the signal.
      assert Map.has_key?(kept, "sig-5")
      refute Map.has_key?(kept, "sig-1")
    end
  end
end
