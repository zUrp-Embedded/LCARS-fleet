defmodule Fleet.Project.IncidentsTest do
  @moduledoc """
  BL-6-114 — le producteur du rail projet. L'ancien module traversait la frontière VERS LE HAUT
  (module en valeur via `:project_incident_rail`, invisible pour boundary) ; celui-ci PUBLIE sur
  le bus, et la conversion en incident vit dans les routes `events.yaml`. Ces témoins tiennent le
  contrat du producteur : les deux ops connus deviennent LEUR événement (source `:project`, sujet
  = dépôt), un op inconnu ne devient RIEN — bruyamment.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.EventRouter.Bus
  alias Fleet.Project.Incidents

  setup do
    Bus.subscribe()
    :ok
  end

  test "op \"card\" → project.card_failed, source :project, le dépôt en sujet" do
    assert :ok =
             Incidents.emit("card", "fleet/demo", :declared_card_unloadable,
               reason_detail: "standard-qa: not found"
             )

    assert_receive %Fleet.Event{
      source: :project,
      type: :"project.card_failed",
      correlation_id: "fleet/demo",
      payload: %{
        "repo" => "fleet/demo",
        "reason" => "declared_card_unloadable",
        "reason_detail" => "standard-qa: not found"
      }
    }
  end

  test "op \"declaration\" → project.declaration_invalid — le second op garde SON événement" do
    assert :ok = Incidents.emit("declaration", "fleet/broken", :declaration_invalid)

    assert_receive %Fleet.Event{
      source: :project,
      type: :"project.declaration_invalid",
      payload: %{"repo" => "fleet/broken", "reason" => "declaration_invalid"}
    }
  end

  test "op inconnu → RIEN n'est émis, et c'est dit — la table est close" do
    # Un troisième op exige sa route events.yaml + sa clause kind_describe : un passthrough
    # silencieux émettrait un événement que personne ne route (perdu sans trace).
    log =
      capture_log(fn ->
        assert :ok = Incidents.emit("autre", "fleet/x", :whatever)
      end)

    refute_receive %Fleet.Event{source: :project}, 50
    assert log =~ "unknown incident op"
  end
end
