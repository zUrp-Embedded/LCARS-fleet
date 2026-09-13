defmodule Fleet.ConfigKnobsTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Sets distinctive Application values to check that limit/deadline readers and incident
  registry behavior consult their configuration. Does not exercise runtime environment
  parsing. workflow_git_push_timeout_ms is outside this file's coverage.
  """

  alias Fleet.Pilot.IncidentRegistry

  describe "the knobs that bound a safety are actually READ" do
    test ":lcars_fleet, :spawner_max_pods — the fleet-wide FUSE (not a policy)" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_max_pods, 7)
      assert Fleet.Spawner.max_pods() == 7
    end

    test ":lcars_fleet, :spawner_publish_deadline_ms — the fail-safe that lifts a DESTRUCTIVE reset" do
      # The publish deadline lifts the flag that prevents destructive reset/clean operations.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_publish_deadline_ms, 4_242)
      assert Fleet.Spawner.Pod.Publishing.publish_deadline_ms() == 4_242
    end
  end

  describe ":lcars_fleet, :pilot_incident_registry_sync_debounce_ms — the ops-commit window" do
    setup do
      tmp = Fleet.TestEnv.tmp_path("knobs_window")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      {:ok, wal_path: Path.join(tmp, "wal.json")}
    end

    # Omit the constructor's sync_debounce_ms seam so only Application config selects the window.
    defp start_without_seam(wal_path, test_pid) do
      start_supervised!(
        {IncidentRegistry,
         name: :"knobs_window_#{System.unique_integer([:positive])}",
         wal_path: wal_path,
         get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
         put_file_fun: fn _r, _p, content, _o ->
           send(test_pid, {:put, content})
           {:ok, "c"}
         end}
      )
    end

    test "the knob sets the window: 5 ms → the note reaches the forge at once", %{
      wal_path: wal_path
    } do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_incident_registry_sync_debounce_ms, 5)
      registry = start_without_seam(wal_path, self())

      :ok = IncidentRegistry.note("wake:p:dead", :dead, server: registry)
      assert_receive {:put, content}, 1_000
      assert content =~ "wake:p:dead"
    end

    # Separate the short and longer configured windows without asserting exact scheduling times.
    test "counter-witness: a 400 ms window holds the note back, then lets it through", %{
      wal_path: wal_path
    } do
      Fleet.TestEnv.put_env_restoring(
        :lcars_fleet,
        :pilot_incident_registry_sync_debounce_ms,
        400
      )

      registry = start_without_seam(wal_path, self())

      :ok = IncidentRegistry.note("wake:p:dead", :dead, server: registry)
      refute_receive {:put, _}, 200
      assert_receive {:put, _}, 1_000
    end
  end

  describe ":lcars_fleet, :pilot_incident_registry_max_entries — bounds unbounded growth" do
    setup do
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
           get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
           put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end}
        )

      {:ok, registry: pid, wal_path: wal_path}
    end

    test "beyond the cap, the OLDEST entries are evicted and the newest survive", %{
      registry: registry,
      wal_path: wal_path
    } do
      # Exercise pruning through the persisted WAL, not only a configuration accessor.
      for i <- 1..5 do
        :ok = IncidentRegistry.note("sig-#{i}", "reason #{i}", server: registry)

        # Calls serialize upserts but do not guarantee distinct timestamps. Equal last_seen values
        # retain map enumeration order under stable sorting, not insertion order.
      end

      kept = wal_path |> File.read!() |> Jason.decode!()

      assert map_size(kept) == 3,
             "the cap was not applied — the knob is documented but not read (#{map_size(kept)} entries)"

      # These identity assertions assume distinct timestamps and can fail on ties.
      # They do not establish deterministic newest-first eviction for equal last_seen values.
      assert Map.has_key?(kept, "sig-5")
      refute Map.has_key?(kept, "sig-1")
    end
  end
end
