defmodule Fleet.Workflow.OpsObjectSyncTest do
  @moduledoc """
  CI-11 — the ops write serializer. `OpsObject` is the untouched engine; this GenServer is the
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

    # A process that receives the $gen_call but NEVER replies → the caller's GenServer.call times out,
    # exactly like a server still grinding through a composed-budget queue.
    defp dead_air_server do
      spawn(fn -> Process.sleep(:infinity) end)
    end

    test "timeout but the object IS already committed → {:ok, sha, :unknown} via readback",
         %{tmp_dir: tmp} do
      git_init(tmp)

      # Pre-commit directly (as if the server had landed our transaction just before we timed out).
      # No `push:` opt, so the direct call did not even attempt one.
      assert {:ok, sha, :not_requested} =
               Fleet.Workflow.OpsObject.commit_object(tmp, "briefs/x.md", "landed\n", label: "t")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # `:unknown`, and it is the point of the readback path: `committed_sha/3` proves the
          # COMMIT landed and says NOTHING about a publication. The reply that carried the push
          # outcome is exactly what the timeout lost — reporting `:local_only` here would invent an
          # observation, reporting `:pushed` would invent a success.
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

    test "a version DISPLACED at the tip still confirms — the readback asks 'did MY commit land'",
         %{tmp_dir: tmp} do
      # The deceptive case a tip-identity readback got wrong. Two writers on ONE ref: ours lands
      # first, a second overwrites it. Our commit is in the history, is real, is pushable — and
      # asking "is my content at the TIP" answered no, so the caller was told `:ops_sync_timeout`
      # and the log called that DEFINITIVE. A caller acting on it retries and overwrites the
      # version that displaced ours.
      git_init(tmp)

      {:ok, ours, _push} =
        Fleet.Workflow.OpsObject.commit_object(tmp, "briefs/x.md", "V1 ours\n", label: "t")

      {:ok, theirs, _push} =
        Fleet.Workflow.OpsObject.commit_object(tmp, "briefs/x.md", "V2 theirs\n", label: "t")

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
      # The adverse half: widening the readback from the tip to the history must not turn it into a
      # yes-machine. A ref with real history, and a version that was never committed to it.
      git_init(tmp)
      {:ok, _, _} = Fleet.Workflow.OpsObject.commit_object(tmp, "briefs/x.md", "V1\n", label: "t")
      {:ok, _, _} = Fleet.Workflow.OpsObject.commit_object(tmp, "briefs/x.md", "V2\n", label: "t")

      assert :not_committed =
               Fleet.Workflow.OpsObject.committed_sha(tmp, "briefs/x.md", "never written\n")
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

    assert Enum.all?(results, &match?({:ok, _sha, _push}, &1)),
           "every serialized commit must succeed: #{inspect(results)}"

    # N distinct objects, serialized → N commits (no lost/failed write, no corrupt index).
    assert commit_count(tmp) == "#{n}"
  end

  test "the scope is NODE-GLOBAL: two DIFFERENT work_dirs go through the SAME server (BL-6-43.4)",
       %{tmp_dir: tmp, server: srv} do
    # ⚠ HISTORICAL, and it must read as such: the module USED TO say "NO test pins the node-wide
    # scope, so a green suite would not by itself prove such a change safe". THIS test is what
    # closed that gap on 2026-08-03 (BL-6-43.4), and the module now says so. The old sentence is
    # quoted here only to name what was missing — it is NOT the current state.
    #
    # That distinction cost two false confirmations on 2026-08-05: an audit grepped the sentence,
    # read it as live, and reported the scope as unpinned; a second pass "verified" it against a
    # truncated listing that stopped before this line. A verbatim obsolete claim living inside its
    # own fix is a trap for whoever searches rather than reads.
    #
    # What the gap WAS: the CI-11 test above proves serialization within ONE work_dir, and a
    # per-work_dir sharding would keep it green while silently dropping the cross-project guarantee.
    #
    # What is pinned here is the ROUTING KEY: `work_dir` travels as PAYLOAD, the server is the only
    # address. Two unrelated repos are committed through one explicitly-named instance, and both
    # must land. A refactor that derived the process from `work_dir` could not satisfy this call
    # shape — it would have to resolve elsewhere, and this test is where it says so.
    #
    # What is NOT pinned, deliberately: mutual exclusion ACROSS work_dirs by timing. Proving "these
    # two never overlapped" needs a clock, and a clock in a test buys flakiness rather than truth.
    # The structural property is the one a refactor breaks first.
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
    # The optional-layer posture is documented; what could not stand is the SILENT bypass in
    # a booted daemon (restart window / crash loop): the gate's absence must be visible.
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_start_ops_object_sync, true)

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
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_start_ops_object_sync, false)

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

  # 6-048 — LE DISQUE NE PROUVE RIEN SUR L'HISTOIRE. Le raccourci d'idempotence rendait
  # `Git.last_commit_sha/2` — le dernier commit ayant TOUCHE ce chemin — sans verifier que le
  # contenu A CE COMMIT est celui qu'on annonce. Un fichier ecrit puis non commite suffit.
  #
  # Ce sha remonte jusqu'aux pointeurs d'epinglage : `Brief: <ref> @ <sha>` dans le corps du ticket,
  # avec la phrase « ce qui fait foi est le doc ci-dessous, A CE COMMIT EXACT ». Un juge qui resout
  # le pointeur lit alors une version PRECEDENTE, sans qu'aucune erreur ne se leve.
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
      # Sans ce temoin, un correctif qui re-commiterait a chaque appel passerait le test precedent
      # et ferait de l'idempotence une illusion — un commit par appel dans le journal de `work/ops`.
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

  # 6-081 — `File.exists?/1` PUIS `File.read!/1` est un check-then-act, et la variante `!` LEVE
  # dans une expression booleenne ou l'echec de lecture voulait dire « contenu different ». Ce code
  # tourne dans le `handle_call` du serialiseur : la levee le TUE, et tous les appels en attente
  # recoivent un `:exit`.
  describe "6-081 — un fichier illisible ne tue pas le serialiseur de work/ops" do
    test "chemin devenu un REPERTOIRE : materialise ou echoue, mais le serveur survit",
         %{tmp_dir: tmp, server: srv, name: name} do
      git_init(tmp)

      # Un repertoire la ou un fichier est attendu : `File.exists?` rend true, `File.read!` LEVE
      # (`:eisdir`). C'est la forme reproductible du disparait-entre-les-deux, et elle passe par le
      # meme chemin de code.
      File.mkdir_p!(Path.join(tmp, "briefs/x.md"))

      _ = OpsObjectSync.commit_object(srv, tmp, "briefs/x.md", "content\n", label: "t")

      # LA propriete : le serialiseur est toujours vivant et repond encore. Le sort de CET appel
      # importe moins que le fait que les suivants ne recoivent pas un `:exit`.
      assert Process.alive?(srv)
      assert Process.whereis(name) == srv

      assert {:ok, _sha, _} =
               OpsObjectSync.commit_object(srv, tmp, "briefs/autre.md", "ok\n", label: "t")
    end
  end
end
