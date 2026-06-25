defmodule Fleet.MCP.ResultEventTest do
  @moduledoc """
  Completion event-driven (ADR-G) — sur `submit_result`, le **broker** `fleet_task_queue`
  broadcast `%Fleet.Event{source: :task_queue, type: :task_completed}` sur `fleet.events`.

  `pod.ex` (Ring 1) y souscrit pour déclencher sa complétion SANS lire fleet_mcp (Ring 4)
  en direct. Ici on prouve l'émission via le tool `submit_result` (PUR, pas de claude).
  `fleet_mcp` n'émet plus le string-topic `pod.result_submitted` — c'est le broker qui possède l'event.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TaskQueue

  # Identité prouvée par capability (même modèle de test que pod_tools_test) : le résolveur stubbé reconnaît
  # tout pod via `"CAP-" <> pod_id`. Le pod légitime présente cette capability → la gate passe.
  setup do
    prev = Application.get_env(:fleet_mcp, :pod_resolver)

    Application.put_env(:fleet_mcp, :pod_resolver, fn pod_id ->
      {:ok, %{role: "engineer", capability: "CAP-" <> pod_id}}
    end)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:fleet_mcp, :pod_resolver, prev),
        else: Application.delete_env(:fleet_mcp, :pod_resolver)
    end)

    :ok
  end

  test "submit_result → broker broadcast %Fleet.Event{task_completed} (pod_id + correlation_id)" do
    pod = "pod-evt-#{System.unique_integer([:positive])}"
    {:ok, task} = TaskQueue.enqueue(pod, %{brief: "x"})
    tid = task.id
    Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")

    payload = %{"answer" => "42", "nonce" => "evt-#{System.unique_integer([:positive])}"}

    assert {:ok, %{content: [%{"type" => "text"}]}, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{
                 "payload" => payload,
                 "task_id" => tid,
                 "_lcars_pod_id" => pod,
                 "_lcars_pod_capability" => "CAP-" <> pod
               },
               %{}
             )

    # Le livrable broadcasté = le `payload` métier EXACT (le task_id, corrélateur de transport, est retiré
    # du result stocké par le broker → pas de pollution du livrable).
    assert_receive %Fleet.Event{
                     source: :task_queue,
                     type: :task_completed,
                     pod_id: ^pod,
                     correlation_id: ^tid,
                     payload: %{result: ^payload}
                   },
                   2_000
  end

  test "submit_result sans _lcars_pod_id → erreur (pas de broadcast)" do
    Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")
    payload = %{"answer" => "anon-#{System.unique_integer([:positive])}"}

    assert {:error, :pod_id_required, %{}} =
             PodTools.handle_tool_call("submit_result", %{"payload" => payload}, %{})

    refute_receive %Fleet.Event{source: :task_queue, type: :task_completed}, 200
  end

  test "submit_result avec task_id NICHÉ dans le payload (pas top-level) → accepté + clôt le mandat" do
    # Régression live (e2e) : un agent juge range son task_id DANS le payload de verdict au lieu du
    # paramètre top-level. Le broker corrèle pod_id ↔ task_id quel que soit l'emplacement → le livrable
    # NE DOIT PAS être perdu (sinon le hop review timeout → escalade → pipeline gelé, observé sur le
    # qualifier qui tâtonnait `payload:{decision, task_id}` à l'infini contre `:task_id_required`).
    pod = "pod-evt-#{System.unique_integer([:positive])}"
    {:ok, task} = TaskQueue.enqueue(pod, %{brief: "x"})
    tid = task.id
    Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")

    # task_id ABSENT du top-level, présent DANS le payload — la forme exacte produite par le juge en e2e.
    verdict = %{"decision" => "continue", "reason" => "ok", "task_id" => tid}

    assert {:ok, %{content: [%{"type" => "text"}]}, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{
                 "payload" => verdict,
                 "_lcars_pod_id" => pod,
                 "_lcars_pod_capability" => "CAP-" <> pod
               },
               %{}
             )

    # Le corrélateur de transport est retiré du livrable STOCKÉ, même rangé dans le payload (pas de pollution).
    assert_receive %Fleet.Event{
                     source: :task_queue,
                     type: :task_completed,
                     pod_id: ^pod,
                     correlation_id: ^tid,
                     payload: %{result: result}
                   },
                   2_000

    assert result == %{"decision" => "continue", "reason" => "ok"}
  end

  test "submit_result sans task_id NI au top-level NI dans le payload → :task_id_required (garde tenue)" do
    # La tolérance d'emplacement ne rouvre PAS le fallback supprimé : task_id absent des DEUX = refus net
    # (sinon le broker retomberait sur « la dernière active du pod » — le levier d'impersonation).
    pod = "pod-evt-#{System.unique_integer([:positive])}"
    {:ok, _task} = TaskQueue.enqueue(pod, %{brief: "x"})
    Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")

    assert {:error, :task_id_required, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{
                 "payload" => %{"decision" => "continue"},
                 "_lcars_pod_id" => pod,
                 "_lcars_pod_capability" => "CAP-" <> pod
               },
               %{}
             )

    refute_receive %Fleet.Event{source: :task_queue, type: :task_completed}, 200
  end
end
