defmodule Fleet.MCP.ResultEventTest do
  @moduledoc """
  Completion event-driven — sur `submit_result`, le **broker** `fleet_task_queue`
  broadcast `%Fleet.Event{source: :task_queue, type: :task_completed}` sur `fleet.events`.

  `pod.ex` (Ring 1) y souscrit pour déclencher sa complétion SANS lire fleet_mcp (Ring 4)
  en direct. Ici on prouve l'émission via le tool `submit_result` (PUR, pas de claude).
  L'identité du pod vient du `state` (`%{pod_id: pod}`) — porté par l'accepteur de socket
  en prod, jamais des arguments.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TaskQueue

  defp pod_state(pod), do: %{pod_id: pod}

  test "submit_result → broker broadcast %Fleet.Event{task_completed} (pod_id + correlation_id)" do
    pod = "pod-evt-#{System.unique_integer([:positive])}"
    {:ok, task} = TaskQueue.enqueue(pod, %{brief: "x"})
    tid = task.id
    Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")

    payload = %{"answer" => "42", "nonce" => "evt-#{System.unique_integer([:positive])}"}

    assert {:ok, %{content: [%{"type" => "text"}]}, _} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => payload, "task_id" => tid},
               pod_state(pod)
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

  test "submit_result sans pod_id dans le state → erreur (pas de broadcast)" do
    Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")
    payload = %{"answer" => "anon-#{System.unique_integer([:positive])}"}

    assert {:error, :pod_id_required, %{}} =
             PodTools.handle_tool_call("submit_result", %{"payload" => payload}, %{})

    refute_receive %Fleet.Event{source: :task_queue, type: :task_completed}, 200
  end

  test "submit_result avec task_id NICHÉ dans le payload (pas top-level) → accepté + clôt le brief" do
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

    assert {:ok, %{content: [%{"type" => "text"}]}, _} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => verdict},
               pod_state(pod)
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

    assert {:error, :task_id_required, _} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"decision" => "continue"}},
               pod_state(pod)
             )

    refute_receive %Fleet.Event{source: :task_queue, type: :task_completed}, 200
  end
end
