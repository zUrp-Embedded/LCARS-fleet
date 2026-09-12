defmodule Fleet.EventRouter.BusTest do
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus

  setup do
    :ok = Bus.subscribe()
    on_exit(fn -> Bus.unsubscribe() end)
    :ok
  end

  defp ev(type), do: Fleet.Event.new(:spawner, type)

  describe "subscribe/unsubscribe" do
    test "unsubscribe stops delivery" do
      Bus.broadcast("fleet.events", ev(:"pod.completed"))
      assert_receive %Fleet.Event{type: :"pod.completed"}

      :ok = Bus.unsubscribe()
      Bus.broadcast("fleet.events", ev(:"pod.completed"))
      refute_receive %Fleet.Event{type: :"pod.completed"}, 100

      :ok = Bus.subscribe()
    end
  end

  describe "6-041 — sujet par pod" do
    # The test process already subscribes to main; use a pod-only listener to distinguish deliveries.
    defp ecouteur(topic) do
      parent = self()

      pid =
        spawn_link(fn ->
          :ok = Bus.subscribe(topic)
          send(parent, {:pret, self()})

          receive do
            %Fleet.Event{} = ev -> send(parent, {:recu, ev})
          after
            1_500 -> send(parent, :silence)
          end
        end)

      assert_receive {:pret, ^pid}, 1_000
      pid
    end

    # Emit from another process so broadcast_from's exclusion cannot hide listener delivery.
    defp emet(event) do
      parent = self()
      spawn_link(fn -> send(parent, {:emis, Bus.broadcast_main(event)}) end)
      assert_receive {:emis, :ok}, 1_000
    end

    test "un evenement porteur d'un pod_id atteint le sujet de CE pod" do
      moi = "pod-6041-#{System.unique_integer([:positive])}"
      _ = ecouteur(Bus.pod_topic(moi))

      emet(Fleet.Event.new(:task_queue, :"work_item.completed", pod_id: moi))

      assert_receive {:recu, %Fleet.Event{type: :"work_item.completed", pod_id: ^moi}}, 2_000
    end

    test "le sujet d'un pod ne recoit RIEN de ce qui est adresse a un autre" do
      moi = "pod-6041-a-#{System.unique_integer([:positive])}"
      autre = "pod-6041-b-#{System.unique_integer([:positive])}"
      _ = ecouteur(Bus.pod_topic(moi))

      emet(Fleet.Event.new(:task_queue, :"work_item.completed", pod_id: autre))

      assert_receive :silence, 2_500

      # Main-topic receipt is the control against a completely silent bus.
      assert_received %Fleet.Event{type: :"work_item.completed", pod_id: ^autre}
    end

    test "un evenement SANS pod_id ne cree aucun sujet de pod" do
      _ = ecouteur(Bus.pod_topic("pod-6041-nil-#{System.unique_integer([:positive])}"))

      emet(Fleet.Event.new(:spawner, :"pod.completed"))

      assert_receive :silence, 2_500
      assert_received %Fleet.Event{type: :"pod.completed", pod_id: nil}
    end

    # Lifecycle events must reach observers without echoing to their emitter's pod subscription.
    test "l'emetteur ne recoit pas sur SON sujet ce qu'il vient d'emettre lui-meme" do
      moi = "pod-6041-echo-#{System.unique_integer([:positive])}"
      parent = self()

      spawn_link(fn ->
        :ok = Bus.subscribe(Bus.pod_topic(moi))
        :ok = Bus.broadcast_main(Fleet.Event.new(:spawner, :"pod.spawned", pod_id: moi))

        receive do
          %Fleet.Event{} = ev -> send(parent, {:echo, ev})
        after
          800 -> send(parent, :pas_d_echo)
        end
      end)

      assert_receive :pas_d_echo, 2_000

      # TEMOIN — l'evenement a bien ete emis : le sujet principal le porte.
      assert_received %Fleet.Event{type: :"pod.spawned", pod_id: ^moi}
    end
  end
end
