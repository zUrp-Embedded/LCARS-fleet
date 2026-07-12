defmodule Fleet.EventRouter.ApplicationEscalationTest do
  use ExUnit.Case, async: true

  alias Fleet.EventRouter.Application, as: DomApp

  # Le contrat d'escalade « crash PubSub → node » est MÉCANIQUE, pas documentaire :
  # un restart local de Phoenix.PubSub perd TOUTES les souscriptions du node — consumers
  # vivants mais sourds à vie, node vert (la panne success-shaped exacte que le dispositif
  # existe pour interdire). Trois propriétés le rendent impossible ; ce test les verrouille.

  test "child spec du Bus : restart :temporary + significant:true (jamais ressuscité sourd)" do
    assert [%{id: Fleet.EventRouter.Bus.EscalatingSupervisor} = spec] = DomApp.base_children()

    # :temporary — un PubSub neuf au registre de souscriptions VIDE serait un mensonge
    # success-shaped ; significant — sa mort doit éteindre le domaine, pas passer inaperçue.
    assert spec.restart == :temporary
    assert spec.significant == true
  end

  test "superviseur de domaine : auto_shutdown :any_significant (mort du Bus = mort du domaine)" do
    assert {:ok, {flags, _children}} = DomApp.init([])

    # La mort du child significant éteint CE superviseur → la racine (Fleet.Application,
    # max_restarts: 0, cicatrice F8/D-17) transforme l'extinction en node-down. Le check
    # boot.order_f8 verrouille l'ordre de boot ; ce test verrouille l'escalade.
    assert flags.auto_shutdown == :any_significant
  end
end
