defmodule Fleet.Pilot.StepDispatcher.ArchEscalationTest do
  @moduledoc """
  B-#3 — l'escalade arch pose le verrou `lcars-awaits-arch` (LE throttle : `decide/1`/`dispatch_review`
  skippent dessus). Si `add_label` ÉCHOUE, le verrou ne prend pas → la PR est re-dispatchée chaque tick
  (le churn EXACT que l'escalade existe pour stopper), alors que le retour reste `{:skipped, _escalated}`.
  Repli d'origine : `_ = add_label(...)` → l'échec était AVALÉ, la boucle invisible. Fix : log LOUD.

  On teste l'API PUBLIQUE (`escalate_rework/4`) en direct avec un forge dont `add_label` échoue.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Fleet.Pilot.StepDispatcher.ArchEscalation
  alias Fleet.Pilot.StepDispatcher.ArchEscalation.Seams

  defmodule LabelFailForge do
    # comment EXPLICATIF OK (non porteur — le porteur est le label) ; add_label ÉCHOUE → le
    # throttle ne prend jamais.
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    def add_label(_repo, _n, _label, _opts), do: {:error, {:http, 500, "label boom"}}
  end

  defmodule OkForge do
    # Forme réelle `ForgeClient.post_comment/4` = {:ok, :posted | :already}, PAS {:ok, 1}.
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
  end

  @head "lcars/issue-42-engineer"

  defp seams(forge), do: %Seams{forge: forge, repo: "fleet/proj", forge_opts: []}

  test "throttle label FAILS → retour {:skipped, _escalated} MAIS log LOUD (churn visible)" do
    log =
      capture_log(fn ->
        assert {:skipped, {:rework_exhausted_escalated, 5}} =
                 ArchEscalation.escalate_rework(seams(LabelFailForge), 5, @head, %{
                   rounds: 4,
                   budget: 3
                 })
      end)

    # Token ARCH-SPÉCIFIQUE (`ArchEscalation:` + le fragment unique du message) : sous `async` + `capture_log`,
    # une chaîne partagée comme « NOT added » bave depuis un test IncidentRegistry.Escalation concurrent (même
    # mot). On assert sur ce que SEUL ce module émet → pas de faux-positif par bleed.
    assert log =~ "ArchEscalation:"
    assert log =~ "until the label sticks"
  end

  test "throttle label OK → retour {:skipped, _escalated}, AUCUN log de churn" do
    log =
      capture_log(fn ->
        assert {:skipped, {:rework_exhausted_escalated, 5}} =
                 ArchEscalation.escalate_rework(seams(OkForge), 5, @head, %{rounds: 4, budget: 3})
      end)

    # `ArchEscalation:` (préfixe de log unique à ce module ; arch ne logue QUE sur échec) au lieu de la chaîne
    # PARTAGÉE « NOT added » : robuste au bleed async d'un log IncidentRegistry.Escalation concurrent (flaky fix).
    refute log =~ "ArchEscalation:"
  end
end
