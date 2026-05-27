defmodule Fleet.Pipeline.StageRunnerPipeTest do
  @moduledoc """
  Tests du chantier engineer long-lived : `Fleet.Pipeline.StageRunner`
  réutilise le pod pipe-scoped à travers stages au lieu de spawn neuf.

  ## Scénario testé

  1. Cycle 1 : pas de pod en registry → spawn + register dans
     `PodRegistry`.
  2. Cycle 2 : lookup trouve pod → wake (send `yop` via stub) + push
     task ciblée `_lcars_pod_id` dans TaskQueue (cohérent
     `PodTools.get_task` qui filtre par `_lcars_pod_id`).

  ## Stubs utilisés

    * `SpawnerBackendStub` — spawn synchrone qui broadcast (existant)
    * `SpawnerStub` — intercepte `wake_pod` / `kill_pod` pour assertion
    * Resolver `lifetime_scope_resolver` injecté en config (skip I/O
      cap-profile YAML)
  """

  use ExUnit.Case, async: false

  alias Fleet.MCP.TaskQueue
  alias Fleet.Pipeline.{PodRegistry, SpawnerStub, StageRunner}

  setup do
    Application.put_env(:fleet_pipeline, :spawner_backend, Fleet.Pipeline.StageSpawnerStub)
    Application.put_env(:fleet_pipeline, :spawner, SpawnerStub)

    # Resolver lifetime_scope : "engineer" → pipe, autres → one-shot.
    Application.put_env(
      :fleet_pipeline,
      :lifetime_scope_resolver,
      fn
        "engineer", _ -> "pipe"
        _other, _ -> "one-shot"
      end
    )

    start_supervised!(TaskQueue)
    start_supervised!(SpawnerStub)

    on_exit(fn ->
      Application.delete_env(:fleet_pipeline, :spawner_backend)
      Application.delete_env(:fleet_pipeline, :spawner)
      Application.delete_env(:fleet_pipeline, :lifetime_scope_resolver)
    end)

    :ok
  end

  defp stage_spec(role) do
    %{
      "role" => role,
      "profile" => nil
    }
  end

  describe "cycle pipe-scoped (engineer long-lived)" do
    test "cycle 1 spawn + register PodRegistry ; cycle 2 wake (pas de re-spawn)" do
      pipeline_id = "test-pipe-#{System.unique_integer([:positive])}"
      mandate_ctx = %{ticket_id: "ticket-1"}

      # Cycle 1 : registry vide → spawn classique via SpawnerBackendStub
      # + register dans PodRegistry.
      assert {:ok, pod_id_1} =
               StageRunner.run(
                 "implement",
                 stage_spec("engineer"),
                 mandate_ctx,
                 %{},
                 pipeline_id
               )

      # SpawnerBackendStub retourne "stub-pod-<stage>".
      assert pod_id_1 == "stub-pod-implement"

      # Registry contient maintenant le binding {pipeline_id, engineer} → pod.
      assert {:ok, ^pod_id_1} = PodRegistry.lookup(pipeline_id, "engineer")

      # Aucun wake_pod sur cycle 1 (c'était un spawn neuf).
      assert SpawnerStub.wake_calls() == []

      # Cycle 2 : même pipeline + même role → lookup hit → wake + push task
      # (PAS de nouveau pod spawn).
      assert {:ok, ^pod_id_1} =
               StageRunner.run(
                 "implement",
                 stage_spec("engineer"),
                 mandate_ctx,
                 # outputs prior (cycle audit → renvoi-au-dev)
                 %{"spec-review" => %{"findings" => ["fix this"]}},
                 pipeline_id
               )

      # wake_pod a été appelé une fois avec le pod existant.
      assert SpawnerStub.wake_calls() == [pod_id_1]

      # Une task est dans la TaskQueue, ciblée _lcars_pod_id == pod_id_1.
      assert {:ok, task} = TaskQueue.next_for(pod_id_1)
      assert task["_lcars_pod_id"] == pod_id_1
      assert task["stage"] == "implement"
      assert task["ticket_id"] == "ticket-1"

      # Registry inchangé (pas de re-register sur wake).
      assert {:ok, ^pod_id_1} = PodRegistry.lookup(pipeline_id, "engineer")

      # Cleanup
      PodRegistry.cleanup_pipeline(pipeline_id)
    end

    test "cycle one-shot ne touche pas le PodRegistry" do
      pipeline_id = "test-os-#{System.unique_integer([:positive])}"
      mandate_ctx = %{ticket_id: "ticket-2"}

      # qualifier = one-shot par resolver → path classique (spawn sans
      # register).
      assert {:ok, pod_id} =
               StageRunner.run(
                 "spec-review",
                 stage_spec("qualifier"),
                 mandate_ctx,
                 %{},
                 pipeline_id
               )

      assert pod_id == "stub-pod-spec-review"

      # Pas de registration.
      assert :not_found = PodRegistry.lookup(pipeline_id, "qualifier")
      # Pas de wake (c'était spawn neuf).
      assert SpawnerStub.wake_calls() == []
    end

    test "task wake porte les inputs prior_outputs (correction d'audit)" do
      pipeline_id = "test-aud-#{System.unique_integer([:positive])}"

      # Cycle 1 spawn
      StageRunner.run("implement", stage_spec("engineer"), %{ticket_id: "t"}, %{}, pipeline_id)

      # Cycle 2 wake avec findings audit en inputs
      stage_spec_with_inputs = %{
        "role" => "engineer",
        "profile" => nil,
        "inputs" => [%{"from_stage" => "spec-review", "key" => "findings"}]
      }

      StageRunner.run(
        "implement",
        stage_spec_with_inputs,
        %{ticket_id: "t"},
        %{"spec-review" => %{"findings" => ["fix this"]}},
        pipeline_id
      )

      assert {:ok, task} = TaskQueue.next_for("stub-pod-implement")
      assert task["inputs"] == %{"spec-review" => ["fix this"]}
      assert task["description"] =~ "Inputs (stages amont)"

      PodRegistry.cleanup_pipeline(pipeline_id)
    end
  end
end
