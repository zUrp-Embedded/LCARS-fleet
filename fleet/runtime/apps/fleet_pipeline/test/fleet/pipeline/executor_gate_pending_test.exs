defmodule Fleet.Pipeline.GateMandateTaskQueueStub do
  @moduledoc """
  Stub TaskQueue pour R4/B : capture l'enqueue du mandat d'éval adressé au
  gatekeeper, rend un id de mandat déterministe (`= correlation_id`). Le test
  pilote ensuite l'event `task_queue.task_completed` pour rendre la décision.
  """
  def enqueue(pod_id, attrs) do
    # corr unique sans état global (le test le récupère via la probe → pas de
    # dépendance à un compteur partagé inter-tests).
    corr = "corr-#{System.unique_integer([:positive])}"
    send(:gate_probe, {:enqueued, corr, pod_id, attrs.metadata["stage"]})
    # Brief du mandat de GATE uniquement (le stage enqueue aussi via StageRunner).
    if pod_id == "gk-permanent", do: send(:gate_probe, {:brief, attrs.brief})
    {:ok, %{id: corr}}
  end
end

defmodule Fleet.Pipeline.GateEnqueueFailStub do
  @moduledoc """
  Stub : l'enqueue échoue UNIQUEMENT pour le gatekeeper (le stage s'enqueue
  normalement — StageRunner partage le même seam). Teste le fail-loud de la gate.
  """
  def enqueue("gk-permanent", _attrs), do: {:error, :broker_down}
  def enqueue(_pod_id, _attrs), do: {:ok, %{id: "stage-task"}}
end

defmodule Fleet.Pipeline.GatePendingStageStub do
  @moduledoc "Stub StageSpawner : spawn le pod de stage no-emit (complétion pilotée à la main)."
  @behaviour Fleet.Pipeline.StageSpawner

  @impl Fleet.Pipeline.StageSpawner
  def spawn_stage_pod(_role, _profile, ctx) do
    send(:gate_probe, {:spawned, ctx.stage})

    # F150 — expose le mandate_context du spawn (le test vérifie que `previous_failure` y arrive au retry).
    send(:gate_probe, {:stage_ctx, ctx.stage, ctx.mandate})
    {:ok, "pod-#{ctx.stage}"}
  end
end

