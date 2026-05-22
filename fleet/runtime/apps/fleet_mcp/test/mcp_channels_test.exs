defmodule Fleet.MCP.ChannelsTest do
  @moduledoc """
  Lot 1 inc3 — **smoke test critère décisif** (DN ring4/fleet_mcp.md
  §"Choix SDK" + plan-implementation.md Lot 1 done) : un event broadcasté
  sur un channel est reçu côté subscriber < 100 ms. Prouve aussi le
  fan-out multi-subscriber via Phoenix.PubSub (anti-goulot : aucun
  GenServer dans le chemin de broadcast).

  `async: false` : Fleet.PubSub est une instance nommée partagée umbrella.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.Channels.{FleetControl, FleetForge}

  setup_all do
    # Fleet.PubSub est démarré par fleet_event_router (chantier 11) en
    # contexte umbrella ; en run isolé on le démarre. Guard idempotent.
    unless Process.whereis(Fleet.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Fleet.PubSub})
    end

    :ok
  end

  test "fleet-control : push reçu côté subscriber < 100 ms (critère décisif)" do
    {:ok, ref} = FleetControl.subscribe("fleet-control", topic: "fleet-control.coord.smoke")
    event = %{"topic" => "fleet-control.coord.smoke", "action" => "handoff", "n" => 1}

    assert :ok = FleetControl.broadcast("fleet-control", event)
    assert_receive ^event, 100

    FleetControl.unsubscribe(ref)
  end

  test "fleet-forge : push reçu côté subscriber < 100 ms" do
    {:ok, ref} = FleetForge.subscribe("fleet-forge", topic: "fleet-forge.engineer")
    event = %{"topic" => "fleet-forge.engineer", "ticket" => 553}

    assert :ok = FleetForge.broadcast("fleet-forge", event)
    assert_receive ^event, 100

    FleetForge.unsubscribe(ref)
  end

  test "fan-out multi-subscriber (Phoenix.PubSub, zéro goulot GenServer)" do
    topic = "fleet-control.audit.fanout"
    parent = self()

    subs =
      for i <- 1..3 do
        spawn_link(fn ->
          {:ok, _} = FleetControl.subscribe("fleet-control", topic: topic)
          send(parent, {:ready, i})

          receive do
            %{"v" => v} -> send(parent, {:got, i, v})
          after
            1000 -> send(parent, {:timeout, i})
          end
        end)
      end

    for i <- 1..3, do: assert_receive({:ready, ^i}, 200)

    assert :ok =
             FleetControl.broadcast("fleet-control", %{"topic" => topic, "v" => 42})

    for i <- 1..3, do: assert_receive({:got, ^i, 42}, 100)
    Enum.each(subs, fn p -> if Process.alive?(p), do: Process.exit(p, :kill) end)
  end

  test "unsubscribe stoppe la livraison" do
    {:ok, ref} = FleetControl.subscribe("fleet-control", topic: "fleet-control.coord.unsub")
    :ok = FleetControl.unsubscribe(ref)

    assert :ok =
             FleetControl.broadcast("fleet-control", %{
               "topic" => "fleet-control.coord.unsub",
               "x" => 1
             })

    refute_receive %{"x" => 1}, 80
  end

  test "channel_name/0 expose le nom canon" do
    assert FleetControl.channel_name() == "fleet-control"
    assert FleetForge.channel_name() == "fleet-forge"
  end
end
