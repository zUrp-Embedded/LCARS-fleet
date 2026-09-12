defmodule Fleet.Workflow.GateBriefFindingsContractTest do
  use ExUnit.Case, async: true

  # probe-rails#47: "FLAT object of scalars" contradicted nested findings, which the judge
  # serialized as a string. Check the contradictory wording is gone and findings is named.
  # This fixture passes kind, while GateBrief reads subject: both iterations render deliverable.
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
