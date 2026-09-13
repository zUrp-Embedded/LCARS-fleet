defmodule Fleet.Spawner.PublishConsumerTest do
  @moduledoc """
  Dispatch and publish-outcome tests use injected spawners without Bus subscription.
  """
  use ExUnit.Case, async: true
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.EventRouter.Bus
  alias Fleet.Spawner.PublishConsumer

  defmodule StubSpawner do
    # Return a PID as production does. Calls run in the consumer’s process, so relay to
    # a registered observer keyed by unique issue_id rather than using the test’s process dictionary.
    def spawn_pod(_cap_profile, issue_id, opts) do
      if obs = Process.whereis(:"spawn_probe_#{issue_id}"),
        do: send(obs, {:spawn_called, issue_id, opts})

      {:ok, self()}
    end

    # The same observer pattern reports notifications from the consumer process.
    def notify_pod(pod, msg) do
      if obs = Process.whereis(:"notify_probe_#{pod}"), do: send(obs, {:notified, pod, msg})
      :ok
    end
  end

  # Use a real catalogue role so profile resolution succeeds before the injected spawn error.
  defmodule RaisingOnSpawnSpawner do
    def spawn_pod(_cap_profile, _issue_id, _opts), do: raise("boom spawn (test E-04)")
  end

  defmodule ExitingSpawner do
    def spawn_pod(_cap_profile, _issue_id, _opts), do: exit(:spawner_unavailable)
  end

  defmodule ErrorOnSpawnSpawner do
    def spawn_pod(_cap_profile, _issue_id, _opts), do: {:error, :no_capacity}
  end

  defp start_consumer(spawner \\ StubSpawner) do
    name = :"pc_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised({PublishConsumer, name: name, subscribe: false, spawner: spawner})

    {pid, name}
  end

  test "admin.spawn.request with absent name → warn log, alive, count++" do
    {pid, _} = start_consumer()

    send(pid, Fleet.Event.new(:api, :"admin.spawn.request"))

    # settle is a FIFO barrier: the earlier send is processed before state is inspected.
    assert Process.alive?(pid)
    assert %{count: 1} = settle(pid)
    refute_received {:spawn_called, _, _}
  end

  # Empty strings are truthy; the unauthenticated Bus boundary must normalize names itself.
  defmodule OkSpawner do
    def spawn_pod(_cap_profile, _issue_id, _opts), do: {:ok, self()}
  end

  test "acte4 #32: empty cap_profile_name + valid role → the role is resolved (spawn fired)" do
    {pid, _} = start_consumer(OkSpawner)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(
          pid,
          Fleet.Event.new(:api, :"admin.spawn.request",
            payload: %{"cap_profile_name" => "", "role" => "engineer", "issue_id" => "issue-9"}
          )
        )

        _ = settle(pid)
      end)

    assert Process.alive?(pid)
    assert log =~ "spawn dispatched name=engineer issue=issue-9"
    refute log =~ "invalid — name missing/empty"
  end

  test "nominal dispatch threads issue_id + allowlisted opts to spawn_pod (proven, not just logged)" do
    issue_id = "issue-proven-#{System.unique_integer([:positive])}"
    Process.register(self(), :"spawn_probe_#{issue_id}")
    {pid, _} = start_consumer()

    send(
      pid,
      Fleet.Event.new(:api, :"admin.spawn.request",
        payload: %{
          "cap_profile_name" => "engineer",
          "issue_id" => issue_id,
          "opts" => %{"brief" => "ship it", "pod_id" => "#{issue_id}-engineer"}
        }
      )
    )

    assert_receive {:spawn_called, ^issue_id, opts}, 2000
    assert Keyword.get(opts, :brief) == "ship it"
    assert Keyword.get(opts, :pod_id) == "#{issue_id}-engineer"
    assert Process.alive?(pid)
  end

  test "acte4 #32: fully empty name → spawn.failed emitted (visible drop, not a mute warning)" do
    :ok = Bus.subscribe()
    on_exit(fn -> Bus.unsubscribe() end)
    {pid, _} = start_consumer()

    send(
      pid,
      Fleet.Event.new(:api, :"admin.spawn.request",
        payload: %{"cap_profile_name" => "", "issue_id" => "issue-10"}
      )
    )

    assert Process.alive?(pid)

    # A missing role still needs a binary incident subject and a JSON-safe reason.
    assert_receive %Fleet.Event{
                     source: :spawner,
                     type: :"spawn.failed",
                     payload:
                       %{"reason" => "name_missing_or_empty", "cap_profile_name" => "unknown"} =
                         payload
                   },
                   500

    assert {:ok, _} = Jason.encode(payload)

    refute_received {:spawn_called, _, _}
  end

  test "admin.spawn.request with ghost name → CapProfile.load fail → warn log, alive" do
    {pid, _} = start_consumer()

    send(
      pid,
      Fleet.Event.new(:api, :"admin.spawn.request",
        payload: %{"cap_profile_name" => "ghost-role-xyz"}
      )
    )

    assert Process.alive?(pid)
    assert %{count: 1} = settle(pid)
    refute_received {:spawn_called, _, _}
  end

  test "RAISING dispatch → spawn.failed event emitted on the Bus (the drop is no longer silent)" do
    :ok = Bus.subscribe()
    {pid, _} = start_consumer(RaisingOnSpawnSpawner)

    send(
      pid,
      Fleet.Event.new(:api, :"admin.spawn.request",
        payload: %{"cap_profile_name" => "engineer", "issue_id" => "tk-42"}
      )
    )

    # The consumer resolves a catalogue profile from disk before emitting. Allow async scheduling
    # and parsing time; this test checks delivery, not latency.
    assert_receive %Fleet.Event{
                     source: :spawner,
                     type: :"spawn.failed",
                     payload: %{
                       "cap_profile_name" => "engineer",
                       "issue_id" => "tk-42",
                       "reason" => reason
                     }
                   },
                   2000

    assert reason =~ "boom spawn"
    assert Process.alive?(pid)
    assert %{count: 1} = settle(pid)
  end

  test "F-06 (codex audit): EXITING dispatch → consumer stays ALIVE + spawn.failed emitted" do
    # Exceptions and process exits need separate coverage; rescue does not catch exit.
    :ok = Bus.subscribe()
    {pid, _} = start_consumer(ExitingSpawner)

    send(
      pid,
      Fleet.Event.new(:api, :"admin.spawn.request",
        payload: %{"cap_profile_name" => "engineer", "issue_id" => "tk-66"}
      )
    )

    assert_receive %Fleet.Event{
                     source: :spawner,
                     type: :"spawn.failed",
                     payload: %{"issue_id" => "tk-66", "reason" => reason} = failed
                   },
                   2000

    assert reason == "exit"
    assert inspect(failed["reason_detail"]) =~ "spawner_unavailable"
    assert Process.alive?(pid)
    assert %{count: 1} = settle(pid)
  end

  test "F-C044: CapProfile.load fail → spawn.failed emitted (the load drop is no longer silent)" do
    :ok = Bus.subscribe()
    {pid, _} = start_consumer()

    send(
      pid,
      Fleet.Event.new(:api, :"admin.spawn.request",
        payload: %{"cap_profile_name" => "ghost-role-xyz", "issue_id" => "tk-7"}
      )
    )

    assert_receive %Fleet.Event{
                     source: :spawner,
                     type: :"spawn.failed",
                     payload: %{
                       "cap_profile_name" => "ghost-role-xyz",
                       "issue_id" => "tk-7",
                       "reason" => _
                     }
                   },
                   2000

    assert Process.alive?(pid)
  end

  test "F-C044: spawn_pod {:error} → spawn.failed emitted (202 queued, 0 pod → alarm, not silence)" do
    :ok = Bus.subscribe()
    {pid, _} = start_consumer(ErrorOnSpawnSpawner)

    send(
      pid,
      Fleet.Event.new(:api, :"admin.spawn.request",
        payload: %{"cap_profile_name" => "engineer", "issue_id" => "tk-8"}
      )
    )

    assert_receive %Fleet.Event{
                     source: :spawner,
                     type: :"spawn.failed",
                     payload: %{
                       "cap_profile_name" => "engineer",
                       "issue_id" => "tk-8",
                       "reason" => _
                     }
                   },
                   2000

    assert Process.alive?(pid)
  end

  test "event other than admin.spawn.request → ignored (alive, no spawn_called)" do
    {pid, _} = start_consumer()

    send(pid, Fleet.Event.new(:spawner, :"pod.drift"))

    send(pid, Fleet.Event.new(:pilot, :"pod.completed"))

    _ = settle(pid)
    assert Process.alive?(pid)
    refute_received {:spawn_called, _, _}
  end

  test "non-event msg: no crash" do
    {pid, _} = start_consumer()
    send(pid, :random)
    _ = settle(pid)
    assert Process.alive?(pid)
  end

  describe "to_keyword/1 — anti atom-leak (finding Vulcan)" do
    test "known key (existing atom) converted, unknown key ignored (no String.to_atom)" do
      assert PublishConsumer.to_keyword(%{"brief" => "x"}) == [brief: "x"]

      # Use a fresh key so the test actually exercises the absent-atom path.
      garbage = "atom_inexistant_zzz_#{System.unique_integer([:positive])}"
      assert PublishConsumer.to_keyword(%{garbage => 1}) == []
    end

    test "keyword list passes through as-is; anything else → []" do
      assert PublishConsumer.to_keyword(brief: 1) == [brief: 1]
      assert PublishConsumer.to_keyword(nil) == []
    end

    test "R1-30: INFRASTRUCTURE opts (existing but dangerous atoms) DROPPED (fail-closed allowlist)" do
      # Intern these keys first: exclusion must come from the allowlist, not the absent-atom filter.
      _intern = [:pod_dir_root, :state_fs_root, :containment, :launch_backend]

      injected = %{
        "brief" => "x",
        "pod_id" => "issue-1-engineer",
        "pod_dir_root" => "/evil",
        "state_fs_root" => "/evil",
        "containment" => "none",
        "launch_backend" => "Evil"
      }

      kept = PublishConsumer.to_keyword(injected)

      assert Keyword.get(kept, :brief) == "x"
      assert Keyword.get(kept, :pod_id) == "issue-1-engineer"
      refute Keyword.has_key?(kept, :pod_dir_root)
      refute Keyword.has_key?(kept, :state_fs_root)
      refute Keyword.has_key?(kept, :containment)
      refute Keyword.has_key?(kept, :launch_backend)
    end

    test "NON-keyword list (decoded JSON array) → [] (defense in depth, no longer swallowed raw)" do
      assert PublishConsumer.to_keyword(["module", "fun"]) == []
      assert PublishConsumer.to_keyword([%{"pod_dir_root" => "/evil"}]) == []
      assert PublishConsumer.to_keyword([{"string_key", 1}]) == []
    end
  end

  describe "relaying a publish outcome to the requester" do
    test "project_publish.done -> notify_pod the requester with the url" do
      {pid, _} = start_consumer()
      Process.register(self(), :"notify_probe_pod-req")

      send(
        pid,
        Fleet.Event.new(:mcp, :"project_publish.done",
          payload: %{
            "repo" => "fleet/demo",
            "url" => "https://forge/pr/1",
            "requester_pod_id" => "pod-req"
          }
        )
      )

      assert_receive {:notified, "pod-req", msg}
      assert msg =~ "fleet/demo"
      assert msg =~ "https://forge/pr/1"
      refute msg =~ "ouvre"
    end

    test "project_publish.done manual:true -> notify_pod says 'ouvre la PR/MR' (Tier 2, one more click)" do
      {pid, _} = start_consumer()
      Process.register(self(), :"notify_probe_pod-t2")

      send(
        pid,
        Fleet.Event.new(:mcp, :"project_publish.done",
          payload: %{
            "repo" => "fleet/demo",
            "url" => "https://forge/compare/main...lcars/publish?expand=1",
            "manual" => true,
            "requester_pod_id" => "pod-t2"
          }
        )
      )

      assert_receive {:notified, "pod-t2", msg}
      assert msg =~ "ouvre la PR/MR"
      assert msg =~ "https://forge/compare/main...lcars/publish?expand=1"
    end

    test "project_publish.failed -> notify_pod the requester with the reason" do
      {pid, _} = start_consumer()
      Process.register(self(), :"notify_probe_pod-req2")

      send(
        pid,
        Fleet.Event.new(:mcp, :"project_publish.failed",
          payload: %{
            "repo" => "fleet/demo",
            "reason" => "not_linked",
            "reason_detail" => "not_linked",
            "requester_pod_id" => "pod-req2"
          }
        )
      )

      assert_receive {:notified, "pod-req2", msg}
      assert msg =~ "ECHEC"
      assert msg =~ "not_linked"
    end

    test "an outcome with no requester_pod_id -> no notify, consumer stays alive" do
      {pid, _} = start_consumer()

      send(
        pid,
        Fleet.Event.new(:mcp, :"project_publish.done",
          payload: %{
            "repo" => "fleet/demo",
            "url" => "https://forge/pr/1",
            "requester_pod_id" => nil
          }
        )
      )

      assert %{} = settle(pid)
      assert Process.alive?(pid)
      refute_received {:notified, _, _}
    end
  end
end