defmodule Fleet.Pipeline.ExecutorGatePendingTest do
  @moduledoc """
  R4/B — state-machine de gate via mandat MCP. Un stage à gate (soft / terminal
  non-tranchable) **enqueue un mandat d'éval au gatekeeper permanent** (adressé
  par `gatekeeper_pod_id`) ; le pipeline reste `:awaiting_gate` jusqu'au
  `task_queue.task_completed` (corrélé par `correlation_id`), puis ré-évalue avec
  le vocab canon `gate-decision-v1.json` (continue → avance ; reste → halt).
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.EventRouter.Bus
  alias Fleet.Pipeline

  setup %{tmp_dir: tmp_dir} do
    Process.register(self(), :gate_probe)

    write_pipeline(tmp_dir, "softgate", soft_gate_yaml())
    write_pipeline(tmp_dir, "termgate", terminal_gate_yaml())
    write_pipeline(tmp_dir, "failgate", fail_gate_yaml())

    Application.put_env(:fleet_pipeline, :pipelines_root, tmp_dir)
    # Stage pods : spawn no-emit (la complétion de stage est pilotée à la main).
    Application.put_env(:fleet_pipeline, :spawner_backend, Fleet.Pipeline.GatePendingStageStub)
    # Gatekeeper permanent adressable (booté Type 3 dans la vraie vie ; ici fixe).
    Application.put_env(:fleet_pipeline, :gatekeeper_pod_id, "gk-permanent")
    Application.put_env(:fleet_pipeline, :task_queue, Fleet.Pipeline.GateMandateTaskQueueStub)
    Bus.subscribe()

    on_exit(fn ->
      # Plusieurs pipelines de ce module s'AUTO-stoppent (`:gate_halt`/`:gate_fail`)
      # → l'enfant peut déjà être mort quand le cleanup tourne (race which_children
      # ↔ terminate_child). Best-effort + catch :exit : un enfant/superviseur absent
      # n'est PAS une erreur de cleanup (sinon fail intermittent du run, indépendant
      # du test réel).
      try do
        for {_, pid, _, _} <- DynamicSupervisor.which_children(Fleet.Pipeline.ExecutorSupervisor) do
          DynamicSupervisor.terminate_child(Fleet.Pipeline.ExecutorSupervisor, pid)
        end
      catch
        :exit, _ -> :ok
      end

      for k <- [:pipelines_root, :spawner_backend, :gatekeeper_pod_id, :task_queue] do
        Application.delete_env(:fleet_pipeline, k)
      end
    end)

    :ok
  end

  defp write_pipeline(dir, name, yaml), do: File.write!(Path.join(dir, "#{name}.yaml"), yaml)

  defp soft_gate_yaml do
    """
    name: softgate
    version: 1
    stages:
      audit:
        role: scout
        profile: empty
        gate:
          type: soft
    """
  end

  defp terminal_gate_yaml do
    """
    name: termgate
    version: 1
    stages:
      audit:
        role: scout
        profile: empty
        gate:
          type: terminal
          rules:
            - name: soft_check
              required: false
              match:
                clean: true
    """
  end

  # F150 — hard gate dont la `rule` ne matche JAMAIS l'output `%{"ok" => true}` ⇒ `{:fail}` déterministe.
  defp fail_gate_yaml do
    """
    name: failgate
    version: 1
    stages:
      build:
        role: engineer
        profile: empty
        gate:
          type: hard
          rule:
            passed: true
    """
  end

  # Simule la complétion du mandat d'éval (gatekeeper submit_result → event canon
  # task_queue, corrélé par correlation_id). `result` = la décision JSON.
  defp complete_gate(corr, result) do
    Bus.broadcast("fleet.events", %Fleet.Event{
      source: :task_queue,
      type: :task_completed,
      timestamp: DateTime.utc_now(),
      correlation_id: corr,
      payload: %{task_id: corr, result: result}
    })
  end

  defp complete_stage(pid, stage) do
    Bus.broadcast("fleet.events", %Fleet.Event{
      source: :spawner,
      type: :"pod.completed",
      timestamp: DateTime.utc_now(),
      pod_id: "pod-#{stage}",
      payload: %{
        "pod_id" => "pod-#{stage}",
        "result" => %{"ok" => true},
        "pipeline_id" => pid,
        "stage" => stage
      }
    })
  end

  # Démarre + amène le stage `audit` jusqu'à l'enqueue du mandat au gatekeeper.
  defp start_to_gate(name) do
    {:ok, pid} = Pipeline.start_pipeline(name, %{ticket_id: "sg#{name}"})
    assert_receive {:spawned, "audit"}, 5_000
    complete_stage(pid, "audit")
    assert_receive {:enqueued, corr, "gk-permanent", "audit"}, 5_000
    {pid, corr}
  end

  test "gate → mandat enqueué au gatekeeper, pipeline en attente (pas d'avancement)" do
    {pid, _corr} = start_to_gate("softgate")
    # Le mandat porte le brief d'éval (sous-lot D — GateBrief câblé).
    assert_receive {:brief, brief}, 5_000
    assert brief =~ "gate-decision-v1.json"
    assert brief =~ "Stage jugé : audit"
    refute_receive %Fleet.Event{source: :pipeline, type: :"pipeline.completed"}, 200
    _ = pid
  end

  test "décision continue → pipeline.completed" do
    {pid, corr} = start_to_gate("softgate")
    complete_gate(corr, %{"decision" => "continue", "reason" => "ok"})

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.completed",
                     payload: %{"pipeline_id" => ^pid}
                   },
                   5_000
  end

  test "décision dans l'enveloppe worker %{status, result} → dépliée → continue (forme RÉELLE du pod)" do
    {pid, corr} = start_to_gate("softgate")

    # Forme RÉELLE qu'un pod gatekeeper soumet : `agent-worker-base.md` impose
    # l'enveloppe `%{"status","result"}` à TOUT submit_result ; le GateBrief
    # demande la décision DANS `result`. Le gatekeeper réconcilie en nichant.
    # Exposé LIVE par C4a (2026-06-06) : sans dépliage, l'Executor lisait
    # `result["decision"] = nil` → "halt_invalid" → le pipeline haltait alors
    # que le gatekeeper avait dit `continue`. Régression #C4a.
    complete_gate(corr, %{
      "status" => "ok",
      "result" => %{"decision" => "continue", "reason" => "soft_gate_pass_coherent_deliverable"}
    })

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.completed",
                     payload: %{"pipeline_id" => ^pid}
                   },
                   5_000
  end

  test "enveloppe worker status=failed (gatekeeper n'a pas pu juger) → halt fail-closed" do
    {pid, corr} = start_to_gate("softgate")

    # Mode fail explicite de `agent-worker-base.md` : pas de `result`, donc pas
    # de décision → halt fail-closed (jamais continue sur un fail de jugement).
    complete_gate(corr, %{
      "status" => "failed",
      "reason" => "ambiguous",
      "details" => "gate unclear"
    })

    assert_receive %Fleet.Event{source: :pipeline, type: :"pipeline.failed"}, 5_000
    refute_receive %Fleet.Event{type: :"pipeline.completed"}, 100
    _ = pid
  end

  test "enveloppe worker status=ok mais result=nil (sortie vide) → halt fail-closed" do
    {pid, corr} = start_to_gate("softgate")

    # `result` non-map (nil) → pas de dépliage (clause `when is_map(inner)` échoue),
    # pas de `"decision"` → halt. Jamais un continue silencieux sur une sortie vide.
    complete_gate(corr, %{"status" => "ok", "result" => nil})

    assert_receive %Fleet.Event{source: :pipeline, type: :"pipeline.failed"}, 5_000
    refute_receive %Fleet.Event{type: :"pipeline.completed"}, 100
    _ = pid
  end

  test "décision abandon → pipeline.failed (halt)" do
    {pid, corr} = start_to_gate("softgate")
    complete_gate(corr, %{"decision" => "abandon", "reason" => "not salvageable"})

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.failed",
                     payload: %{"pipeline_id" => ^pid, "reason" => reason}
                   },
                   5_000

    assert reason =~ "abandon"
  end

  test "décision redirect → pipeline.failed, décision portée pour le handoff" do
    {pid, corr} = start_to_gate("softgate")
    complete_gate(corr, %{"decision" => "redirect", "reason" => "mandate_too_big_needs_split"})

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.failed",
                     payload: %{"pipeline_id" => ^pid, "reason" => reason}
                   },
                   5_000

    assert reason =~ "redirect"
  end

  test "décision malformée (pas de :decision) → halt (fail-closed, jamais continue)" do
    {pid, corr} = start_to_gate("softgate")
    complete_gate(corr, %{"garbage" => true})

    assert_receive %Fleet.Event{source: :pipeline, type: :"pipeline.failed"}, 5_000
    refute_receive %Fleet.Event{type: :"pipeline.completed"}, 100
    _ = pid
  end

  test "terminal non-tranchable → mandat gatekeeper ; continue → completed" do
    {:ok, pid} = Pipeline.start_pipeline("termgate", %{ticket_id: "tg"})
    assert_receive {:spawned, "audit"}, 5_000
    complete_stage(pid, "audit")
    assert_receive {:enqueued, corr, "gk-permanent", "audit"}, 5_000

    complete_gate(corr, %{"decision" => "continue", "reason" => "ok"})

    assert_receive %Fleet.Event{type: :"pipeline.completed", payload: %{"pipeline_id" => ^pid}},
                   5_000
  end

  test "aucun gatekeeper booté (gatekeeper_pod_id nil) → fail-loud (jamais silent pass)" do
    Application.delete_env(:fleet_pipeline, :gatekeeper_pod_id)
    {:ok, pid} = Pipeline.start_pipeline("softgate", %{ticket_id: "nogk"})
    assert_receive {:spawned, "audit"}, 5_000
    complete_stage(pid, "audit")

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.failed",
                     payload: %{"pipeline_id" => ^pid, "reason" => reason}
                   },
                   5_000

    assert reason =~ "no gatekeeper"
  end

  test "enqueue du mandat échoue → fail-loud" do
    Application.put_env(:fleet_pipeline, :task_queue, Fleet.Pipeline.GateEnqueueFailStub)
    {:ok, pid} = Pipeline.start_pipeline("softgate", %{ticket_id: "enqfail"})
    assert_receive {:spawned, "audit"}, 5_000
    complete_stage(pid, "audit")

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.failed",
                     payload: %{"pipeline_id" => ^pid, "reason" => reason}
                   },
                   5_000

    assert reason =~ "enqueue failed"
  end

  # ── F150 — retry borné système-side + interception au seuil ───────────────────
  test "F150 — hard-gate FAIL : retry borné par le SYSTÈME, puis interception gatekeeper au seuil" do
    {:ok, pid} = Pipeline.start_pipeline("failgate", %{ticket_id: "f150"})
    assert_receive {:spawned, "build"}, 5_000

    # 1er FAIL → le système RETRY (re-spawn le stage) ; il ne tue PAS le pipeline (≠ ancien
    # comportement « 1er FAIL = pipeline mort »). Le compteur vit dans l'Executor, pas le pod.
    complete_stage(pid, "build")
    assert_receive {:spawned, "build"}, 5_000

    # Feedback (fork 3) : le re-dispatch porte `previous_failure` (raison + tentative) → l'eng REÇOIT
    # quoi corriger (pas juste un re-spawn aveugle). Pattern sélectif : le spawn INITIAL n'a pas la clé.
    assert_receive {:stage_ctx, "build",
                    %{"previous_failure" => %{"attempt" => 1, "reason" => _}}},
                   5_000

    # 2e FAIL → retry encore (toujours sous le seuil 3).
    complete_stage(pid, "build")
    assert_receive {:spawned, "build"}, 5_000

    # 3e FAIL → INTERCEPTION : mandat de DIAGNOSTIC au gatekeeper (PAS un 4e retry infini).
    complete_stage(pid, "build")
    assert_receive {:enqueued, corr, "gk-permanent", "build"}, 5_000
    assert_receive {:brief, brief}, 5_000
    assert brief =~ "retry_exhausted"
    # Le brief cadre le diagnostic : mandat mal construit → `redirect` (renvoi arch).
    assert brief =~ "redirect"

    # La décision du diagnostic revient par le MÊME chemin que les gates (handle_gate_decision) :
    # `redirect` (mandat mal construit → renvoi arch) → halt, décision portée pour le handoff aval.
    complete_gate(corr, %{"decision" => "redirect", "reason" => "mandat trop gros"})

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.failed",
                     payload: %{"pipeline_id" => ^pid}
                   },
                   5_000
  end

  test "F150 — borne configurable : stage_max_retries=1 → interception au 1er FAIL (zéro retry)" do
    Application.put_env(:fleet_pipeline, :stage_max_retries, 1)
    on_exit(fn -> Application.delete_env(:fleet_pipeline, :stage_max_retries) end)

    {:ok, pid} = Pipeline.start_pipeline("failgate", %{ticket_id: "f150max1"})
    assert_receive {:spawned, "build"}, 5_000

    # max=1 → n=1 n'est PAS < 1 → interception immédiate, AUCUN re-spawn de "build".
    complete_stage(pid, "build")
    assert_receive {:enqueued, _corr, "gk-permanent", "build"}, 5_000
    refute_received {:spawned, "build"}
  end

  test "F150 — diagnostic qui revient `continue` → halt fail-closed (JAMAIS avancer un livrable non validé)" do
    # Un livrable qui a échoué la gate au seuil NE doit pas avancer même si le gatekeeper rend `continue`
    # (le brief l'interdit, mais on ne fait pas confiance au seul texte : enforcement code-side).
    Application.put_env(:fleet_pipeline, :stage_max_retries, 1)
    on_exit(fn -> Application.delete_env(:fleet_pipeline, :stage_max_retries) end)

    {:ok, pid} = Pipeline.start_pipeline("failgate", %{ticket_id: "f150cont"})
    assert_receive {:spawned, "build"}, 5_000
    complete_stage(pid, "build")
    assert_receive {:enqueued, corr, "gk-permanent", "build"}, 5_000

    complete_gate(corr, %{
      "decision" => "continue",
      "reason" => "(le gatekeeper tente d'avancer à tort)"
    })

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.failed",
                     payload: %{"pipeline_id" => ^pid, "reason" => reason}
                   },
                   5_000

    assert reason =~ "continue` INVALIDE"
    refute_received %Fleet.Event{type: :"pipeline.completed"}
  end
end
