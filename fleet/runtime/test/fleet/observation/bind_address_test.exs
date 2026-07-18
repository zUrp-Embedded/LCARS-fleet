defmodule Fleet.Observation.BindAddressTest do
  @moduledoc """
  Bind contract of the observation deck listener `:8091`.

  The deck is read-only no-auth (boundary = network isolation, like fleet_api):
  its Cowboy child-spec MUST carry `ip: {127,0,0,1}` by default. Public
  exposure = named opt-in (`LCARS_BIND_HOST`). Threading regressions caught here.
  """
  use ExUnit.Case, async: false

  setup do
    prev = Application.get_env(:fleet_observation, :start_listener)
    Application.put_env(:fleet_observation, :start_listener, true)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:fleet_observation, :start_listener)
        v -> Application.put_env(:fleet_observation, :start_listener, v)
      end

      System.delete_env("LCARS_BIND_HOST")
    end)

    :ok
  end

  defp listener_ip do
    [{Plug.Cowboy, opts}] = Fleet.Observation.Application.listener_children()
    opts |> Keyword.fetch!(:options) |> Keyword.fetch!(:ip)
  end

  test "binds loopback by default (no exposure env)" do
    System.delete_env("LCARS_BIND_HOST")
    assert listener_ip() == {127, 0, 0, 1}
  end

  test "global LCARS_BIND_HOST override → ip threaded into the listener" do
    System.put_env("LCARS_BIND_HOST", "0.0.0.0")
    assert listener_ip() == {0, 0, 0, 0}
  end
end
