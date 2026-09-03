defmodule Fleet.Pilot.StepRunConsumer.GateSystemOutputsTest do
  @moduledoc """
  BL-6-59 — the gate reads the SYSTEM's facts about a step's declared `outputs`, not the pod's
  claim about its own delivery.

  This goes through `GateEngine.resolve_next/3` on purpose. A test that merged the two maps itself
  would pin the merge order of its OWN assertion and leave the production one free to invert — the
  exact shape of a hollow green. Here the pod lies in its `result` and the verdict comes out of the
  rail.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepRunConsumer.GateEngine

  defmodule ForgeStub do
    @moduledoc false
    # Signing a failed run and counting the budget are the two forge reads on the FAIL path. They
    # are stubbed to the nominal answer so the test measures the gate, not the forge.
    def post_comment(_repo, _n, _body, _opts), do: {:ok, %{}}
    def count_signed_step_runs(_repo, _n, _opts), do: {:ok, 0}
  end

  # Shape of a LOADED card (`WorkflowMapNav` reads `steps` at the top level — the loader flattens
  # the YAML `spec:` away), reduced to the single step this test is about.
  @card %{
    "max_rework_rounds" => 2,
    "steps" => %{
      "audit" => %{
        "role" => "scribe",
        "needs" => [],
        "outputs" => ["audits/scribe-{date}.json"],
        "gate" => %{
          "type" => "terminal",
          "rules" => ["outputs_exist AND outputs_non_empty"]
        }
      }
    }
  }

  defp seams do
    %GateEngine.Seams{
      loader: fn _name -> @card end,
      # `scribe` publishes git-natively; the value only steers the terminal intent, not the gate.
      deliverable_mode_fun: fn _role, _root -> {:ok, "git_native"} end,
      repo: "fleet/probe",
      forge_opts: [],
      forge_client: ForgeStub,
      escalation: nil
    }
  end

  defp payload(workspace, result) do
    %{
      "workflow_map" => "audit-only",
      "step" => "audit",
      "role" => "scribe",
      "workspace" => workspace,
      "result" => result
    }
  end

  # The pod asserting exactly what the old rule used to believe.
  @lying %{"outputs_exist" => true, "outputs_non_empty" => true}

  @tag :tmp_dir
  test "a pod that claims both facts and produced NOTHING is bounced", %{tmp_dir: ws} do
    assert {:ok, :rework, _routing} = GateEngine.resolve_next(payload(ws, @lying), 7, seams())
  end

  @tag :tmp_dir
  test "the same claim passes once the declared output really exists", %{tmp_dir: ws} do
    File.mkdir_p!(Path.join(ws, "audits"))
    File.write!(Path.join(ws, "audits/scribe-20260813.json"), ~s({"findings":[]}))

    assert {:ok, :review, {nil, nil}} = GateEngine.resolve_next(payload(ws, @lying), 7, seams())
  end

  @tag :tmp_dir
  test "an HONEST pod that produced the document passes without claiming anything", %{
    tmp_dir: ws
  } do
    File.mkdir_p!(Path.join(ws, "audits"))
    File.write!(Path.join(ws, "audits/scribe-2026-08-13.json"), ~s({"findings":[]}))

    assert {:ok, :review, {nil, nil}} = GateEngine.resolve_next(payload(ws, %{}), 7, seams())
  end

  @tag :tmp_dir
  test "an EMPTY document exists and still fails — the second fact is not decoration", %{
    tmp_dir: ws
  } do
    File.mkdir_p!(Path.join(ws, "audits"))
    File.write!(Path.join(ws, "audits/scribe-2026-08-13.json"), "")

    assert {:ok, :rework, _} = GateEngine.resolve_next(payload(ws, @lying), 7, seams())
  end
end
