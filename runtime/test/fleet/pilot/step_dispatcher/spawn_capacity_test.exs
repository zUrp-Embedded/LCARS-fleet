defmodule Fleet.Pilot.StepDispatcher.SpawnCapacityTest do
  @moduledoc """
  Checks capacity preflight, materialized orders and compensation calls.
  Role-bucket saturation is a skip; global :max_children remains an error.
  Spies observe calls and payloads, not persisted forge state or actual pod cleanup.
  """
  use ExUnit.Case, async: false

  # Serialized because these tests change global :pilot_require_onboarded during dispatch.

  alias Fleet.Pilot.StepDispatcher.Spawn
  alias Fleet.Pilot.StubTaskQueue

  defmodule CaptureForge do
    def add_label(_repo, _n, label, _opts) do
      send(self(), {:add_label, label})
      {:ok, :added}
    end

    def remove_label(_repo, _n, label, _opts) do
      send(self(), {:remove_label, label})
      {:ok, :removed}
    end

    def start_stopwatch(_repo, _n, _opts), do: :ok
    def stop_stopwatch(_repo, _n, _opts), do: :ok
    def get_route(_repo, _n, opts), do: Keyword.get(opts, :_test_route, :none)
  end

  defmodule StubLoader do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{},
           spec: %{"brief_kind" => "worker", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}
  end

  # Capture fresh-spawn options on the materialized-order path.
  defmodule RecordingSpawner do
    def has_capacity?, do: true
    def has_free_slot?(_role, _repo, _scope), do: true
    def pod_info(_pod_id), do: {:error, :not_found}

    def spawn_pod(_p, _i, opts) do
      send(self(), {:spawn_opts, opts})
      {:ok, self()}
    end

    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  # Full role bucket; this fixture does not model a separate global preflight.
  defmodule FullRoleSpawner do
    def has_free_slot?(_role, _repo, _slot_scope), do: false
    def pod_info(_pod_id), do: {:error, :not_found}
    def spawn_pod(_p, _i, _o), do: raise("spawn_pod must NEVER be reached on a full role bucket")
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  # Observe the exact bucket identity used by preflight.
  defmodule BucketRecordingSpawner do
    def has_free_slot?(role, repo, slot_scope) do
      send(self(), {:bucket, role, repo, slot_scope})
      false
    end

    def pod_info(_pod_id), do: {:error, :not_found}
    def spawn_pod(_p, _i, _o), do: raise("unreachable")
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  # Missing capacity capability permits reaching the materialization refusal.
  defmodule FreshSpawner do
    def pod_info(_pod_id), do: {:error, :not_found}

    def spawn_pod(_p, _i, _o),
      do: raise("spawn_pod must NEVER be reached: the order refused first")

    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  # Live pod fixture; its legacy has_capacity?/0 is not read by Spawn.
  defmodule FullAliveSpawner do
    def has_capacity?, do: false
    def pod_info(_pod_id), do: {:ok, %{phase: :monitoring}}
    def spawn_pod(_p, _i, _o), do: raise("a live pod gets re-briefed, no spawn")
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  # Missing role preflight capability allows reaching the injected global max_children error.
  defmodule ToctouSpawner do
    def pod_info(_pod_id), do: {:error, :not_found}
    def spawn_pod(_p, _i, _o), do: {:error, :max_children}
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  defp profile do
    {:ok, p} = StubLoader.load("engineer")
    p
  end

  defp seams(spawner) do
    %Spawn.Seams{
      forge: CaptureForge,
      spawner: spawner,
      task_queue: StubTaskQueue,
      repo: "lordzurp/lcars-test",
      forge_opts: [],
      wake_recovery: fn _pod_id, _spawn_fn, _opts -> :ok end
    }
  end

  describe "order materialization — the delivery breaks, it does not degrade" do
    setup do
      # Enable the shared onboarding policy normally disabled for fictional test repos.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_require_onboarded, true)
      :ok
    end

    test "an un-onboarded project REFUSES the dispatch — and takes no lock doing it" do
      # Absence of label calls proves refusal precedes locking; error-only assertions would not.
      assert {:error, {:order_not_materialized, {:work_dir_missing, _}}} =
               Spawn.spawn_step(
                 seams(FreshSpawner),
                 %Spawn.Order{
                   pod_id: "pod-x",
                   role: "engineer",
                   profile: profile(),
                   brief: "brief",
                   spawn_opts: [],
                   lock_target: 42,
                   issue_number: 42,
                   log_ctx: "ctx"
                 }
               )

      refute_received {:add_label, _}
      refute_received {:remove_label, _}
    end

    test "a dispatch with NO brief refuses too — that one is a bug upstream, not a setup gap" do
      assert {:error, {:order_not_materialized, :no_brief}} =
               Spawn.spawn_step(
                 seams(FreshSpawner),
                 %Spawn.Order{
                   pod_id: "pod-x",
                   role: "engineer",
                   profile: profile(),
                   brief: "",
                   spawn_opts: [],
                   lock_target: 42,
                   issue_number: 42,
                   log_ctx: "ctx"
                 }
               )

      refute_received {:add_label, _}
    end
  end

  @tag :tmp_dir
  test "NOMINAL: the order is materialized, and what travels is its CONTENT at the pinned version",
       %{tmp_dir: tmp} do
    # Inject an existing ops repository to exercise actual Git materialization, not missing-worktree fallback.
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_require_onboarded, true)

    work_dir = Path.join(tmp, "lcars-test")
    File.mkdir_p!(work_dir)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

    order = "Implémente le sélecteur de pièce suivante, avec ses tests."

    assert {:ok, {:spawned, _pod, "engineer"}} =
             Spawn.spawn_step(
               seams(RecordingSpawner),
               %Spawn.Order{
                 pod_id: "pod-x",
                 role: "engineer",
                 profile: profile(),
                 brief: order,
                 spawn_opts: [repo_id: 7, ops_root: tmp],
                 lock_target: 42,
                 issue_number: 42,
                 log_ctx: "ctx"
               }
             )

    assert_received {:spawn_opts, spawn_opts}
    sha = Keyword.fetch!(spawn_opts, :brief_sha)
    ref = Keyword.fetch!(spawn_opts, :brief_ref)

    # Queue carries content; spawn options carry the pin.
    assert_received {:enqueued, "pod-x", attrs}
    payload = attrs.brief

    # Deliver committed content through the queue without an instruction to mount the entire ops tree.
    assert payload =~ order

    # Runtime provenance retains the pin; the pod is not asked to cite it.
    assert is_binary(sha) and byte_size(sha) >= 7
    assert Fleet.Layout.valid_brief_ref?(ref)

    # Do not reintroduce an ops-tree mount through the payload's instructions.
    refute payload =~ "LCARS_PROJECT_OPS"
    refute payload =~ "git -C"

    # Verify content at the returned local Git pin, without claiming it was pushed remotely.
    {content, 0} = System.cmd("git", ["show", "#{sha}:#{ref}"], cd: work_dir)
    assert content =~ order
  end

  @tag :tmp_dir
  test "NOMINAL: no copy of the order text reaches the pod's spawn opts", %{tmp_dir: tmp} do
    # This fixture starts without :brief and proves Spawn does not add it.
    # The following fixture starts with :brief to test removing the caller's copy.
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_require_onboarded, true)

    work_dir = Path.join(tmp, "lcars-test")
    File.mkdir_p!(work_dir)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

    order = "Corrige le placement latéral des pièces."

    assert {:ok, _} =
             Spawn.spawn_step(
               seams(RecordingSpawner),
               %Spawn.Order{
                 pod_id: "pod-x",
                 role: "engineer",
                 profile: profile(),
                 brief: order,
                 spawn_opts: [repo_id: 7, ops_root: tmp],
                 lock_target: 42,
                 issue_number: 42,
                 log_ctx: "ctx"
               }
             )

    assert_received {:spawn_opts, spawn_opts}

    refute Keyword.has_key?(spawn_opts, :brief),
           "the dispatcher put the order in the spawn opts — the pod would write it to " <>
             "issues/<id>.md, a second copy of a text whose single source is the committed doc"

    # Queue content remains available when the spawn copy is absent.
    assert_received {:enqueued, "pod-x", attrs}
    assert attrs.brief =~ order
  end

  @tag :tmp_dir
  test "NOMINAL: the copy the DISPATCHER puts in the opts is dropped once the pointer exists",
       %{tmp_dir: tmp} do
    # Start with the real caller's inline copy to prove it is removed after materialization.
    # A live pod would otherwise retain its initial file while queued rework changes.
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_require_onboarded, true)

    work_dir = Path.join(tmp, "lcars-test")
    File.mkdir_p!(work_dir)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

    order = "Corrige le placement latéral des pièces."

    assert {:ok, _} =
             Spawn.spawn_step(
               seams(RecordingSpawner),
               %Spawn.Order{
                 pod_id: "pod-x",
                 role: "engineer",
                 profile: profile(),
                 brief: order,
                 spawn_opts: [repo_id: 7, ops_root: tmp, brief: order],
                 lock_target: 42,
                 issue_number: 42,
                 log_ctx: "ctx"
               }
             )

    assert_received {:spawn_opts, spawn_opts}

    refute Keyword.has_key?(spawn_opts, :brief),
           "the caller's copy survived materialisation — the pod would write a text that never " <>
             "gets rewritten next to a pointer that keeps moving"

    # The address remains in spawn metadata.
    assert is_binary(spawn_opts[:brief_ref])
    assert is_binary(spawn_opts[:brief_sha])
  end

  @tag :tmp_dir
  test "DEGRADED (no pointer): the copy STAYS — there is no address to name in its place",
       %{tmp_dir: tmp} do
    # With onboarding checks disabled and no committed replacement, retain the caller's inline copy.
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_require_onboarded, false)

    order = "Ordre inline, rail degrade."

    assert {:ok, _} =
             Spawn.spawn_step(
               seams(RecordingSpawner),
               %Spawn.Order{
                 pod_id: "pod-y",
                 role: "engineer",
                 profile: profile(),
                 brief: order,
                 spawn_opts: [repo_id: 7, ops_root: Path.join(tmp, "absent"), brief: order],
                 lock_target: 43,
                 issue_number: 43,
                 log_ctx: "ctx"
               }
             )

    assert_received {:spawn_opts, spawn_opts}
    assert spawn_opts[:brief] == order
    refute Keyword.has_key?(spawn_opts, :brief_ref)
  end

  test "a role DECLARING no forge identity is not a provisioning hole — no as_role, no warning" do
    # Declaring no forge identity is distinct from missing a required token; it should not warn.
    no_identity =
      put_in(profile().metadata, Map.put(profile().metadata, "forge_identity", false))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, {:spawned, _, _}} =
                 Spawn.spawn_step(
                   seams(RecordingSpawner),
                   %Spawn.Order{
                     pod_id: "pod-x",
                     role: "engineer",
                     profile: no_identity,
                     brief: "brief",
                     spawn_opts: [repo_id: 7],
                     lock_target: 42,
                     issue_number: 42,
                     log_ctx: "ctx"
                   }
                 )
      end)

    refute log =~ "no forge token"
    refute log =~ "role account/token provisioning"
  end

  test "a role that DOES hold an identity still warns when its token is missing" do
    # Use scribe because engineer has a fixture token; otherwise this would test the success path.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, {:spawned, _, _}} =
                 Spawn.spawn_step(
                   seams(RecordingSpawner),
                   %Spawn.Order{
                     pod_id: "pod-x",
                     role: "scribe",
                     profile: profile(),
                     brief: "brief",
                     spawn_opts: [repo_id: 7],
                     lock_target: 42,
                     issue_number: 42,
                     log_ctx: "ctx"
                   }
                 )
      end)

    assert log =~ "no forge token"
  end

  test "role bucket FULL + fresh spawn → {:skipped, :role_at_capacity}, NO forge write (no lock)" do
    # Preflight must avoid the forge lock/unlock churn of discovering saturation only during spawn.
    assert {:skipped, :role_at_capacity} =
             Spawn.spawn_step(
               seams(FullRoleSpawner),
               %Spawn.Order{
                 pod_id: "pod-x",
                 role: "engineer",
                 profile: profile(),
                 brief: "brief",
                 spawn_opts: [repo_id: 7],
                 lock_target: 42,
                 issue_number: 42,
                 log_ctx: "ctx"
               }
             )

    refute_received {:add_label, _}
    refute_received {:remove_label, _}
  end

  test "the pre-flight asks the SAME bucket the wall will refuse on" do
    Spawn.spawn_step(
      seams(BucketRecordingSpawner),
      %Spawn.Order{
        pod_id: "pod-x",
        role: "engineer",
        profile: profile(),
        brief: "brief",
        spawn_opts: [repo_id: 7],
        lock_target: 42,
        issue_number: 42,
        log_ctx: "ctx"
      }
    )

    # Match allocation's role/repo/scope bucket; scope comes from the profile accessor.
    assert_received {:bucket, "engineer", 7, "project"}
  end

  test "a LIVE pod is not gated by the role bucket — re-briefing it starts no child" do
    # Reuse must bypass a full role bucket or it could starve the pod already holding the slot.
    defmodule LivePodFullRoleSpawner do
      def has_free_slot?(_role, _repo, _scope), do: false
      def pod_info(_pod_id), do: {:ok, %{phase: :monitoring}}
      def wake_pod(_pod_id), do: :ok
      def kill_pod(_pod_id), do: :ok
    end

    refute match?(
             {:skipped, :role_at_capacity},
             Spawn.spawn_step(
               seams(LivePodFullRoleSpawner),
               %Spawn.Order{
                 pod_id: "pod-x",
                 role: "engineer",
                 profile: profile(),
                 brief: "brief",
                 spawn_opts: [repo_id: 7],
                 lock_target: 42,
                 issue_number: 42,
                 log_ctx: "ctx"
               }
             )
           )
  end

  test "saturation reached AT THE WALL is a WAIT, not an error (the residual TOCTOU)" do
    # Optimistic preflight followed by role-capacity refusal must return a skip after compensation attempts.
    defmodule WallRefusesSpawner do
      # The pre-flight is optimistic — this is the TOCTOU, so it must answer yes.
      def has_free_slot?(_role, _repo, _scope), do: true
      def pod_info(_pod_id), do: {:error, :not_found}
      def spawn_pod(_p, _i, _o), do: {:error, :role_at_capacity}
      def wake_pod(_pod_id), do: :ok
      def kill_pod(_pod_id), do: :ok
    end

    assert {:skipped, :role_at_capacity} =
             Spawn.spawn_step(
               seams(WallRefusesSpawner),
               %Spawn.Order{
                 pod_id: "pod-x",
                 role: "engineer",
                 profile: profile(),
                 brief: "brief",
                 spawn_opts: [repo_id: 7],
                 lock_target: 42,
                 issue_number: 42,
                 log_ctx: "ctx"
               }
             )

    # Observe both label calls; these spies do not prove their persistence.
    assert_received {:add_label, "lcars-in-flight"}
    assert_received {:remove_label, "lcars-in-flight"}
  end

  test "a real post-lock failure stays an ERROR — only saturation converts" do
    defmodule BrokenSpawner do
      def has_free_slot?(_role, _repo, _scope), do: true
      def pod_info(_pod_id), do: {:error, :not_found}
      def spawn_pod(_p, _i, _o), do: {:error, :launch_failed}
      def wake_pod(_pod_id), do: :ok
      def kill_pod(_pod_id), do: :ok
    end

    assert {:error, :launch_failed} =
             Spawn.spawn_step(
               seams(BrokenSpawner),
               %Spawn.Order{
                 pod_id: "pod-x",
                 role: "engineer",
                 profile: profile(),
                 brief: "brief",
                 spawn_opts: [repo_id: 7],
                 lock_target: 42,
                 issue_number: 42,
                 log_ctx: "ctx"
               }
             )
  end

  test "saturated + ALIVE pod → the re-brief PROCEEDS (a live pipe creates no child: not starved)" do
    assert {:ok, {:spawned, "pod-alive", "engineer"}} =
             Spawn.spawn_step(
               seams(FullAliveSpawner),
               %Spawn.Order{
                 pod_id: "pod-alive",
                 role: "engineer",
                 profile: profile(),
                 brief: "brief",
                 spawn_opts: [],
                 lock_target: 42,
                 issue_number: 42,
                 log_ctx: "ctx"
               }
             )

    # Reuse reaches label addition without removal; wake receipt is not observed.
    assert_received {:add_label, "lcars-in-flight"}
    refute_received {:remove_label, _}
  end

  test "TOCTOU (slot stolen between check and spawn) → :max_children at spawn + compensation intact" do
    assert {:error, :max_children} =
             Spawn.spawn_step(
               seams(ToctouSpawner),
               %Spawn.Order{
                 pod_id: "pod-t",
                 role: "engineer",
                 profile: profile(),
                 brief: "brief",
                 spawn_opts: [],
                 lock_target: 42,
                 issue_number: 42,
                 log_ctx: "ctx"
               }
             )

    # Observe label addition/removal on global capacity failure; result stays an error.
    assert_received {:add_label, "lcars-in-flight"}
    assert_received {:remove_label, "lcars-in-flight"}
  end
end
