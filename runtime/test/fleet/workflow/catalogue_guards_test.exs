defmodule Fleet.Workflow.CatalogueGuardsTest do
  @moduledoc """
  Direct checks of the bundled catalogue and a non-judge jury rejection.
  Fleet.Pilot.ApplicationTest covers additional broken cards through the boot seam.
  """
  use ExUnit.Case, async: false

  alias Fleet.Workflow.CatalogueGuards

  test "the bundled catalogue passes the four guards" do
    assert :ok = CatalogueGuards.validate_card_juries!()
    assert :ok = CatalogueGuards.validate_card_steps!()
    assert :ok = CatalogueGuards.validate_default_card_loads!()
    assert :ok = CatalogueGuards.validate_workshop_card!()
  end

  @tag :tmp_dir
  test "a jury naming a non-judge is refused, and the refusal names the card and the role",
       %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "odd.yaml"), """
    kind: WorkflowMap
    metadata:
      name: odd
      description: "jury of workers"
    spec:
      jury: [engineer]
      ci: ignore
      max_rework_rounds: 1
      steps:
        build:
          role: scribe
          needs: []
          inputs:
            - ticket.body
    """)

    assert_raise RuntimeError,
                 ~r/odd jury contains "engineer" whose cap-profile is NOT a judge/,
                 fn ->
                   CatalogueGuards.validate_card_juries!(workflow_maps_root: tmp)
                 end
  end
end
