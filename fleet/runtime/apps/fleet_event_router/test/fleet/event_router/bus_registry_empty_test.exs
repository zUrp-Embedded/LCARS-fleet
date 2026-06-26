defmodule Fleet.EventRouter.BusRegistryEmptyTest do
  @moduledoc """
  Durcissement « registry vide → permissif EXPLICITE » : le comportement du Bus quand
  `authorized_event_types` est VIDE n'est plus un trou silencieux mais un régime choisi par
  `:fleet_event_router, :permit_when_registry_empty`. Ce test verrouille les DEUX régimes ET la
  bascule vide→peuplé (sinon une régression du flag/de la garde passerait inaperçue).

  Invariant prouvé (sur N types arbitraires, registered ou non) :
    * registry VIDE + permit=true  → TOUT type passe (safety-net d'init).
    * registry VIDE + permit=false → TOUT type raise (fail-closed).
    * registry PEUPLÉ              → un type DEDANS passe, un type DEHORS raise (indépendant du flag).

  Régression : retirer la garde `permit_when_registry_empty?` (revenir au `:ok` inconditionnel sur
  set vide) fait échouer le cas fail-closed ; câbler le flag à l'envers fait échouer les deux cas vide.
  """
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus

  # Le registry est un `:persistent_term` GLOBAL et le flag une config d'app GLOBALE → ce test ne peut
  # pas être async. On part TOUJOURS d'un set vide + défaut restauré, pour ne pas polluer les voisins.
  setup do
    previous = Bus.authorized_event_types()
    Bus.set_authorized_event_types(MapSet.new())

    on_exit(fn ->
      Bus.set_authorized_event_types(previous)
      Application.delete_env(:fleet_event_router, :permit_when_registry_empty)
    end)

    :ok
  end

  defp ev(type), do: Fleet.Event.new(:spawner, type)

  # Échantillon de types arbitraires (registered ou pas) — un mini-balayage qui exerce la propriété
  # « le verdict ne dépend QUE du régime, pas du type précis » quand le registry est vide.
  @arbitrary_types [
    :"pod.completed",
    :"phantom.never.registered",
    :task_completed,
    :"some.random.type.xyz",
    :wake_failed
  ]

  describe "registry VIDE — régime explicite (:permit_when_registry_empty)" do
    test "permit=true (défaut) → TOUT type passe (safety-net d'init, comportement legacy)" do
      Application.put_env(:fleet_event_router, :permit_when_registry_empty, true)

      for type <- @arbitrary_types do
        assert :ok = Bus.broadcast("fleet.events", ev(type)),
               "registry vide + permit=true doit laisser passer #{inspect(type)}"
      end
    end

    test "défaut IMPLICITE (clé absente) = permit (le safety-net est le défaut, pas une option à poser)" do
      # On NE pose PAS la clé → la garde doit retomber sur le défaut `true`. Verrouille que le défaut
      # est bien permissif (un défaut fail-closed casserait le boot précoce + tout l'hermétisme test).
      Application.delete_env(:fleet_event_router, :permit_when_registry_empty)
      assert :ok = Bus.broadcast("fleet.events", ev(:"pod.completed"))
    end

    test "permit=false → TOUT type raise UnregisteredError (fail-closed)" do
      Application.put_env(:fleet_event_router, :permit_when_registry_empty, false)

      for type <- @arbitrary_types do
        assert_raise Fleet.Event.UnregisteredError, fn ->
          Bus.broadcast("fleet.events", ev(type))
        end
      end
    end
  end

  describe "registry PEUPLÉ — le flag n'a plus d'effet (validation stricte par appartenance)" do
    # Quel que soit `permit_when_registry_empty`, dès que le set est peuplé la garde tranche par
    # appartenance : la fenêtre d'init est close, le flag ne s'applique qu'au set VIDE.
    for permit <- [true, false] do
      test "permit=#{permit} : type DEDANS passe, type DEHORS raise" do
        Application.put_env(:fleet_event_router, :permit_when_registry_empty, unquote(permit))
        Bus.set_authorized_event_types(MapSet.new([:"pod.completed"]))

        assert :ok = Bus.broadcast("fleet.events", ev(:"pod.completed"))

        assert_raise Fleet.Event.UnregisteredError, fn ->
          Bus.broadcast("fleet.events", ev(:"phantom.never.registered"))
        end
      end
    end
  end

  test "bascule vide→peuplé : un type non registré passe tant que vide, raise une fois le set peuplé" do
    # Le scénario de boot réel : le Bus démarre (set vide → broadcast permis), puis Catalog.load!
    # peuple le set → le MÊME type, s'il n'est pas dans events.yaml, devient refusé. Prouve que la
    # validation s'ACTIVE à la transition, pas qu'elle est désactivée à vie.
    Application.put_env(:fleet_event_router, :permit_when_registry_empty, true)

    assert :ok = Bus.broadcast("fleet.events", ev(:"phantom.never.registered"))

    Bus.set_authorized_event_types(MapSet.new([:"pod.completed"]))

    assert_raise Fleet.Event.UnregisteredError, fn ->
      Bus.broadcast("fleet.events", ev(:"phantom.never.registered"))
    end
  end
end
