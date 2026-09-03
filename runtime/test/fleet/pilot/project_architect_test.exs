defmodule Fleet.Project.ArchitectTest do
  # async: false — captures the spawn call via an app-env pid (global).
  use ExUnit.Case, async: false

  alias Fleet.Project.Architect, as: ProjectArchitect

  @cap_key :test_project_architect_capture_pid

  defmodule StubForge do
    # Numeric forge id resolution (resolve_repo_id → forge.repo_id/2).
    def repo_id("fleet/demo", _opts), do: {:ok, 4242}
    def repo_id(_repo, _opts), do: {:error, :not_found}
  end

  defmodule CaptureSpawner do
    def spawn_pod(cap, issue_id, opts) do
      send(
        Application.fetch_env!(:lcars_fleet, :test_project_architect_capture_pid),
        {:spawn_pod, cap, issue_id, opts}
      )

      {:ok, spawn(fn -> :ok end)}
    end
  end

  defmodule FailSpawner do
    def spawn_pod(_cap, _issue_id, _opts), do: {:error, :launch_failed}
  end

  setup do
    Application.put_env(:lcars_fleet, @cap_key, self())
    on_exit(fn -> Application.delete_env(:lcars_fleet, @cap_key) end)
    :ok
  end

  test "pod_id_for/1 — THE per-project authority (full_name or bare name)" do
    # `architect-` is the RESOLVED role of the bundled catalogue, not a literal in the builder:
    # see the derivation test below, which renames the delegate and watches the id follow.
    assert ProjectArchitect.pod_id_for("fleet/demo") == "architect-demo"
    assert ProjectArchitect.pod_id_for("demo") == "architect-demo"
  end

  describe "ensure/2" do
    @describetag :tmp_dir

    # The project's THREE faces on the machine (ensure refuses an absent one — its mounts ARE its
    # world, and bwrap binds strictly: a missing source kills the launcher, it does not skip).
    defp mk_dirs(tmp) do
      proj = Path.join([tmp, "projects", "demo"])
      work = Path.join([tmp, "projects.work", "demo"])
      doc = Path.join([tmp, "projects.doc", "demo"])
      Enum.each([proj, work, doc], &File.mkdir_p!/1)

      {proj, work, doc,
       [
         code_root: Path.join(tmp, "projects"),
         ops_root: Path.join(tmp, "projects.work"),
         workshop_root: Path.join(tmp, "projects.doc")
       ]}
    end

    test "spawns the architect PROJECT-BOUND: composed cap + repo_id + repo + rc_name + MOUNTS (no clone)",
         %{tmp_dir: tmp} do
      {proj, work, doc, roots} = mk_dirs(tmp)

      assert {:ok, "architect-demo"} =
               ProjectArchitect.ensure(
                 "fleet/demo",
                 [spawner: CaptureSpawner, forge_client: StubForge] ++ roots
               )

      assert_received {:spawn_pod, cap, _issue_id, opts}

      # The composed architect cap (default modops applied).
      assert Fleet.CapProfile.name(cap) == "architect"
      # Deterministic per-project pod_id (relaunch-idempotent), via the single authority.
      assert opts[:pod_id] == "architect-demo"

      # Identity: numeric repo id → the <REPO4> of the deterministic UUID; `repo` = the channel-side
      # binding pod_info exposes (the repo-implicit MCP tools resolve "the project" from it).
      assert opts[:repo_id] == 4242
      assert opts[:repo] == "fleet/demo"
      # One Desktop slot per project.
      assert opts[:rc_name] == "demo_architect"

      # No ticket: the architect is project-bound, not ticket-bound — the label carries no number,
      # and the slug still travels explicitly (the spawn choke point demands it of every named pod).
      assert opts[:project_slug] == "demo"
      # NO CLONE (§14.d): the arch is not a producer of code — its world is the three live host
      # dirs, one per face.
      refute Keyword.has_key?(opts, :project)

      # ONE writable face, and it is `doc`. `ops` is the record the arch is JUDGED against: it
      # reads it to follow the work and report, and it cannot touch it — a judged party that can
      # rewrite the tree it is judged on is not judged. `code` goes through the pipeline like
      # everyone else's, with no typo exception: an actor holding a pen uses it where nobody looks.
      assert opts[:mounts] == [
               %{"mode" => "ro", "path" => proj},
               %{"mode" => "ro", "path" => work},
               %{"mode" => "rw", "path" => doc}
             ]

      # And the ORDER is load-bearing, not cosmetic: `pod_cwd/3` falls back to the FIRST rw mount
      # for a pod with no project remap, and `pod_mounts_env/3` keeps the FIRST occurrence of a
      # path. The two read-only faces must precede the writable one.
      assert [%{"mode" => "ro"}, %{"mode" => "ro"}, %{"mode" => "rw"}] =
               Enum.map(opts[:mounts], &Map.take(&1, ["mode"]))
    end

    test "a project whose DOC face is absent is NOT onboarded — bwrap would die on the bind", %{
      tmp_dir: tmp
    } do
      # The guard used to look at the code face alone. A project whose doc face never landed then
      # passed this door and failed at the bind, with an error naming bwrap instead of the
      # onboarding that never finished — and the arch's producing face IS the doc one.
      {_proj, _work, doc, roots} = mk_dirs(tmp)
      File.rm_rf!(doc)

      assert {:error, {:not_onboarded, ^doc}} =
               ProjectArchitect.ensure(
                 "fleet/demo",
                 [spawner: CaptureSpawner, forge_client: StubForge] ++ roots
               )

      refute_received {:spawn_pod, _, _, _}
    end

    test "project NOT on the machine → {:error, {:not_onboarded, _}} — no spawn", %{tmp_dir: tmp} do
      assert {:error, {:not_onboarded, _}} =
               ProjectArchitect.ensure(
                 "fleet/demo",
                 spawner: CaptureSpawner,
                 forge_client: StubForge,
                 code_root: Path.join(tmp, "projects"),
                 ops_root: Path.join(tmp, "projects.work")
               )

      refute_received {:spawn_pod, _, _, _}
    end

    test "numeric repo id unresolved → refusal CARRYING the forge's reason, no spawn", %{
      tmp_dir: tmp
    } do
      {_proj, _work, _doc, roots} = mk_dirs(tmp)

      defmodule NoIdForge do
        def repo_id(_repo, _opts), do: {:error, :forge_down}
      end

      # The reason must SURVIVE to the caller and to the log. It used to be flattened to `nil` by
      # `resolve_repo_id/3`, after which the log filled the hole with "(forge down?)" — a guess that
      # was quoted as a diagnosis over a forge that was answering.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:repo_id_unresolved, "fleet/demo", :forge_down}} =
                   ProjectArchitect.ensure(
                     "fleet/demo",
                     [spawner: CaptureSpawner, forge_client: NoIdForge] ++ roots
                   )
        end)

      assert log =~ ":forge_down"
      refute log =~ "?", "the log must report what the forge said, never suppose"

      refute_received {:spawn_pod, _, _, _}
    end

    test "a seam with no repo_id/2 is a WIRING fact, never reported as a forge failure", %{
      tmp_dir: tmp
    } do
      {_proj, _work, _doc, roots} = mk_dirs(tmp)

      defmodule NoRepoIdFunctionForge do
        # deliberately exports nothing: the historical stub shape
        def unrelated, do: :ok
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:repo_id_unresolved, "fleet/demo", :repo_id_unsupported}} =
                   ProjectArchitect.ensure(
                     "fleet/demo",
                     [spawner: CaptureSpawner, forge_client: NoRepoIdFunctionForge] ++ roots
                   )
        end)

      assert log =~ ":repo_id_unsupported"

      refute_received {:spawn_pod, _, _, _}
    end

    test "a spawn failure is returned (best-effort at call sites)", %{tmp_dir: tmp} do
      {_proj, _work, _doc, roots} = mk_dirs(tmp)

      assert {:error, :launch_failed} =
               ProjectArchitect.ensure(
                 "fleet/demo",
                 [spawner: FailSpawner, forge_client: StubForge] ++ roots
               )
    end
  end

  describe "ensure_alive/2 — the KEEPER keeps, it never creates" do
    @describetag :tmp_dir

    # The keeper's only caller is the poller, which walks the ORG SCAN: every repo of the fleet
    # org, including the ones another human onboarded. Measured 2026-08-12 on a two-human bench —
    # a fleet whose human had made a single `project_create` call was running an architect for a
    # project created by the other human and never opened here. The shared ops directory that
    # gated the call proves *someone* onboarded, never *this* human.
    defmodule AliveTmux do
      def alive?(_pod_id), do: true
    end

    defmodule DeadTmux do
      def alive?(_pod_id), do: false
    end

    test "NOT on record: no spawn, no liveness call, nothing — this fleet was never asked" do
      assert {:ok, :not_ours} =
               ProjectArchitect.ensure_alive("fleet/demo",
                 on_record: fn _repo, _opts -> false end,
                 pod_tmux: DeadTmux,
                 spawner: CaptureSpawner,
                 forge_client: StubForge
               )

      refute_received {:spawn_pod, _, _, _}
    end

    test "on record and alive: the cheap answer, still no spawn" do
      assert {:ok, :alive} =
               ProjectArchitect.ensure_alive("fleet/demo",
                 on_record: fn _repo, _opts -> true end,
                 pod_tmux: AliveTmux,
                 spawner: CaptureSpawner,
                 forge_client: StubForge
               )

      refute_received {:spawn_pod, _, _, _}
    end

    test "on record and dead: THAT is what a keeper is for — it respawns", %{tmp_dir: tmp} do
      {_proj, _work, _doc, roots} = mk_dirs(tmp)

      assert {:ok, "architect-demo"} =
               ProjectArchitect.ensure_alive(
                 "fleet/demo",
                 [
                   on_record: fn _repo, _opts -> true end,
                   pod_tmux: DeadTmux,
                   spawner: CaptureSpawner,
                   forge_client: StubForge
                 ] ++ roots
               )

      assert_received {:spawn_pod, _cap, "architect-demo", _opts}
    end

    test "on_record?/2 reads the DURABLE snapshot, not liveness", %{tmp_dir: tmp} do
      # The record is written at spawn and cleared on a terminal phase: a crash or a fleet restart
      # leaves it (the case the keeper exists for), a deliberate kill removes it (not resurrecting
      # is then the correct answer).
      refute ProjectArchitect.on_record?("fleet/demo", state_fs_root: tmp)

      File.mkdir_p!(Path.join([tmp, "pods", "architect-demo"]))
      refute ProjectArchitect.on_record?("fleet/demo", state_fs_root: tmp)

      File.write!(Path.join([tmp, "pods", "architect-demo", "state.json"]), "{}")
      assert ProjectArchitect.on_record?("fleet/demo", state_fs_root: tmp)
    end

    test "an unreadable state root answers NO — a failed read must never authorise a spawn" do
      refute ProjectArchitect.on_record?("fleet/demo",
               state_fs_root: "/nonexistent/#{System.unique_integer([:positive])}"
             )
    end
  end

  test "the prefix is the DELEGATE'S ROLE, not the word architect" do
    # The defect this closes: a catalogue naming its delegate `tech-lead` resolved the role
    # correctly and still spawned a pod called `architect-vitrine`, whose own CLAUDE.md and SP both
    # said `tech-lead`. The name the operator reads was the last literal left.
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_project_delegate_role, "tech-lead")

    assert ProjectArchitect.pod_id_for("fleet/vitrine") == "tech-lead-vitrine"
  end
end
