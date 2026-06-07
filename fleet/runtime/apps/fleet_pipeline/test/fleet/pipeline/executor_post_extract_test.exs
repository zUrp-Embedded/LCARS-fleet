defmodule Fleet.Pipeline.PostExtractCaptureStub do
  @moduledoc """
  Stub StageSpawner dédié à ce module : `{:ok, pod_id}` sans émettre
  `pipeline.stage.completed` (le test pilote l'avancement via `pod.completed`
  broadcast manuel). Identique au CaptureStub d'executor_pod_completed_test
  mais isolé pour permettre l'exécution standalone du fichier.
  """
  @behaviour Fleet.Pipeline.StageSpawner

  @impl Fleet.Pipeline.StageSpawner
  def spawn_stage_pod(_role, _profile, stage_ctx) do
    send(:post_extract_probe, {:spawned, stage_ctx.stage, Map.get(stage_ctx, :spawn_opts)})
    {:ok, "pod-#{stage_ctx.stage}"}
  end
end

defmodule Fleet.Pipeline.ExecutorPostExtractTest do
  @moduledoc """
  Face 2 briques 2.3 + 2.4 — chaîne pipeline:
    do_run_stage → WorkspaceProvisioner.provision_for_stage (clone repo_url)
                 → spawn (stub)
                 → pod.completed → apply payload → Fleet.Pipeline.Git.publish
                 → broadcast git.published / git.publish_failed.

  Tests pilotés par bare repo local seedé (file://…). Pas de pod réel,
  pas de claude.
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.EventRouter.Bus
  alias Fleet.Pipeline

  # R2 (D1) : émet la complétion pod via la struct canon %Fleet.Event{} (comme
  # Spawner.Pod.safe_broadcast/2) au lieu du tuple legacy broadcast/3.
  defp pod_completed(payload) do
    Bus.broadcast("fleet.events", %Fleet.Event{
      source: :spawner,
      type: :"pod.completed",
      timestamp: DateTime.utc_now(),
      pod_id: payload["pod_id"],
      payload: payload
    })
  end

  setup %{tmp_dir: tmp_dir} do
    Process.register(self(), :post_extract_probe)

    Application.put_env(:fleet_pipeline, :pipelines_root, tmp_dir)
    Application.put_env(:fleet_pipeline, :workspaces_root, Path.join(tmp_dir, "ws-root"))
    Application.put_env(:fleet_pipeline, :spawner_backend, Fleet.Pipeline.PostExtractCaptureStub)
    # O5 — ces tests couvrent le wiring du mode PAYLOAD (le système écrit+commite le payload).
    # Le profil `engineer` résout `git_native` par défaut (cap-profile) ; on force payload via le
    # seam. Les tests git_native ci-dessous overrident localement.
    Application.put_env(:fleet_pipeline, :deliverable_mode_resolver, fn _role, _profile ->
      "payload"
    end)

    # Broker Fleet.TaskQueue app-global (ensure_all_started) — pas de start_supervised.
    Bus.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Fleet.Pipeline.ExecutorSupervisor) do
        DynamicSupervisor.terminate_child(Fleet.Pipeline.ExecutorSupervisor, pid)
      end

      Application.delete_env(:fleet_pipeline, :pipelines_root)
      Application.delete_env(:fleet_pipeline, :workspaces_root)
      Application.delete_env(:fleet_pipeline, :spawner_backend)
      Application.delete_env(:fleet_pipeline, :deliverable_mode_resolver)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  defp write_pipeline(tmp_dir, name, stage_extra) do
    # Format v1 flat — l'Executor lit `pipeline["stages"]` au niveau racine.
    # La bascule v2.5 côté Executor est un chantier séparé (R0.8/06_modops bloqué) ;
    # le wiring post_extract.git testé ici est indépendant du format YAML.
    yaml = """
    name: #{name}
    version: 1
    stages:
      publish:
        role: engineer
        profile: engineer
    #{stage_extra}
    """

    File.write!(Path.join(tmp_dir, "#{name}.yaml"), yaml)
  end

  # Bare repo source + commit initial sur main (poussé par un seeder éphémère).
  defp seed_remote(tmp_dir, name) do
    bare = Path.join(tmp_dir, "#{name}.git")
    File.mkdir_p!(bare)
    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", bare])

    seeder = Path.join(tmp_dir, "#{name}-seeder")
    File.mkdir_p!(seeder)
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", seeder])
    {_, 0} = System.cmd("git", ["config", "user.name", "seeder"], cd: seeder)
    {_, 0} = System.cmd("git", ["config", "user.email", "s@e"], cd: seeder)
    File.write!(Path.join(seeder, "README.md"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: seeder)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: seeder)
    {_, 0} = System.cmd("git", ["remote", "add", "origin", bare], cd: seeder)
    {_, 0} = System.cmd("git", ["push", "origin", "main"], cd: seeder)

    bare
  end

  defp workspace_for(pipeline_id, stage) do
    Path.join([
      Application.get_env(:fleet_pipeline, :workspaces_root),
      pipeline_id,
      stage,
      "workspace"
    ])
  end

  # ============================================================
  # Cas nominal : post_extract.git présent + payload files → commit + event
  # ============================================================

  test "post_extract.git + result.files → commit créé + git.published émis", %{tmp_dir: tmp_dir} do
    bare = seed_remote(tmp_dir, "p1-source")

    write_pipeline(tmp_dir, "p1", """
        post_extract:
          git:
            repo_url: #{bare}
            branch: main
    """)

    {:ok, pipeline_id} = Pipeline.start_pipeline("p1", %{ticket_id: "p1#1"})
    assert_receive {:spawned, "publish", _}, 2_000

    ws = workspace_for(pipeline_id, "publish")
    # Le WorkspaceProvisioner a déjà cloné bare → ws ; pas d'init manuel.
    assert File.dir?(Path.join(ws, ".git"))

    pod_completed(%{
      "pod_id" => "pod-publish",
      "ticket_id" => "p1#1",
      "pipeline_id" => pipeline_id,
      "stage" => "publish",
      "result" => %{
        "files" => [%{"path" => "out/X.md", "content" => "from worker\n"}],
        "message" => "feat(publish): worker payload"
      }
    })

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"git.published",
                     payload: %{
                       "pipeline_id" => ^pipeline_id,
                       "stage" => "publish",
                       "commit_sha" => <<_::binary-size(40)>>,
                       "pushed?" => false
                     }
                   },
                   2_000

    # Le fichier livré est bien commit dans le workspace.
    {tracked, 0} = System.cmd("git", ["show", "--name-only", "--format=", "HEAD"], cd: ws)
    assert String.contains?(tracked, "out/X.md")

    {author, 0} = System.cmd("git", ["log", "-1", "--format=%an <%ae>"], cd: ws)
    assert String.trim(author) == "LCARS-engineer <engineer@lcars.local>"

    {committer, 0} = System.cmd("git", ["log", "-1", "--format=%cn <%ce>"], cd: ws)
    assert String.trim(committer) == "LCARS System <system@lcars.local>"

    {msg, 0} = System.cmd("git", ["log", "-1", "--format=%s"], cd: ws)
    assert String.trim(msg) == "feat(publish): worker payload"

    # Le pipeline avance malgré tout (post_extract est best-effort).
    assert_receive %Fleet.Event{source: :pipeline, type: :"pipeline.completed"}, 2_000
  end

  # ============================================================
  # Brique 2.4 : provision fail (repo_url invalide) → pipeline.failed
  # ============================================================

  test "repo_url invalide → pipeline.failed (provision fail), pas de spawn",
       %{tmp_dir: tmp_dir} do
    write_pipeline(tmp_dir, "p2", """
        post_extract:
          git:
            repo_url: #{Path.join(tmp_dir, "does-not-exist.git")}
            branch: main
    """)

    {:ok, pipeline_id} = Pipeline.start_pipeline("p2", %{ticket_id: "p2#1"})

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.failed",
                     payload: %{
                       "pipeline_id" => ^pipeline_id,
                       "stage" => "publish",
                       "reason" => reason
                     }
                   },
                   3_000

    assert String.contains?(reason, "workspace provision fail")
    assert String.contains?(reason, ":clone_failed")

    # Le pod n'a JAMAIS été spawné (provisioner halt avant le backend).
    refute_receive {:spawned, _, _}, 200
  end

  # ============================================================
  # Payload sans files : skip publish gracieusement (no_files_in_payload)
  # ============================================================

  test "result sans files → git.publish_failed (:no_files_in_payload)", %{tmp_dir: tmp_dir} do
    bare = seed_remote(tmp_dir, "p3-source")

    write_pipeline(tmp_dir, "p3", """
        post_extract:
          git:
            repo_url: #{bare}
            branch: main
    """)

    {:ok, pipeline_id} = Pipeline.start_pipeline("p3", %{ticket_id: "p3#1"})
    assert_receive {:spawned, "publish", _}, 2_000

    pod_completed(%{
      "pod_id" => "pod-publish",
      "ticket_id" => "p3#1",
      "pipeline_id" => pipeline_id,
      "stage" => "publish",
      "result" => %{"answer" => "ok"}
    })

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"git.publish_failed",
                     payload: %{"reason" => reason}
                   },
                   2_000

    assert String.contains?(reason, ":no_files_in_payload")

    assert_receive %Fleet.Event{source: :pipeline, type: :"pipeline.completed"}, 2_000
  end

  # ============================================================
  # Sécu : path traversal dans le payload worker → git.publish_failed
  # (audit externe 2026-05-24 #3)
  # ============================================================

  test "payload path traversal `../../etc/x` → git.publish_failed (:path_traversal)",
       %{tmp_dir: tmp_dir} do
    bare = seed_remote(tmp_dir, "p5-source")

    write_pipeline(tmp_dir, "p5", """
        post_extract:
          git:
            repo_url: #{bare}
            branch: main
    """)

    {:ok, pipeline_id} = Pipeline.start_pipeline("p5", %{ticket_id: "p5#1"})
    assert_receive {:spawned, "publish", _}, 2_000

    ws = workspace_for(pipeline_id, "publish")
    assert File.dir?(Path.join(ws, ".git"))

    # Le worker tente d'écraser un fichier hors workspace via `../`.
    pod_completed(%{
      "pod_id" => "pod-publish",
      "ticket_id" => "p5#1",
      "pipeline_id" => pipeline_id,
      "stage" => "publish",
      "result" => %{
        "files" => [%{"path" => "../../escaped.md", "content" => "evil\n"}]
      }
    })

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"git.publish_failed",
                     payload: %{"reason" => reason}
                   },
                   2_000

    assert String.contains?(reason, ":path_traversal")
    # Aucun fichier écrit hors workspace.
    refute File.exists?(Path.join([ws, "..", "..", "escaped.md"]))

    assert_receive %Fleet.Event{source: :pipeline, type: :"pipeline.completed"}, 2_000
  end

  test "payload multi-fichiers AVEC un path traversal → AUCUN fichier écrit (pré-validation)",
       %{tmp_dir: tmp_dir} do
    bare = seed_remote(tmp_dir, "p6-source")

    write_pipeline(tmp_dir, "p6", """
        post_extract:
          git:
            repo_url: #{bare}
            branch: main
    """)

    {:ok, pipeline_id} = Pipeline.start_pipeline("p6", %{ticket_id: "p6#1"})
    assert_receive {:spawned, "publish", _}, 2_000

    ws = workspace_for(pipeline_id, "publish")

    pod_completed(%{
      "pod_id" => "pod-publish",
      "ticket_id" => "p6#1",
      "pipeline_id" => pipeline_id,
      "stage" => "publish",
      "result" => %{
        "files" => [
          %{"path" => "ok/A.md", "content" => "A\n"},
          %{"path" => "../escaped.md", "content" => "evil\n"},
          %{"path" => "ok/B.md", "content" => "B\n"}
        ]
      }
    })

    assert_receive %Fleet.Event{source: :pipeline, type: :"git.publish_failed"}, 2_000

    # Atomicité (#4) : validation préalable refuse tout → aucun fichier écrit,
    # y compris A.md qui passerait isolément.
    refute File.exists?(Path.join(ws, "ok/A.md"))
    refute File.exists?(Path.join(ws, "ok/B.md"))

    assert_receive %Fleet.Event{source: :pipeline, type: :"pipeline.completed"}, 2_000
  end

  # ============================================================
  # O5 mode git_native : le POD commite dans son workspace, le système gate + pousse
  # ============================================================

  # Mime le pod : commite `file`/`content` dans le workspace avec une identité git arbitraire.
  defp pod_commits(ws, name, content, msg, email, author_name) do
    File.write!(Path.join(ws, name), content)
    {_, 0} = System.cmd("git", ["-C", ws, "add", "."], stderr_to_stdout: true)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-C",
          ws,
          "-c",
          "user.email=#{email}",
          "-c",
          "user.name=#{author_name}",
          "commit",
          "-q",
          "-m",
          msg
        ],
        stderr_to_stdout: true
      )
  end

  test "git_native : pod a commité (identité rôle) → git.published mode=git_native, gate OK",
       %{tmp_dir: tmp_dir} do
    Application.put_env(:fleet_pipeline, :deliverable_mode_resolver, fn _r, _p -> "git_native" end)

    bare = seed_remote(tmp_dir, "gn1-source")

    write_pipeline(tmp_dir, "gn1", """
        post_extract:
          git:
            repo_url: #{bare}
            branch: main
    """)

    {:ok, pipeline_id} = Pipeline.start_pipeline("gn1", %{ticket_id: "gn1#1"})
    assert_receive {:spawned, "publish", _}, 2_000

    ws = workspace_for(pipeline_id, "publish")
    # Le pod commite lui-même (identité engineer, injectée immuable en prod — ici mimée).
    pod_commits(
      ws,
      "feature.py",
      "x = 1\n",
      "feat: agent work",
      "engineer@lcars.local",
      "LCARS-engineer"
    )

    pod_completed(%{
      "pod_id" => "pod-publish",
      "ticket_id" => "gn1#1",
      "pipeline_id" => pipeline_id,
      "stage" => "publish",
      # En git_native, le payload ne porte pas de files : le livrable est dans le .git.
      "result" => %{"answer" => "committed"}
    })

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"git.published",
                     payload: %{
                       "pipeline_id" => ^pipeline_id,
                       "stage" => "publish",
                       "commit_sha" => <<_::binary-size(40)>>,
                       "pushed?" => false,
                       "mode" => "git_native"
                     }
                   },
                   2_000

    assert_receive %Fleet.Event{source: :pipeline, type: :"pipeline.completed"}, 2_000
  end

  test "git_native : pod usurpe une identité (architect) → git.publish_failed (bad_identity)",
       %{tmp_dir: tmp_dir} do
    Application.put_env(:fleet_pipeline, :deliverable_mode_resolver, fn _r, _p -> "git_native" end)

    bare = seed_remote(tmp_dir, "gn2-source")

    write_pipeline(tmp_dir, "gn2", """
        post_extract:
          git:
            repo_url: #{bare}
            branch: main
    """)

    {:ok, pipeline_id} = Pipeline.start_pipeline("gn2", %{ticket_id: "gn2#1"})
    assert_receive {:spawned, "publish", _}, 2_000

    ws = workspace_for(pipeline_id, "publish")
    # Le pod se fait passer pour l'architect → la gate (F-01) doit refuser.
    pod_commits(ws, "x.py", "x = 1\n", "fraud", "architect@lcars.local", "evil")

    pod_completed(%{
      "pod_id" => "pod-publish",
      "ticket_id" => "gn2#1",
      "pipeline_id" => pipeline_id,
      "stage" => "publish",
      "result" => %{"answer" => "committed"}
    })

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"git.publish_failed",
                     payload: %{"reason" => reason}
                   },
                   2_000

    assert String.contains?(reason, "bad_identity")
    assert String.contains?(reason, "architect@lcars.local")

    assert_receive %Fleet.Event{source: :pipeline, type: :"pipeline.completed"}, 2_000
  end

  test "git_native : pod n'a produit aucun commit → git.publish_failed (no_deliverable_commit)",
       %{tmp_dir: tmp_dir} do
    Application.put_env(:fleet_pipeline, :deliverable_mode_resolver, fn _r, _p -> "git_native" end)

    bare = seed_remote(tmp_dir, "gn3-source")

    write_pipeline(tmp_dir, "gn3", """
        post_extract:
          git:
            repo_url: #{bare}
            branch: main
    """)

    {:ok, pipeline_id} = Pipeline.start_pipeline("gn3", %{ticket_id: "gn3#1"})
    assert_receive {:spawned, "publish", _}, 2_000
    # Le pod n'a RIEN commité : HEAD == base.

    pod_completed(%{
      "pod_id" => "pod-publish",
      "ticket_id" => "gn3#1",
      "pipeline_id" => pipeline_id,
      "stage" => "publish",
      "result" => %{"answer" => "nothing"}
    })

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"git.publish_failed",
                     payload: %{"reason" => reason}
                   },
                   2_000

    assert String.contains?(reason, "no_deliverable_commit")

    assert_receive %Fleet.Event{source: :pipeline, type: :"pipeline.completed"}, 2_000
  end

  # ============================================================
  # Régression : stage SANS post_extract → comportement inchangé
  # ============================================================

  test "stage sans post_extract → aucun event git.*, comportement R1.3 inchangé",
       %{tmp_dir: tmp_dir} do
    write_pipeline(tmp_dir, "p4", "")

    {:ok, pipeline_id} = Pipeline.start_pipeline("p4", %{ticket_id: "p4#1"})
    assert_receive {:spawned, "publish", _}, 2_000

    pod_completed(%{
      "pod_id" => "pod-publish",
      "ticket_id" => "p4#1",
      "pipeline_id" => pipeline_id,
      "stage" => "publish",
      "result" => %{"answer" => "x"}
    })

    assert_receive %Fleet.Event{source: :pipeline, type: :"pipeline.completed"}, 2_000

    refute_receive %Fleet.Event{source: :pipeline, type: :"git.published"}, 200
    refute_receive %Fleet.Event{source: :pipeline, type: :"git.publish_failed"}, 200
  end
end
