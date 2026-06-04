defmodule Fleet.Pipeline.R1SeamTest do
  @moduledoc """
  R1 — filet anti-régression : tests d'intégration des VRAIES coutures avec
  la forme canon `%Fleet.Event{}`, SANS les stubs qui masquent (on n'utilise
  PAS `StageSpawnerStub`, qui auto-complète via un tuple legacy).

  ROUGES sur le code actuel : ils prouvent la classe de dérive BL-021
  (producteurs migrés au schema canon `%Fleet.Event{}`, consommateurs restés
  sur le tuple legacy `{atom, %{"event_type" => ...}}`). Passent au vert quand
  R2 (consommateurs→canon) et R3 (pipeline v2.5 exécutable) landent.

  Tag `:r1_seam` — exclus du run par défaut (cf. test_helper), lancés via
  `mix test --only r1_seam`.
  """
  use ExUnit.Case, async: false

  @moduletag :r1_seam

  alias Fleet.EventRouter.Bus
  alias Fleet.Pipeline.Executor

  # Backend qui spawn SANS auto-compléter (≠ StageSpawnerStub qui broadcast un
  # `pipeline.stage.completed` legacy et masquerait la couture). Enregistre
  # chaque spawn auprès du pid test → on observe l'avancement réel de stage.
  defmodule SpawnOnlyBackend do
    @behaviour Fleet.Pipeline.StageSpawner

    @impl Fleet.Pipeline.StageSpawner
    def spawn_stage_pod(role, _profile, stage_ctx) do
      case Application.get_env(:fleet_pipeline, :r1_test_pid) do
        pid when is_pid(pid) -> send(pid, {:spawned, stage_ctx.stage, role})
        _ -> :ok
      end

      {:ok, "r1-pod-#{stage_ctx.stage}"}
    end
  end

  defmodule NoopTaskQueue do
    def enqueue(_pod_id, _attrs), do: {:ok, %{id: "r1-task"}}
  end

  setup do
    Application.put_env(:fleet_pipeline, :spawner_backend, SpawnOnlyBackend)
    Application.put_env(:fleet_pipeline, :task_queue, NoopTaskQueue)
    Application.put_env(:fleet_pipeline, :lifetime_scope_resolver, fn _r, _p -> "one-shot" end)
    Application.put_env(:fleet_pipeline, :r1_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:fleet_pipeline, :spawner_backend)
      Application.delete_env(:fleet_pipeline, :task_queue)
      Application.delete_env(:fleet_pipeline, :lifetime_scope_resolver)
      Application.delete_env(:fleet_pipeline, :r1_test_pid)
    end)

    :ok
  end

  defp canon_pod_completed(pipeline_id, stage) do
    # Forme EXACTE émise par Fleet.Spawner.Pod.safe_broadcast/2 (pod.ex:257-270).
    %Fleet.Event{
      source: :spawner,
      type: :"pod.completed",
      timestamp: DateTime.utc_now(),
      pod_id: "r1-pod-#{stage}",
      correlation_id: nil,
      payload: %{
        "pod_id" => "r1-pod-#{stage}",
        "ticket_id" => "t-#{pipeline_id}",
        "result" => %{"ok" => true},
        "pipeline_id" => pipeline_id,
        "stage" => stage
      }
    }
  end

  # T1 — pod.completed (struct canon) → l'Executor complète le stage.
  test "T1 — %Fleet.Event{:\"pod.completed\"} canon fait avancer l'Executor" do
    Bus.subscribe()
    pid = "r1-t1-#{System.unique_integer([:positive])}"

    {:ok, _exec} = start_supervised({Executor, pipeline_id: pid, pipeline_name: "judge-ping"})

    # Stage unique "audit" (qualifier), sans gate → :pass à complétion.
    assert_receive {:spawned, "audit", "qualifier"}, 2_000

    Bus.broadcast("fleet.events", canon_pod_completed(pid, "audit"))

    # Stage unique complété ⇒ pipeline.completed (struct canon) broadcast.
    # RED : la struct tombe dans le catch-all handle_info (executor.ex:149) →
    # droppée → pipeline.completed jamais émis → timeout.
    assert_receive %Fleet.Event{type: :"pipeline.completed", payload: %{"pipeline_id" => ^pid}},
                   2_000
  end

  # T3 — l'Executor exécute un pipeline canon v2.5 (enveloppe spec.stages).
  test "T3 — pipeline v2.5 canon (standard-qa, spec.stages) est exécutable" do
    pid = "r1-t3-#{System.unique_integer([:positive])}"

    # standard-qa.yaml = enveloppe v2.5. Loader.load! la valide mais ne déballe
    # PAS `spec` → Executor lit pipeline["stages"] = nil → Map.keys(nil) crash
    # à l'init. RED : le pipeline canon ne démarre pas. Après U1 (Loader-
    # normalizer) + R3 (inputs/gate v2.5), le 1er stage doit être spawné.
    {:ok, _exec} = start_supervised({Executor, pipeline_id: pid, pipeline_name: "standard-qa"})

    assert_receive {:spawned, "brainstorm", "architect-interactive"}, 2_000
  end

  # T6 (e2e) — spawn stage_a → pod.completed canon → gate → spawn stage_b.
  @tag :tmp_dir
  test "T6 (e2e) — pod.completed canon stage_a déclenche le spawn de stage_b", %{tmp_dir: tmp} do
    pipelines_dir = Path.join(tmp, "pipelines")
    File.mkdir_p!(pipelines_dir)

    File.write!(Path.join(pipelines_dir, "r1-e2e.yaml"), """
    name: r1-e2e
    version: 1
    stages:
      stage_a:
        role: scout
        profile: noop
      stage_b:
        role: scout
        profile: noop
        needs: [stage_a]
    """)

    Application.put_env(:fleet_pipeline, :pipelines_root, pipelines_dir)
    on_exit(fn -> Application.delete_env(:fleet_pipeline, :pipelines_root) end)

    Bus.subscribe()
    pid = "r1-t6-#{System.unique_integer([:positive])}"

    {:ok, _exec} = start_supervised({Executor, pipeline_id: pid, pipeline_name: "r1-e2e"})

    assert_receive {:spawned, "stage_a", "scout"}, 2_000

    Bus.broadcast("fleet.events", canon_pod_completed(pid, "stage_a"))

    # RED : la complétion canon de stage_a est droppée → stage_b jamais spawné.
    assert_receive {:spawned, "stage_b", "scout"}, 2_000
  end
end
