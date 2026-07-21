defmodule Fleet.Workflow.OpsObjectSyncTest do
  @moduledoc """
  CI-11 — the work/ops write serializer. `OpsObject` is the untouched engine; this GenServer is the
  gate that funnels concurrent git transactions (briefs from several MCP connections + the poller,
  provenance from up to 16 completion Tasks) ONE at a time onto the shared worktree, against the
  `.git/index.lock` + moving-HEAD race. Real temp git repo (`git init`) — the gate commits for real,
  through an ISOLATED instance the setup starts: the app's always-on singleton is OFF in `:test` for
  hermeticity (see the setup note), so each test drives its own named server via `commit_object/5`.
  """
  use ExUnit.Case, async: true

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

    assert {:ok, sha} = OpsObjectSync.commit_object(srv, tmp, "briefs/x.md", "content\n", label: "test")
    assert File.read!(Path.join(tmp, "briefs/x.md")) == "content\n"
    assert sha =~ ~r/\A[0-9a-f]{40}\z/
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
    assert sha == String.trim(head)
  end

  test "idempotent through the gate: same path + same content → same identity, no new commit",
       %{tmp_dir: tmp, server: srv} do
    git_init(tmp)
    assert {:ok, sha1} = OpsObjectSync.commit_object(srv, tmp, "briefs/x.md", "same\n", label: "test")
    assert {:ok, sha2} = OpsObjectSync.commit_object(srv, tmp, "briefs/x.md", "same\n", label: "test")
    assert sha1 == sha2
    assert commit_count(tmp) == "1"
  end

  test "fallback: an unregistered server routes DIRECT to OpsObject (still commits)", %{tmp_dir: tmp} do
    git_init(tmp)
    # No process registered under this name → whereis nil → direct OpsObject call.
    assert {:ok, sha} =
             OpsObjectSync.commit_object(:ops_sync_absent, tmp, "briefs/y.md", "z\n", label: "test")

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
          OpsObjectSync.commit_object(srv, tmp, "briefs/obj-#{i}.md", "content #{i}\n", label: "test")
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
end
