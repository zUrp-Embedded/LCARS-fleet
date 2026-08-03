defmodule Fleet.Pilot.StepDispatcherCapacityTest do
  @moduledoc """
  Regression acte4 A-11 — PRE-FLIGHT capacity gate (before the forge lock). At saturation
  (`max_pods`), taking the lock first would discover `:max_children` at spawn, then compensate
  (unlock) EVERY tick: ~4 forge writes/issue/30s polluting the timeline, and "full" tallied as an
  ERROR (poller backoff as if the forge were failing). The pre-flight gate defers WITHOUT any
  write (`{:skipped, :at_capacity}`); the residual TOCTOU stays covered by `max_children` + the
  compensation (now the rare exception).
  """
  use ExUnit.Case, async: false

  # SYNC on purpose: a describe here flips the GLOBAL `:fleet_pilot, :require_onboarded`, which
  # every dispatch path reads. Async peers running in that window were refused with
  # `{:work_dir_missing, _}` — a flake that fires by timing, not by order, so a seed does not
  # reproduce it. The restore-on-exit is correct and was never the problem: the value is right
  # after the test, and wrong DURING it for everyone else.

  alias Fleet.Pilot.StepDispatcher
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

  # Room, no live pod, and it RECORDS what the spawn was handed: the nominal materialized branch
  # asserts on the ORDER, not on a refusal.
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

  # Global room, but the ROLE's bucket is full — the ceiling `PoolSlot.allocate/3` will enforce.
  # The two pre-flights are independent: passing the global one proves nothing about the seat.
  defmodule FullRoleSpawner do
    def has_free_slot?(_role, _repo, _slot_scope), do: false
    def pod_info(_pod_id), do: {:error, :not_found}
    def spawn_pod(_p, _i, _o), do: raise("spawn_pod must NEVER be reached on a full role bucket")
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  # Same, but it RECORDS the bucket it was asked about: a pre-flight that interrogates a different
  # bucket than the wall is worse than none, so the arguments are what this pins.
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

  # Room available and no live pod: the spawn WOULD proceed — so a refusal in these tests can only
  # come from the order materialization, never from capacity.
  defmodule FreshSpawner do
    def pod_info(_pod_id), do: {:error, :not_found}

    def spawn_pod(_p, _i, _o),
      do: raise("spawn_pod must NEVER be reached: the order refused first")

    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  # Saturated + ALIVE pod: the re-brief creates no child → must NOT be gated.
  defmodule FullAliveSpawner do
    def has_capacity?, do: false
    def pod_info(_pod_id), do: {:ok, %{phase: :monitoring}}
    def spawn_pod(_p, _i, _o), do: raise("a live pod gets re-briefed, no spawn")
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  # TOCTOU: the free slot at check time is stolen before the spawn → :max_children at real spawn.
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
      # The gate the hermetic baseline keeps open (fictional repos have no work/ops on disk). Same
      # single lever as the poller's admission gate: one policy, two depths.
      Fleet.TestEnv.put_env_restoring(:fleet_pilot, :require_onboarded, true)
      :ok
    end

    test "an un-onboarded project REFUSES the dispatch — and takes no lock doing it" do
      # The refusal happens before `add_label`, which is what makes it free: no compensation, no
      # forge write, the ticket simply is not dispatched this tick. Asserting the absence of the
      # label is what pins that ORDER; asserting only the error would pass with the check anywhere.
      assert {:error, {:order_not_materialized, {:work_dir_missing, _}}} =
               Spawn.spawn_step(
                 seams(FreshSpawner),
                 "pod-x",
                 "engineer",
                 profile(),
                 "brief",
                 [],
                 42,
                 42,
                 "ctx"
               )

      refute_received {:add_label, _}
      refute_received {:remove_label, _}
    end

    test "a dispatch with NO brief refuses too — that one is a bug upstream, not a setup gap" do
      assert {:error, {:order_not_materialized, :no_brief}} =
               Spawn.spawn_step(
                 seams(FreshSpawner),
                 "pod-x",
                 "engineer",
                 profile(),
                 "",
                 [],
                 42,
                 42,
                 "ctx"
               )

      refute_received {:add_label, _}
    end
  end

  @tag :tmp_dir
  test "NOMINAL: the order is materialized, and what travels is the POINTER — not a second copy",
       %{tmp_dir: tmp} do
    # THE nominal branch, and it had NO coverage: measured before writing, zero test in the
    # dispatcher suite materializes a brief — all of them run with the work_dir absent, i.e. on the
    # DEGRADED rail. That is how the order's delivery could carry a self-referential instruction
    # ("read the pin if the file changed", which requires the pin to evaluate) for a whole chantier
    # without a test noticing.
    #
    # It needed a SEAM: `materialize/3` had `:work_root`, but the dispatcher never threaded it, so
    # the real hardcoded global root was the only reachable one. Same seam, same reason, as
    # `StepRunCompleter`'s.
    Fleet.TestEnv.put_env_restoring(:fleet_pilot, :require_onboarded, true)

    work_dir = Path.join(tmp, "lcars-test")
    File.mkdir_p!(work_dir)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

    order = "Implémente le sélecteur de pièce suivante, avec ses tests."

    assert {:ok, {:spawned, _pod, "engineer"}} =
             Spawn.spawn_step(
               seams(RecordingSpawner),
               "pod-x",
               "engineer",
               profile(),
               order,
               [repo_id: 7, work_root: tmp],
               42,
               42,
               "ctx"
             )

    assert_received {:spawn_opts, spawn_opts}
    sha = Keyword.fetch!(spawn_opts, :brief_sha)
    ref = Keyword.fetch!(spawn_opts, :brief_ref)

    # The ORDER travels through the QUEUE, and only there — measured while writing this: the
    # dispatcher's spawn_opts carry `brief_ref`/`brief_sha` but no `:brief`. The pod pulls it with
    # the MCP `get_work_item`.
    assert_received {:enqueued, "pod-x", attrs}
    payload = attrs.brief

    # The pointer, addressed by its PIN — the one thing the pod is later asked to cite.
    assert payload =~ "git -C $LCARS_PROJECT_OPS show #{sha}:#{ref}"

    # And NOT a second copy of the order. The committed doc is the single source; a payload that
    # also carried the text would make "the version to judge" ambiguous the moment the two differ.
    refute payload =~ order

    # The doc really exists at that pin, and it holds the order.
    {content, 0} = System.cmd("git", ["show", "#{sha}:#{ref}"], cd: work_dir)
    assert content =~ order
  end

  @tag :tmp_dir
  test "NOMINAL: no copy of the order text reaches the pod's spawn opts", %{tmp_dir: tmp} do
    # The wall the IPC report asked for was "default_brief/1 never contains opts[:brief]". It cannot
    # be written that way — interpolating `opts[:brief]` is that function's whole job. Measured, the
    # property is one layer up and stronger: on the step rail the dispatcher puts NO `:brief` in the
    # spawn opts at all, so `Pod.Brief.default_brief/1` has nothing to interpolate and the pod's
    # `issues/<id>.md` cannot hold a copy. The order reaches the pod through the queue, as a pointer.
    #
    # This is what makes the committed doc the single source in fact and not only in intent: there
    # is no second place for the text to be.
    Fleet.TestEnv.put_env_restoring(:fleet_pilot, :require_onboarded, true)

    work_dir = Path.join(tmp, "lcars-test")
    File.mkdir_p!(work_dir)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

    order = "Corrige le placement latéral des pièces."

    assert {:ok, _} =
             Spawn.spawn_step(
               seams(RecordingSpawner),
               "pod-x",
               "engineer",
               profile(),
               order,
               [repo_id: 7, work_root: tmp],
               42,
               42,
               "ctx"
             )

    assert_received {:spawn_opts, spawn_opts}

    refute Keyword.has_key?(spawn_opts, :brief),
           "the dispatcher put the order in the spawn opts — the pod would write it to " <>
             "issues/<id>.md, a second copy of a text whose single source is the committed doc"

    assert_received {:enqueued, "pod-x", attrs}
    refute attrs.brief =~ order
  end

  test "a role DECLARING no forge identity is not a provisioning hole — no as_role, no warning" do
    # `forge_identity: false` had no runtime reader: only `mix lcars.contracts.check` consulted it.
    # So the dispatch could not tell "declares none" from "token MISSING" and warned identically —
    # telling the operator to check a provisioning that works as declared. That made the flag
    # unusable for any role the dispatch reaches, which is why choosing it was never a real choice.
    no_identity =
      put_in(profile().metadata, Map.put(profile().metadata, "forge_identity", false))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, {:spawned, _, _}} =
                 Spawn.spawn_step(
                   seams(RecordingSpawner),
                   "pod-x",
                   "engineer",
                   no_identity,
                   "brief",
                   [repo_id: 7],
                   42,
                   42,
                   "ctx"
                 )
      end)

    refute log =~ "no forge token"
    refute log =~ "role account/token provisioning"
  end

  test "a role that DOES hold an identity still warns when its token is missing" do
    # The other half, and the reason the warning exists: an absent token for a role that claims one
    # IS a provisioning defect, and its only forge-visible symptom is "the worker never shows up on
    # the ticket" — measured twice, one diagnosis session each.
    #
    # `scribe` and not `engineer`: the test fixture holds a token for engineer, so it would take the
    # succeeding path and the assertion would measure nothing. (Checked rather than assumed — the
    # first version of this test asserted on engineer and passed nothing.)
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, {:spawned, _, _}} =
                 Spawn.spawn_step(
                   seams(RecordingSpawner),
                   "pod-x",
                   "scribe",
                   profile(),
                   "brief",
                   [repo_id: 7],
                   42,
                   42,
                   "ctx"
                 )
      end)

    assert log =~ "no forge token"
  end

  test "role bucket FULL + fresh spawn → {:skipped, :role_at_capacity}, NO forge write (no lock)" do
    # The wall is `PoolSlot.allocate/3`, INSIDE the spawn — i.e. past the forge lock. Without this
    # pre-flight, saturation of one role means a lock/unlock cycle per issue per tick and "full"
    # tallied as an error. `has_free_slot?/3` had existed since the seat work and had NO caller:
    # the pre-flight was written and never wired.
    assert {:skipped, :role_at_capacity} =
             Spawn.spawn_step(
               seams(FullRoleSpawner),
               "pod-x",
               "engineer",
               profile(),
               "brief",
               [repo_id: 7],
               42,
               42,
               "ctx"
             )

    refute_received {:add_label, _}
    refute_received {:remove_label, _}
  end

  test "the pre-flight asks the SAME bucket the wall will refuse on" do
    Spawn.spawn_step(
      seams(BucketRecordingSpawner),
      "pod-x",
      "engineer",
      profile(),
      "brief",
      [repo_id: 7],
      42,
      42,
      "ctx"
    )

    # `(role, repo_id, slot_scope)` — the three arguments `PoolSlot.allocate/3` takes. The scope
    # comes from the cap-profile's own accessor (pipe ⟹ project), never from a second opinion.
    assert_received {:bucket, "engineer", 7, "project"}
  end

  test "a LIVE pod is not gated by the role bucket — re-briefing it starts no child" do
    # Load-bearing: gating a live pipe pod at saturation would starve the very pipe holding the
    # seat. The spawner says the bucket is full and the dispatch goes through anyway.
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
               "pod-x",
               "engineer",
               profile(),
               "brief",
               [repo_id: 7],
               42,
               42,
               "ctx"
             )
           )
  end

  test "saturation reached AT THE WALL is a WAIT, not an error (the residual TOCTOU)" do
    # The pre-flight said room, the last seat went between the check and the spawn. The
    # compensation undoes everything (lock removed, pod killed) — so NOTHING started, which is the
    # definition of a skip. Returned as an error, this ticket was tallied as a failure AND left
    # unlabelled (an error says nothing about what a ticket waits for), so it was silently not
    # dispatched. The two saturation paths now say the same thing.
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
               "pod-x",
               "engineer",
               profile(),
               "brief",
               [repo_id: 7],
               42,
               42,
               "ctx"
             )

    # The lock WAS taken (we got past the pre-flight) and the compensation removed it.
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
               "pod-x",
               "engineer",
               profile(),
               "brief",
               [repo_id: 7],
               42,
               42,
               "ctx"
             )
  end

  test "saturated + ALIVE pod → the re-brief PROCEEDS (a live pipe creates no child: not starved)" do
    assert {:ok, {:spawned, "pod-alive", "engineer"}} =
             Spawn.spawn_step(
               seams(FullAliveSpawner),
               "pod-alive",
               "engineer",
               profile(),
               "brief",
               [],
               42,
               42,
               "ctx"
             )

    # the lock IS taken (the pod is working the issue), no kill/compensation
    assert_received {:add_label, "lcars-in-flight"}
    refute_received {:remove_label, _}
  end

  test "TOCTOU (slot stolen between check and spawn) → :max_children at spawn + compensation intact" do
    assert {:error, :max_children} =
             Spawn.spawn_step(
               seams(ToctouSpawner),
               "pod-t",
               "engineer",
               profile(),
               "brief",
               [],
               42,
               42,
               "ctx"
             )

    # the lock was taken THEN compensated (remove_label) — the TOCTOU net holds
    assert_received {:add_label, "lcars-in-flight"}
    assert_received {:remove_label, "lcars-in-flight"}
  end
end
