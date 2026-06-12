defmodule Fleet.API.RelayHandlerTest do
  @moduledoc """
  Tests RelayHandler GenServer round-trip ch10.

  Workflow vérifié :
    1. broadcast `%Fleet.Event{type: :permission_relay_request}` avec ref →
       RelayHandler insère dans ETS pending
    2. `respond/2` lookup ETS → broadcast
       `permission_relay_response` matching ref → delete ETS

  R2b — D1 schema unique : les events de requête sont émis en struct canon
  `%Fleet.Event{}` (ex-tuple legacy `{atom, %{"event_type" => ...}}` retiré).
  """

  use ExUnit.Case, async: false

  alias Fleet.API.RelayHandler
  alias Fleet.Event
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

  # Émet la requête au schema canon %Fleet.Event{} sur fleet.events.
  defp broadcast_req(payload) do
    Bus.broadcast("fleet.events", %Event{
      source: :api,
      type: :permission_relay_request,
      timestamp: DateTime.utc_now(),
      payload: payload
    })
  end

  defp wait_handler_drain do
    _ = :sys.get_state(RelayHandler)
    :ok
  end

  describe "permission_relay_request handling" do
    test "broadcast request → ETS pending insertion" do
      :ok = broadcast_req(%{"ref" => @ref, "tool" => "Bash"})

      wait_handler_drain()

      assert [{@ref, payload}] = :ets.lookup(:fleet_api_relay_pending, @ref)
      assert payload["tool"] == "Bash"
    end
  end

  describe "respond/2" do
    test "ref pending + decision allow → broadcast response + delete ETS" do
      :ok = broadcast_req(%{"ref" => @ref, "tool" => "Bash"})

      wait_handler_drain()

      assert :ok = RelayHandler.respond(@ref, "allow")

      assert_receive {:permission_relay_response, %{ref: @ref, decision: :allow}}, 500

      assert [] = :ets.lookup(:fleet_api_relay_pending, @ref)
    end

    test "decision deny → response avec {:deny, reason}" do
      :ok = broadcast_req(%{"ref" => @ref, "tool" => "Bash"})

      wait_handler_drain()

      assert :ok = RelayHandler.respond(@ref, "deny")

      assert_receive {:permission_relay_response, %{ref: @ref, decision: {:deny, reason}}},
                     500

      assert reason =~ "user denied"
    end

    test "decision inconnue → {:deny, unknown}" do
      :ok = broadcast_req(%{"ref" => @ref})

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
      :ok =
        Bus.broadcast("fleet.events", %Event{
          source: :spawner,
          type: :"pod.allocate",
          timestamp: DateTime.utc_now(),
          payload: %{"pod_id" => "p1"}
        })

      wait_handler_drain()

      assert Process.alive?(Process.whereis(RelayHandler))
    end
  end
end
