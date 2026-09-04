defmodule Fleet.Workflow.StepOutputsTest do
  # async: derive/2 reads only the tmp_dir it is handed — no application env, no global state.
  use ExUnit.Case, async: true

  alias Fleet.Workflow.StepOutputs

  @moduledoc false

  defp write!(dir, rel, content) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  describe "derive/2 — the declared output actually resolves" do
    @tag :tmp_dir
    test "a `{date}` template resolves as a GLOB, whatever graphie the pod used", %{
      tmp_dir: ws
    } do
      spec = %{"outputs" => ["audits/scribe-{date}.json"]}

      # The discriminant of the whole decision: the card says `{date}`, the pod wrote an
      # UNSEPARATED date. An exact resolution would answer false here and block the audit — which
      # is the failure mode BL-6-59 named as worse than the self-declaration it replaces.
      write!(ws, "audits/scribe-20260813.json", ~s({"findings":[]}))

      assert StepOutputs.derive(spec, ws) == %{
               "outputs_exist" => true,
               "outputs_non_empty" => true
             }
    end

    @tag :tmp_dir
    test "an empty file exists but is not non-empty — the two facts are distinct", %{tmp_dir: ws} do
      spec = %{"outputs" => ["audits/scribe-{date}.json"]}
      write!(ws, "audits/scribe-2026-08-13.json", "")

      assert StepOutputs.derive(spec, ws) == %{
               "outputs_exist" => true,
               "outputs_non_empty" => false
             }
    end

    @tag :tmp_dir
    test "nothing produced → both false (the gate's whole point)", %{tmp_dir: ws} do
      spec = %{"outputs" => ["audits/scribe-{date}.json"]}

      assert StepOutputs.derive(spec, ws) == %{
               "outputs_exist" => false,
               "outputs_non_empty" => false
             }
    end

    @tag :tmp_dir
    test "ALL declared outputs must resolve, not just one", %{tmp_dir: ws} do
      spec = %{"outputs" => ["audits/a.json", "audits/b.json"]}
      write!(ws, "audits/a.json", "x")

      assert %{"outputs_exist" => false} = StepOutputs.derive(spec, ws)
    end

    @tag :tmp_dir
    test "a directory matching the pattern is NOT a produced output", %{tmp_dir: ws} do
      spec = %{"outputs" => ["audits/{name}"]}
      File.mkdir_p!(Path.join(ws, "audits/scribe-2026-08-13.json"))

      assert %{"outputs_exist" => false} = StepOutputs.derive(spec, ws)
    end
  end

  describe "derive/2 — absence of a declaration is not a verdict" do
    @tag :tmp_dir
    test "no `outputs` → no facts at all (NOT false)", %{tmp_dir: ws} do
      assert StepOutputs.derive(%{"role" => "scribe"}, ws) == %{}
      assert StepOutputs.derive(%{"outputs" => []}, ws) == %{}
    end
  end

  describe "derive/2 — fail-closed on shape, before any filesystem look" do
    @tag :tmp_dir
    test "malformed `outputs` → both false", %{tmp_dir: ws} do
      assert StepOutputs.derive(%{"outputs" => "audits/x.json"}, ws) ==
               %{"outputs_exist" => false, "outputs_non_empty" => false}

      assert StepOutputs.derive(%{"outputs" => [42]}, ws) ==
               %{"outputs_exist" => false, "outputs_non_empty" => false}
    end

    @tag :tmp_dir
    test "a path escaping the workspace is refused even when the file EXISTS there", %{
      tmp_dir: ws
    } do
      # Proving the refusal is about the shape and not about a missing file: the target is real.
      outside = Path.join(ws, "outside.json")
      File.write!(outside, "real content")
      inner = Path.join(ws, "inner")
      File.mkdir_p!(inner)

      assert StepOutputs.derive(%{"outputs" => ["../outside.json"]}, inner) ==
               %{"outputs_exist" => false, "outputs_non_empty" => false}

      assert StepOutputs.derive(%{"outputs" => [outside]}, inner) ==
               %{"outputs_exist" => false, "outputs_non_empty" => false}
    end

    test "no workspace → both false, never a silent absence of facts" do
      spec = %{"outputs" => ["audits/x.json"]}

      assert StepOutputs.derive(spec, nil) ==
               %{"outputs_exist" => false, "outputs_non_empty" => false}

      assert StepOutputs.derive(spec, "") ==
               %{"outputs_exist" => false, "outputs_non_empty" => false}
    end
  end

  describe "the canon rule it was built for" do
    alias Fleet.Workflow.Gates

    @tag :tmp_dir
    test "the audit-only rule now reads system facts, and a lying pod cannot pass it", %{
      tmp_dir: ws
    } do
      spec = %{
        "outputs" => ["audits/scribe-{date}.json"],
        "gate" => %{"type" => "terminal", "rules" => ["outputs_exist AND outputs_non_empty"]}
      }

      # The pod claims both facts. Nothing was written.
      lying = %{"outputs_exist" => true, "outputs_non_empty" => true}
      system = StepOutputs.derive(spec, ws)

      assert {:fail, _} = Gates.evaluate(spec, Map.merge(lying, system), %{})

      # Same claim, but the document is really there.
      write!(ws, "audits/scribe-2026-08-13.json", ~s({"findings":[]}))
      assert Gates.evaluate(spec, Map.merge(lying, StepOutputs.derive(spec, ws)), %{}) == :pass
    end
  end
end
