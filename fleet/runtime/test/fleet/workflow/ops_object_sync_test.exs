defmodule Fleet.Workflow.OpsObjectSyncTest do
  @moduledoc """
  CI-11 — the work/ops write serializer. `OpsObject` is the untouched engine; this GenServer is the
  gate that funnels concurrent git transactions (briefs from several MCP connections + the poller,
  provenance from up to 16 completion Tasks) ONE at a time onto the shared worktree, against the
  `.git/index.lock` + moving-HEAD race. Real temp git repo (`git init`) — the gate commits for real,
  through an ISOLATED instance the setup starts: the app's always-on singleton is OFF in `:test` for
  hermeticity (see the setup note), so each test drives its own named server via `commit_object/5`.
  """
  # async: false — the bypass-visibility tests mutate the GLOBAL :start_ops_object_sync
  # knob (put_env_restoring); a concurrent suite hitting the fallback would log-bleed.
  use ExUnit.Case, async: false

  alias Fleet.Workflow.OpsObjectSync

  @moduletag :tmp_dir

  # ISOLATED instance (unique name per test): the global singleton is OFF in :test (hermeticity), so we
  # drive the explicit-server `commit_object/5` on our own process — the serialized path proven without
  # touching (or being touched by) any other async test.
  setup do
    name = :"ops_sync_#{System.unique_integer([:positive])}"
    pid = start_supervised!({OpsObjectSync, name: name})
    {:ok, server: pid, name: name}
  end

  defp git_init(dir) do
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    :ok
  end

  defp commit_count(dir) do
    {out, 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: dir)
    String.trim(out)
  end

  test "delegates to OpsObject: commits the object, returns the introducing COMMIT sha",
       %{tmp_dir: tmp, server: srv} do
    git_init(tmp)

    assert {:ok, sha} =
             OpsObjectSync.commit_object(srv, tmp, "briefs/x.md", "content\n", label: "test")

    assert File.read!(Path.join(tmp, "briefs/x.md")) == "content\n"
    assert sha =~ ~r/\A[0-9a-f]{40}\z/
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
    assert sha == String.trim(head)
  end

  describe "call timeout — read-only readback confirms a landed transaction (no retry, no race)" do
    setup do
      Fleet.TestEnv.put_env_restoring(:fleet_workflow, :ops_sync_call_timeout, 30)
      :ok
    end

    # A process that receives the $gen_call but NEVER replies → the caller's GenServer.call times out,
    # exactly like a server still grinding through a composed-budget queue.
    defp dead_air_server do
      spawn(fn -> Process.sleep(:infinity) end)
    end

    test "timeout but the object IS already committed → {:ok, sha} via readback", %{tmp_dir: tmp} do
      git_init(tmp)

      # Pre-commit directly (as if the server had landed our transaction just before we timed out).
      {:ok, sha} =
        Fleet.Workflow.OpsObject.commit_object(tmp, "briefs/x.md", "landed\n", label: "t")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, ^sha} =
                   OpsObjectSync.commit_object(dead_air_server(), tmp, "briefs/x.md", "landed\n",
                     label: "t"
                   )
        end)

      assert log =~ "confirmed by read-only readback"
      assert commit_count(tmp) == "1"
    end

    test "timeout and the object is NOT committed → {:error, {:ops_sync_timeout, _}}", %{
      tmp_dir: tmp
    } do
      git_init(tmp)

      assert {:error, {:ops_sync_timeout, _}} =
               OpsObjectSync.commit_object(dead_air_server(), tmp, "briefs/y.md", "never\n",
                 label: "t"
               )

      refute File.exists?(Path.join(tmp, "briefs/y.md"))
    end
  end

  describe "drain-confirm — a negative immediate readback is never the last word" do
    setup do
      Fleet.TestEnv.put_env_restoring(:fleet_workflow, :ops_sync_call_timeout, 30)

      # The drain must outlive the injected 80ms engine (its own knob; prod default = a full call budget).
      Fleet.TestEnv.put_env_restoring(:fleet_workflow, :ops_sync_drain_timeout, 1_000)
      :ok
    end

    test "commit QUEUED/mid-flight at timeout → drain-confirm waits it out → {:ok, sha}, no false failure",
         %{tmp_dir: tmp} do
      git_init(tmp)

      # Engine slowed beyond the 30ms call budget: the caller times out MID-WORK, the server keeps
      # going and lands the commit — the exact window where the old single immediate readback
      # answered :not_committed and the caller wrongly reported failure while the effect landed
      # behind its back (the deceptive case).
      slow_engine = fn work_dir, ref, content, opts ->
        Process.sleep(80)
        Fleet.Workflow.OpsObject.commit_object(work_dir, ref, content, opts)
      end

      name = :"ops_sync_slow_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec({OpsObjectSync, name: name, commit_fun: slow_engine}, id: name)
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, sha} =
                   OpsObjectSync.commit_object(name, tmp, "briefs/late.md", "lands late\n",
                     label: "t"
                   )

          assert is_binary(sha)
        end)

      assert log =~ "LANDED during drain-confirm"
      assert File.exists?(Path.join(tmp, "briefs/late.md"))
      assert commit_count(tmp) == "1"
    end

    test "commit RAN and FAILED server-side → drain-confirm makes the failure DEFINITIVE, not ambiguous",
         %{tmp_dir: tmp} do
      git_init(tmp)

      # Slow AND failing engine: the caller times out, the server finishes with an error (whose
      # reply is lost with the abandoned call). After the drain the readback is definitive.
      failing_engine = fn _w, _r, _c, _o ->
        Process.sleep(80)
        {:error, :engine_says_no}
      end

      name = :"ops_sync_fail_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec({OpsObjectSync, name: name, commit_fun: failing_engine}, id: name)
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:ops_sync_timeout, _}} =
                   OpsObjectSync.commit_object(name, tmp, "briefs/no.md", "never\n", label: "t")
        end)

      assert log =~ "definitive, not ambiguous"
    end

    test "serializer DEAD (:noproc exit) → typed :ops_sync_unavailable, never a caller crash", %{
      tmp_dir: tmp
    } do
      git_init(tmp)
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

      # The old catch handled ONLY {:timeout, _}: a :noproc exit PROPAGATED and crashed the
      # best-effort provenance caller for a serializer hiccup.
      assert {:error, {:ops_sync_unavailable, _}} =
               OpsObjectSync.commit_object(dead, tmp, "briefs/z.md", "x\n", label: "t")
    end
  end

  test "idempotent through the gate: same path + same content → same identity, no new commit",
       %{tmp_dir: tmp, server: srv} do
    git_init(tmp)

    assert {:ok, sha1} =
             OpsObjectSync.commit_object(srv, tmp, "briefs/x.md", "same\n", label: "test")

    assert {:ok, sha2} =
             OpsObjectSync.commit_object(srv, tmp, "briefs/x.md", "same\n", label: "test")

    assert sha1 == sha2
    assert commit_count(tmp) == "1"
  end

  test "fallback: an unregistered server routes DIRECT to OpsObject (still commits)", %{
    tmp_dir: tmp
  } do
    git_init(tmp)
    # No process registered under this name → whereis nil → direct OpsObject call.
    assert {:ok, sha} =
             OpsObjectSync.commit_object(:ops_sync_absent, tmp, "briefs/y.md", "z\n",
               label: "test"
             )

    assert sha =~ ~r/\A[0-9a-f]{40}\z/
  end

  test "SERIALIZES concurrent commits to the SAME work_dir → all succeed, no index.lock corruption (CI-11)",
       %{tmp_dir: tmp, server: srv} do
    git_init(tmp)
    n = 12

    # N concurrent writers of DISTINCT objects into the ONE repo. Direct on the worktree these race on
    # `.git/index.lock` (some `git commit` fail); through the singleton they queue → every one commits.
    results =
      1..n
      |> Task.async_stream(
        fn i ->
          OpsObjectSync.commit_object(srv, tmp, "briefs/obj-#{i}.md", "content #{i}\n",
            label: "test"
          )
        end,
        max_concurrency: n,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({:ok, _sha}, &1)),
           "every serialized commit must succeed: #{inspect(results)}"

    # N distinct objects, serialized → N commits (no lost/failed write, no corrupt index).
    assert commit_count(tmp) == "#{n}"
  end

  test "the PROD-config bypass is LOUD: serializer absent while config starts it → warning per call" do
    # The optional-layer posture is documented; what could not stand is the SILENT bypass in
    # a booted daemon (restart window / crash loop): the gate's absence must be visible.
    Fleet.TestEnv.put_env_restoring(:fleet_pilot, :start_ops_object_sync, true)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        _ =
          Fleet.Workflow.OpsObjectSync.commit_object(
            :absent_serializer_name,
            "/nonexistent-workdir",
            "ref",
            "content",
            []
          )
      end)

    assert log =~ "serializer NOT registered"
  end

  test "the deliberate no-serializer mode (config off) stays QUIET" do
    Fleet.TestEnv.put_env_restoring(:fleet_pilot, :start_ops_object_sync, false)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        _ =
          Fleet.Workflow.OpsObjectSync.commit_object(
            :absent_serializer_name,
            "/nonexistent-workdir",
            "ref",
            "content",
            []
          )
      end)

    refute log =~ "serializer NOT registered"
  end
end
