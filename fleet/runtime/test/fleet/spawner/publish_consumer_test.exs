defmodule Fleet.Spawner.PublishConsumerTest do
  @moduledoc """
  B10 C3 / #583 Sprint 1 — PublishConsumer subscribe filter +
  dispatch chain. `:subscribe` false + `:spawner` stub → async.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.PublishConsumer

  defmodule StubSpawner do
    # PASSE-9 — real shape of `Spawner.spawn_pod/3` = {:ok, pid()}, NEVER {:ok, :stub_pod}: a
    # consumer re-interpolating the pid would break in prod.
    #
    # Async-safe observability: `spawn_pod` runs INSIDE the consumer GenServer, so it CANNOT read the
    # test's process dictionary (the old `send(Process.get(:test_pid), …)` read the CONSUMER's dict →
    # nil → the {:spawn_called} signal never reached any test, so the nominal dispatch + its threaded
    # opts were never actually asserted). It relays to an observer registered under a name derived from
    # the UNIQUE issue_id (no cross-test collision under `async`); silent no-op when none is registered.
    def spawn_pod(_cap_profile, issue_id, opts) do
      if obs = Process.whereis(:"spawn_probe_#{issue_id}"),
        do: send(obs, {:spawn_called, issue_id, opts})

      {:ok, self()}
    end
  end

  # Spawner that RAISES in `spawn_pod` → exercises the `handle_info` rescue (spawn dropped).
  # CapProfile.load must succeed first to reach spawn_pod: we pass a real canon role ("engineer").
  # Named after the raising op: a homonym `RaisingSpawner` in fleet_starfleet raises on
  # `count_pods` — same name, different contracts = reading trap (B6 dedup, both renamed).
  defmodule RaisingOnSpawnSpawner do
    def spawn_pod(_cap_profile, _issue_id, _opts), do: raise("boom spawn (test E-04)")
  end

  # F-06 — the backend EXITS (not a raise): the plausible OTP path (call on a dead process).
  defmodule ExitingSpawner do
    def spawn_pod(_cap_profile, _issue_id, _opts), do: exit(:spawner_unavailable)
  end

  # F-C044 — spawn_pod returns {:error, _} (NOT a raise) → exercises the ordinary {:error} branch
  # of `handle_spawn_request` (the one that only logged a warning, without `spawn.failed`).
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

    # Mi14: :sys.get_state = FIFO barrier (the send is handled first) → no arbitrary sleep.
    assert Process.alive?(pid)
    assert %{count: 1} = :sys.get_state(pid)
    refute_received {:spawn_called, _, _}
  end

  # Regression acte4 #32 (2nd layer — the no-auth Bus boundary). "" is TRUTHY: without presence/1,
  # `cap_profile_name:"" || role` short-circuits on "" → load("") → drop AFTER the 202 (lying
  # 202). The 1st layer (SpawnAdmission) no longer broadcasts empty keys, but the Bus is
  # no-auth: any process can emit — this consumer normalizes TOO.
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

        # FIFO barrier: the send is handled before this returns
        _ = :sys.get_state(pid)
      end)

    assert Process.alive?(pid)
    assert log =~ "spawn dispatched name=engineer issue=issue-9"
    refute log =~ "invalid — name missing/empty"
  end

  test "nominal dispatch threads issue_id + allowlisted opts to spawn_pod (proven, not just logged)" do
    # The OkSpawner test above proves the spawn FIRES (via the log line); this proves WHAT actually
    # reaches spawn_pod — the issue_id and the allowlisted opts (brief + pod_id), i.e. the payload the
    # pod is born with. The old suite never asserted this: the `{:spawn_called, …}` relay was broken
    # (read the wrong process dict), so the opts threading went entirely unverified.
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
    :ok = Fleet.EventRouter.Bus.subscribe()
    on_exit(fn -> Fleet.EventRouter.Bus.unsubscribe() end)
    {pid, _} = start_consumer()

    send(
      pid,
      Fleet.Event.new(:api, :"admin.spawn.request",
        payload: %{"cap_profile_name" => "", "issue_id" => "issue-10"}
      )
    )

    assert Process.alive?(pid)

    # The subject falls back to the "unknown" sentinel (presence/1 on both candidates, class #32):
    # the alarm ALWAYS reaches the incident rail with a binary subject (IncidentConsumer's
    # is_binary guard) — a "" name no longer makes it vanish silently. `reason` is the
    # string category (JSON-safe payload end to end).
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
    assert %{count: 1} = :sys.get_state(pid)
    refute_received {:spawn_called, _, _}
  end

  test "RAISING dispatch → spawn.failed event emitted on the Bus (the drop is no longer silent)" do
    # E-04: the REST API already answered 202 "queued"; if the dispatch raises, the spawn is dropped.
    # Without `spawn.failed`, the admin believes the pod is queued → no signal. We capture the alarm on the Bus.
    :ok = Fleet.EventRouter.Bus.subscribe()
    {pid, _} = start_consumer(RaisingOnSpawnSpawner)

    send(
      pid,
      Fleet.Event.new(:api, :"admin.spawn.request",
        payload: %{"cap_profile_name" => "engineer", "issue_id" => "tk-42"}
      )
    )

    # INTEGRATION assertion: the broadcast traverses the consumer (GenServer) + `CapProfile.load`
    # (disk I/O + YAML parse + schema validation) BEFORE `emit_spawn_failed`. Under `async`
    # parallelism, `assert_receive`'s default 100ms is too tight → flaky depending on the scheduling
    # seed (the broadcast lands after the timeout, mailbox seen empty). Wide timeout: we test THAT
    # the alarm eventually arrives, never its latency (which varies with concurrent async case load).
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
    # The drop is non-fatal: the consumer stays alive and counted the event.
    assert Process.alive?(pid)
    assert %{count: 1} = :sys.get_state(pid)
  end

  test "F-06 (codex audit): EXITING dispatch → consumer stays ALIVE + spawn.failed emitted" do
    # `rescue` covers exceptions only — a backend that `exit`s (GenServer.call on a dead
    # spawner) killed the consumer: supervisor restart hid the drop, the 202-acked request was
    # lost WITHOUT its alarm. The `catch kind, reason` must normalize exit/throw the same way.
    :ok = Fleet.EventRouter.Bus.subscribe()
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

    # reason = the STABLE category (JSON-safe rail contract); the term goes to reason_detail.
    assert reason == "exit"
    assert inspect(failed["reason_detail"]) =~ "spawner_unavailable"
    assert Process.alive?(pid)
    assert %{count: 1} = :sys.get_state(pid)
  end

  test "F-C044: CapProfile.load fail → spawn.failed emitted (the load drop is no longer silent)" do
    # Same requirement as the RAISE case, but for an ORDINARY {:error} (ghost name → load KO): the admin
    # got their 202, the pod is never born → the alarm must reach the Bus (observation read-model), not just a log.
    :ok = Fleet.EventRouter.Bus.subscribe()
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
    :ok = Fleet.EventRouter.Bus.subscribe()
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

    send(pid, Fleet.Event.new(:coord, :"coord.action_dispatched"))

    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
    refute_received {:spawn_called, _, _}
  end

  test "non-event msg: no crash" do
    {pid, _} = start_consumer()
    send(pid, :random)
    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  describe "to_keyword/1 — anti atom-leak (finding Vulcan)" do
    test "known key (existing atom) converted, unknown key ignored (no String.to_atom)" do
      # :brief exists (literal compiled below + spawn_opts option) → kept
      assert PublishConsumer.to_keyword(%{"brief" => "x"}) == [brief: "x"]

      # key never seen as an atom → to_existing_atom raises → filtered out (anti atom-table DoS)
      garbage = "atom_inexistant_zzz_#{System.unique_integer([:positive])}"
      assert PublishConsumer.to_keyword(%{garbage => 1}) == []
    end

    test "keyword list passes through as-is; anything else → []" do
      assert PublishConsumer.to_keyword(brief: 1) == [brief: 1]
      assert PublishConsumer.to_keyword(nil) == []
    end

    test "R1-30: INFRASTRUCTURE opts (existing but dangerous atoms) DROPPED (fail-closed allowlist)" do
      # Forces these atoms to exist → they PASS the atom-leak filter (to_existing_atom OK): what
      # drops them is therefore the ALLOWLIST, not the filter. They would redirect the FS outside
      # the confined home (pod_dir_root/state_fs_root), open the host (containment) or swap the backend.
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
      # An `opts` arriving as a JSON array (`["module","fun"]` or `[%{...}]`) is NEVER a keyword-list
      # (string keys → maps/scalars). A `to_keyword(list) = list` pass-through would inject arbitrary
      # opts → filtered to []. (The main lock remains the /api/admin/spawn admission allowlist.)
      assert PublishConsumer.to_keyword(["module", "fun"]) == []
      assert PublishConsumer.to_keyword([%{"pod_dir_root" => "/evil"}]) == []
      assert PublishConsumer.to_keyword([{"string_key", 1}]) == []
    end
  end
end
