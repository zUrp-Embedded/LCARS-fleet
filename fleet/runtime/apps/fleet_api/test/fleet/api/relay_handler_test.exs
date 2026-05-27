defmodule Fleet.API.RelayHandlerTest do
  @moduledoc """
  Tests RelayHandler GenServer round-trip ch10.

  Workflow vérifié :
    1. broadcast `permission_relay_request` avec ref → RelayHandler
       insère dans ETS pending
    2. `respond/2` lookup ETS → broadcast
       `permission_relay_response` matching ref → delete ETS
  """

  use ExUnit.Case, async: false

  alias Fleet.API.RelayHandler
  alias Fleet.EventRouter.Bus

  @ref "test-ref-123"

  setup do
    # RelayHandler démarré par Fleet.API.Application — réutilise instance.
    # `@ref` partagé entre les tests pour subscribe sous-topic dans
    # setup (les tests utilisent le même ref par convention).
    Bus.subscribe()
    Bus.subscribe("fleet.events.relay.#{@ref}")

    on_exit(fn ->
      # Cleanup ETS table to avoid cross-test pollution
      if :ets.whereis(:fleet_api_relay_pending) != :undefined do
        :ets.delete_all_objects(:fleet_api_relay_pending)
      end
    end)

    :ok
  end

  defp wait_handler_drain do
    _ = :sys.get_state(RelayHandler)
    :ok
  end

  describe "permission_relay_request handling" do
    test "broadcast request → ETS pending insertion" do
      :ok =
        Bus.broadcast(
          "permission_relay_request",
          %{"ref" => @ref, "tool" => "Bash"},
          []
        )

      wait_handler_drain()

      assert [{@ref, payload}] = :ets.lookup(:fleet_api_relay_pending, @ref)
      assert payload["tool"] == "Bash"
    end
  end

  describe "respond/2" do
    test "ref pending + decision allow → broadcast response + delete ETS" do
      :ok =
        Bus.broadcast(
          "permission_relay_request",
          %{"ref" => @ref, "tool" => "Bash"},
          []
        )

      wait_handler_drain()

      assert :ok = RelayHandler.respond(@ref, "allow")

      assert_receive {:permission_relay_response, %{ref: @ref, decision: :allow}}, 500

      assert [] = :ets.lookup(:fleet_api_relay_pending, @ref)
    end

    test "decision deny → response avec {:deny, reason}" do
      :ok =
        Bus.broadcast(
          "permission_relay_request",
          %{"ref" => @ref, "tool" => "Bash"},
          []
        )

      wait_handler_drain()

      assert :ok = RelayHandler.respond(@ref, "deny")

      assert_receive {:permission_relay_response, %{ref: @ref, decision: {:deny, reason}}},
                     500

      assert reason =~ "user denied"
    end

    test "decision inconnue → {:deny, unknown}" do
      :ok =
        Bus.broadcast(
          "permission_relay_request",
          %{"ref" => @ref},
          []
        )

      wait_handler_drain()

      assert :ok = RelayHandler.respond(@ref, "weird")

      assert_receive {:permission_relay_response, %{ref: @ref, decision: {:deny, msg}}},
                     500

      assert msg =~ "unknown decision"
    end

    test "ref non pending → {:error, _}" do
      assert {:error, msg} = RelayHandler.respond("nonexistent-ref", "allow")
      assert msg =~ "ref not found"
    end
  end

  describe "events non-pertinents" do
    test "event inconnu → ignoré (handler vivant)" do
      :ok = Bus.broadcast("pod.allocate", %{"pod_id" => "p1"}, [])
      wait_handler_drain()

      assert Process.alive?(Process.whereis(RelayHandler))
    end
  end
end
