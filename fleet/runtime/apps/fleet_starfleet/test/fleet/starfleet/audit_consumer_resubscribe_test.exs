defmodule Fleet.Starfleet.AuditConsumerResubscribeTest do
  @moduledoc """
  Contrat re-subscribe au Bus après restart : un consommateur d'events tué redémarre et SE RÉ-ABONNE,
  donc reçoit les events SUIVANTS. La garantie tient par construction (le subscribe vit dans `init/1`,
  qu'OTP rappelle à CHAQUE restart), mais elle DOIT être prouvée de bout en bout — sinon une régression
  (subscribe déplacé hors init, ou subscribe one-shot au boot du superviseur) rendrait un consommateur
  redémarré SOURD en silence : vivant, supervisé vert, mais ne consommant plus rien. C'est le pire mode
  de panne d'un bus pub/sub, et il est invisible sans ce test.

  Non-async + topic DÉDIÉ : on broadcast réellement sur le Bus global ; un topic propre à ce test
  (`@topic`) isole le compteur de tout autre broadcast `fleet.events` parasite → assertion exacte,
  pas de flake.
  """
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus

  # Consommateur minimal qui subscribe DANS init (le contrat sous test) et compte ce qu'il reçoit.
  # Topic dédié passé en opt → isolé des autres broadcasts. Modèle EXACT du pattern réel
  # (AuditConsumer/HopConsumer/ReadModel/… : tous subscribent dans init/1).
  defmodule Counter do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts) do
      # LE contrat : abonnement DANS init → rejoué à chaque (ré)init par OTP.
      :ok = Bus.subscribe(Keyword.fetch!(opts, :topic))
      {:ok, %{count: 0}}
    end

    @impl true
    def handle_info(%Fleet.Event{}, state), do: {:noreply, %{state | count: state.count + 1}}
    def handle_info(_other, state), do: {:noreply, state}
  end

  @topic "fleet.events.resubscribe_test"

  defp ev,
    do: %Fleet.Event{
      source: :spawner,
      type: :"pod.completed",
      timestamp: DateTime.utc_now(),
      payload: %{}
    }

  @tag :resubscribe
  test "consommateur tué → redémarré par le superviseur → reçoit les events POST-restart" do
    name = :"resub_counter_#{System.unique_integer([:positive])}"

    # restart: :permanent (défaut GenServer) → OTP relance au crash. Le superviseur lui-même ne
    # subscribe RIEN : tout passe par init/1 de l'enfant (le seul endroit légitime).
    {:ok, sup} =
      Supervisor.start_link(
        [Supervisor.child_spec({Counter, name: name, topic: @topic}, id: :resub)],
        strategy: :one_for_one
      )

    pid1 = Process.whereis(name)
    assert is_pid(pid1)

    # 1) Abonnement initial OK : l'event est consommé.
    Bus.broadcast(@topic, ev())
    assert %{count: 1} = :sys.get_state(name)

    # 2) Kill brutal → OTP redémarre → nouvel init/1 → nouveau Bus.subscribe.
    ref = Process.monitor(pid1)
    Process.exit(pid1, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid1, :killed}

    pid2 = wait_for_restart(name, pid1)
    assert pid2 != pid1, "le superviseur doit avoir redémarré une NOUVELLE instance"

    # 3) PREUVE : un event POST-restart est reçu par la NOUVELLE instance. Son count repart de 0
    # (instance fraîche), donc le 1 atteste que c'est bien CETTE instance-ci qui s'est ré-abonnée et a
    # consommé — pas un résidu de l'ancienne. Sans re-subscribe, on resterait à 0 (consommateur sourd).
    Bus.broadcast(@topic, ev())
    assert %{count: 1} = :sys.get_state(name)

    Supervisor.stop(sup)
  end

  # Attend (borné) qu'un NOUVEAU pid (≠ ancien) soit enregistré sous `name` = le restart OTP effectif.
  defp wait_for_restart(name, old_pid, tries \\ 200)
  defp wait_for_restart(_name, _old, 0), do: flunk("consommateur jamais redémarré sous son nom")

  defp wait_for_restart(name, old_pid, tries) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid -> pid
      _ -> Process.sleep(5) && wait_for_restart(name, old_pid, tries - 1)
    end
  end
end
