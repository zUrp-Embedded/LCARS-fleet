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
