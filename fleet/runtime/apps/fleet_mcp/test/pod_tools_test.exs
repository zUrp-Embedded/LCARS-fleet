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

  test "get_task sans _lcars_pod_id (anomalie pont) → erreur typée (F045, symétrie submit_result)" do
    # F045 : un pod_id absent = erreur de config (LCARS_POD_ID perdu), pas une fin de
    # mandat. Ne JAMAIS masquer en done:true — sinon le pod s'arrête en croyant avoir fini.
    assert {:error, :pod_id_required, %{}} =
             PodTools.handle_tool_call("get_task", %{}, %{})
  end

  test "submit_result sans _lcars_pod_id → erreur (le pod doit être identifié)" do
    assert {:error, :pod_id_required, %{}} =
             PodTools.handle_tool_call("submit_result", %{"payload" => %{"x" => 1}}, %{})
  end

  test "submit_result sans mandat actif → erreur :no_active_task (F046 : le drop n'est pas masqué)" do
    # F046 : un pod qui submit sans mandat actif (jamais assigné, ou clos/réassigné depuis) → son
    # livrable n'a NULLE PART où aller = DROP. Doit ressortir isError, PAS {:ok "ok"} — sinon le pod
    # croit son livrable accepté. Symétrie avec :task_id_mismatch / :pod_id_required (classe F045).
    pod = uniq("pod-no-task")

    assert {:error, :no_active_task, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"x" => 1}, "_lcars_pod_id" => pod},
               %{}
             )
  end

  test "submit_result en double (mandat déjà clos) → {:ok ignoré}, PAS une erreur (idempotent ≠ F046)" do
    # Verrouille l'asymétrie voulue : un re-submit après une tâche close n'est PAS un livrable perdu
    # (le 1er submit EST encaissé) → :ok "déjà reçu", idempotent. À NE PAS confondre avec :no_active_task.
    pod = uniq("pod-dbl")
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: "once"})
    assert {:ok, _, _} = PodTools.handle_tool_call("get_task", %{"_lcars_pod_id" => pod}, %{})

    assert {:ok, %{content: [%{"type" => "text"}]}, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"a" => 1}, "_lcars_pod_id" => pod},
               %{}
             )

    # 2e submit → idempotent ignoré, toujours :ok (livrable déjà encaissé, rien perdu).
    assert {:ok, %{content: [%{"type" => "text"}]}, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"a" => 2}, "_lcars_pod_id" => pod},
               %{}
             )
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
