defmodule Fleet.SpawnerTest.UnresponsivePod do
  @moduledoc false
  # Fake pod: registers in Fleet.Spawner.Registry under `pod_id` then CRASHES on `:kill` → the
  # `GenServer.call(:kill)` in kill_pod exits → triggers the BRUTAL fallback (R1-18).
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

  # G24-9 (F-CONT-RISK) — minimum disallowedTools required by validate/1 wired at spawn
  # (Z2; cf. cap_profile.ex @disallowed_minimum_strict/_prefix).
  @min_disallowed ~w(web_search web_fetch code_execution bash_code_execution text_editor_code_execution tool_search_web)

  # Test repo_id for PROJECT-BOUND roles (engineer = `valid_profile/0` and `forever_profile/0`).
  # Their hexspeak session_id REQUIRES a resolved repo: without it the mint REFUSES (raise) rather than
  # fabricating a random UUID — a missing repo signals an unresolved forge (forge down). In prod the
  # dispatcher sets this repo; these tests spawn directly, so we pass it via `opts`. Deliberately omitted
  # in the cases that MUST fail before the mint (brief refusal, non path-safe pod_id).
  @test_repo_id 7

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:fleet_spawner, :state_fs_root, Path.join(tmp_dir, "state"))
    Application.put_env(:fleet_spawner, :pod_dir_root, Path.join(tmp_dir, "pods"))
    Application.put_env(:fleet_spawner, :launch_backend, StubBackend)
    # adr-f: no vault anymore (creds via claudeDir bwrap bind).

    sp_root = Path.join(tmp_dir, "cap-profiles")
    File.mkdir_p!(sp_root)
    File.write!(Path.join(sp_root, "engineer-role.md"), "# SP")
    Application.put_env(:fleet_sp_builder, :sp_role_root, sp_root)

    # auth = single bind mode (token_arg removed); the credentials gate still reads the native
    # creds (scope/plan). Default creds fixture (these tests do not test the credentials door) —
    # cf. pod_test.exs. Without it: {:credentials_invalid, _} → pod dies at boot.
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

    Application.put_env(:fleet_spawner, :claude_dir, setup_claude)

    StubBackend.set_reply({:ok, %{}})

    on_exit(fn ->
      StubBackend.clear()
      Application.delete_env(:fleet_spawner, :state_fs_root)
      Application.delete_env(:fleet_spawner, :pod_dir_root)
      # B5 #576: do NOT delete :launch_backend — leave the hermetic
      # config/test.exs baseline (StubBackend) in place, otherwise the
      # REAL code-default LauncherPortBackend is reached under async race.
      Application.delete_env(:fleet_sp_builder, :sp_role_root)
      Application.delete_env(:fleet_spawner, :claude_dir)
    end)

    :ok
  end

  defp valid_profile do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      # role_index/protected/fleet_level: the role catalogue lives in the metadata (source of the WHAT),
      # read by deterministic_session_id. engineer = slot 3, worker (1badcafe), project-bound (repo required).
      metadata: %{
        "name" => "engineer",
        "containment" => "bwrap",
        "role_index" => 3,
        "protected" => false,
        "fleet_level" => false
      },
      spec: %{
        "systemPrompt" => "engineer-role.md",
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
    # g24_15/g24_16: context-long ⟹ the keying is DECLARED (the derivation is a choice here), and
    # a project-keyed pod declares whether it deserves a durable Desktop handle.
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
      # "p1" (short) is ACCEPTED: admission does NOT impose a minimum length — the len≥4 is
      # pkill's LOCAL over-armour (PodTmux.pkill_pattern), not an admission rule.
      for ok <- ["pod-1", "permanent-architect", "repo.issue_1-role", UUID.uuid4(), "p1"] do
        assert Fleet.Spawner.valid_pod_id?(ok), "pod_id #{inspect(ok)} should be accepted"
      end

      # NON-alnum head (`.`/`_`/`-`) and absurd length rejected: any admitted id must be safe for
      # ALL consumers (alnum head = anti-degenerate-pkill-pattern; bound = anti-DoS, precise
      # sun_path at the socket boundary).
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
      # EXPLICIT one-shot = the only form that requires a brief.
      assert Fleet.Spawner.brief_required?(valid_profile())

      # forever/run/pipe/permanent: long-lived, pull via MCP → exempt.
      for scope <- ["forever", "run", "pipe", "permanent"] do
        cap = put_in(valid_profile().spec["invocation"], %{"lifetime_scope" => scope})

        refute Fleet.Spawner.brief_required?(cap),
               "scope #{scope} should NOT require a brief"
      end

      # lifetime_scope absent: brief_required? reads the EXPLICIT "one-shot" → false. This is a
      # dead-safe default: spawn_pod REFUSES a profile without scope upstream (DR-019, dedicated test
      # below), so this predicate is never consulted on a real no-scope in the spawn path.
      no_scope = put_in(valid_profile().spec["invocation"], %{})
      refute Fleet.Spawner.brief_required?(no_scope)
    end

    test "order_present?/1 — shared authority: the order has TWO shapes, text and address" do
      # The predicate both halves consult. The dispatch drops the inline copy when it posts an
      # address and asks this about WHAT REMAINS; the spawn guard asks it about what arrived. Two
      # hand-written shapes disagreed once and looped every one-shot dispatch forever — the point
      # of this function is that there is now only one shape to get wrong.
      assert Fleet.Spawner.order_present?(brief: "fix bug X")
      assert Fleet.Spawner.order_present?(brief_ref: "briefs/x.md", brief_sha: "abc")

      # An address with no text is the NOMINAL rail, not a degradation.
      assert Fleet.Spawner.order_present?(brief_ref: "briefs/x.md")

      refute Fleet.Spawner.order_present?([])
      refute Fleet.Spawner.order_present?(brief: "")
      refute Fleet.Spawner.order_present?(brief: nil)
      # A sha names nothing without a path to resolve it against.
      refute Fleet.Spawner.order_present?(brief_sha: "abc")
    end

    test "DR-019: cap-profile WITHOUT lifetime_scope → spawn REFUSED (invalid state, never spawned)" do
      # `lifetime_scope` is schema-REQUIRED: a %CapProfile{} without it was never validated by the
      # schema. Letting it spawn gives downstream reads that DIVERGE (brief-exempt at the guard, but
      # "one-shot" at extraction → release). The spawn_pod choke point refuses it fail-loud — even with
      # a brief, even with allow_no_brief (the profile's invalidity precedes the brief question).
      no_scope = put_in(valid_profile().spec["invocation"], %{})

      assert {:error, :cap_profile_no_lifetime_scope} =
               Fleet.Spawner.spawn_pod(no_scope, "issue-no-scope", brief: "do x")

      assert {:error, :cap_profile_no_lifetime_scope} =
               Fleet.Spawner.spawn_pod(no_scope, "issue-no-scope", allow_no_brief: true)
    end

    test "cap-profile WITHOUT interlocutor → spawn REFUSED (the protocol contract is never inferred)" do
      # Same structural guard as DR-019, on the field that decides WHICH protocol the pod is
      # provisioned with. Defaulting it would restore the exact silence it exists to end: the pod
      # boots, looks healthy, and holds a machine contract nobody chose for it. The refusal must
      # precede the brief question, like the scope one.
      no_who = Map.delete(valid_profile().spec, "interlocutor")
      cap = %{valid_profile() | spec: no_who}

      assert {:error, :cap_profile_no_interlocutor} =
               Fleet.Spawner.spawn_pod(cap, "issue-no-who", brief: "do x")

      assert {:error, :cap_profile_no_interlocutor} =
               Fleet.Spawner.spawn_pod(cap, "issue-no-who", allow_no_brief: true)

      # An EMPTY string is not a declaration either — the accessor requires a non-empty binary,
      # or `interlocutor: ""` would pass the gate and then match no branch downstream.
      blank = %{valid_profile() | spec: Map.put(valid_profile().spec, "interlocutor", "")}

      assert {:error, :cap_profile_no_interlocutor} =
               Fleet.Spawner.spawn_pod(blank, "issue-blank-who", brief: "do x")
    end

    test "NAMED pod without :project_slug → spawn REFUSED (the label carries no structure)" do
      # Third structural guard at the same choke point. A pod that carries an `rc_name` is a pod
      # placed IN a project: its cwd, its intra-pod home and its checkpoint seed all derive from the
      # slug. The slug used to be re-parsed out of the label, which froze the label's format; now it
      # travels explicitly, so a caller that names a pod and omits it would get a booting pod
      # working on the wrong tree — silently. Refused instead.
      assert {:error, :project_required} =
               Fleet.Spawner.spawn_pod(valid_profile(), "issue-named",
                 brief: "do x",
                 rc_name: "p_engineer"
               )

      # A slug that is not a slug is the same refusal, not a downgrade to `nil`: the value reaches a
      # `Path.join`, so the traversing forms die at the door.
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
      # The guard binds the PAIR, it does not make the slug universally mandatory: a permanent or
      # admin pod has no Desktop label and no cwd remap. It must fail LATER (on the brief), which
      # proves the project guard let it through rather than passing for the wrong reason.
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
      # pod_id flows into pod_dir/sock_path/state recovery (Path.join + interpolation) → a non
      # path-safe pod_id would traverse outside ~/pods. CLEAR refusal BEFORE any spawn. Legitimate ids
      # UUID / `permanent-<name>-ts` / `issue-<n>-<role>-ts` (charset [A-Za-z0-9._-]) pass — covered
      # by the tests spawning with UUID ids (hyphenated = same charset).
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
      # THE RAIL THIS GUARD REFUSED IN PRODUCTION. Once a brief is materialized into work/ops, the
      # dispatch drops the inline copy BECAUSE an address replaces it, and hands the pod a
      # `:brief_ref` — the shape the arbitration made canonical. A guard reading only `:brief` saw
      # nothing and refused, the reconciliation re-dispatched, and it looped every 30s forever.
      # Every one-shot role was affected (scoper, qualifier, reviewer, gatekeeper, chief); the
      # degraded rail, having no address to name, kept working and kept every test green.
      assert {:ok, _pid} =
               Fleet.Spawner.spawn_pod(valid_profile(), "issue-brief-ptr",
                 brief_ref: "briefs/x.md",
                 brief_sha: "62e36295c11f459baed13ebd724583508dc36388",
                 pod_id: "pod-r18-ptr-#{System.unique_integer([:positive])}",
                 repo_id: @test_repo_id
               )
    end

    test "a pointer with NO ref is not an order — the sha alone names nothing" do
      # The pair keys on the ref, exactly like the dispatch site that drops the copy. A sha without
      # a path is not resolvable, so it must NOT open the guard: an order the pod cannot read is
      # the expensive failure this whole guard exists to prevent.
      assert {:error, :brief_required} =
               Fleet.Spawner.spawn_pod(valid_profile(), "issue-sha-only",
                 brief_sha: "62e36295c11f459baed13ebd724583508dc36388"
               )
    end

    test "CONCURRENT spawns of the same (role, repo) never share a pool index" do
      # The allocation runs inside `Pod.start_link/1` — that is, inside the window
      # `DynamicSupervisor.start_child/2` holds open, so it is serialized by the supervisor without
      # a lock and without an extra process. Run in the CALLER's process (where it first lived),
      # two of these would read the same lowest free index and hand it out twice: two live pods
      # sharing a session_id, silently, which is the exact lie the nibble exists to end.
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

      # Six live pods left in a SHARED registry are not this test's business alone: every later
      # test that enumerates pods (`list_pods/0` → a `GenServer.call` per pod) pays for them.
      # Measured: without this, `PodToolsTest`'s supersede path times out at 60 s — green in
      # isolation, red at the gate. Brutal kill on purpose — the graceful `kill_pod/1` is itself a
      # call, so it would queue behind the very thing being cleaned up.
      on_exit(fn -> Enum.each(pids, &Process.exit(&1, :kill)) end)

      pools =
        for {id, pid} <- Enum.zip(ids, pids) do
          # Matched on the PID: a pod that died would fail here by name rather than vanish from a
          # comprehension and turn the uniqueness assertion into a tautology on a shorter list.
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

    # Mi14: synchronous registration (name: {:via, Registry, ...}) → pod registered as of {:ok, pid}.
    assert {:ok, %{pod_id: ^pod_id}} = Fleet.Spawner.pod_info(pod_id)
  end

  # STATE-004 (DN-recovery B coupling): under `:temporary`, a pod dying without
  # completion is not restarted → its active task must be released (clear_for_pod)
  # otherwise it stays orphaned. Failing backend → transition_failed → clear.
  test "a failing pod releases its active task (STATE-004)" do
    pod_id = "pod-orphan-#{System.unique_integer([:positive])}"
    {:ok, _} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "x"})

    # active task present before the failure
    assert {:ok, status} = Fleet.TaskQueue.pod_status(pod_id)
    refute is_nil(status)

    # failing backend → the pod dies via transition_failed → clear_pod_task
    StubBackend.set_reply({:error, :stub_launch_fail})

    {:ok, _pid} =
      Fleet.Spawner.spawn_pod(valid_profile(), "issue-orphan",
        pod_id: pod_id,
        allow_no_brief: true,
        repo_id: @test_repo_id
      )

    # the active task goes `:cleared` (≠ `:pending`/`:assigned`) — ASYNC clear at pod death
    # (clear_pod_task; a failed clear is logged warning on the Pod side) → bounded poll
    assert wait_until(fn -> Fleet.TaskQueue.pod_status(pod_id) == {:ok, :cleared} end),
           "the dead pod's task should be :cleared, current status: #{inspect(Fleet.TaskQueue.pod_status(pod_id))}"
  end

  # LIFE-003 (DN-recovery B §5): kill_pod = DELIBERATE release (handle_call(:kill) →
  # teardown + clear_for_pod + :killed state), not a brutal terminate_child. Discriminant:
  # the active task is released (`:cleared`) — a brutal kill would not clear.
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

    # clean release: the task is released (vs a brutal kill which does not clear)
    assert wait_until(fn -> Fleet.TaskQueue.pod_status(pod_id) == {:ok, :cleared} end),
           "kill_pod should release the task (clean release), status: #{inspect(Fleet.TaskQueue.pod_status(pod_id))}"

    assert wait_until(fn -> match?({:error, :not_found}, Fleet.Spawner.pod_info(pod_id)) end)
  end

  test "R1-18: BRUTAL kill_pod fallback (mute pod) still releases the mandate (no reclaim loop)" do
    pod_id = "pod-brutal-#{System.unique_integer([:positive])}"
    {:ok, _} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "x"})

    # fake pod REGISTERED but CRASHING on :kill → GenServer.call(:kill) exits → brutal fallback
    {:ok, _fake} = Fleet.SpawnerTest.UnresponsivePod.start(pod_id)

    assert :ok = Fleet.Spawner.kill_pod(pod_id)

    # the mandate MUST be released (otherwise the poller re-dispatches it → loop), even without a graceful release
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

    # The old catch-all read this TIMEOUT as {:error, :not_found}: a live-but-slow pod
    # classed absent — the exact false death proof the compensations killed on.
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
    # Mi14: terminate_child is sync on death, BUT the Registry cleanup (via monitor) is
    # async → deterministic bounded poll (≤200ms) instead of a flaky fixed sleep.
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
    assert is_integer(Fleet.Spawner.count_pods())

    pod_id = "pod-count-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Fleet.Spawner.spawn_pod(valid_profile(), "issue-count",
        pod_id: pod_id,
        allow_no_brief: true,
        repo_id: @test_repo_id
      )

    # Mi14: count_children reflects the active child as of start_child's {:ok}. The pod I
    # just spawned is active → count ≥ 1. NO assertion on an `initial+1` DELTA: the pod
    # registry is GLOBAL (singleton DynamicSupervisor) shared across async tests → a
    # concurrent spawn/terminate skews the delta (observed flaky). `≥ 1` is deterministic.
    assert Fleet.Spawner.count_pods() >= 1
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

      # StubBackend does not set tmux_session in launched → pod_info returns
      # tmux_session: nil → wake_pod refuses cleanly (no send-keys).
      assert {:error, :not_a_tmux_pod} = Fleet.Spawner.wake_pod(pod_id)

      Fleet.Spawner.kill_pod(pod_id)
    end

    @tag :tmp_dir
    test "TurnFlag.write: UNIQUE token on every call (content-based watch.sh anti-collision)",
         %{
           tmp_dir: tmp
         } do
      assert :ok = Fleet.Spawner.Pod.TurnFlag.write(tmp)
      t1 = File.read!(Path.join(tmp, "turn.flag"))
      assert :ok = Fleet.Spawner.Pod.TurnFlag.write(tmp)
      t2 = File.read!(Path.join(tmp, "turn.flag"))
      # watch.sh fires on `cur != last` → every write MUST change the content.
      assert t1 != t2
      # bare token (mandate wake): NO space → watch.sh emits the fixed "ton tour".
      refute String.trim(t2) =~ " "
    end

    @tag :tmp_dir
    test "TurnFlag.write with MESSAGE: typed info wake — '<token> <message>', one line, newlines flattened",
         %{tmp_dir: tmp} do
      assert :ok =
               Fleet.Spawner.Pod.TurnFlag.write(tmp, "info : brique fleet/x#12 LIVRÉE\nsur main")

      content = tmp |> Path.join("turn.flag") |> File.read!() |> String.trim()

      [_token, msg] = String.split(content, " ", parts: 2)
      assert msg == "info : brique fleet/x#12 LIVRÉE sur main"
      # single line contract (watch.sh cats the whole file)
      refute content =~ "\n"
    end

    @tag :tmp_dir
    test "TurnFlag.write: missing dir → :ok (logged warning, no crash — wake falls back to send-keys + result_deadline)",
         %{
           tmp_dir: tmp
         } do
      assert :ok = Fleet.Spawner.Pod.TurnFlag.write(Path.join(tmp, "nope/missing"))
    end
  end

  # Deterministic bounded poll (Mi14): waits for the async Registry cleanup post-terminate_child
  # (≤200ms). Replaces a fixed sleep: succeeds as soon as cleaned, fails after the bound.
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
end
