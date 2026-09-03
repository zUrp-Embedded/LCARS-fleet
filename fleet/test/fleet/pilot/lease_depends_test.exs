defmodule Fleet.Pilot.Poller.LeaseDependsTest do
  @moduledoc """
  A ticket whose declared blocker is still OPEN must not START.

  The forge already enforces the other end — it refuses to CLOSE an issue while a blocker is open.
  Without this read, the fleet dispatches anyway: the producer works, delivers, and the wall only
  shows up at the merge. Two rails that meet at the most expensive moment — the exact state the CI
  was in before its gate.
  """
  use ExUnit.Case, async: true

  alias Fleet.Forge.PayloadFixture
  alias Fleet.Pilot.Poller.Lease

  defp issue(n), do: %{"number" => n, "title" => "t#{n}", "body" => "b", "labels" => []}

  # The dispatcher records what actually started. The number is read at `payload["issue"]["number"]`
  # — NOT at `payload["number"]`, which does not exist: a fake that reads the wrong key sends `nil`
  # for every ticket and the test passes while measuring nothing (that exact shape was found in a
  # counting dispatcher on 2026-08-03).
  defmodule Dispatcher do
    def dispatch_issue(payload, _opts) do
      send(self(), {:dispatched, get_in(payload, ["issue", "number"])})
      {:ok, :dispatched}
    end
  end

  defmodule Forge do
    # #1 is blocked by #7 (open) ; #2 is blocked by #8 (CLOSED = satisfied) ; #3 has no edge.
    def issue_dependencies(_repo, 1, _opts),
      do: {:ok, [PayloadFixture.issue(number: 7, state: "open")]}

    def issue_dependencies(_repo, 2, _opts),
      do: {:ok, [PayloadFixture.issue(number: 8, state: "closed")]}

    def issue_dependencies(_repo, 3, _opts), do: {:ok, []}
    # #4: the forge cannot answer.
    def issue_dependencies(_repo, 4, _opts), do: {:error, :boom}

    # No engraved route: every ticket here is a FRESH start, which is the only branch the
    # precondition gates (an engaged run is already past it).
    def route_from_labels(_labels), do: :none
  end

  defp seams do
    %Lease.Seams{
      forge: Forge,
      repo: "fleet/demo",
      forge_opts: [],
      workflow_map_loader: nil,
      incident_fun: fn _, _, _, _ -> :ok end,
      dispatcher: Dispatcher
    }
  end

  defp run(issues), do: Lease.process_issues(issues, MapSet.new(), [], seams())

  describe "the precondition gates the START" do
    test "an OPEN blocker holds the ticket back — and it is not dispatched" do
      run([issue(1)])
      refute_received {:dispatched, 1}
    end

    test "a CLOSED blocker is satisfied — the ticket starts" do
      run([issue(2)])
      assert_received {:dispatched, 2}
    end

    test "no edge at all changes nothing — the nominal path stays nominal" do
      run([issue(3)])
      assert_received {:dispatched, 3}
    end

    # JG-058 — CE TEST EPINGLAIT L'INVERSE, ET SON ARGUMENT SE REFUTAIT DIX LIGNES PLUS HAUT.
    # Il tenait ainsi : « la forge REFUSERA la fermeture si un bloqueur est ouvert, donc le mur tient
    # de toute facon ». C'est exactement le raisonnement que cette lecture existe pour rejeter — le
    # commentaire du site de dispatch dit que sans elle « le producteur travaille, livre, et le mur
    # ne se revele qu'au merge : deux rails paralleles qui ne se rencontrent qu'au moment le plus
    # cher ». Se rabattre dessus en cas d'echec de lecture, c'est retablir l'etat que la lecture
    # supprime.
    #
    # L'AUTRE MOITIE DE SON TITRE ETAIT JUSTE ET RESTE EPINGLEE, un test plus bas : refuser n'est pas
    # bloquer. `Admission.refuse` marque CE ticket en attente et passe au suivant ; le tick d'apres
    # relit. La fleet ne s'arrete pas — c'est la distinction que l'ancien test confondait.
    test "JG-058 : une forge illisible NE dispatche PAS — illisible n'est pas « aucun bloqueur »" do
      run([issue(4)])

      refute_received {:dispatched, 4},
                      "un ticket a ete depeche sur une lecture d'aretes ratee : le producteur part " <>
                        "sur une brique dont la precondition n'est peut-etre pas livree"
    end

    test "JG-058 : et la fleet n'est PAS arretee — les autres tickets partent au meme tick" do
      run([issue(4), issue(3)])

      refute_received {:dispatched, 4}
      assert_received {:dispatched, 3}, "un hoquet sur UN ticket a arrete les autres"
    end
  end

  describe "the refusal is NAMED" do
    test "a held ticket carries the `wait/depends` vocabulary, never a silence" do
      assert Fleet.Labels.wait_for({:depends, 7}) == "wait/depends"
    end

    # Meme etiquette que son voisin, et pour la meme raison que la porte CI : du cote du ticket c'est
    # le MEME fait — il est arrete a cette porte, personne ne travaille dessus. La distinction vit
    # dans la raison du skip, ou elle est actionnable.
    test "JG-058 : une lecture ratee porte la meme etiquette de porte, pas une taxonomie de plus" do
      assert Fleet.Labels.wait_for({:depends_unreadable, :timeout}) == "wait/depends"
    end
  end
end
