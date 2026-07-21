defmodule Fleet.Spawner.PodTest do
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.Spawner.LaunchBackend.StubBackend

  # G24-9 (F-CONT-RISK) — minimum disallowedTools required by Fleet.CapProfile.validate/1
  # (wired at spawn, Z2; cf. cap_profile.ex @disallowed_minimum_strict/_prefix). Every
  # spawned profile MUST carry them, otherwise the gate rejects it (:cap_profile_invalid).
  @min_disallowed ~w(web_search web_fetch code_execution bash_code_execution text_editor_code_execution tool_search_web)

  # test repo_id for PROJECT-BOUND roles (engineer = `valid_profile/0` default, and any derivative).
  # Their hexspeak session_id REQUIRES a resolved repo: without it, the mint REFUSES (raise) instead of
  # fabricating a random UUID — a missing repo signals a forge that did not resolve the id (forge down).
  # In prod the repo comes from the dispatcher; these tests spawn the pod directly, so we put this
  # neutral repo in `opts` to exercise the lifecycle. Arbitrary value (≠ the hexspeak ids hardcoded
  # elsewhere in this file).
  @test_repo_id 7

  @moduletag :tmp_dir

  # MA-04 — bus stub: `broadcast/2` RAISES (simulates UnregisteredError / PubSub down). The Pod's
  # `required_broadcast` must rescue → `{:error, {:broadcast_failed, _}}` → `do_extract` does NOT
  # release/kill the pod on an orphaned completion.
  defmodule RaiseBus do
    def broadcast(_topic, _ev),
      do: raise(Fleet.Event.UnregisteredError, "forced pod.completed fail")
  end

  # Fails the FIRST broadcast then delegates to the real Bus (state shared via an Agent in app-env).
  defmodule FlakyBus do
    def broadcast(topic, ev) do
      agent = Application.fetch_env!(:fleet_spawner, :flaky_agent)
      n = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
      if n == 0, do: {:error, :transient}, else: Fleet.EventRouter.Bus.broadcast(topic, ev)
    end
  end

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:fleet_spawner, :state_fs_root, Path.join(tmp_dir, "state"))
    Application.put_env(:fleet_spawner, :pod_dir_root, Path.join(tmp_dir, "pods"))
    Application.put_env(:fleet_spawner, :launch_backend, StubBackend)
    # adr-f: no vault. Creds come from the claudeDir bound by bwrap
    # (CLAUDE_DIR, config default); no vault setup in test.

    sp_root = Path.join(tmp_dir, "cap-profiles")
    File.mkdir_p!(sp_root)
    File.write!(Path.join(sp_root, "engineer-role.md"), "# Engineer SP base")
    Application.put_env(:fleet_sp_builder, :sp_role_root, sp_root)

    # mundo invocado #1: auth = single bind mode (token_arg removed). The credentials gate
    # (scope/plan) always reads the native creds → default creds fixture for the tests that do not
    # test the credentials gate; the credentials/fail-loud tests override :claude_dir per-test.
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

    on_exit(fn ->
      StubBackend.clear()
      Application.delete_env(:fleet_spawner, :state_fs_root)
      Application.delete_env(:fleet_spawner, :pod_dir_root)
      Application.delete_env(:fleet_sp_builder, :sp_role_root)
      Application.delete_env(:fleet_spawner, :claude_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "kick_keyword/3 (#5.2 — kick keyword based on the ACK + the two gates)" do
    test "not yet polled → 'yop' (bootstrap-arm, never gated by the GLOBAL knob)" do
      assert Fleet.Spawner.Pod.Kick.kick_keyword(false, true, true) == "yop"
      assert Fleet.Spawner.Pod.Kick.kick_keyword(false, false, true) == "yop"
    end

    test "already polled + knob on → 'wake' (fallback)" do
      assert Fleet.Spawner.Pod.Kick.kick_keyword(true, true, true) == "wake"
    end

    test "already polled + knob off → nil (flag-only, no send-keys)" do
      assert Fleet.Spawner.Pod.Kick.kick_keyword(true, false, true) == nil
    end

    test "profile gate off → nil for EVERYTHING, yop included (human-terminal class)" do
      # Live 2026-07-19: a resumed starfleet (front-desk, Desktop bridge) took the bootstrap yop
      # drizzle to the cap — the cap-profile gate must mute the yop too, not just the wake.
      assert Fleet.Spawner.Pod.Kick.kick_keyword(false, true, false) == nil
      assert Fleet.Spawner.Pod.Kick.kick_keyword(false, false, false) == nil
      assert Fleet.Spawner.Pod.Kick.kick_keyword(true, true, false) == nil
    end
  end

  describe "acked?/3 (#5.2 F3 — the loop control = the ACK, not a proxy)" do
    test "wake: brief pull = ACK (regardless of polled)" do
      assert Fleet.Spawner.Pod.Kick.acked?(true, false, false)
      assert Fleet.Spawner.Pod.Kick.acked?(true, false, true)
    end

    test "bootstrap: poll = ACK (no brief to pull, last_poll is enough)" do
      assert Fleet.Spawner.Pod.Kick.acked?(false, true, true)
    end

    test "bootstrap not yet polled → NO ACK (we keep kicking 'yop')" do
      refute Fleet.Spawner.Pod.Kick.acked?(false, true, false)
    end

    test "worker not yet pulled → NO ACK even if polled (polled counts ONLY for bootstrap)" do
      refute Fleet.Spawner.Pod.Kick.acked?(false, false, true)
    end
  end

  defp valid_profile do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      # role_index/protected/fleet_level: the role catalog lives in the metadata (source of the WHAT),
      # read by deterministic_session_id. engineer = slot 3, worker (1badcafe), project-bound (repo required).
      metadata: %{
        "name" => "engineer",
        "containment" => "bwrap",
        "role_index" => 3,
        "protected" => false,
        "fleet_level" => false
      },
      spec: %{
        "lifetime_scope" => "one-shot",
        "systemPrompt" => "engineer-role.md",
        "scope" => %{"disallowedTools" => @min_disallowed, "git_ops_denied" => []},
        "knowledge" => %{"skills" => []},
        "invocation" => %{"lifetime_scope" => "one-shot"},
        "modop_set" => []
      }
    }
  end

  # Minimal profile carrying ONLY a lifetime_scope — for the FS-bucket mapping (scope_for via
  # state_fs_path_for/3). Not spawned; exercises the path resolution alone.
  defp profile_with_scope(scope) do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "x", "containment" => "bwrap"},
      spec: %{"invocation" => %{"lifetime_scope" => scope}}
    }
  end

  defp spawn_via_supervisor(args) do
    StubBackend.set_parent(self())
    Fleet.Spawner.Pod.start_link(args)
  end

  defp build_args(pod_id, issue_id) do
    # engineer = project-bound → repo_id mandatory to mint its deterministic session_id.
    %{
      cap_profile: valid_profile(),
      issue_id: issue_id,
      pod_id: pod_id,
      opts: [repo_id: @test_repo_id]
    }
  end

  # Source repo for the project tests: `main` (src.txt) + orphan branch `work/ops` (BACKLOG.md).
  defp source_repo_with_doc(dir) do
    File.mkdir_p!(dir)
    g = fn args -> System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true) end
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", dir], stderr_to_stdout: true)
    {_, 0} = g.(["config", "user.email", "t@lcars.local"])
    {_, 0} = g.(["config", "user.name", "test"])
    File.write!(Path.join(dir, "src.txt"), "code")
    {_, 0} = g.(["add", "."])
    {_, 0} = g.(["commit", "-q", "-m", "code"])
    {_, 0} = g.(["checkout", "-q", "--orphan", "work/ops"])
    {_, _} = g.(["rm", "-rfq", "."])
    File.write!(Path.join(dir, "BACKLOG.md"), "doc")
    {_, 0} = g.(["add", "."])
    {_, 0} = g.(["commit", "-q", "-m", "doc"])
    {_, 0} = g.(["checkout", "-q", "main"])
    dir
  end

  # Interactive model: the backend opens the Port and returns immediately (no NDJSON frame).
  # Real shape of `LauncherPortBackend.launch/2` = %{port:, tmux_session:} — NO session_id
  # (NDJSON vestige: the session_id is PRE-ALLOCATED pod-side, never returned by the backend).
  # tmux_session nil = non-kickable pod, the StubBackend behavior these tests expect.
  defp interactive_reply(opts \\ []) do
    {:ok,
     %{
       port: Keyword.get(opts, :port),
       tmux_session: nil
     }}
  end

  # R-CORE.comm ADR-G — event-driven completion: simulates the fleet_task_queue broker broadcasting
  # %Fleet.Event{work_item.completed} on fleet.events (= what happens when the agent calls
  # submit_result via fleet_mcp). The pod must be in :monitoring (subscribed) before the call.
  defp submit_result_event(pod_id, payload) do
    Phoenix.PubSub.broadcast(
      Fleet.PubSub,
      "fleet.events",
      Fleet.Event.new(:task_queue, :"work_item.completed",
        pod_id: pod_id,
        correlation_id: "test-corr-#{pod_id}",
        payload: %{result: payload}
      )
    )
  end

  defp state_fs_path(pod_id, scope_dir \\ "pods") do
    root = Application.get_env(:fleet_spawner, :state_fs_root)
    Path.join([root, scope_dir, pod_id, "state.json"])
  end

  defp os_alive?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true))
  end

  setup do
    case Registry.start_link(keys: :unique, name: Fleet.Spawner.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "interactive happy path (result event → stop)" do
    test "pod.result_submitted received → extract → release → :normal stop" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-happy-#{System.unique_integer([:positive])}"

      assert {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))

      assert_receive {:launch_called, _args, env}, 2_000
      # adr-f: no injected OAuth env; the pod receives CLAUDE_DIR (the human's
      # claudeDir) that bwrap_launch.sh binds as ~/.claude.
      assert env["CLAUDE_DIR"] =~ ".claude"

      # Barrier: pod in :monitoring ⇒ do_monitor ran ⇒ subscribed to the Bus.
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      # The central (fleet_mcp) broadcasts the pod's result → extract → release → {:stop, :normal}.
      submit_result_event(pod_id, %{"answer" => "OK"})

      assert_receive {:EXIT, ^pid, :normal}, 3_000

      # state.json written at RELEASE with phase :succeeded.
      content = File.read!(state_fs_path(pod_id)) |> Jason.decode!()
      assert content["phase"] == "succeeded"
    end

    test "R1-20: state.json PRESENT but CORRUPT → LOUD recover (error), no silent fresh init" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-corrupt-#{System.unique_integer([:positive])}"

      # broken recovery point: file present, unreadable JSON (≠ absent = normal fresh pod)
      path = state_fs_path(pod_id)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{ this is not json")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))
          assert_receive {:launch_called, _args, _env}, 2_000
        end)

      assert log =~ "CORRUPT",
             "a corrupt state.json must be LOUD (error, like the TaskQueue's state.corrupt), not silent"
    end

    test "R1-20: state.json ABSENT → SILENT fresh init (no false corrupt warning)" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-fresh-#{System.unique_integer([:positive])}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))
          assert_receive {:launch_called, _args, _env}, 2_000
        end)

      refute log =~ "CORRUPT"
      refute log =~ "recover: state.json"
    end

    # MA-04 — THE finding: `pod.completed` is load-bearing LIFECYCLE (the StepRunConsumer depends on it
    # to finish the step_run). If its diffusion FAILS, the pod must NOT release/kill on an orphaned
    # completion (otherwise the pod "succeeds" but the step_run never finishes → forge lock forever).
    # Raising Bus stub → the pod STAYS alive in :monitoring (result retained, deadline re-armed), NO
    # :normal EXIT.
    test "MA-04: failing pod.completed broadcast → pod NOT released/killed (stays alive), fail-loud" do
      Process.flag(:trap_exit, true)
      Application.put_env(:fleet_spawner, :event_bus, RaiseBus)
      on_exit(fn -> Application.delete_env(:fleet_spawner, :event_bus) end)

      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-ma04-#{System.unique_integer([:positive])}"

      assert {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))
      assert_receive {:launch_called, _args, _env}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      # The central broadcasts the result → extract → pod.completed (which FAILS via RaiseBus).
      submit_result_event(pod_id, %{"answer" => "OK"})

      # THE finding: NO :normal EXIT (the one-shot does NOT release on an undiffused completion).
      refute_receive {:EXIT, ^pid, :normal}, 800

      # The pod STAYS alive in :monitoring (fail-loud: the :extract_retry timer re-fires the extract).
      assert Process.alive?(pid)
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      GenServer.stop(pid)
    end

    test "MA-04b: pod.completed fails on the 1st shot then SUCCEEDS on the bounded retry → pod.completed finally emitted" do
      Process.flag(:trap_exit, true)
      Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      Application.put_env(:fleet_spawner, :flaky_agent, agent)
      Application.put_env(:fleet_spawner, :event_bus, FlakyBus)

      on_exit(fn ->
        Application.delete_env(:fleet_spawner, :event_bus)
        Application.delete_env(:fleet_spawner, :flaky_agent)
      end)

      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-ma04b-#{System.unique_integer([:positive])}"

      assert {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      # The incoming work_item.completed goes through direct Phoenix.PubSub (not event_bus) → FlakyBus
      # intercepts ONLY pod.completed. 1st pod.completed fails (:transient) → pod stays :monitoring;
      # the :extract_retry timer (1s) re-enters :extracting and RE-EMITS → 2nd shot succeeds.
      submit_result_event(pod_id, %{"answer" => "OK"})

      # The retry RE-EMITS pod.completed successfully → the one-shot resumes its normal completion
      # (release → stop :normal). Proof the rail is unblocked: the re-emitted event THEN the clean
      # stop (a wedged pod would stay in :monitoring forever, no :normal EXIT).
      assert_receive %Fleet.Event{source: :spawner, type: :"pod.completed"}, 5_000
      assert_receive {:EXIT, ^pid, :normal}, 2_000
    end

    test "SLOT-FREEZE: the pod ADOPTS the TASK's issue_id -> the deliverable follows the RIGHT brick (not the spawn's)" do
      # hello-buddy regression: the pipe kept its SPAWN issue_id (issue-4) for ALL its deliverables ->
      # the 2nd brick (issue-3) landed on issue-4's branch/PR (overwrite). Here the pod spawns on
      # "issue-4" but the completed task carries "issue-3" -> the pod.completed (consumed by the
      # StepRunConsumer which pushes HEAD:lcars/issue-N) must carry "issue-3", the brick actually handled.
      Process.flag(:trap_exit, true)
      Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")
      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-adopt-#{System.unique_integer([:positive])}"

      assert {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-4"))
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      # work_item.completed for brick issue-3 (re-brief), NOT the issue-4 spawn (issue_id in the payload,
      # like the real TaskQueue event which carries completed.issue_id).
      Phoenix.PubSub.broadcast(
        Fleet.PubSub,
        "fleet.events",
        Fleet.Event.new(:task_queue, :"work_item.completed",
          pod_id: pod_id,
          correlation_id: "c-adopt",
          payload: %{result: %{"answer" => "OK"}, issue_id: "issue-3"}
        )
      )

      # The pod.completed (= the deliverable broadcast to the StepRunConsumer) carries the ADOPTED issue-3.
      assert_receive %Fleet.Event{
                       type: :"pod.completed",
                       payload: %{"issue_id" => "issue-3"}
                     },
                     3_000
    end

    test "POD_DIR + artifacts created (pod in MONITORING as long as no deliverable)" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-dir-#{System.unique_integer([:positive])}"
      # NO deliverable → the pod stays in :monitoring (poll), GenServer alive.
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))
      assert_receive {:launch_called, _args, _env}, 2_000

      info = GenServer.call(pid, :info)
      assert info.phase == :monitoring
      assert File.dir?(info.pod_dir)
      assert File.exists?(Path.join(info.pod_dir, ".cap-profile.json"))

      # P1/C9 — pod-owned `.claude/`: target of the creds-only bind (bwrap binds ONLY
      # .credentials.json inside it, not the whole human dir). Must exist, created by do_project.
      assert File.dir?(Path.join(info.pod_dir, ".claude")),
             "pod_dir/.claude must exist (pod-owned target of the .credentials.json bind)"

      # No human settings.json may leak (userSettings = .claude/settings.json absent
      # → 0 hooks loaded; getAllHooks ignores --setting-sources, cf JOURNAL-P1-hooks).
      refute File.exists?(Path.join(info.pod_dir, ".claude/settings.json")),
             ".claude/settings.json must NOT exist (otherwise hooks would load)"

      # Provisioning of the rest OUTSIDE .claude/: .lcars/ + pod root for CLAUDE.md.
      assert File.exists?(Path.join(info.pod_dir, ".lcars/system-prompt.md"))
      assert File.exists?(Path.join(info.pod_dir, "CLAUDE.md"))
      assert File.exists?(Path.join(info.pod_dir, ".lcars/protocole-user.md"))
      # Issue-driven (doctrine pivot): the brief lives in issues/<issue_id>.md
      # (not context/brief.md). Claude reads it as project content.
      assert File.exists?(Path.join(info.pod_dir, "issues/issue-1.md"))

      # In-pod Monitor (wake-by-flag, ADR-G): watch.sh provisioned at the pod_dir,
      # executable. The agent arms it via the Monitor tool (cf. SP).
      watch = Path.join(info.pod_dir, "watch.sh")
      assert File.exists?(watch)
      assert File.read!(watch) =~ "ton tour"
      %File.Stat{mode: mode} = File.stat!(watch)
      assert Bitwise.band(mode, 0o100) != 0, "watch.sh must be executable (owner)"

      # SP enriched by the ROLE draft (resolved via metadata.name=engineer → agent-engineer-base.md,
      # generated by blocks): must carry the role identity + the yop → get_work_item → submit_result
      # workflow + the Monitor protocol (wake-by-flag), all carried by core/runtime-contract.
      sp = File.read!(Path.join(info.pod_dir, ".lcars/system-prompt.md"))
      assert sp =~ "System Prompt — engineer"
      assert sp =~ "submit_result"
      assert sp =~ "yop"
      assert sp =~ "Monitor"
      assert sp =~ "watch.sh"

      Process.exit(pid, :kill)
    end

    test "PUSH — the work (opts[:brief]) is delivered in issues/<issue_id>.md" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-brief-#{System.unique_integer([:positive])}"
      brief = "Compile le module X et retourne le nombre de warnings."

      args = %{
        cap_profile: valid_profile(),
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [brief: brief, repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000

      info = GenServer.call(pid, :info)
      # Issue-driven: the brief is in issues/<issue_id>.md, not a user-channel
      # prompt (REPL safety guardrail).
      issue = File.read!(Path.join(info.pod_dir, "issues/issue-1.md"))
      # F128: neutral frame + interpolated role (no "worker engineer" priming).
      assert issue =~ "LCARS pod (role engineer"
      assert issue =~ brief
      assert issue =~ "submit_result"

      Process.exit(pid, :kill)
    end

    test "PUSH — admin.spawn (opts[:brief] + self_enqueue_brief, no dispatcher) enqueues the brief in the TaskQueue (get_work_item channel) [F-arch-MCP]" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-mq-#{System.unique_integer([:positive])}"
      brief = "Crée le projet poc-run-5 puis délègue digit_sum."
      on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod_id) end)

      args = %{
        cap_profile: valid_profile(),
        issue_id: "issue-mq",
        pod_id: pod_id,
        # C-01: the admin rail authorizes the pod's own enqueue via `self_enqueue_brief` (no dispatcher).
        opts: [brief: brief, self_enqueue_brief: true, repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000

      # Without this enqueue, `get_work_item` returns `{done:true}` → the pod (which polls
      # get_work_item) stays idle (arch forensic 3f12edd9). The brief lives in the canonical channel.
      assert [%{brief: ^brief}] =
               Enum.filter(Fleet.TaskQueue.list_pending(), &(&1.pod_id == pod_id))

      Process.exit(pid, :kill)
    end

    test "PUSH — dispatch spawn (opts[:brief], NO self_enqueue flag) never self-enqueues, even on a FREE slot (C-01 race fix) [F-arch-MCP]" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-mq2-#{System.unique_integer([:positive])}"
      on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod_id) end)

      # The DISPATCHER owns the enqueue (via TaskQueue, AFTER the spawn — canonical order
      # lock→pod→enqueue→wake). The brief is in opts only for the pod's DATA (SLSA/provenance). Pre-C-01
      # the pod ALSO self-enqueued from opts[:brief] whenever it booted onto a FREE slot (dispatcher not
      # yet enqueued) → double-enqueue / :cleared mid-run race. Now the self-enqueue is gated on the
      # explicit `self_enqueue_brief` flag (admin rail only). Here the slot is FREE and a brief IS in
      # opts, but the flag is ABSENT (dispatch rail) → the pod self-enqueues NOTHING. `maybe_enqueue_brief`
      # runs in `:projecting`, BEFORE the launch, so by `:launch_called` it has already (not) fired.
      args = %{
        cap_profile: valid_profile(),
        issue_id: "issue-mq2",
        pod_id: pod_id,
        opts: [brief: "dispatch-brief", repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000

      # Free slot + brief in opts, NO flag → the pod is the sole non-enqueuer: the dispatcher (absent in
      # this unit test) is the only owner of the enqueue on this rail. The race is structurally gone.
      assert [] = Enum.filter(Fleet.TaskQueue.list_pending(), &(&1.pod_id == pod_id))

      Process.exit(pid, :kill)
    end

    test "git_ops_denied (cap-profile) merged into disallowedTools of the .cap-profile.json written to the pod" do
      # git archi decision, face 1: the git_ops_denied catalog semantics must land as claude CLI
      # disallowedTools patterns in the .cap-profile.json read by claude_launch.sh — dead line →
      # line enforced by the generic cap_profile→claude CLI mechanism.
      StubBackend.set_reply(interactive_reply())

      profile = valid_profile()

      profile =
        put_in(profile.spec["scope"], %{
          "disallowedTools" => @min_disallowed,
          "git_ops_denied" => ["push --force", "reset --hard"]
        })

      pod_id = "pod-gitops-#{System.unique_integer([:positive])}"

      args = %{
        cap_profile: profile,
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      info = GenServer.call(pid, :info)
      written = File.read!(Path.join(info.pod_dir, ".cap-profile.json")) |> Jason.decode!()
      disallowed = get_in(written, ["spec", "scope", "disallowedTools"])

      assert "web_search" in disallowed
      assert "Bash(git push --force:*)" in disallowed
      assert "Bash(git reset --hard:*)" in disallowed

      Process.exit(pid, :kill)
    end

    test "state.json written after launch (recovery point, PRE-ALLOCATED session_id)" do
      # session_id pre-allocated at spawn (DN §A): passed via opts (the caller allocates it, like
      # pod_id). The backend does NOT capture it (the -p model is dead) — the state is authoritative,
      # persisted as-is. BND-024: an explicit seed MUST be a valid UUID (recall/boot resume a real
      # vendor session).
      StubBackend.set_reply(interactive_reply())

      seed = "abcdef01-2345-4678-9abc-def012345678"
      pod_id = "pod-state-#{System.unique_integer([:positive])}"
      args = build_args(pod_id, "issue-1") |> Map.put(:opts, session_id: seed)
      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000
      # Sync barrier: :launch_called is emitted DURING launch_backend.launch, before do_launch
      # does write_state_fs. GenServer.call is handled after the handle_continue chain.
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      # state.json written at LAUNCH (before MONITOR) → present even without a deliverable.
      # BL-021: full C-3 schema (v, session_id, cap_profile_name,
      # started_at, phase, conditions, issue_id). `pod_id` is NOT persisted
      # (the recovery key = path /var/lib/lcars/<scope>/<pod_id>/state.json).
      content = File.read!(state_fs_path(pod_id)) |> Jason.decode!()
      assert content["v"] == 1
      assert content["issue_id"] == "issue-1"
      assert content["session_id"] == seed
      assert is_binary(content["cap_profile_name"])
      assert is_binary(content["started_at"])
      assert is_list(content["conditions"])
      assert content["phase"] in ["launching", "monitoring"]

      Process.exit(pid, :kill)
    end

    test "BND-024: non-UUID opts[:session_id] → spawn REFUSED (never an arbitrary identity)" do
      # An explicit seed is exported to the launcher (LCARS_POD_SESSION_ID) + persisted for
      # recovery/recall. Any binary would become an alternative identity authority, not
      # reconstructible. A present-but-non-UUID seed = caller/seed corruption → LOUD refusal (no
      # arbitrary accept, no silent fallback to the mint that would hide the corrupt seed under a
      # mistaken recall intention).
      Process.flag(:trap_exit, true)
      pod_id = "pod-badseed-#{System.unique_integer([:positive])}"

      assert {:error, {%ArgumentError{message: msg}, _stack}} =
               spawn_via_supervisor(%{
                 cap_profile: valid_profile(),
                 issue_id: "issue-1",
                 pod_id: pod_id,
                 opts: [session_id: "sess-xyz", repo_id: @test_repo_id]
               })

      assert msg =~ "not a valid UUID"
      refute_received {:launch_called, _args, _env}
    end
  end

  describe "BL-055 — deterministic session_id at spawn (Fleet.Spawner.SessionId)" do
    setup do
      StubBackend.set_reply(interactive_reply())
      :ok
    end

    defp gatekeeper_args(pod_id, opts \\ []) do
      # gatekeeper = slot 2 — PROJECT-BOUND since the 2026-07-19 reorg (repo in its UUID): the spawn
      # carries a repo_id, like every non-starfleet pod. Catalog in the metadata.
      gk = %{
        valid_profile()
        | metadata: %{
            "name" => "gatekeeper",
            "containment" => "bwrap",
            "role_index" => 2
          }
      }

      %{cap_profile: gk, issue_id: "issue-1", pod_id: pod_id, opts: Keyword.put_new(opts, :repo_id, 7)}
    end

    test "fleet-scope role (role_index 0) → deterministic hexspeak session_id, repo 0000 (v2)" do
      pod_id = "pod-sf-det-#{System.unique_integer([:positive])}"
      # role_index 0 ≡ the fleet-scope (starfleet) — the ONLY pod minted on repo 0000 (the old
      # fleet_level flag collapsed into this identity). uid injected (hermetic).
      sf = %{
        valid_profile()
        | metadata: %{"name" => "starfleet", "containment" => "bwrap", "role_index" => 0}
      }

      args = %{cap_profile: sf, issue_id: "issue-1", pod_id: pod_id, opts: [uid: 4242]}
      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000

      # sync barrier (state.json written at LAUNCH, after :launch_called) — cf. the state.json test
      GenServer.call(pid, :info)

      content = File.read!(state_fs_path(pod_id)) |> Jason.decode!()
      expected = Fleet.Spawner.SessionId.encode(0, Fleet.CapProfile.kill_class(sf), 4242, 0)
      assert content["session_id"] == expected
    end

    test "project-bound role (gatekeeper, reorg) → deterministic session_id with ITS repo (v2)" do
      pod_id = "pod-gk-det-#{System.unique_integer([:positive])}"
      # uid injected (hermetic — else the assert would depend on the runner's uid).
      args = gatekeeper_args(pod_id, uid: 4242, repo_id: 7)
      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000

      GenServer.call(pid, :info)

      content = File.read!(state_fs_path(pod_id)) |> Jason.decode!()
      # role 2, class from the fixture's lifetime_scope, uid 4242, repo 7 — the per-project identity.
      expected = Fleet.Spawner.SessionId.encode(2, Fleet.CapProfile.kill_class(args.cap_profile), 4242, 7)
      assert content["session_id"] == expected
    end

    test "explicit opts[:session_id] WINS (e.g. arch boot-from-base on 0badcafe)" do
      pod_id = "pod-explicit-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        spawn_via_supervisor(
          gatekeeper_args(pod_id, session_id: "0badcafe-feed-4dad-babe-0000dec0de01")
        )

      assert_receive {:launch_called, _args, _env}, 2_000
      GenServer.call(pid, :info)

      content = File.read!(state_fs_path(pod_id)) |> Jason.decode!()
      assert content["session_id"] == "0badcafe-feed-4dad-babe-0000dec0de01"
    end

    test "project-bound (engineer) WITHOUT repo_id → spawn REFUSED (unconstructible identity, forge unresolved)" do
      # engineer = project-bound: its hexspeak session_id REQUIRES a resolved repo. WITHOUT a repo (the
      # forge did not return the id — forge down / broken upstream), the mint REFUSES rather than
      # fabricating a random UUID: a random would hide the absent forge and set a NON-reconstructible
      # identity. So the pod does NOT start — init/1 raises → start_link returns
      # {:error, {%ArgumentError{}, _stacktrace}}, no launch. (The clean stop on the dispatch side is
      # upstream; here we fail-loud at the mint, last resort.)
      Process.flag(:trap_exit, true)
      pod_id = "pod-eng-norepo-#{System.unique_integer([:positive])}"

      assert {:error, {%ArgumentError{message: msg}, _stack}} =
               spawn_via_supervisor(%{
                 cap_profile: valid_profile(),
                 issue_id: "issue-1",
                 pod_id: pod_id,
                 opts: []
               })

      assert msg =~ "project-bound"
      assert msg =~ "without repo_id"
      refute_received {:launch_called, _args, _env}
    end

    test "DR-020: repo_id > 9999 (outside <REPO4>) → spawn REFUSED loud, NO silent modulo truncation" do
      # A `rem(id, 10_000)` fold would make repo 10000 encode the SAME identity as repo 0 (two
      # projects, one deterministic session_id → JSONL/slot/GC conflated). The mint REFUSES loud an
      # out-of-format id rather than corrupting the identity through a hidden modulo.
      Process.flag(:trap_exit, true)
      pod_id = "pod-eng-bigrepo-#{System.unique_integer([:positive])}"

      assert {:error, {%ArgumentError{message: msg}, _stack}} =
               spawn_via_supervisor(%{
                 cap_profile: valid_profile(),
                 issue_id: "issue-1",
                 pod_id: pod_id,
                 opts: [repo_id: 10_000]
               })

      assert msg =~ "<REPO4>"
      assert msg =~ "no silent modulo"
      refute_received {:launch_called, _args, _env}
    end

    test "project-bound (engineer) WITH repo_id → deterministic hexspeak (v2: class + uid + DECIMAL repo)" do
      pod_id = "pod-eng-repo-#{System.unique_integer([:positive])}"
      # uid injected (hermetic). repo 161 = 4 DECIMAL digits (grep-direct).
      args = build_args(pod_id, "issue-1") |> Map.put(:opts, repo_id: 161, uid: 4242)
      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000
      GenServer.call(pid, :info)

      content = File.read!(state_fs_path(pod_id)) |> Jason.decode!()
      expected =
        Fleet.Spawner.SessionId.encode(3, Fleet.CapProfile.kill_class(valid_profile()), 4242, 161)

      assert content["session_id"] == expected
    end

    test "graine decision: a captured sidecar for the identity → resume-FROM-GRAINE (slot back)",
         %{tmp_dir: tmp_dir} do
      pod_id = "pod-graine-#{System.unique_integer([:positive])}"
      args = gatekeeper_args(pod_id, uid: 4242, repo_id: 7)
      uuid = Fleet.Spawner.SessionId.encode(2, Fleet.CapProfile.kill_class(args.cap_profile), 4242, 7)

      # The identity's graine sits in the seed store (captured by a previous life).
      Application.put_env(:fleet_spawner, :seed_store_root, Path.join(tmp_dir, "seeds"))
      on_exit(fn -> Application.delete_env(:fleet_spawner, :seed_store_root) end)
      File.mkdir_p!(Path.join([tmp_dir, "seeds", "_slots"]))

      File.write!(
        Path.join([tmp_dir, "seeds", "_slots", "#{uuid}.jsonl"]),
        ~s({"type":"bridge-session","bridgeSessionId":"cse_01GRAINE","sessionId":"#{uuid}"}\n)
      )

      {:ok, _pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _largs, env}, 2_000

      # The pod flipped itself to resume (unified seed decision) and the graine was RESTORED
      # under its identity (the --resume will find it → slot re-attached).
      assert env["LCARS_POD_RESUME"] == "1"

      restored =
        Path.join([tmp_dir, "pods", "pod_#{pod_id}", ".claude", "projects"])
        |> then(fn base ->
          base |> File.ls!() |> Enum.map(&Path.join([base, &1, "#{uuid}.jsonl"]))
        end)
        |> Enum.find(&File.exists?/1)

      assert restored, "the graine should be restored under the identity's jsonl path"
      assert File.read!(restored) =~ "cse_01GRAINE"
    end

    test "graine decision: NO sidecar, NO live jsonl → fresh create (resume 0)", %{tmp_dir: tmp_dir} do
      pod_id = "pod-nograine-#{System.unique_integer([:positive])}"
      Application.put_env(:fleet_spawner, :seed_store_root, Path.join(tmp_dir, "seeds"))
      on_exit(fn -> Application.delete_env(:fleet_spawner, :seed_store_root) end)

      {:ok, _pid} = spawn_via_supervisor(gatekeeper_args(pod_id, uid: 4242, repo_id: 7))
      assert_receive {:launch_called, _largs, env}, 2_000
      assert env["LCARS_POD_RESUME"] == "0"
    end

    test "boot-epoch: a snapshot from a PREVIOUS fleet life + graine → RESUME (not a crash recovery)",
         %{tmp_dir: tmp_dir} do
      # Live scar 2026-07-19: a clean `fleet_v2 stop` leaves a non-terminal state.json — without the
      # epoch discriminator every reboot fell into :recreate and the slot never came back.
      pod_id = "pod-epoch-#{System.unique_integer([:positive])}"
      args = gatekeeper_args(pod_id, uid: 4242, repo_id: 7)
      uuid = Fleet.Spawner.SessionId.encode(2, Fleet.CapProfile.kill_class(args.cap_profile), 4242, 7)

      # Snapshot of a PREVIOUS fleet life (stale/absent boot_id) — non-terminal phase.
      state_path = state_fs_path(pod_id)
      File.mkdir_p!(Path.dirname(state_path))

      File.write!(
        state_path,
        Jason.encode!(%{
          "v" => 1,
          "pod_id" => pod_id,
          "issue_id" => "issue-1",
          "session_id" => uuid,
          "phase" => "monitoring",
          "boot_id" => "boot-PREVIOUS-LIFE"
        })
      )

      # The identity's graine exists.
      Application.put_env(:fleet_spawner, :seed_store_root, Path.join(tmp_dir, "seeds"))
      on_exit(fn -> Application.delete_env(:fleet_spawner, :seed_store_root) end)
      File.mkdir_p!(Path.join([tmp_dir, "seeds", "_slots"]))

      File.write!(
        Path.join([tmp_dir, "seeds", "_slots", "#{uuid}.jsonl"]),
        ~s({"type":"bridge-session","bridgeSessionId":"cse_01EPOCH","sessionId":"#{uuid}"}\n)
      )

      {:ok, _pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _largs, env}, 2_000
      assert env["LCARS_POD_RESUME"] == "1"
    end

    test "boot-epoch: a snapshot from THIS fleet life keeps the fresh-reroll recovery (resume 0)",
         %{tmp_dir: tmp_dir} do
      pod_id = "pod-epoch-same-#{System.unique_integer([:positive])}"
      args = gatekeeper_args(pod_id, uid: 4242, repo_id: 7)
      uuid = Fleet.Spawner.SessionId.encode(2, Fleet.CapProfile.kill_class(args.cap_profile), 4242, 7)

      state_path = state_fs_path(pod_id)
      File.mkdir_p!(Path.dirname(state_path))

      File.write!(
        state_path,
        Jason.encode!(%{
          "v" => 1,
          "pod_id" => pod_id,
          "issue_id" => "issue-1",
          "session_id" => uuid,
          "phase" => "monitoring",
          # CURRENT epoch = the pod died while THIS fleet was alive → crash doctrine.
          "boot_id" => Fleet.Spawner.BootEpoch.id()
        })
      )

      # Even WITH a graine present, a same-life crash NEVER resumes (fresh-reroll).
      Application.put_env(:fleet_spawner, :seed_store_root, Path.join(tmp_dir, "seeds"))
      on_exit(fn -> Application.delete_env(:fleet_spawner, :seed_store_root) end)
      File.mkdir_p!(Path.join([tmp_dir, "seeds", "_slots"]))

      File.write!(
        Path.join([tmp_dir, "seeds", "_slots", "#{uuid}.jsonl"]),
        ~s({"type":"bridge-session","bridgeSessionId":"cse_01SAME","sessionId":"#{uuid}"}\n)
      )

      {:ok, _pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _largs, env}, 2_000
      assert env["LCARS_POD_RESUME"] == "0"
    end

    test "UUID GC: a stale <uuid>.jsonl (pod_dir surviving a crash) is removed before --session-id",
         %{tmp_dir: tmp_dir} do
      pod_id = "pod-gc-#{System.unique_integer([:positive])}"
      args = gatekeeper_args(pod_id, uid: 4242, repo_id: 7)
      # the pod's deterministic v2 uuid (class from fixture, uid injected, ITS repo) — the GC targets THIS name.
      uuid = Fleet.Spawner.SessionId.encode(2, Fleet.CapProfile.kill_class(args.cap_profile), 4242, 7)

      # simulates a surviving pod_dir (failed teardown): the deterministic UUID's jsonl already lingers.
      stale =
        Path.join([
          tmp_dir,
          "pods",
          "pod_#{pod_id}",
          ".claude",
          "projects",
          "-home-x",
          "#{uuid}.jsonl"
        ])

      File.mkdir_p!(Path.dirname(stale))
      File.write!(stale, "{}\n")
      assert File.exists?(stale)

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, _env}, 2_000
      GenServer.call(pid, :info)

      refute File.exists?(stale), "the stale jsonl should have been GC'd before the --session-id"
    end
  end

  describe "#kill-yolo — LCARS_PERMISSION_MODE (--permission-mode vs --dangerously-skip)" do
    setup do
      StubBackend.set_reply(interactive_reply())
      :ok
    end

    test "default = 'default' (claude_launch → --permission-mode default, lists enforced)" do
      pod_id = "pod-perm-#{System.unique_integer([:positive])}"
      {:ok, _pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))
      assert_receive {:launch_called, _args, env}, 2_000
      assert env["LCARS_PERMISSION_MODE"] == "default"
    end

    test "cap-profile spec.invocation.permission_mode overrides the default" do
      pod_id = "pod-perm-ovr-#{System.unique_integer([:positive])}"
      cp = valid_profile()
      inv = Map.put(cp.spec["invocation"] || %{}, "permission_mode", "bypassPermissions")
      cp = %{cp | spec: Map.put(cp.spec, "invocation", inv)}

      args = %{
        cap_profile: cp,
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      {:ok, _pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _args, env}, 2_000
      assert env["LCARS_PERMISSION_MODE"] == "bypassPermissions"
    end
  end

  describe "LAUNCH-Q — containment branch (host_launch vs bwrap) on the launch path" do
    # The gap: a `do_launch` that bwraps EVERYTHING (containment never read). Here we prove that the
    # N0 launcher passed to the backend (`args.launcher_path`) AND the HOME follow `metadata.containment`.
    defp host_profile, do: put_in(valid_profile().metadata["containment"], "none")

    test "containment: none → host_launch.sh launcher + HOME = the human's real home (native auth)",
         %{
           tmp_dir: tmp_dir
         } do
      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-host-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        spawn_via_supervisor(%{
          cap_profile: host_profile(),
          issue_id: "t1",
          pod_id: pod_id,
          opts: [repo_id: @test_repo_id]
        })

      assert_receive {:launch_called, args, env}, 2_000
      assert String.ends_with?(args.launcher_path, "host_launch.sh")

      # HOME = parent of the human claudeDir (= config override :claude_dir = <tmp_dir>/.claude) → tmp_dir.
      # claude thus reads the native human ~/.claude (OAuth refresh, no 8h cliff — arch forever).
      assert env["HOME"] == tmp_dir
      Process.exit(pid, :kill)
    end

    test "containment: bwrap (default) → bwrap_launch.sh launcher + HOME = pod_dir (unchanged)" do
      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-bwrap-#{System.unique_integer([:positive])}"

      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t1"))

      assert_receive {:launch_called, args, env}, 2_000
      assert String.ends_with?(args.launcher_path, "bwrap_launch.sh")
      assert env["HOME"] == args.pod_dir
      Process.exit(pid, :kill)
    end

    test "ABSENT containment key → rejected at the G24-1 gate (allocate), NEVER launched on host" do
      # LAUNCH-Q security invariant: a malformed cap-profile (no `containment`) can NOT reach
      # host_launch — the G24-1 gate (`check_containment`, enum {bwrap,none}) rejects it at
      # allocate, BEFORE do_launch. (The "bwrap" default of `cap_profile_containment/1` is a
      # defense-in-depth net, unreachable in the guarded path: the gate decides first.)
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())
      profile = update_in(valid_profile().metadata, &Map.delete(&1, "containment"))
      pod_id = "pod-nocont-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        spawn_via_supervisor(%{
          cap_profile: profile,
          issue_id: "t1",
          pod_id: pod_id,
          opts: [repo_id: @test_repo_id]
        })

      assert_receive {:EXIT, ^pid,
                      {:shutdown, {:allocate_failed, {:cap_profile_invalid, violations}}}},
                     2_000

      assert :g24_1 in violations
      refute_received {:launch_called, _, _}
    end
  end

  describe "result deadline — Z1 (RESPONSE timeout, not a life budget)" do
    # `spec.timeouts.response_sec` (optional field) → short deterministic forcing
    # (the per-scope default is 300s, too long for a unit test). 1s minimum because
    # Process.send_after requires an integer; assert_receive/sleep tolerate the delay.
    defp short_timeout(profile), do: put_in(profile.spec["timeouts"], %{"response_sec" => 1})

    test "timeout WITH active task → :failed (result_timeout)" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-timeout-active-#{System.unique_integer([:positive])}"
      # An ACTIVE (pending) task for this pod → at the deadline FIRE,
      # pod_has_active_task? = true → real response timeout → transition_failed.
      {:ok, _t} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "fais X", role: "engineer"})
      on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod_id) end)

      args = %{
        cap_profile: short_timeout(valid_profile()),
        issue_id: "t1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      assert_receive {:EXIT, ^pid, {:shutdown, {:result_timeout, _}}}, 5_000
    end

    test "timeout WITHOUT active task (idle) → pod survives (Z1: no idle-kill)" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-timeout-idle-#{System.unique_integer([:positive])}"
      # NO task → at the FIRE, pod_has_active_task? = false → the pod was just waiting
      # for its next task → NO kill. This is the original bug the 60ks band-aid was
      # hiding; here proven fixed at the root (check at fire, not at arming).
      args = %{
        cap_profile: short_timeout(valid_profile()),
        issue_id: "t1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      # Beyond response_sec (1s): the deadline fired, but idle → no kill.
      Process.sleep(1_300)
      assert Process.alive?(pid), "idle pod killed by :result_deadline (Z1 regression)"
      assert GenServer.call(pid, :info).phase == :monitoring

      Process.exit(pid, :kill)
    end

    # F-C037 — 3-state decision at the deadline FIRE (testable seam without an unreachable TaskQueue).
    test "F-C037 :idle → lapse (:keep_state_and_data, NO re-arm) — pod between two tasks" do
      data = %{pod_id: "p-idle", cap_profile: valid_profile()}
      assert :keep_state_and_data = Fleet.Spawner.Pod.result_deadline_fire(:idle, data)
    end

    test "F-C037 :unknown (broker unreachable) → RE-ARMS the deadline, never a lapse (else orphaned hung pod)" do
      # The bug: pod_has_active_task? conflated a broker :error into `false` (= idle) → lapse → a HUNG
      # pod whose broker blips right at the fire is never re-checked (liveness only re-arms if the pod
      # MOVES, and a hung one does not move). Fail-safe: :unknown → re-arm (stays under watch),
      # no-kill preserved.
      data = %{pod_id: "p-unknown", cap_profile: valid_profile()}

      assert {:keep_state_and_data, actions} =
               Fleet.Spawner.Pod.result_deadline_fire(:unknown, data)

      assert Enum.any?(actions, fn
               {:state_timeout, ms, :result_deadline} when is_integer(ms) -> true
               _ -> false
             end),
             "the deadline must be RE-ARMED (state_timeout), not consumed"
    end

    test "forever pod — deadline NEVER armed (survives even with an active task + short timeout)" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-forever-noarm-#{System.unique_integer([:positive])}"
      # forever = permanent: arm_result_deadline does NOT arm (no response timeout;
      # governed by external kill_pod). Even WITH an active task + response_sec=1s, no
      # kill — direct proof of the auditor's point (a permanent does not die on timeout).
      {:ok, _t} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "veille", role: "gatekeeper"})
      on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod_id) end)

      profile = valid_profile()

      profile =
        put_in(profile.spec["invocation"], %{"lifetime_scope" => "forever"})

      args = %{
        cap_profile: short_timeout(profile),
        issue_id: "t1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      Process.sleep(1_300)
      assert Process.alive?(pid), "forever pod killed by :result_deadline (must NEVER arm)"

      Process.exit(pid, :kill)
    end

    test "liveness MOVES → deadline re-armed → pod survives despite active task + short timeout (F-RESULT-DEADLINE-LOOP)" do
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-liveness-alive-#{System.unique_integer([:positive])}"

      # Active task: without the liveness watchdog, the deadline (1s) would fire → result_timeout (cf.
      # the "timeout WITH active task" test). Here the probe returns an ALWAYS increasing value
      # (monotonic) → on every tick (100ms) the pod "moved" → arm_result_deadline re-arms → the
      # deadline never falls.
      {:ok, _t} =
        Fleet.TaskQueue.enqueue(pod_id, %{brief: "vrai livrable long", role: "engineer"})

      on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod_id) end)

      probe = fn _state -> {System.monotonic_time(:microsecond), nil} end

      args = %{
        cap_profile: short_timeout(valid_profile()),
        issue_id: "t1",
        pod_id: pod_id,
        opts: [liveness_tick_ms: 100, liveness_probe_fun: probe, repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      # Well beyond response_sec (1s): an engineer that MOVES must NEVER time out.
      Process.sleep(1_500)

      assert Process.alive?(pid),
             "MOVING engineer killed by the deadline (F-RESULT-DEADLINE-LOOP not fixed)"

      assert GenServer.call(pid, :info).phase == :monitoring

      Process.exit(pid, :kill)
    end

    test "FLAT liveness (silence) WITH active task → deadline fire → result_timeout (real stuck)" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())

      pod_id = "pod-liveness-stuck-#{System.unique_integer([:positive])}"

      # CONSTANT probe → no movement → the watchdog never re-arms → the deadline (1s) falls on total
      # silence = real stuck → transition_failed. (1st tick without a baseline = 1 "benefit of the
      # doubt" re-arm → fire ~1 tick later, covered by the 5s assert_receive.)
      {:ok, _t} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "fais X", role: "engineer"})
      on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod_id) end)

      probe = fn _state -> {42, 42} end

      args = %{
        cap_profile: short_timeout(valid_profile()),
        issue_id: "t1",
        pod_id: pod_id,
        opts: [liveness_tick_ms: 100, liveness_probe_fun: probe, repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      assert_receive {:EXIT, ^pid, {:shutdown, {:result_timeout, _}}}, 5_000
    end
  end

  describe "Z2 — G24 cap-profile gate at spawn (CAP-D1 / F-CONT-RISK)" do
    test "G24-invalid profile (server-tools not denied) → :failed, NEVER launched" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())

      # EMPTY disallowedTools → violates g24_9 (F-CONT-RISK: web_search/web_fetch/code_execution/…
      # not denied). The validate/1 gate (do_allocate) must refuse BEFORE any launch.
      profile =
        put_in(valid_profile().spec["scope"], %{"disallowedTools" => [], "git_ops_denied" => []})

      pod_id = "pod-g24-invalid-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        spawn_via_supervisor(%{
          cap_profile: profile,
          issue_id: "t1",
          pod_id: pod_id,
          opts: [repo_id: @test_repo_id]
        })

      assert_receive {:EXIT, ^pid,
                      {:shutdown, {:allocate_failed, {:cap_profile_invalid, violations}}}},
                     2_000

      assert :g24_9_strict in violations, "the gate must raise g24_9 (F-CONT-RISK)"
      # The refusal is at the ALLOCATE boundary → the pod is NEVER launched (effective gate).
      refute_received {:launch_called, _, _}
    end

    test "DR-021: injecting mount (newline) → pod fails CLEANLY (raise caught), NEVER launched" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())

      # A mount with a newline = LCARS_POD_MOUNTS injection. LaunchSpec REFUSES (raise) instead of
      # dropping-and-launching; the raise is caught by LaunchEnv.build/4 →
      # {:error, {:launch_env_unresolved,_}} → transition_failed. PROOF that the R1-21 reversal
      # (refusal instead of drop) fails the pod cleanly, WITHOUT crashing the gen_statem (the clean
      # {:EXIT, :shutdown, _}, not an {:EXIT, _, {%ArgumentError{}}}).
      profile = put_in(valid_profile().metadata["mounts"], [%{"mode" => "ro", "path" => "/x\nrw:/etc"}])
      pod_id = "pod-mount-inject-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        spawn_via_supervisor(%{
          cap_profile: profile,
          issue_id: "t1",
          pod_id: pod_id,
          opts: [repo_id: @test_repo_id]
        })

      assert_receive {:EXIT, ^pid, {:shutdown, {:launch_env_unresolved, _msg}}}, 2_000
      refute_received {:launch_called, _, _}
    end
  end

  describe "Z2 — credentials gate at spawn (login-validity only, scope/plan nuked 2026-07-20)" do
    defp write_creds(dir, oauth) do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".credentials.json"), Jason.encode!(%{"claudeAiOauth" => oauth}))
      Application.put_env(:fleet_spawner, :claude_dir, dir)
    end

    test "free plan + minimal scopes still LAUNCHES (login is enough — vendor enforces scope/plan)",
         %{tmp_dir: tmp_dir} do
      # Regression of the nuke: the old gate refused this (unpaid / missing scope). The scope+plan
      # checks duplicated the claude binary's own 401 enforcement → removed; only login remains.
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())

      write_creds(Path.join(tmp_dir, "creds-free"), %{
        "accessToken" => "sk-ant-x",
        "scopes" => ["user:inference"],
        "subscriptionType" => "free"
      })

      pod_id = "pod-free-#{System.unique_integer([:positive])}"
      {:ok, _pid} = spawn_via_supervisor(build_args(pod_id, "t1"))

      # The login is valid → the pod LAUNCHES (no credentials refusal).
      assert_receive {:launch_called, _, _}, 2_000
    end

    test "no valid login (empty accessToken) → :failed, never launched", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply())

      write_creds(Path.join(tmp_dir, "creds-nologin"), %{"accessToken" => ""})

      pod_id = "pod-nologin-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t1"))

      assert_receive {:EXIT, ^pid,
                      {:shutdown, {:credentials_invalid, {:not_logged_in, _}}}},
                     2_000

      refute_received {:launch_called, _, _}
    end
  end

  describe "launch backend errors" do
    test "backend :error → phase :failed with a reason" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply({:error, :bwrap_failed})

      pod_id = "pod-launch-fail-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))

      assert_receive {:EXIT, ^pid, {:shutdown, {:launch_failed, :bwrap_failed}}}, 2_000
    end
  end

  describe "process exit before result" do
    test "exit_status without result → pod.failed + {:shutdown, exited_before_result} stop" do
      Process.flag(:trap_exit, true)
      # Live fake port (sleep); we simulate the process exit before any submit_result.
      fake_port = Port.open({:spawn, "/bin/sleep 60"}, [:binary, :exit_status])
      StubBackend.set_reply(interactive_reply(port: fake_port))

      pod_id = "pod-exit-noliv-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t-exit"))
      assert_receive {:launch_called, _, _}, 2_000

      # The pod is in :monitoring (no result received). We send the port exit.
      send(pid, {fake_port, {:exit_status, 137}})

      assert_receive {:EXIT, ^pid, {:shutdown, {:exited_before_result, 137}}}, 2_000
    end

    test "exit_status without result ENGRAVES the state.json tombstone phase=failed (PodWarden GC-able)" do
      Process.flag(:trap_exit, true)
      fake_port = Port.open({:spawn, "/bin/sleep 60"}, [:binary, :exit_status])
      StubBackend.set_reply(interactive_reply(port: fake_port))

      pod_id = "pod-exit-tomb-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t-exit"))
      assert_receive {:launch_called, _, _}, 2_000
      send(pid, {fake_port, {:exit_status, 137}})
      assert_receive {:EXIT, ^pid, {:shutdown, {:exited_before_result, 137}}}, 2_000

      # The write is SYNCHRONOUS before the stop → the post-EXIT disk assertion is deterministic.
      content = File.read!(state_fs_path(pod_id)) |> Jason.decode!()

      assert content["phase"] == "failed",
             "exit-before-result must engrave the :failed tombstone — otherwise state.json stays " <>
               ":monitoring → pod_dir (git clone) invisible to the PodWarden GC (monotonic leak)"
    end
  end

  describe "pipe lifecycle (long-lived engineer)" do
    # Long-lived engineer (cf. pipeline-implementation.md doctrine
    # Phase III). For lifetime_scope != one-shot, do_extract does NOT
    # release: the pod broadcasts pod.completed, resets submitted_result,
    # returns to :monitoring, re-arms result_deadline. Release only
    # on kill_pod (gatekeeper promote/abandon) or deadline.
    defp pipe_profile do
      profile = valid_profile()

      put_in(profile.spec["invocation"], %{
        "lifetime_scope" => "pipe"
      })
    end

    # Pipe with an async git deliverable: only this mode has a push (read from the workspace,
    # confirmed by deliverable.published) to protect from a re-brief → :publishing at submit.
    # pipe_profile() alone defaults deliverable_mode to "payload" (gatekeeper/architect-like:
    # verdict/interactive, no push).
    defp git_native_pipe_profile do
      profile = pipe_profile()
      put_in(profile.spec["deliverable_mode"], "git_native")
    end

    test "F-28: reprovision repins the pod's PROJECT MAP — the payload reports the re-brief base, never the spawn base",
         %{tmp_dir: tmp_dir} do
      # Source repo with TWO commits on main: the spawn pins the OLD base, the re-brief
      # pins the NEW one (both in clone history → reset_in_place stays local).
      src = Path.join(tmp_dir, "f28-src")
      File.mkdir_p!(src)
      g = fn args -> {_, 0} = System.cmd("git", ["-C", src] ++ args, stderr_to_stdout: true) end
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", src], stderr_to_stdout: true)
      g.(["config", "user.email", "t@lcars.local"])
      g.(["config", "user.name", "test"])
      File.write!(Path.join(src, "f.txt"), "v1")
      g.(["add", "."])
      g.(["commit", "-q", "-m", "old base"])
      {old_out, 0} = System.cmd("git", ["-C", src, "rev-parse", "HEAD"])
      old_sha = String.trim(old_out)
      File.write!(Path.join(src, "f.txt"), "v2")
      g.(["add", "."])
      g.(["commit", "-q", "-m", "fresh base"])
      {new_out, 0} = System.cmd("git", ["-C", src, "rev-parse", "HEAD"])
      new_sha = String.trim(new_out)

      project = fn sha ->
        %{
          "repo" => "fleet/f28-demo",
          "repo_path" => src,
          "base_branch" => "main",
          "base_sha" => sha,
          "gate_base_sha" => sha
        }
      end

      StubBackend.set_reply(interactive_reply(session_id: "s-pipe-f28"))
      pod_id = "pod-pipe-#{System.unique_integer([:positive])}"

      Bus.subscribe()

      {:ok, pid} =
        spawn_via_supervisor(%{
          cap_profile: pipe_profile(),
          issue_id: "issue-1",
          pod_id: pod_id,
          opts: [repo_id: @test_repo_id, project: project.(old_sha)]
        })

      assert_receive {:launch_called, _, _}, 3_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      # Re-brief: the dispatcher resolved a FRESH base and reprovisions the pipe.
      assert :ok = Fleet.Spawner.reprovision_pipe_workspace(pod_id, project.(new_sha))

      submit_result_event(pod_id, %{"answer" => "ok"})

      assert_receive %Fleet.Event{type: :"pod.completed", payload: payload}, 2_000

      # The regression: `keep_state_and_data` threw the fresh map away → the payload (thus
      # the branch birth, the ancestor gate AND the provenance input_sha) reported the
      # SPAWN-time base. The payload must carry the RE-BRIEF base.
      assert payload["base_sha"] == new_sha
      assert payload["gate_base_sha"] == new_sha
    end

    test "cycle 1 submit_result → pod.completed broadcast, pod stays in :monitoring" do
      StubBackend.set_reply(interactive_reply(session_id: "s-pipe"))

      pod_id = "pod-pipe-#{System.unique_integer([:positive])}"

      args = %{
        cap_profile: pipe_profile(),
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      Bus.subscribe()

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      submit_result_event(pod_id, %{"cycle" => 1, "answer" => "ok"})

      # pod.completed received Bus-side.
      assert_receive %Fleet.Event{
                       source: :spawner,
                       type: :"pod.completed",
                       payload: payload
                     },
                     2_000

      assert payload["pod_id"] == pod_id
      assert payload["result"]["cycle"] == 1

      # Pod STILL alive + back to :monitoring + submitted_result reset.
      Process.sleep(50)
      info = GenServer.call(pid, :info)
      assert info.phase == :monitoring
      assert Process.alive?(pid)

      Process.exit(pid, :kill)
    end

    test "cycle 2 submit_result after cycle 1 → second pod.completed, pod still alive" do
      StubBackend.set_reply(interactive_reply(session_id: "s-pipe2"))

      pod_id = "pod-pipe-2cy-#{System.unique_integer([:positive])}"

      args = %{
        cap_profile: pipe_profile(),
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      Bus.subscribe()

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      submit_result_event(pod_id, %{"cycle" => 1})

      assert_receive %Fleet.Event{
                       source: :spawner,
                       type: :"pod.completed",
                       payload: %{"result" => %{"cycle" => 1}}
                     },
                     2_000

      Process.sleep(50)
      assert GenServer.call(pid, :info).phase == :monitoring

      submit_result_event(pod_id, %{"cycle" => 2})

      assert_receive %Fleet.Event{
                       source: :spawner,
                       type: :"pod.completed",
                       payload: %{"result" => %{"cycle" => 2}}
                     },
                     2_000

      assert Process.alive?(pid)
      info = GenServer.call(pid, :info)
      assert info.phase == :monitoring
      assert info.last_result == %{"cycle" => 2}

      Process.exit(pid, :kill)
    end

    test "a pipe pod stays :monitoring after a submit, then a brutal Process.exit(:kill) terminates it" do
      # NOT a kill_pod / clean-release proof — this test never calls Fleet.Spawner.kill_pod nor exercises
      # the release path (the DynamicSupervisor is not started here). The real kill_pod clean-release is
      # proven in spawner_test.exs ("kill_pod does a clean release", LIFE-003). Here we only prove the
      # pipe LIFECYCLE: it survives a submit at :monitoring and dies with :killed on a brutal exit.
      Process.flag(:trap_exit, true)
      StubBackend.set_reply(interactive_reply(session_id: "s-pipe-kill"))

      pod_id = "pod-pipe-kill-#{System.unique_integer([:positive])}"

      args = %{
        cap_profile: pipe_profile(),
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      submit_result_event(pod_id, %{"cycle" => 1})
      Process.sleep(50)
      assert GenServer.call(pid, :info).phase == :monitoring

      # Brutal kill (Process.exit, not kill_pod — cf. the header): the pod terminates with :killed.
      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}, 2_000
    end

    # SLOT-FREEZE guard — :publishing is armed ONLY for an async git deliverable (maybe_enter_publishing).
    test "submit of a git_native pipe → :publishing condition armed (push to protect)" do
      StubBackend.set_reply(interactive_reply(session_id: "s-pub-git"))

      pod_id = "pod-pub-git-#{System.unique_integer([:positive])}"

      args = %{
        cap_profile: git_native_pipe_profile(),
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      Bus.subscribe()

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      submit_result_event(pod_id, %{"cycle" => 1})

      assert_receive %Fleet.Event{source: :spawner, type: :"pod.completed"}, 2_000

      # publish_deadline is at 120s (never fires here) and deliverable.published is not emitted
      # (StepRunCompleter off in test) → :publishing stays present after the return to :monitoring.
      Process.sleep(50)
      info = GenServer.call(pid, :info)
      assert info.phase == :monitoring
      assert :publishing in info.conditions

      Process.exit(pid, :kill)
    end

    # A payload pipe (no async push) does NOT arm :publishing — otherwise it would arm a 120s
    # deadline never lifted by deliverable.published (emitted only for git_native).
    test "submit of a payload pipe → NO :publishing condition (nothing to protect)" do
      StubBackend.set_reply(interactive_reply(session_id: "s-pub-payload"))

      pod_id = "pod-pub-payload-#{System.unique_integer([:positive])}"

      # pipe_profile() = deliverable_mode defaults to "payload".
      args = %{
        cap_profile: pipe_profile(),
        issue_id: "issue-1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      Bus.subscribe()

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      submit_result_event(pod_id, %{"cycle" => 1})

      assert_receive %Fleet.Event{source: :spawner, type: :"pod.completed"}, 2_000

      Process.sleep(50)
      info = GenServer.call(pid, :info)
      assert info.phase == :monitoring
      refute :publishing in info.conditions

      Process.exit(pid, :kill)
    end
  end

  describe "recovery from state FS" do
    test "in-flight → :recreate (FRESH session, not --resume)" do
      pod_id = "pod-recover-os-#{System.unique_integer([:positive])}"
      Process.flag(:trap_exit, true)

      state_path = state_fs_path(pod_id)
      File.mkdir_p!(Path.dirname(state_path))

      File.write!(
        state_path,
        Jason.encode!(%{
          "v" => 1,
          "pod_id" => pod_id,
          "issue_id" => "issue-old",
          "session_id" => "session-old",
          "phase" => "launching"
        })
      )

      StubBackend.set_reply(interactive_reply(session_id: "ignored"))

      # Any IN-FLIGHT phase on a (re)spawn → :recreate (the backend is dead under
      # `:temporary`, never --resume on a dead session). The pod relaunches with a
      # FRESH session (here the engineer's deterministic mint, test repo resolved), NOT
      # --resume session-old: what we prove = recreate ≠ resume, not the id's shape.
      {:ok, _pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))
      assert_receive {:launch_called, args, env}, 2_000
      refute args.session_id == "session-old"
      assert env["LCARS_POD_RESUME"] == "0"
    end
  end

  describe "terminate_pod_port/1 (bwrap chain teardown)" do
    test "SIGTERMs the port's process — the holder is NOT killed by Port.close alone" do
      # Reproduces the holder: a process that IGNORES stdin EOF (sleep) → Port.close orphans it;
      # terminate_pod_port SIGTERMs it by os_pid. (The real bwrap+holder is proven in e2e; here we
      # lock the exact mechanics of the fix at the unit level.)
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["60"]])
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      assert os_alive?(os_pid)

      assert :ok = Fleet.Spawner.Pod.Backend.terminate_pod_port(port)
      Process.sleep(400)
      refute os_alive?(os_pid)
    end

    # F-C4b-3: TOCTOU race — the port closes on its own (claude finishes after submit_result)
    # between the check and the Port.close → ArgumentError → the pod's GenServer crashed on a
    # SUCCESSFUL completion (observed at C4b do_release). safe_port_close absorbs the
    # ArgumentError; without the rescue, this test crashes (RED).
    test "safe_port_close on an ALREADY closed port → :ok (no crash, do_release race)" do
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["60"]])
      true = Port.close(port)
      # port now closed: a raw Port.close would raise ArgumentError.
      assert :ok = Fleet.Spawner.Pod.Backend.safe_port_close(port)
    end

    test "terminate_pod_port on an already closed port → :ok (idempotent teardown)" do
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["60"]])
      true = Port.close(port)
      assert :ok = Fleet.Spawner.Pod.Backend.terminate_pod_port(port)
    end
  end

  describe "terminate/2 — GUARANTEED backend teardown on every {:stop} (OTP net)" do
    # A `transition_failed` ({:stop, {:shutdown, _}}) that does not tear down the backend leaves the
    # claude/holder process alive as an ORPHAN (OAuth+RAM) until the periodic reaper (~60s, if ON).
    # terminate/2 guarantees it: OTP calls it on EVERY {:stop}. We observe via a LIVE fake-port
    # (sleep) whose os_pid MUST be SIGTERMed at teardown (the stub port is set by interactive_reply(port:)).
    test "transition_failed (result_timeout) → terminate/2 tears down the backend (os_pid SIGTERM)" do
      Process.flag(:trap_exit, true)

      fake_port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["60"]])
      {:os_pid, os_pid} = Port.info(fake_port, :os_pid)
      assert os_alive?(os_pid)

      StubBackend.set_reply(interactive_reply(port: fake_port))

      pod_id = "pod-term-tf-#{System.unique_integer([:positive])}"

      # Active task → at the deadline FIRE (response_sec=1s), pod_has_active_task? = true → transition_failed.
      {:ok, _t} = Fleet.TaskQueue.enqueue(pod_id, %{brief: "fais X", role: "engineer"})
      on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod_id) end)

      args = %{
        cap_profile: short_timeout(valid_profile()),
        issue_id: "t1",
        pod_id: pod_id,
        opts: [repo_id: @test_repo_id]
      }

      {:ok, pid} = spawn_via_supervisor(args)
      assert_receive {:launch_called, _, _}, 2_000

      # transition_failed → {:stop, {:shutdown, {:result_timeout, _}}} → terminate/2 → teardown_backend.
      assert_receive {:EXIT, ^pid, {:shutdown, {:result_timeout, _}}}, 5_000

      Process.sleep(400)

      refute os_alive?(os_pid),
             "orphaned backend: terminate/2 did not tear down the port on transition_failed"
    end

    # The success path (`do_release`) ALREADY tears down explicitly, BEFORE the {:stop}; terminate/2
    # re-calls teardown_backend (the net). The double call must be IDEMPOTENT: no crash (otherwise the
    # EXIT would not be :normal), backend properly dead. (The double `terminate_pod_port` on a closed
    # port is proven unit-level just above; here we lock the double call on the FULL life path.)
    test "double teardown (explicit do_release + terminate/2 net) idempotent — :normal EXIT, backend dead" do
      Process.flag(:trap_exit, true)

      fake_port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["60"]])
      {:os_pid, os_pid} = Port.info(fake_port, :os_pid)
      assert os_alive?(os_pid)

      StubBackend.set_reply(interactive_reply(port: fake_port, session_id: "s-idem"))

      pod_id = "pod-term-idem-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t-idem"))
      assert_receive {:launch_called, _, _}, 2_000
      assert %{phase: :monitoring} = GenServer.call(pid, :info)

      # one-shot: submit_result → extract → release (teardown #1) → {:stop, :normal} → terminate (teardown #2).
      submit_result_event(pod_id, %{"answer" => "OK"})

      assert_receive {:EXIT, ^pid, :normal}, 3_000

      Process.sleep(400)

      refute os_alive?(os_pid),
             "backend not torn down on the success path (do_release + terminate/2)"
    end
  end

  describe "auth — single bind mode (token_arg removed)" do
    test "every spawn sets LCARS_AUTH_MODE=bind, never a cleartext token (LCARS_ANTHROPIC_AUTH_TOKEN)" do
      # No switch: bind is the only mode (bwrap mounts the .credentials.json RW → native OAuth
      # refresh, no 8h cliff, no argv leak). No :auth_mode config to set.
      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-auth-bind-#{System.unique_integer([:positive])}"

      {:ok, _pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))

      assert_receive {:launch_called, _args, env}, 2_000
      assert env["LCARS_AUTH_MODE"] == "bind"
      refute Map.has_key?(env, "LCARS_ANTHROPIC_AUTH_TOKEN")

      # LCARS_POD_DIR is NOT set by the spawner (dead code: bwrap_launch `--clearenv` strips it,
      # host_launch `export`s it = $POD_DIR, F-E1). The pod root travels via LCARS_POD_HOME (bwrap,
      # forwarded by bwrap_launch) + the `$HOME` fallback. cf. pod.ex (Map.put 5001703f reverted).
      refute Map.has_key?(env, "LCARS_POD_DIR")
      assert env["LCARS_POD_HOME"] == "/home/.pod"
    end
  end

  describe "per-human credential — anti cross-human (accepted sharing residue)" do
    test "the spawn's CLAUDE_DIR = the resolved per-human claudeDir, never a shared hardcoded global dir",
         %{tmp_dir: tmp_dir} do
      # The shared-writable `.credentials.json` between pods of the same human is INTENDED (the only
      # vendor multi-agent mechanic under subscription; cf. the big "ON N'Y TOUCHE PAS" block around
      # `claude_dir` in pod.ex). The residue "a pod reads/overwrites its human's creds" is ACCEPTED
      # (overwriting = self-DoS; reading = its own token, pod = AS the human). The ONLY invariant to
      # keep = PER-HUMAN: the spawn carries the claudeDir resolved for the owning human (in prod =
      # the runtime user's `~/.claude`; in test = the `:claude_dir` config the setup points at
      # `<tmp>/.claude`), NEVER a hardcoded GLOBAL dir shared between humans (= the cross-human
      # exfil, the only real vector). If someone wires a shared claudeDir (`/var/lib/.../.claude`…),
      # CLAUDE_DIR ≠ `<tmp>/.claude` → THIS test breaks.
      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-cred-perhuman-#{System.unique_integer([:positive])}"
      {:ok, _pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))

      assert_receive {:launch_called, _args, env}, 2_000
      assert env["CLAUDE_DIR"] == Path.join(tmp_dir, ".claude")
    end
  end

  describe "R14 — mcp_server_spec mandatory for a real backend" do
    test "real backend + nil mcp_server_spec → spawn refused (fail-loud, no broken pod)" do
      # Real backend (non-Stub) without an MCP spec: the real pod speaks MCP → clean refusal
      # at do_project (maybe_provision_mcp_config) BEFORE any launch. We do NOT actually
      # launch bwrap (the failure is at provisioning).
      Application.put_env(
        :fleet_spawner,
        :launch_backend,
        Fleet.Spawner.LaunchBackend.LauncherPortBackend
      )

      Application.delete_env(:fleet_spawner, :mcp_server_spec)

      on_exit(fn ->
        Application.put_env(:fleet_spawner, :launch_backend, StubBackend)
        Application.delete_env(:fleet_spawner, :mcp_server_spec)
      end)

      Process.flag(:trap_exit, true)
      pod_id = "pod-mcp-missing-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))

      assert_receive {:EXIT, ^pid,
                      {:shutdown, {:project_failed, {:mcp_server_spec_required, _backend}}}},
                     2_000

      # The refusal is at do_project (provisioning) BEFORE do_launch → never a launch.
      refute_received {:launch_called, _args, _env}
    end

    test "monde-propre: .mcp-fleet.json carries the IN-NAMESPACE path (/home/.pod), not the host pod_dir" do
      # Live regression: the generation put the bridge's HOST path (state.pod_dir) in the
      # .mcp-fleet.json. bwrap remaps the pod_dir → /home/.pod, so that path does NOT exist
      # in-sandbox → the MCP bridge never started → 0 mcp__fleet__* tools → ALL pods blind
      # (data-plane dead, proven arch+gatekeeper+consultants). The config must carry the sandbox path
      # (`sandbox_home`), while the bridge's COPY targets the host pod_dir. valid_profile =
      # containment bwrap → sandbox_home = /home/.pod. No static "env" key in the spec: the per-pod
      # socket (LCARS_FLEET_MCP_SOCKET) is injected PER-POD by pod.ex (build_fleet_mcp_entry) from
      # the socket provisioner (stub in test).
      Application.put_env(:fleet_spawner, :mcp_server_spec, %{
        "command" => "bash",
        "args" => ["-c", "exec python3 {{BRIDGE}} 2>>{{BRIDGE_LOG}}"]
      })

      on_exit(fn -> Application.delete_env(:fleet_spawner, :mcp_server_spec) end)

      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-mcp-ns-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "issue-1"))
      assert_receive {:launch_called, _args, _env}, 2_000

      %{pod_dir: pod_dir} = GenServer.call(pid, :info)
      config = Path.join(pod_dir, ".mcp-fleet.json") |> File.read!() |> Jason.decode!()
      [_, cmd] = get_in(config, ["mcpServers", "fleet", "args"])

      assert cmd =~ "/home/.pod/.lcars/fleet_mcp_bridge.py"
      assert cmd =~ "/home/.pod/.lcars/fleet_mcp_bridge.log"
      # NEVER the host pod_dir (invisible in-sandbox → that was THE bug).
      refute cmd =~ pod_dir

      # R9 — the MCP server env carries ONLY the per-pod socket (host path returned by the stub
      # provisioner, contains the pod_id) as `LCARS_FLEET_MCP_SOCKET`: identity = the channel/the
      # socket, not a secret on the wire → no `LCARS_POD_ID` (removed, the bridge does not read
      # it), no `LCARS_POD_CAPABILITY`, no `LCARS_FLEET_MCP_URL` (HTTP removed).
      env = get_in(config, ["mcpServers", "fleet", "env"])
      assert env["LCARS_FLEET_MCP_SOCKET"] =~ pod_id
      refute Map.has_key?(env, "LCARS_POD_ID")
      refute Map.has_key?(env, "LCARS_POD_CAPABILITY")
      refute Map.has_key?(env, "LCARS_FLEET_MCP_URL")
    end
  end

  describe "mundo invocado — e2e integration (#1 creds-inject + cwd + doc-mount in one spawn)" do
    test "project pod: bind auth + cwd=workspace + code & doc cloned",
         %{tmp_dir: tmp_dir} do
      # per-human creds fixture (Fleet.Credentials.Gate.validate reads this claudeDir)
      fake_claude = Path.join(tmp_dir, "fake-claude")
      File.mkdir_p!(fake_claude)

      File.write!(
        Path.join(fake_claude, ".credentials.json"),
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-mundo-XYZ",
            "expiresAt" => 99_999_999_999_999,
            "refreshToken" => "rt",
            "scopes" => ["user:inference", "user:sessions:claude_code"],
            "subscriptionType" => "max"
          }
        })
      )

      # claude_dir override → Fleet.Credentials.Gate.validate reads this claudeDir (scope/plan validation). Mode = bind.
      Application.put_env(:fleet_spawner, :claude_dir, fake_claude)
      on_exit(fn -> Application.delete_env(:fleet_spawner, :claude_dir) end)

      # source repo with a code branch (main) + a doc branch (work/ops)
      src = source_repo_with_doc(Path.join(tmp_dir, "proj-src"))

      base = valid_profile()

      profile = %{
        base
        | spec:
            base.spec
            |> Map.put("project", %{
              "repo_path" => src,
              "base_branch" => "main",
              "work_branch" => "work/ops"
            })
      }

      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-mundo-#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        spawn_via_supervisor(%{
          cap_profile: profile,
          issue_id: "t-1",
          pod_id: pod_id,
          opts: [repo_id: @test_repo_id]
        })

      assert_receive {:launch_called, _args, env}, 3_000

      # #1 — bind mode (token_arg removed): LCARS_AUTH_MODE=bind, no cleartext token in the env
      assert env["LCARS_AUTH_MODE"] == "bind"
      refute Map.has_key?(env, "LCARS_ANTHROPIC_AUTH_TOKEN")

      # cwd → the CODE branch (workspace)
      pod_dir = env["HOME"]

      # #monde-propre Stage B: INTRA-POD cwd relocated (the real pod_dir hidden behind /home/.pod).
      # Legacy project-without-rc_name → the relocated workspace. (An rc_name worker would see /home/<project>.)
      assert env["LCARS_POD_CWD"] == "/home/.pod/workspace"

      # doc-mount: code branch + doc branch cloned side by side in the pod
      assert File.exists?(Path.join([pod_dir, "workspace", "src.txt"]))
      assert File.exists?(Path.join([pod_dir, "work", "BACKLOG.md"]))

      # P2: composed CLAUDE.md present AT THE CWD ROOT (workspace), not only at the pod_dir
      assert File.exists?(Path.join([pod_dir, "workspace", "CLAUDE.md"]))

      # O5 (Brick 5): the role's git identity is NOT set by a mutable `git config` in the
      # workspace (F-01 falsifiable) — it is injected as env at launch (bwrap_launch.sh:
      # GIT_AUTHOR_*/GIT_COMMITTER_* + GIT_CONFIG_GLOBAL=/dev/null), not observable from this stub
      # backend. The F-01 enforcement (gate at push) is covered by deliverable_gate_test.exs +
      # executor_post_extract_test.exs (git_native usurpation case). So no assertion on the local
      # git config here.
    end

    test "project injected by the BRIEF (opts[:project]) — no need for the static cap_profile",
         %{tmp_dir: tmp_dir} do
      src = source_repo_with_doc(Path.join(tmp_dir, "brief-src"))

      # cap_profile WITHOUT project (project absent); the brief injects it via opts.
      profile = valid_profile()

      StubBackend.set_reply(interactive_reply())
      pod_id = "pod-brief-#{System.unique_integer([:positive])}"

      args = %{
        cap_profile: profile,
        issue_id: "t-1",
        pod_id: pod_id,
        opts: [
          project: %{"repo_path" => src, "base_branch" => "main", "work_branch" => "work/ops"},
          repo_id: @test_repo_id
        ]
      }

      {:ok, _pid} = spawn_via_supervisor(args)

      assert_receive {:launch_called, _args, env}, 3_000
      pod_dir = env["HOME"]

      # the brief's project is cloned (code + doc) + cwd set, without any project in the catalog
      # #monde-propre Stage B: INTRA-POD cwd relocated (the real pod_dir hidden behind /home/.pod).
      # Legacy project-without-rc_name → the relocated workspace. (An rc_name worker would see /home/<project>.)
      assert env["LCARS_POD_CWD"] == "/home/.pod/workspace"
      assert File.exists?(Path.join([pod_dir, "workspace", "src.txt"]))
      assert File.exists?(Path.join([pod_dir, "work", "BACKLOG.md"]))
    end
  end

  # BL-055 — under the DETERMINISTIC pod id, a re-dispatch lands on the same pod_id: a terminal
  # tombstone (state.json :succeeded/:released/:killed) from a previous cycle would short-circuit
  # `recover_or_init` into `:release` (mute stop, no launch) → orphan loop on the poller side.
  # `spawn_pod` calls `clear_terminal_snapshot/3` BEFORE spawn to restart FRESH. Regression
  # validated live.
  describe "clear_terminal_snapshot/3 (anti-tombstone)" do
    test "erases the TERMINAL tombstone (:succeeded) + the pod_dir → fresh re-spawn", %{
      tmp_dir: tmp
    } do
      pod_id = "issue-99-engineer"
      snap = write_snapshot!(tmp, pod_id, "succeeded")
      pod_dir = seed_pod_dir!(tmp, pod_id)

      assert :ok = Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot(pod_id, valid_profile())

      refute File.exists?(snap)
      refute File.exists?(pod_dir)
    end

    test "also erases :released and :killed (all terminal phases)", %{tmp_dir: tmp} do
      for phase <- ["released", "killed"] do
        pod_id = "issue-#{phase}-engineer"
        snap = write_snapshot!(tmp, pod_id, phase)
        pod_dir = seed_pod_dir!(tmp, pod_id)

        assert :ok = Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot(pod_id, valid_profile())
        refute File.exists?(snap)
        refute File.exists?(pod_dir)
      end
    end

    test "PRESERVES an IN-FLIGHT snapshot (:monitoring) — recovery stays intact", %{tmp_dir: tmp} do
      pod_id = "issue-77-engineer"
      snap = write_snapshot!(tmp, pod_id, "monitoring")
      pod_dir = seed_pod_dir!(tmp, pod_id)

      assert :ok = Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot(pod_id, valid_profile())

      assert File.exists?(snap)
      assert File.exists?(pod_dir)
    end

    test "idempotent no-op if no snapshot", %{tmp_dir: _tmp} do
      assert :ok =
               Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot(
                 "issue-404-engineer",
                 valid_profile()
               )
    end
  end

  describe "rm_terminal_artifacts/2,3 — path-escape guard (never rm_rf outside a root)" do
    test "REFUSES a state_dir/pod_dir OUTSIDE the roots (state_fs_root/pod_dir_root) — nothing erased",
         %{
           tmp_dir: tmp
         } do
      # A victim dir UNDER tmp but OUTSIDE the `<tmp>/state` and `<tmp>/pods` roots (simulates a
      # state_dir/pod_dir forged via an escaping pod_id that got past valid_pod_id? — defense in depth).
      victim = Path.join(tmp, "victim-outside-roots")
      File.mkdir_p!(victim)
      File.write!(Path.join(victim, "precious"), "keep")

      # The refusal is SURFACED (structured verdict), never a fake :ok that a caller would read as "erased".
      assert {:error, [error: {:state_dir, :path_escape}, error: {:pod_dir, :path_escape}]} =
               Fleet.Spawner.Pod.StateFs.rm_terminal_artifacts(victim, victim)

      assert File.exists?(Path.join(victim, "precious")),
             "rm_terminal_artifacts erased a dir OUTSIDE the root — the path-escape guard does not hold"
    end

    test "does erase a state_dir/pod_dir UNDER the root (the nominal path still works)", %{
      tmp_dir: tmp
    } do
      pod_id = "issue-guardok-engineer"
      snap = write_snapshot!(tmp, pod_id, "succeeded")
      pod_dir = seed_pod_dir!(tmp, pod_id)
      state_dir = Path.dirname(snap)

      assert :ok = Fleet.Spawner.Pod.StateFs.rm_terminal_artifacts(state_dir, pod_dir)
      refute File.exists?(state_dir)
      refute File.exists?(pod_dir)
    end

    test "B-#6 — rm_rf FAILS (I/O) → {:error} surfaced (non-fatal to the caller) AND LOUD log (surviving tombstone = loop)",
         %{tmp_dir: tmp} do
      # B-#6 fold: a `_ = File.rm_rf(dir)` swallows an erase failure. If the `state.json` SURVIVES,
      # `recover_or_init` re-reads it → `:release` → SILENT `{:stop, :normal}` → poller reclaim →
      # re-dispatch → same tombstone: INFINITE no-launch loop, masked by a fake "erased".
      # We force a DETERMINISTIC I/O failure (non-root runner): the state_dir lives under a read-only
      # parent → `rm_rf` removes the content but fails at the final `rmdir` (`{:error, :eacces, _}`).
      state_root = Path.join(tmp, "state")
      ro_parent = Path.join(state_root, "ro-parent")
      state_dir = Path.join(ro_parent, "doomed")
      File.mkdir_p!(state_dir)
      # benign pod_dir (nonexistent under its root → rm_rf {:ok, []}, no parasitic log).
      pod_root = Path.join(tmp, "pods")
      File.mkdir_p!(pod_root)
      pod_dir = Path.join(pod_root, "pod_absent")

      opts = [state_fs_root: state_root, pod_dir_root: pod_root]

      # Codex audit F-07 (2026-07-19): the read-only parent must NEVER survive this test —
      # a leftover `0500` dir under the STABLE @tmp_dir path blocks the NEXT runner's
      # `create_tmp_dir!` (rm_rf of a non-writable dir owned by another UID fails). So the restore
      # is SYNCHRONOUS (`try/after` — runs even if the body raises, unlike `on_exit`) AND
      # group-writable (`0770` — a fleet-group runner can clean it; `on_exit` keeps a belt for the
      # capture_log path). kill -9 mid-test is covered by test_helper's pre-run tmp sweep.
      File.chmod!(ro_parent, 0o500)
      on_exit(fn -> File.chmod(ro_parent, 0o770) end)

      try do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            # The verdict is SURFACED (:eacces at the final rmdir), no longer swallowed to a fake :ok —
            # the caller (clear_terminal_snapshot) can then avoid logging "erased" over a survivor.
            assert {:error, [error: {:state_dir, :eacces}]} =
                     Fleet.Spawner.Pod.StateFs.rm_terminal_artifacts(state_dir, pod_dir, opts)
          end)

        assert log =~ "tombstone erase FAILED"
        assert log =~ "state_dir"
        assert log =~ "loop the pod"
      after
        File.chmod(ro_parent, 0o770)
      end
    end
  end

  describe "maybe_recall_restore/1 — total (rescues the SeedStore.restore bang → {:error}, no crash)" do
    test "seed failing restore (raise) → {:error, {:recall_restore_failed, _}}", %{
      tmp_dir: tmp
    } do
      # SeedStore.restore/4 is a BANG: File.cp!/mkdir_p!/escape raise. We trigger the raise with a
      # seed_jsonl that EXISTS but is a DIRECTORY (File.exists? true → File.cp! raises :eisdir). An
      # uncaught raise would traverse the :projecting `with` → gen_statem crash (no tombstone).
      seed = Path.join(tmp, "seed-as-dir")
      File.mkdir_p!(seed)
      pod_dir = Path.join(tmp, "pod_recall")
      File.mkdir_p!(pod_dir)

      state = %{
        opts: [recall_seed_jsonl: seed],
        pod_dir: pod_dir,
        cap_profile: valid_profile(),
        session_id: "11111111-1111-1111-1111-111111111111"
      }

      assert {:error, {:recall_restore_failed, _}} =
               Fleet.Spawner.Pod.Scaffold.maybe_recall_restore(state)
    end

    test "absent seed → {:error, {:recall_seed_missing, _}} (already-typed path, unchanged)", %{
      tmp_dir: tmp
    } do
      missing = Path.join(tmp, "nope.jsonl")

      state = %{
        opts: [recall_seed_jsonl: missing],
        pod_dir: Path.join(tmp, "pod_x"),
        cap_profile: valid_profile(),
        session_id: "22222222-2222-2222-2222-222222222222"
      }

      assert {:error, {:recall_seed_missing, ^missing}} =
               Fleet.Spawner.Pod.Scaffold.maybe_recall_restore(state)
    end
  end

  describe "state_fs_path_for/3 — scope → FS bucket mapping (BND-106)" do
    test "ENUM scopes → expected bucket, no anomaly warning" do
      root = "/tmp/lcars-scope-test"

      for {scope, bucket} <- [
            {"one-shot", "pods"},
            {"forever", "pods"},
            {"pipe", "pipes"},
            {"run", "runs"}
          ] do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            path =
              Fleet.Spawner.Pod.Paths.state_fs_path_for(
                "pod-1",
                profile_with_scope(scope),
                state_fs_root: root
              )

            assert path == Path.join([root, bucket, "pod-1", "state.json"])
          end)

        refute log =~ "non-enum", "an enum scope (#{scope}) must NOT log an anomaly"
      end
    end

    test "BND-106: OUT-OF-enum scope → pods/ bucket BUT LOUD warning (never a silent default)" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          path =
            Fleet.Spawner.Pod.Paths.state_fs_path_for(
              "pod-2",
              profile_with_scope("banana"),
              state_fs_root: "/tmp/lcars-scope-test"
            )

          # Always bucketed pods/ (safe), but made VISIBLE: a mis-bucketed state.json is a
          # recovery/GC footgun the warden would re-scan wrong.
          assert path == Path.join(["/tmp/lcars-scope-test", "pods", "pod-2", "state.json"])
        end)

      assert log =~ "non-enum lifetime_scope"
    end
  end

  # scope_for("one-shot") == "pods" → <state_fs_root>/pods/<pod_id>/state.json (config set by setup).
  defp write_snapshot!(tmp, pod_id, phase) do
    path = Path.join([tmp, "state", "pods", pod_id, "state.json"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{"phase" => phase, "session_id" => "sid-#{pod_id}", "v" => 1})
    )

    path
  end

  defp seed_pod_dir!(tmp, pod_id) do
    dir = Path.join([tmp, "pods", "pod_#{pod_id}"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "workspace_marker"), "stale")
    dir
  end
end
