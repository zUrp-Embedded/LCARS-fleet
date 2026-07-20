defmodule Fleet.Pilot.StepDispatcher.ArchEscalationTest do
  @moduledoc """
  B-#3 / C-02 — arch escalation sets the `lcars-awaits-arch` lock (THE throttle: `decide/1`/
  `dispatch_review` skip on it). If `add_label` FAILS, the lock does not take → the PR is re-dispatched
  every tick (the EXACT churn the escalation exists to stop). C-02 (sonde convergence 2026-07-20): the
  return must NOT stay a lying `{:skipped, _escalated}` — it becomes `{:error, {:escalation_incomplete,
  pr, reason}}` so the poller folds an HONEST `tally.errors` and re-attempts next tick, AND we log LOUD.

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
    def remove_label(_repo, _n, _label, _opts), do: {:ok, :removed}
  end

  defmodule OkForge do
    # Real `ForgeClient.post_comment/4` shape = {:ok, :posted | :already}, NOT {:ok, 1}.
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
    # awaits-arch ⇒ ¬in-flight (invariant 2026-07-19): best-effort removal on escalation.
    def remove_label(_repo, _n, _label, _opts), do: {:ok, :removed}
  end

  @head "lcars/issue-42-engineer"

  defp seams(forge), do: %Seams{forge: forge, repo: "fleet/proj", forge_opts: []}

  test "throttle label FAILS → return {:error, escalation_incomplete} AND log LOUD (honest tally, C-02)" do
    log =
      capture_log(fn ->
        assert {:error, {:escalation_incomplete, 5, {:awaits_arch_label_failed, _}}} =
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
