defmodule Fleet.MCP.PodToolsTest do
  @moduledoc """
  Couche tool MCP pod-facing (`Fleet.MCP.PodTools`) round-trip avec le **vrai broker**
  `Fleet.TaskQueue` (ADR-G — remplace le stub in-memory).

  PUR Elixir : appelle `handle_tool_call/3` en direct (pas de transport, pas de claude).
  Le mandat enqueué pour un pod ressort via `get_task` (canal IN, avec `task_id` =
  correlation_id) et le livrable est encaissé via `submit_result` (canal OUT).
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TaskQueue

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  test "round-trip get_task/submit_result d'un mandat enqueué pour le pod" do
    pod = uniq("pod-rt")
    nonce = "rt-#{System.unique_integer([:positive])}"
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: nonce, role: "engineer"})

    # Canal IN : get_task renvoie le mandat (brief = nonce) + task_id (correlation).
    assert {:ok, %{content: [%{"type" => "text", "text" => t1}]}, %{}} =
             PodTools.handle_tool_call("get_task", %{"_lcars_pod_id" => pod}, %{})

    assert {:ok, %{"done" => false, "task" => task}} = Jason.decode(t1)
    assert task["brief"] == nonce
    assert is_binary(task["task_id"])
    refute Map.has_key?(task, "_lcars_pod_id")

    # Canal OUT : submit_result encaisse le livrable → mandat :completed.
    assert {:ok, %{content: [%{"type" => "text"}]}, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"answer" => nonce}, "_lcars_pod_id" => pod},
               %{}
             )

    assert {:ok, :completed} = TaskQueue.pod_status(pod)

    # Plus de mandat actif → get_task suivant = done (le pod s'arrête).
    assert {:ok, %{content: [%{"text" => t2}]}, %{}} =
             PodTools.handle_tool_call("get_task", %{"_lcars_pod_id" => pod}, %{})

    assert {:ok, %{"done" => true}} = Jason.decode(t2)
  end

  test "get_task sans _lcars_pod_id (anomalie pont) → done:true" do
    assert {:ok, %{content: [%{"text" => t}]}, %{}} =
             PodTools.handle_tool_call("get_task", %{}, %{})

    assert {:ok, %{"done" => true}} = Jason.decode(t)
  end

  test "submit_result sans _lcars_pod_id → erreur (le pod doit être identifié)" do
    assert {:error, :pod_id_required, %{}} =
             PodTools.handle_tool_call("submit_result", %{"payload" => %{"x" => 1}}, %{})
  end

  test "tool inconnu / mauvais args → erreurs propres" do
    assert {:error, :unknown_tool, %{}} = PodTools.handle_tool_call("nope", %{}, %{})

    assert {:error, :invalid_arguments, %{}} =
             PodTools.handle_tool_call("submit_result", %{}, %{})
  end

  describe "routage par pod (multi-pod pipeline)" do
    test "chaque pod ne voit QUE son propre mandat" do
      pod_a = uniq("pod-A")
      pod_b = uniq("pod-B")
      {:ok, _} = TaskQueue.enqueue(pod_a, %{brief: "for-A"})
      {:ok, _} = TaskQueue.enqueue(pod_b, %{brief: "for-B"})

      assert {:ok, %{content: [%{"text" => tb}]}, %{}} =
               PodTools.handle_tool_call("get_task", %{"_lcars_pod_id" => pod_b}, %{})

      assert {:ok, %{"done" => false, "task" => %{"brief" => "for-B"}}} = Jason.decode(tb)

      assert {:ok, %{content: [%{"text" => ta}]}, %{}} =
               PodTools.handle_tool_call("get_task", %{"_lcars_pod_id" => pod_a}, %{})

      assert {:ok, %{"done" => false, "task" => %{"brief" => "for-A"}}} = Jason.decode(ta)
    end
  end
end
