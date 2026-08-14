defmodule Fleet.EventRouter.BusTest do
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus

  setup do
    :ok = Bus.subscribe()
    on_exit(fn -> Bus.unsubscribe() end)
    :ok
  end

  # Z5 (ER-D2) — the `broadcast/3` blocks (legacy `{atom, map}` shim) are gone with the legacy.
  # The canonical path `broadcast/2 (topic, %Fleet.Event{})` is tested here + in
  # r1_seam_broadcast_test (registry / UnregisteredError).

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

  # 6-041 — L'ADRESSAGE PAR POD. Chaque pod s'abonnait au sujet GLOBAL : tout evenement reveillait
  # les N pods actifs (plafond 128) et N-1 le jetaient. Le pod ne consomme que ce qui porte SON
  # `pod_id` — le bus peut donc adresser au lieu de diffuser, et la repartition vit ICI, en un seul
  # endroit, plutot qu'en devoir de memoire chez chaque emetteur.
  describe "6-041 — sujet par pod" do
    # ⚠ LE TEST LUI-MEME EST ABONNE AU SUJET PRINCIPAL (`setup`), donc il ne peut pas distinguer
    # « livre sur le sujet du pod » de « livre sur le principal ». Un `refute_receive` pose ici
    # rougirait sur le trafic normal du sujet global — mesure faite, premier jet. L'ecoute d'un
    # sujet de pod se delegue donc a un processus qui n'ecoute QUE lui, et qui rapporte.
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

    # Emis depuis un TIERS : `broadcast_from` exclut l'emetteur, donc emettre depuis l'ecouteur ou
    # depuis le test ne mesurerait pas la meme chose.
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

      # TEMOIN — le sujet PRINCIPAL, lui, l'a bien vu : un observateur n'est pas adresse, il
      # observe. Sans lui, le silence ci-dessus passerait aussi si le bus n'emettait plus rien.
      assert_received %Fleet.Event{type: :"work_item.completed", pod_id: ^autre}
    end

    test "un evenement SANS pod_id ne cree aucun sujet de pod" do
      _ = ecouteur(Bus.pod_topic("pod-6041-nil-#{System.unique_integer([:positive])}"))

      emet(Fleet.Event.new(:spawner, :"pod.completed"))

      assert_receive :silence, 2_500
      assert_received %Fleet.Event{type: :"pod.completed", pod_id: nil}
    end

    # L'ECHO : un pod emet ses propres evenements de cycle de vie avec son propre `pod_id`. Sans
    # l'exclusion par pid, le bus lui rendrait tout ce qu'il vient de dire — et la clause du pod qui
    # NOMME un evenement adresse sans clause crierait sur chacun d'eux.
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
