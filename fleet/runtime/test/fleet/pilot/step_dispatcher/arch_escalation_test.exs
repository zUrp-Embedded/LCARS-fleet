defmodule Fleet.Pilot.StepDispatcher.ArchEscalationTest do
  @moduledoc """
  B-#3 — arch escalation sets the `lcars-awaits-arch` lock (THE throttle: `decide/1`/`dispatch_review`
  skip on it). If `add_label` FAILS, the lock does not take → the PR is re-dispatched every tick
  (the EXACT churn the escalation exists to stop), while the return stays `{:skipped, _escalated}`.
  A `_ = add_label(...)` fallback would SWALLOW the failure, making the loop invisible. Fix: log LOUD.

  We test the PUBLIC API (`escalate_rework/4`) directly with a forge whose `add_label` fails.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Fleet.Pilot.StepDispatcher.ArchEscalation
  alias Fleet.Pilot.StepDispatcher.ArchEscalation.Seams

  defmodule LabelFailForge do
    # EXPLANATORY comment OK (not load-bearing — the label is); add_label FAILS → the
    # throttle never takes.
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    def add_label(_repo, _n, _label, _opts), do: {:error, {:http, 500, "label boom"}}
  end

  defmodule OkForge do
    # Real `ForgeClient.post_comment/4` shape = {:ok, :posted | :already}, NOT {:ok, 1}.
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
  end

  @head "lcars/issue-42-engineer"

  defp seams(forge), do: %Seams{forge: forge, repo: "fleet/proj", forge_opts: []}

  test "throttle label FAILS → return {:skipped, _escalated} BUT log LOUD (churn visible)" do
    log =
      capture_log(fn ->
        assert {:skipped, {:rework_exhausted_escalated, 5}} =
                 ArchEscalation.escalate_rework(seams(LabelFailForge), 5, @head, %{
                   rounds: 4,
                   budget: 3
                 })
      end)

    # ARCH-SPECIFIC token (`ArchEscalation:` + the unique fragment of the message): under `async` +
    # `capture_log`, a shared string like "NOT added" bleeds from a concurrent
    # IncidentRegistry.Escalation test (same word). We assert on what ONLY this module emits → no
    # false positive from bleed.
    assert log =~ "ArchEscalation:"
    assert log =~ "until the label sticks"
  end

  test "throttle label OK → return {:skipped, _escalated}, NO churn log" do
    log =
      capture_log(fn ->
        assert {:skipped, {:rework_exhausted_escalated, 5}} =
                 ArchEscalation.escalate_rework(seams(OkForge), 5, @head, %{rounds: 4, budget: 3})
      end)

    # `ArchEscalation:` (log prefix unique to this module; arch only logs on failure) instead of the
    # SHARED string "NOT added": robust to async bleed from a concurrent IncidentRegistry.Escalation
    # log (flaky fix).
    refute log =~ "ArchEscalation:"
  end
end
