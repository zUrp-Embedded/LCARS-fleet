defmodule Fleet.MCP.PodToolsTest do
  @moduledoc """
  Gate R-CORE.comm inc3b.1 — couche tool MCP pod-facing (`Fleet.MCP.PodTools`,
  `use ExMCP.Server`) round-trip avec la file in-memory `Fleet.MCP.TaskQueue`.

  PUR Elixir : appelle `handle_tool_call/3` en direct (pas de transport, pas de
  claude). Preuve : un nonce déposé UNIQUEMENT dans la file ressort via `get_task`
  (canal IN) et est ré-encaissé via `submit_result` (canal OUT). C'est la couche
  tool RÉELLE (SDK ex_mcp) qui remplacera la fixture python ; inc3b.2 ajoute le
  transport HTTP-SSE, inc3b.3 le pod réel.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.{PodTools, TaskQueue}

  setup do
    start_supervised!(TaskQueue)
    :ok
  end

  test "canal IN+OUT round-trip nonce via get_task/submit_result" do
    nonce = "inc3b1-#{System.system_time(:second)}-#{:rand.uniform(1_000_000)}"
    :ok = TaskQueue.push(%{"id" => 1, "ask" => "Reponds EXACTEMENT : #{nonce}"})

    # Canal IN : get_task pop la tâche (le nonce vient de la file, pas du brief).
    assert {:ok, %{content: [%{"type" => "text", "text" => t1}]}, %{}} =
             PodTools.handle_tool_call("get_task", %{}, %{})

    assert {:ok, %{"done" => false, "task" => %{"id" => 1, "ask" => ask}}} = Jason.decode(t1)
    assert ask =~ nonce

    # Canal OUT : submit_result encaisse le résultat (avec le nonce).
    assert {:ok, %{content: [%{"type" => "text"}]}, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"id" => 1, "answer" => nonce}},
               %{}
             )

    assert [%{"id" => 1, "answer" => ^nonce}] = TaskQueue.results()

    # File vidée → get_task suivant = done (le pod s'arrête).
    assert {:ok, %{content: [%{"type" => "text", "text" => t2}]}, %{}} =
             PodTools.handle_tool_call("get_task", %{}, %{})

    assert {:ok, %{"done" => true}} = Jason.decode(t2)

    # Tool inconnu / mauvais args → erreurs propres.
    assert {:error, :unknown_tool, %{}} = PodTools.handle_tool_call("nope", %{}, %{})

    assert {:error, :invalid_arguments, %{}} =
             PodTools.handle_tool_call("submit_result", %{}, %{})
  end

  describe "ciblage pod_id (multi-pod pipeline)" do
    # Pattern pipeline standard-qa : N pods consomment la même TaskQueue
    # centrale. Le routage par `_lcars_pod_id` permet à chaque pod de ne
    # voir QUE ses tâches (engineer pipe + judges one-shot en parallèle).

    test "get_task avec _lcars_pod_id pop uniquement les tâches du pod ciblé" do
      :ok = TaskQueue.push(%{"id" => "T1", "_lcars_pod_id" => "pod-A"})
      :ok = TaskQueue.push(%{"id" => "T2", "_lcars_pod_id" => "pod-B"})
      :ok = TaskQueue.push(%{"id" => "T3", "_lcars_pod_id" => "pod-A"})

      # pod-B voit T2 (saute T1 destinée à A).
      assert {:ok, %{content: [%{"text" => t1}]}, %{}} =
               PodTools.handle_tool_call("get_task", %{"_lcars_pod_id" => "pod-B"}, %{})

      assert {:ok, %{"done" => false, "task" => task_b}} = Jason.decode(t1)
      assert task_b["id"] == "T2"
      # `_lcars_pod_id` strippé de la task vue par le pod (metafield fleet-side).
      refute Map.has_key?(task_b, "_lcars_pod_id")

      # pod-A voit T1 puis T3 (ordre FIFO préservé parmi ses éligibles).
      assert {:ok, %{content: [%{"text" => t2}]}, %{}} =
               PodTools.handle_tool_call("get_task", %{"_lcars_pod_id" => "pod-A"}, %{})

      assert {:ok, %{"task" => %{"id" => "T1"}}} = Jason.decode(t2)

      assert {:ok, %{content: [%{"text" => t3}]}, %{}} =
               PodTools.handle_tool_call("get_task", %{"_lcars_pod_id" => "pod-A"}, %{})

      assert {:ok, %{"task" => %{"id" => "T3"}}} = Jason.decode(t3)

      # File vide pour pod-A.
      assert {:ok, %{content: [%{"text" => t4}]}, %{}} =
               PodTools.handle_tool_call("get_task", %{"_lcars_pod_id" => "pod-A"}, %{})

      assert {:ok, %{"done" => true}} = Jason.decode(t4)
    end

    test "tâche untargeted (`_lcars_pod_id` absent) prise par n'importe quel pod" do
      :ok = TaskQueue.push(%{"id" => "T-untargeted"})

      assert {:ok, %{content: [%{"text" => t}]}, %{}} =
               PodTools.handle_tool_call("get_task", %{"_lcars_pod_id" => "pod-X"}, %{})

      assert {:ok, %{"done" => false, "task" => %{"id" => "T-untargeted"}}} = Jason.decode(t)
    end
  end
end
