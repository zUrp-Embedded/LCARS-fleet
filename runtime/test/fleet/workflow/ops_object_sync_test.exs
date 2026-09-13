defmodule Fleet.Workflow.OpsObjectSyncTest do
  @moduledoc """
  Tests a named serializer with real temporary Git repositories and injected
  timeout engines. The production singleton is disabled in test configuration.
  Concurrent writes, history recovery and direct fallback have separate cases.
  """
  # Mutates global :pilot_start_ops_object_sync and timeout settings; restore after each test.
  use ExUnit.Case, async: false

  alias Fleet.Workflow.OpsObject
  alias Fleet.Workflow.OpsObjectSync

  @moduletag :tmp_dir

  # A separate named instance exercises the serialized path without the app singleton.
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

    assert {:ok, sha, _push} =
             OpsObjectSync.commit_object(srv, tmp, "briefs/x.md", "content\n", label: "test")

    assert File.read!(Path.join(tmp, "briefs/x.md")) == "content\n"
    assert sha =~ ~r/\A[0-9a-f]{40}\z/
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
    assert sha == String.trim(head)
  end

  describe "call timeout — read-only readback confirms a landed transaction (no retry, no race)" do
    setup do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :workflow_ops_sync_call_timeout, 30)
      :ok
    end

    # A process that never handles its mailbox forces call and drain timeouts.
    defp dead_air_server do
      spawn(fn -> Process.sleep(:infinity) end)
    end

    test "timeout but the object IS already committed → {:ok, sha, :unknown} via readback",
         %{tmp_dir: tmp} do
      git_init(tmp)

      # Pre-commit directly (as if the server had landed our transaction just before we timed out).
      # No `push:` opt, so the direct call did not even attempt one.
      assert {:ok, sha, :not_requested} =
               OpsObject.commit_object(tmp, "briefs/x.md", "landed\n", label: "t")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # History identifies committed content without observing its publication.
          assert {:ok, ^sha, :unknown} =
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
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :workflow_ops_sync_call_timeout, 30)

      # The drain must outlive the injected 80ms engine (its own knob; prod default = a full call budget).
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :workflow_ops_sync_drain_timeout, 1_000)
      :ok
    end

    test "commit QUEUED/mid-flight at timeout → drain-confirm waits it out, no false failure",
         %{tmp_dir: tmp} do
      git_init(tmp)

      # Inject a commit slower than the call budget but shorter than the drain budget.
      slow_engine = fn work_dir, ref, content, opts ->
        Process.sleep(80)
        OpsObject.commit_object(work_dir, ref, content, opts)
      end

      name = :"ops_sync_slow_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec({OpsObjectSync, name: name, commit_fun: slow_engine}, id: name)
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, sha, _push} =
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

      # The injected engine returns an error after the initial call times out.
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

    test "a version DISPLACED at the tip still confirms — the readback asks 'did MY commit land'",
         %{tmp_dir: tmp} do
      # A newer version must not hide the earlier committed content during recovery.
      git_init(tmp)

      {:ok, ours, _push} =
        OpsObject.commit_object(tmp, "briefs/x.md", "V1 ours\n", label: "t")

      {:ok, theirs, _push} =
        OpsObject.commit_object(tmp, "briefs/x.md", "V2 theirs\n", label: "t")

      assert ours != theirs
      # The tip is THEIRS: the premise of the test, and what used to end the story.
      assert File.read!(Path.join(tmp, "briefs/x.md")) == "V2 theirs\n"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, ^ours, :unknown} =
                   OpsObjectSync.commit_object(dead_air_server(), tmp, "briefs/x.md", "V1 ours\n",
                     label: "t"
                   )
        end)

      assert log =~ "confirmed by read-only readback"
      # No retry: the displacing version is untouched, and no third commit was made.
      assert File.read!(Path.join(tmp, "briefs/x.md")) == "V2 theirs\n"
      assert commit_count(tmp) == "2"
    end

    test "a version that NEVER landed is still not confirmed by a history walk", %{tmp_dir: tmp} do
      # Negative control: real path history must not confirm unrelated content.
      git_init(tmp)
      {:ok, _, _} = OpsObject.commit_object(tmp, "briefs/x.md", "V1\n", label: "t")
      {:ok, _, _} = OpsObject.commit_object(tmp, "briefs/x.md", "V2\n", label: "t")

      assert :not_committed =
               OpsObject.committed_sha(tmp, "briefs/x.md", "never written\n")
    end

    test "serializer DEAD (:noproc exit) → typed :ops_sync_unavailable, never a caller crash", %{
      tmp_dir: tmp
    } do
      git_init(tmp)
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

      # A dead PID must produce a typed result instead of propagating the call exit.
      assert {:error, {:ops_sync_unavailable, _}} =
               OpsObjectSync.commit_object(dead, tmp, "briefs/z.md", "x\n", label: "t")
    end
  end

  test "idempotent through the gate: same path + same content → same identity, no new commit",
       %{tmp_dir: tmp, server: srv} do
    git_init(tmp)

    assert {:ok, sha1, _push} =
             OpsObjectSync.commit_object(srv, tmp, "briefs/x.md", "same\n", label: "test")

    assert {:ok, sha2, _push} =
             OpsObjectSync.commit_object(srv, tmp, "briefs/x.md", "same\n", label: "test")

    assert sha1 == sha2
    assert commit_count(tmp) == "1"
  end

  test "fallback: an unregistered server routes DIRECT to OpsObject (still commits)", %{
    tmp_dir: tmp
  } do
    git_init(tmp)
    # No process registered under this name → whereis nil → direct OpsObject call.
    assert {:ok, sha, _push} =
             OpsObjectSync.commit_object(:ops_sync_absent, tmp, "briefs/y.md", "z\n",
               label: "test"
             )

    assert sha =~ ~r/\A[0-9a-f]{40}\z/
  end

  test "SERIALIZES concurrent commits to the SAME work_dir → all succeed, no index.lock corruption (CI-11)",
       %{tmp_dir: tmp, server: srv} do
    git_init(tmp)
    n = 12

    # Concurrent distinct writes through one server must all return successfully.
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

    assert Enum.all?(results, &match?({:ok, _sha, _push}, &1)),
           "every serialized commit must succeed: #{inspect(results)}"

    # Commit count checks that serialized writes remain separate.
    assert commit_count(tmp) == "#{n}"
  end

  test "the scope is NODE-GLOBAL: two DIFFERENT work_dirs go through the SAME server (BL-6-43.4)",
       %{tmp_dir: tmp, server: srv} do
    # Both work_dirs are payload to one explicit server. This checks that call shape
    # and resulting files, not overlap timing or the production singleton's routing.
    a = Path.join(tmp, "project-a")
    b = Path.join(tmp, "project-b")
    File.mkdir_p!(a)
    File.mkdir_p!(b)
    git_init(a)
    git_init(b)

    results =
      [{a, "briefs/from-a.md"}, {b, "briefs/from-b.md"}]
      |> Task.async_stream(
        fn {dir, ref} ->
          OpsObjectSync.commit_object(srv, dir, ref, "content for #{ref}\n", label: "test")
        end,
        max_concurrency: 2,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({:ok, _sha, _push}, &1)),
           "both projects must land through the single node-global server: #{inspect(results)}"

    # Each repo carries exactly its OWN commit — the shared server never cross-wrote.
    assert commit_count(a) == "1"
    assert commit_count(b) == "1"
    assert File.exists?(Path.join(a, "briefs/from-a.md"))
    assert File.exists?(Path.join(b, "briefs/from-b.md"))
    refute File.exists?(Path.join(a, "briefs/from-b.md"))
  end

  test "the PROD-config bypass is LOUD: serializer absent while config starts it → warning per call" do
    # A missing serializer warns when configuration says it should be running.
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_start_ops_object_sync, true)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        _ =
          OpsObjectSync.commit_object(
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
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_start_ops_object_sync, false)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        _ =
          OpsObjectSync.commit_object(
            :absent_serializer_name,
            "/nonexistent-workdir",
            "ref",
            "content",
            []
          )
      end)

    refute log =~ "serializer NOT registered"
  end

  # Disk content left after a failed commit must not inherit a previous version's SHA.
  describe "6-048 — le sha rendu porte le contenu annonce" do
    alias Fleet.Workflow.OpsObject

    test "fichier ecrit NON COMMITE : le sha d'une version precedente n'est pas rendu",
         %{tmp_dir: tmp} do
      git_init(tmp)

      # v1 commitee — c'est ELLE que le raccourci rendait a tort.
      assert {:ok, sha_v1, _} = OpsObject.commit_object(tmp, "briefs/x.md", "v1\n", label: "t")

      # v2 ecrite sur le disque et JAMAIS commitee : exactement l'etat que laisse un
      # `materialize/5` dont le commit a echoue.
      File.write!(Path.join(tmp, "briefs/x.md"), "v2\n")

      assert {:ok, sha_v2, _} = OpsObject.commit_object(tmp, "briefs/x.md", "v2\n", label: "t")

      refute sha_v2 == sha_v1, "le sha de v1 a ete rendu pour le contenu v2"

      # Et le sha rendu porte VRAIMENT v2 — c'est la propriete, pas « un autre sha ».
      {contenu, 0} = System.cmd("git", ["show", "#{sha_v2}:briefs/x.md"], cd: tmp)
      assert contenu == "v2\n"
    end

    test "TEMOIN — contenu deja commite : le raccourci rend bien SON commit, sans en creer",
         %{tmp_dir: tmp} do
      # Positive control: matching committed content must not create another commit.
      git_init(tmp)

      assert {:ok, sha1, _} = OpsObject.commit_object(tmp, "briefs/x.md", "stable\n", label: "t")
      avant = commit_count(tmp)

      assert {:ok, sha2, _} = OpsObject.commit_object(tmp, "briefs/x.md", "stable\n", label: "t")

      assert sha2 == sha1

      assert commit_count(tmp) == avant,
             "un commit a ete cree alors que le contenu etait identique"
    end

    test "une version ANCIENNE re-demandee retrouve SON commit, pas le dernier du chemin",
         %{tmp_dir: tmp} do
      # Le cas qui distingue « dernier commit du chemin » de « commit portant ce contenu » : trois
      # versions, puis on redemande la premiere. `last_commit_sha` aurait rendu le commit de v3.
      git_init(tmp)

      assert {:ok, sha_v1, _} = OpsObject.commit_object(tmp, "briefs/x.md", "v1\n", label: "t")
      assert {:ok, _sha_v2, _} = OpsObject.commit_object(tmp, "briefs/x.md", "v2\n", label: "t")
      assert {:ok, sha_v3, _} = OpsObject.commit_object(tmp, "briefs/x.md", "v3\n", label: "t")

      # On remet v1 sur le disque, sans commiter, et on la redemande.
      File.write!(Path.join(tmp, "briefs/x.md"), "v1\n")
      assert {:ok, sha, _} = OpsObject.commit_object(tmp, "briefs/x.md", "v1\n", label: "t")

      assert sha == sha_v1
      refute sha == sha_v3

      {contenu, 0} = System.cmd("git", ["show", "#{sha}:briefs/x.md"], cd: tmp)
      assert contenu == "v1\n"
    end
  end

  # Non-bang reads let unreadable paths reach a returned write error instead of a server crash.
  describe "6-081 — un fichier illisible ne tue pas le serialiseur de work/ops" do
    test "chemin devenu un REPERTOIRE : materialise ou echoue, mais le serveur survit",
         %{tmp_dir: tmp, server: srv, name: name} do
      git_init(tmp)

      # A directory deterministically makes File.read fail; this does not reproduce a timed race.
      File.mkdir_p!(Path.join(tmp, "briefs/x.md"))

      _ = OpsObjectSync.commit_object(srv, tmp, "briefs/x.md", "content\n", label: "t")

      # Check server identity and a subsequent successful request, beyond mere liveness.
      assert Process.alive?(srv)
      assert Process.whereis(name) == srv

      assert {:ok, _sha, _} =
               OpsObjectSync.commit_object(srv, tmp, "briefs/autre.md", "ok\n", label: "t")
    end
  end
end
