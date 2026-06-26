defmodule Fleet.Starfleet.Shutdown.AggregateDispatcherTest do
  @moduledoc """
  Backend RÉEL du seam `:shutdown_dispatcher` (brique R4 D5 2/3). async: false :
  `refuse_new_jobs` mute le flag global `Fleet.Shutdown.Quiesce` — on_exit
  resume! impératif.
  """
  use ExUnit.Case, async: false

  alias Fleet.Starfleet.Shutdown.AggregateDispatcher
  alias Fleet.Shutdown.Quiesce

  # Stubs injectés via le seam `:fleet_starfleet, :spawner_mod` pour induire un comptage de pods
  # défaillant (Spawner injoignable = restart en plein quiesce) sans toucher le vrai Spawner.
  defmodule RaisingSpawner do
    def count_pods, do: raise("Spawner injoignable (test E-05)")
  end

  defmodule ExitingSpawner do
    def count_pods, do: exit(:noproc)
  end

  setup do
    on_exit(&Quiesce.resume!/0)
    :ok
  end

  defp inject_spawner(mod) do
    Application.put_env(:fleet_starfleet, :spawner_mod, mod)
    on_exit(fn -> Application.delete_env(:fleet_starfleet, :spawner_mod) end)
  end

  test "refuse_new_jobs/1 active la quiescence" do
    Quiesce.resume!()
    refute Quiesce.quiescing?()
    assert :ok = AggregateDispatcher.refuse_new_jobs(reason: :shutdown)
    assert Quiesce.quiescing?()
  end

  test "in_flight_count/0 rend un entier >= 0 (agrégat résilient layering)" do
    # Spawner.count_pods direct (Spawner démarré en env test fleet_starfleet → comptage réel).
    # fleet_task_queue n'est PAS une dép → app non démarrée → `task_queue_running?` faux → `tasks_pending`
    # rend 0 HONNÊTE (absence légitime, pas un échec masqué) sans logguer d'erreur. Ce test exerce donc
    # le chemin nominal (pas de crash) en plus de la forme.
    n = AggregateDispatcher.in_flight_count()
    assert is_integer(n) and n >= 0
  end

  test "count_pods qui LÈVE → in_flight_count > 0 (fail-closed : drain ne peut PAS conclure 0)" do
    # E-05 : Spawner présent mais injoignable (restart en plein quiesce). L'ancien `rescue -> 0`
    # sous-comptait → drain déclaré complet à tort. Désormais : sentinel « pas vide ».
    inject_spawner(RaisingSpawner)
    assert AggregateDispatcher.in_flight_count() > 0
  end

  test "count_pods qui EXIT (:noproc) → in_flight_count > 0 (pas de sous-comptage)" do
    inject_spawner(ExitingSpawner)
    assert AggregateDispatcher.in_flight_count() > 0
  end

  test "drain avec AggregateDispatcher quand count_pods LÈVE → ne conclut pas :drained (timeout)" do
    # Intégration : le drain réel ne doit PAS couper « vide » quand le comptage est indisponible —
    # il consomme la fenêtre de grâce puis procède (status :timeout), au lieu d'un :drained prématuré.
    inject_spawner(RaisingSpawner)
    name = :"sd_e05_#{System.unique_integer([:positive])}"

    {:ok, _} =
      start_supervised({Fleet.Starfleet.Shutdown, name: name, dispatcher: AggregateDispatcher})

    assert :ok = Fleet.Starfleet.Shutdown.drain_in_flight(name: name, grace_ms: 200)
    assert %{status: :timeout} = :sys.get_state(name)
  end
end
