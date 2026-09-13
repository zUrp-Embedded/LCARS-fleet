defmodule Fleet.SpawnerTest.UnresponsivePod do
  @moduledoc false
  # Registered fake pod that crashes on :kill to exercise the forced-termination fallback.
  use GenServer

  def start(pod_id), do: GenServer.start(__MODULE__, pod_id)

  @impl true
  def init(pod_id) do
    {:ok, _} = Registry.register(Fleet.Spawner.Registry, pod_id, nil)
    {:ok, pod_id}
  end

  @impl true
  def handle_call(:kill, _from, _state), do: raise("simulated unresponsive pod (R1-18)")
end

defmodule Fleet.SpawnerTest do
  use ExUnit.Case, async: false

  alias Fleet.Spawner.LaunchBackend.StubBackend
  alias Fleet.Spawner.Pod.TurnFlag

  # Minimum disallowed tools needed for the fixture to pass profile validation.
  @min_disallowed ~w(web_search web_fetch code_execution bash_code_execution text_editor_code_execution tool_search_web)

  # Direct spawns need a repository ID for session minting. Admission-refusal tests
  # can omit it when they must fail before minting.
  @test_repo_id 7

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:lcars_fleet, :spawner_state_fs_root, Path.join(tmp_dir, "state"))
    Application.put_env(:lcars_fleet, :spawner_pod_dir_root, Path.join(tmp_dir, "pods"))
    Application.put_env(:lcars_fleet, :spawner_launch_backend, StubBackend)

    # Provide valid credentials so unrelated spawn tests reach their intended phase.
    setup_claude = Path.join(tmp_dir, ".claude")
    File.mkdir_p!(setup_claude)

    File.write!(
      Path.join(setup_claude, ".credentials.json"),
      Jason.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => "sk-ant-setup-tok",
          "expiresAt" => 99_999_999_999_999,
          "refreshToken" => "rt",
          "scopes" => ["user:inference", "user:sessions:claude_code"],
          "subscriptionType" => "max"
        }
      })
    )

    Application.put_env(:lcars_fleet, :spawner_claude_dir, setup_claude)

    StubBackend.set_reply({:ok, %{}})

    on_exit(fn ->
      StubBackend.clear()
      Application.delete_env(:lcars_fleet, :spawner_state_fs_root)
      Application.delete_env(:lcars_fleet, :spawner_pod_dir_root)
      # Keep the configured StubBackend; deleting the key would select the real launcher.
      Application.delete_env(:lcars_fleet, :spawner_claude_dir)
    end)

    :ok
  end

  defp valid_profile do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{
        "name" => "engineer",
        "containment" => "bwrap",
        "role_index" => 3,
        "protected" => false,
        "fleet_level" => false
      },
      spec: %{
        "scope" => %{"disallowedTools" => @min_disallowed, "git_ops_denied" => []},
        "knowledge" => %{"skills" => []},
        "invocation" => %{"lifetime_scope" => "one-shot"},
        "interlocutor" => "fleet",
        "injects" => %{},
        "budget" => %{"maxUsd" => 1.0, "maxDurationSec" => 60},
        "modop_set" => []
      }
    }
  end

  defp forever_profile do
    put_in(valid_profile().spec["invocation"], %{
      "lifetime_scope" => "forever",
      "slot_scope" => "project",
      "remote_control" => true
    })
  end

  defp wait_until(fun, tries \\ 80) do
    cond do
      fun.() ->
        true

      tries <= 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end

  describe "one-shot spawn without brief is refused (brief guard)" do
    test "valid_pod_id?/1 is the public authority on the pod_id charset" do
      # Admission accepts short IDs; the stricter pkill pattern limit belongs to PodTmux.
      for ok <- ["pod-1", "permanent-architect", "repo.issue_1-role", UUID.uuid4(), "p1"] do
        assert Fleet.Spawner.valid_pod_id?(ok), "pod_id #{inspect(ok)} should be accepted"
      end

      for bad <- [
            "../etc/passwd",
            "a/b",
            "..",
            "pod_..",
            "x y",
            "",
            nil,
            42,
            ".hidden",
            "_lead",
            "-flag",
            String.duplicate("a", 200)
          ] do
        refute Fleet.Spawner.valid_pod_id?(bad), "pod_id #{inspect(bad)} should be rejected"
      end
    end

    test "brief_required?/1 — shared authority: one-shot → true, other scopes / absent → false" do
      assert Fleet.Spawner.brief_required?(valid_profile())

      for scope <- ["forever", "run", "pipe", "permanent"] do
        cap = put_in(valid_profile().spec["invocation"], %{"lifetime_scope" => scope})

        refute Fleet.Spawner.brief_required?(cap),
               "scope #{scope} should NOT require a brief"
      end

      # This predicate returns false without scope; spawn admission separately rejects that profile.
      no_scope = put_in(valid_profile().spec["invocation"], %{})
      refute Fleet.Spawner.brief_required?(no_scope)
    end

    test "order_present?/1 — shared authority: the order has TWO shapes, text and address" do
      assert Fleet.Spawner.order_present?(brief: "fix bug X")
      assert Fleet.Spawner.order_present?(brief_ref: "briefs/x.md", brief_sha: "abc")

      assert Fleet.Spawner.order_present?(brief_ref: "briefs/x.md")

      refute Fleet.Spawner.order_present?([])
      refute Fleet.Spawner.order_present?(brief: "")
      refute Fleet.Spawner.order_present?(brief: nil)
      refute Fleet.Spawner.order_present?(brief_sha: "abc")
    end

    test "DR-019: cap-profile WITHOUT lifetime_scope → spawn REFUSED (invalid state, never spawned)" do
      no_scope = put_in(valid_profile().spec["invocation"], %{})

      assert {:error, :cap_profile_no_lifetime_scope} =
               Fleet.Spawner.spawn_pod(no_scope, "issue-no-scope", brief: "do x")

      assert {:error, :cap_profile_no_lifetime_scope} =
               Fleet.Spawner.spawn_pod(no_scope, "issue-no-scope", allow_no_brief: true)
    end

    test "cap-profile WITHOUT interlocutor → spawn REFUSED (the protocol contract is never inferred)" do
      no_who = Map.delete(valid_profile().spec, "interlocutor")
      cap = %{valid_profile() | spec: no_who}

      assert {:error, :cap_profile_no_interlocutor} =
               Fleet.Spawner.spawn_pod(cap, "issue-no-who", brief: "do x")

      assert {:error, :cap_profile_no_interlocutor} =
               Fleet.Spawner.spawn_pod(cap, "issue-no-who", allow_no_brief: true)

      blank = %{valid_profile() | spec: Map.put(valid_profile().spec, "interlocutor", "")}

      assert {:error, :cap_profile_no_interlocutor} =
               Fleet.Spawner.spawn_pod(blank, "issue-blank-who", brief: "do x")
    end

    test "NAMED pod without :project_slug → spawn REFUSED (the label carries no structure)" do
      assert {:error, :project_required} =
               Fleet.Spawner.spawn_pod(valid_profile(), "issue-named",
                 brief: "do x",
                 rc_name: "p_engineer"
               )

      for bad <- ["../evil", "a/b", "", nil, 42] do
        assert {:error, :project_required} =
                 Fleet.Spawner.spawn_pod(valid_profile(), "issue-bad-slug",
                   brief: "do x",
                   rc_name: "p_engineer",
                   project_slug: bad
                 ),
               "slug #{inspect(bad)} should be refused"
      end
    end

    test "UNNAMED pod (no rc_name) → the slug is not demanded (permanent / admin pods)" do
      # The later brief refusal proves the project guard accepted an unlabeled pod.
      assert {:error, :brief_required} =
               Fleet.Spawner.spawn_pod(valid_profile(), "issue-unnamed")
    end

    test "one-shot + no brief → {:error, :brief_required}" do
      assert {:error, :brief_required} =
               Fleet.Spawner.spawn_pod(valid_profile(), "issue-no-brief")
    end

    test "one-shot + EMPTY brief (e.g. empty StageSpawner ctx) → {:error, :brief_required}" do
      assert {:error, :brief_required} =
               Fleet.Spawner.spawn_pod(valid_profile(), "issue-empty-brief", brief: "")
    end

    test "F076 — non path-safe pod_id (.. or / or empty) → {:error, :invalid_pod_id}, no spawn" do
      for bad <- ["../etc/passwd", "a/b", "..", "pod_..", "x y", ""] do
        assert match?(
                 {:error, :invalid_pod_id},
                 Fleet.Spawner.spawn_pod(valid_profile(), "issue-1",
                   pod_id: bad,
                   brief: "do x"
                 )
               ),
               "pod_id #{inspect(bad)} should have been rejected (path-traversal)"
      end
    end

    test "one-shot + brief → {:ok, _}" do
      assert {:ok, _pid} =
               Fleet.Spawner.spawn_pod(valid_profile(), "issue-brief",
                 brief: "fix bug X",
                 pod_id: "pod-r18-brief-#{System.unique_integer([:positive])}",
                 repo_id: @test_repo_id
               )
    end

    test "one-shot + POINTER (brief_ref, no inline text) → {:ok, _} — the nominal rail" do
      assert {:ok, _pid} =
               Fleet.Spawner.spawn_pod(valid_profile(), "issue-brief-ptr",
                 brief_ref: "briefs/x.md",
                 brief_sha: "62e36295c11f459baed13ebd724583508dc36388",
                 pod_id: "pod-r18-ptr-#{System.unique_integer([:positive])}",
                 repo_id: @test_repo_id
               )
    end

    test "a pointer with NO ref is not an order — the sha alone names nothing" do
      assert {:error, :brief_required} =
               Fleet.Spawner.spawn_pod(valid_profile(), "issue-sha-only",
                 brief_sha: "62e36295c11f459baed13ebd724583508dc36388"
               )
    end

    test "CONCURRENT spawns of the same (role, repo) never share a pool index" do
      # Concurrent callers must receive distinct slots through the serialized supervisor start.
      n = 6
      ids = for i <- 1..n, do: "pod-conc-#{System.unique_integer([:positive])}-#{i}"

      pids =
        ids
        |> Enum.map(fn id ->
          Task.async(fn ->
            Fleet.Spawner.spawn_pod(valid_profile(), "issue-conc",
              brief: "x",
              pod_id: id,
              repo_id: @test_repo_id
            )
          end)
        end)
        |> Enum.map(fn task ->
          assert {:ok, pid} = Task.await(task, 15_000)
          pid
        end)

      # Force cleanup without waiting on pod calls, so surviving test pods do not delay
      # later Registry enumeration.
      on_exit(fn -> Enum.each(pids, &Process.exit(&1, :kill)) end)

      pools =
        for {id, pid} <- Enum.zip(ids, pids) do
          # Require every started PID to remain registered; omitted entries would weaken uniqueness.
          assert [{^pid, %{pool: pool}}] = Registry.lookup(Fleet.Spawner.Registry, id)
          pool
        end

      assert length(pools) == n
      assert Enum.uniq(pools) == pools, "pools collided: #{inspect(pools)}"
      refute 0 in pools, "an instance-keyed pod took the reserved seat: #{inspect(pools)}"
    end

    test "one-shot + allow_no_brief (admin/diagnostic) → {:ok, _}" do
      assert {:ok, _pid} =
               Fleet.Spawner.spawn_pod(valid_profile(), "issue-admin",
                 allow_no_brief: true,
                 pod_id: "pod-r18-admin-#{System.unique_integer([:positive])}",
                 repo_id: @test_repo_id
               )
    end

    test "long-lived (forever) without brief → {:ok, _} (exempt, pull via MCP)" do
      assert {:ok, _pid} =
               Fleet.Spawner.spawn_pod(forever_profile(), "issue-forever",
                 pod_id: "pod-r18-forever-#{System.unique_integer([:positive])}",
                 repo_id: @test_repo_id
               )
    end
  end

  test "spawn_pod returns {:ok, pid} and registers the pod" do
    pod_id = "pod-public-api-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Fleet.Spawner.spawn_pod(valid_profile(), "issue-1",
               pod_id: pod_id,
               allow_no_brief: true,
               repo_id: @test_repo_id
             )

    assert is_pid(pid)

    assert {:ok, %{pod_id: ^pod_id}} = Fleet.Spawner.pod_info(pod_id)
  end

  test "a failing pod releases its active task (STATE-004)" do
    pod_id = "pod-orphan-#{System.unique_integer([:positive])}"
    {:ok, _} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "x"})

    assert {:ok, status} = Fleet.TaskQueue.pod_status(pod_id)
    refute is_nil(status)

    StubBackend.set_reply({:error, :stub_launch_fail})

    {:ok, _pid} =
      Fleet.Spawner.spawn_pod(valid_profile(), "issue-orphan",
        pod_id: pod_id,
        allow_no_brief: true,
        repo_id: @test_repo_id
      )

    assert wait_until(fn -> Fleet.TaskQueue.pod_status(pod_id) == {:ok, :cleared} end),
           "the dead pod's task should be :cleared, current status: #{inspect(Fleet.TaskQueue.pod_status(pod_id))}"
  end

  test "kill_pod does a clean release: task released + pod gone (LIFE-003)" do
    pod_id = "pod-killclean-#{System.unique_integer([:positive])}"
    {:ok, _} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "x"})

    {:ok, _pid} =
      Fleet.Spawner.spawn_pod(forever_profile(), "issue-kill",
        pod_id: pod_id,
        repo_id: @test_repo_id
      )

    assert wait_until(fn -> match?({:ok, _}, Fleet.Spawner.pod_info(pod_id)) end)

    assert :ok = Fleet.Spawner.kill_pod(pod_id)

    assert wait_until(fn -> Fleet.TaskQueue.pod_status(pod_id) == {:ok, :cleared} end),
           "kill_pod should release the task (clean release), status: #{inspect(Fleet.TaskQueue.pod_status(pod_id))}"

    assert wait_until(fn -> match?({:error, :not_found}, Fleet.Spawner.pod_info(pod_id)) end)
  end

  test "R1-18: BRUTAL kill_pod fallback (mute pod) still releases the mandate (no reclaim loop)" do
    pod_id = "pod-brutal-#{System.unique_integer([:positive])}"
    {:ok, _} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "x"})

    {:ok, _fake} = Fleet.SpawnerTest.UnresponsivePod.start(pod_id)

    assert :ok = Fleet.Spawner.kill_pod(pod_id)

    assert wait_until(fn -> Fleet.TaskQueue.pod_status(pod_id) == {:ok, :cleared} end),
           "the brutal fallback should have released the task, status: #{inspect(Fleet.TaskQueue.pod_status(pod_id))}"
  end

  test "pod_info: a registered-but-silent pod is UNREACHABLE, never absent (timeout is not death)" do
    pod_id = "pod-slow-#{System.unique_integer([:positive])}"
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        {:ok, _} = Registry.register(Fleet.Spawner.Registry, pod_id, nil)
        send(parent, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered

    assert {:error, :unreachable} = Fleet.Spawner.pod_info(pod_id, 50)

    Process.exit(pid, :kill)
  end

  test "pod_info returns :not_found when pod doesn't exist" do
    assert {:error, :not_found} = Fleet.Spawner.pod_info("nonexistent-pod-id")
  end

  test "kill_pod terminates the pod" do
    pod_id = "pod-kill-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Fleet.Spawner.spawn_pod(valid_profile(), "issue-2",
        pod_id: pod_id,
        allow_no_brief: true,
        repo_id: @test_repo_id
      )

    assert :ok = Fleet.Spawner.kill_pod(pod_id)
    # Registry monitor cleanup is asynchronous even after terminate_child returns.
    assert :ok = wait_unregistered(pod_id)
    assert {:error, :not_found} = Fleet.Spawner.pod_info(pod_id)
  end

  test "kill_pod :not_found for unknown pod_id" do
    assert {:error, :not_found} = Fleet.Spawner.kill_pod("never-spawned")
  end

  test "spawn_pod uses UUID by default if no :pod_id opt given" do
    {:ok, pid1} =
      Fleet.Spawner.spawn_pod(valid_profile(), "issue-uuid-1",
        allow_no_brief: true,
        repo_id: @test_repo_id
      )

    {:ok, pid2} =
      Fleet.Spawner.spawn_pod(valid_profile(), "issue-uuid-2",
        allow_no_brief: true,
        repo_id: @test_repo_id
      )

    assert pid1 != pid2
  end

  test "count_pods returns the number of active pods" do
    # Assert a lower bound because other live pods may share the supervisor.
    for n <- 1..2 do
      {:ok, _pid} =
        Fleet.Spawner.spawn_pod(valid_profile(), "issue-count-#{n}",
          pod_id: "pod-count-#{n}-#{System.unique_integer([:positive])}",
          allow_no_brief: true,
          repo_id: @test_repo_id
        )
    end

    assert Fleet.Spawner.count_pods() >= 2

    # This does not cover an empty supervisor returning zero.
  end

  describe "wake_pod/1" do
    test "wake_pod :not_found for unknown pod_id" do
      assert {:error, :not_found} = Fleet.Spawner.wake_pod("never-spawned-id")
    end

    test "wake_pod :not_a_tmux_pod when the pod exists but not via TmuxBackend (StubBackend → tmux_session nil)" do
      pod_id = "pod-wake-stub-#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Fleet.Spawner.spawn_pod(valid_profile(), "issue-wake",
          pod_id: pod_id,
          allow_no_brief: true,
          repo_id: @test_repo_id
        )

      assert {:error, :not_a_tmux_pod} = Fleet.Spawner.wake_pod(pod_id)

      Fleet.Spawner.kill_pod(pod_id)
    end

    @tag :tmp_dir
    test "TurnFlag.write: UNIQUE token on every call (content-based watch.sh anti-collision)",
         %{
           tmp_dir: tmp
         } do
      assert :ok = TurnFlag.write(tmp)
      t1 = File.read!(Path.join(tmp, "turn.flag"))
      assert :ok = TurnFlag.write(tmp)
      t2 = File.read!(Path.join(tmp, "turn.flag"))
      # The watcher detects content changes, so consecutive writes must differ.
      assert t1 != t2
      # A token without a message selects the watcher's default wake text.
      refute String.trim(t2) =~ " "
    end

    @tag :tmp_dir
    test "TurnFlag.write with MESSAGE: typed info wake — '<token> <message>', one line, newlines flattened",
         %{tmp_dir: tmp} do
      assert :ok =
               TurnFlag.write(tmp, "info : brique fleet/x#12 LIVRÉE\nsur main")

      content = tmp |> Path.join("turn.flag") |> File.read!() |> String.trim()

      [_token, msg] = String.split(content, " ", parts: 2)
      assert msg == "info : brique fleet/x#12 LIVRÉE sur main"
      refute content =~ "\n"
    end

    @tag :tmp_dir
    test "TurnFlag.write: missing dir → :ok (logged warning, no crash — wake falls back to send-keys + result_deadline)",
         %{
           tmp_dir: tmp
         } do
      assert :ok = TurnFlag.write(Path.join(tmp, "nope/missing"))
    end
  end

  # Wait for asynchronous Registry cleanup with a bounded poll.
  defp wait_unregistered(pod_id, tries \\ 100) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [] ->
        :ok

      _ when tries > 0 ->
        Process.sleep(2)
        wait_unregistered(pod_id, tries - 1)

      _ ->
        :timeout
    end
  end

  describe "kill_project_pods/1 — the sweep that spares what costs a conversation" do
    test "kills the project's WORKERS, leaves the architect and the permanents standing" do
      repo = "lordzurp/sweep-#{System.unique_integer([:positive])}"
      prefix = Fleet.PodId.scope_prefix(repo)

      worker = prefix <> "issue-7-engineer"
      judge = prefix <> "pr-3-reviewer"
      # Architect and permanent IDs lack this repository prefix and are outside the sweep.
      arch = "architect-sweep-#{System.unique_integer([:positive])}"
      perm = "permanent-starfleet-#{System.unique_integer([:positive])}"

      for id <- [worker, judge, arch, perm] do
        {:ok, _} =
          Fleet.Spawner.spawn_pod(valid_profile(), "issue-sweep",
            pod_id: id,
            allow_no_brief: true,
            repo_id: @test_repo_id
          )
      end

      assert {:ok, %{killed: 2, pod_ids: killed}} = Fleet.Spawner.kill_project_pods(repo)
      assert killed == Enum.sort([worker, judge])

      assert {:error, :not_found} = Fleet.Spawner.wake_pod(worker)
      assert {:error, :not_found} = Fleet.Spawner.wake_pod(judge)
      refute match?({:error, :not_found}, Fleet.Spawner.wake_pod(arch))
      refute match?({:error, :not_found}, Fleet.Spawner.wake_pod(perm))

      Fleet.Spawner.kill_pod(arch)
      Fleet.Spawner.kill_pod(perm)
    end

    test "a project with nothing in flight sweeps to zero, not to an error" do
      assert {:ok, %{killed: 0, pod_ids: []}} =
               Fleet.Spawner.kill_project_pods("lordzurp/never-dispatched")
    end

    test "another project's pods are untouched — the prefix is the whole scope" do
      mine = "lordzurp/mine-#{System.unique_integer([:positive])}"
      theirs = "lordzurp/theirs-#{System.unique_integer([:positive])}"
      mine_pod = Fleet.PodId.for_issue(mine, 1, "engineer")
      theirs_pod = Fleet.PodId.for_issue(theirs, 1, "engineer")

      for id <- [mine_pod, theirs_pod] do
        {:ok, _} =
          Fleet.Spawner.spawn_pod(valid_profile(), "issue-sweep",
            pod_id: id,
            allow_no_brief: true,
            repo_id: @test_repo_id
          )
      end

      assert {:ok, %{killed: 1, pod_ids: [^mine_pod]}} = Fleet.Spawner.kill_project_pods(mine)
      refute match?({:error, :not_found}, Fleet.Spawner.wake_pod(theirs_pod))

      Fleet.Spawner.kill_pod(theirs_pod)
    end
  end

  describe "project_guard — a fleet-level pod carries a label and no project" do
    test "a NAMED pod without a project is refused… unless its label is the role alone" do
      assert {:error, :project_required} =
               Fleet.Spawner.spawn_pod(valid_profile(), "issue-x",
                 pod_id: "pg-#{System.unique_integer([:positive])}",
                 allow_no_brief: true,
                 repo_id: @test_repo_id,
                 rc_name: "tetris_engineer"
               )
    end

    test "the permanent boot's own shape passes — it is what boots the fleet" do
      pod =
        Fleet.Spawner.PermanentBoot.pod_id_for("starfleet-#{System.unique_integer([:positive])}")

      assert {:ok, _} =
               Fleet.Spawner.spawn_pod(valid_profile(), "issue-x",
                 pod_id: pod,
                 allow_no_brief: true,
                 repo_id: @test_repo_id,
                 rc_name: Fleet.Layout.pod_label(nil, "starfleet", nil)
               )

      Fleet.Spawner.kill_pod(pod)
    end
  end

  describe "pod_info — the project a pod belongs to is PUBLISHED, not inferred" do
    test "a dispatched pod exposes its project_slug; `repo` stays nil and that is not a bug" do
      pod_id = "pv-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Fleet.Spawner.spawn_pod(valid_profile(), "issue-1",
          pod_id: pod_id,
          allow_no_brief: true,
          repo_id: @test_repo_id,
          project_slug: "banc-egress",
          rc_name: Fleet.Layout.pod_label("banc-egress", "engineer", 42)
        )

      assert {:ok, info} = Fleet.Spawner.pod_info(pod_id)
      assert info.project_slug == "banc-egress"
      assert info.repo == nil

      Fleet.Spawner.kill_pod(pod_id)
    end

    test "a pod with no project says so with nil — an answer, not a gap" do
      pod_id = "pv-none-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Fleet.Spawner.spawn_pod(valid_profile(), "issue-1",
          pod_id: pod_id,
          allow_no_brief: true,
          repo_id: @test_repo_id
        )

      assert {:ok, info} = Fleet.Spawner.pod_info(pod_id)
      assert info.project_slug == nil

      Fleet.Spawner.kill_pod(pod_id)
    end
  end

  describe "6-084 — l'absence du destinataire est dite, et rendue" do
    test "pod hors du Registry -> {:error, _} ET un warning qui nomme la perte" do
      absent = "pod-jamais-demarre-#{System.unique_integer([:positive])}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, _reason} = Fleet.Spawner.notify_pod(absent, "verdict terminal")
        end)

      assert log =~ absent
      assert log =~ "NOT delivered"

      # The warning must identify the lost delivery and the absence of replay.
      assert log =~ "LOST"
    end

    test "TEMOIN — un pod VIVANT recoit toujours, et sans warning" do
      pod_id = "pv-notify-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Fleet.Spawner.spawn_pod(valid_profile(), "issue-1",
          pod_id: pod_id,
          allow_no_brief: true,
          repo_id: @test_repo_id
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          refute match?({:error, _}, Fleet.Spawner.notify_pod(pod_id, "info : rien de grave"))
        end)

      refute log =~ "NOT delivered"

      Fleet.Spawner.kill_pod(pod_id)
    end
  end
end
