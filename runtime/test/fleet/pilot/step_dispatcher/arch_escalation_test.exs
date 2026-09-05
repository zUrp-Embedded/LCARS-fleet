defmodule Fleet.Pilot.StepDispatcher.ArchEscalationTest do
  @moduledoc """
  B-#3 / C-02 — arch escalation sets the `lcars-awaits-arch` lock (THE throttle: `decide/1`/
  `dispatch_review` skip on it). If `add_label` FAILS, the lock does not take → the PR is re-dispatched
  every tick (the EXACT churn the escalation exists to stop). C-02: the
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
    # awaits-arch ⇒ ¬in-flight (invariant 2026-07-19): verified removal on escalation.
    def remove_label(_repo, _n, _label, _opts), do: {:ok, :removed}
  end

  defmodule RemoveFailForge do
    # awaits-arch ADD succeeds (throttle takes), but the in-flight retrait FAILS → CI-04: the retrait
    # is verified and SURFACES (both labels present would contradict awaits-arch⇒¬in-flight).
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
    def remove_label(_repo, _n, _label, _opts), do: {:error, {:http, 500, "remove boom"}}
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

  test "throttle OK but in-flight retrait FAILS → {:error, escalation_incomplete/in_flight_removal_failed} + LOUD (CI-04)" do
    log =
      capture_log(fn ->
        assert {:error, {:escalation_incomplete, 5, {:in_flight_removal_failed, _}}} =
                 ArchEscalation.escalate_rework(seams(RemoveFailForge), 5, @head, %{
                   rounds: 4,
                   budget: 3
                 })
      end)

    # Module-unique prefix + the retrait-specific fragment (robust to async bleed).
    assert log =~ "ArchEscalation:"
    assert log =~ "NOT removed"
    assert log =~ "invariant awaits-arch⇒¬in-flight violated"
  end

  describe "escalate_merge_blocked/5 — the architect reads the CAUSE, not the catch-all" do
    # 2026-09-05: `Remediation.escalate_ci/5` passed the literal `:ci` as class, so every CI
    # escalation read « échec de merge non classifié » and sent the architect looking for a git
    # conflict. No witness ever asserted the BODY of a CI escalation.
    defmodule CaptureForge do
      def post_comment(_repo, n, body, _opts) do
        send(self(), {:escalation_body, n, body})
        {:ok, :posted}
      end

      def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
      def remove_label(_repo, _n, _label, _opts), do: {:ok, :removed}
    end

    defp body_for(class, reason) do
      assert {:skipped, {:merge_blocked_escalated, 6}} =
               ArchEscalation.escalate_merge_blocked(seams(CaptureForge), 6, @head, class, reason)

      assert_received {:escalation_body, 42, body}
      body
    end

    test "{:ci_stalled, :unclaimed} → names the runner, never « non classifié »" do
      body =
        body_for({:ci_stalled, :unclaimed}, "aucun runner ne réclame le job (label `lcars`).")

      assert body =~ "BLOQUÉE"
      refute body =~ "non classifié"
    end

    test "{:ci_stalled, :pending} → the pending clause" do
      body = body_for({:ci_stalled, :pending}, "plus de 45 min sans verdict")
      assert body =~ "PENDANTE"
      refute body =~ "non classifié"
    end

    test "{:ci_impossible, :no_workflow} → points at the CI rail, not at a rebase" do
      body = body_for({:ci_impossible, :no_workflow}, "aucun workflow déclaré.")
      assert body =~ "IMPOSSIBLE"
      assert body =~ "project_reset_ci_rail"
      refute body =~ "non classifié"
    end

    test ":ci_red_loop → the producer cannot turn it green" do
      body = body_for(:ci_red_loop, "deux têtes rouges.")
      assert body =~ "ROUGE"
      refute body =~ "non classifié"
    end

    test ":provenance_incoherent → the wall's refusal, a terminal state named to a human" do
      body = body_for(:provenance_incoherent, {:base_not_ancestor, "a", "b"})
      assert body =~ "PROVENANCE"
      assert body =~ "base_not_ancestor"
      refute body =~ "non classifié"
    end

    test "an unknown class still lands in the catch-all (the floor is kept)" do
      assert body_for(:something_new, "?") =~ "non classifié"
    end

    test "the gesture follows the cause: « rien à rebaser » is never followed by « rebase la PR »" do
      for {class, reason} <- [
            {{:ci_stalled, :unclaimed}, "m."},
            {{:ci_impossible, :no_workflow}, "m."},
            {:ci_red_loop, "m."},
            {:provenance_incoherent, :x}
          ] do
        body = body_for(class, reason)

        # « Rien à rebaser » is the cause's own sentence; what must not follow is an INSTRUCTION
        # to rebase, or the blind-barrier sentence that only makes sense before one.
        refute body =~ ~r/rebase la PR|pour rebaser/,
               "#{inspect(class)}: a cause with nothing to rebase names a rebase"
      end

      assert body_for(:conflict, :real) =~ "rebase la PR"

      assert body_for(:conflict, {:conflict_rework_exhausted, 1, :exception_pass_disabled}) =~
               "exception_pass_disabled"
    end

    test "the conflict ladder's own reasons are read, not replaced by a generic git conflict" do
      assert body_for(:conflict, {:conflict_rework_exhausted, 2, :x}) =~ "2 passe(s)"
      assert body_for(:conflict, {:conflict_budget_unreadable, :forge_down}) =~ "ILLISIBLE"
      assert body_for(:conflict, {:conflict_marker_unpostable, :boom}) =~ "marqueur"
      assert body_for(:conflict, {:conflict_exception_marker_unpostable, :boom}) =~ "marqueur"
      assert body_for(:rerequest_read_failed, :forge_down) =~ "re-demandés"
      refute body_for(:rerequest_read_failed, :forge_down) =~ "non classifié"
    end
  end
end
