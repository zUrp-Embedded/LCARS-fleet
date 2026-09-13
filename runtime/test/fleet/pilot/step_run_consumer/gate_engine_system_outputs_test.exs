defmodule Fleet.Pilot.StepRunConsumer.GateEngineSystemOutputsTest do
  @moduledoc """
  Exercises system output derivation through GateEngine.resolve_next rather than
  reproducing the map merge in the test. Missing/empty files must override positive pod claims.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepRunConsumer.GateEngine

  defmodule ForgeStub do
    @moduledoc false
    # Stub the marker write and budget read; the assertions isolate workspace gate decisions.
    def post_comment(_repo, _n, _body, _opts), do: {:ok, %{}}
    def count_signed_step_runs(_repo, _n, _opts), do: {:ok, 0}
  end

  # Loaded cards expose steps directly; YAML spec nesting has already been removed.
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
