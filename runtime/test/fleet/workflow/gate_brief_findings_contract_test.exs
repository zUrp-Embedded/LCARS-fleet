defmodule Fleet.Workflow.GateBriefFindingsContractTest do
  use ExUnit.Case, async: true

  # ⚠ CE TEST EXISTE À CAUSE D'UNE CONTRADICTION MESURÉE, PAS PAR PRÉCAUTION. Le gabarit disait à
  # tout juge : « `details` — a FLAT object of scalars », pendant que son SP lui demandait d'y
  # loger `findings`, un objet IMBRIQUÉ. Un juge qui obéissait à son ordre de mission ne POUVAIT
  # pas émettre la charge machine ; celui qui a tenté d'obéir aux deux l'a SÉRIALISÉE EN CHAÎNE
  # pour la faire rentrer dans un « scalaire » (mesuré au banc, probe-rails#47) — un compromis
  # intelligent que le rail a refusé comme une maladresse.
  #
  # Deux jours de mesures d'émission (~31 verdicts, taux erratique 0/3, 3/4, 0/6) s'expliquent par
  # là : on ne mesurait pas un taux de conformité mais QUEL ORDRE l'agent privilégiait quand les
  # deux s'excluaient. Aucun levier testé (schéma d'outil, exemple littéral) ne touchait la
  # contradiction — ils ajoutaient de l'insistance d'un côté sans retirer l'interdiction de l'autre.
  for kind <- [:deliverable, :brief] do
    test "le gabarit #{kind} n'INTERDIT plus la charge machine qu'il exige par ailleurs" do
      brief =
        Fleet.Workflow.GateBrief.build(%{
          step: "review",
          workflow_map_id: "standard-qa",
          gate: nil,
          outputs: %{},
          kind: unquote(kind)
        })

      assert brief =~ "findings",
             "le juge lit ce texte AU MOMENT D'AGIR : si la clé n'y est pas nommée, elle n'existe " <>
               "pas pour lui — la consigne du SP est à des centaines de lignes et au boot"

      refute brief =~ "FLAT object of scalars",
             "cette phrase interdisait littéralement l'objet imbriqué qu'on réclame dix lignes plus bas"
    end
  end
end
