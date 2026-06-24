defmodule Fleet.Observation.BindAddressTest do
  @moduledoc """
  Contrat de bind du listener observation deck `:8091`.

  Le deck est read-only no-auth (frontière = isolation réseau, comme fleet_api) :
  son child-spec Cowboy DOIT porter `ip: {127,0,0,1}` par défaut. Exposition
  publique = opt-in nommé (`LCARS_BIND_HOST`). Régression de threading attrapée ici.
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

  test "bind loopback par défaut (pas d'env d'exposition)" do
    System.delete_env("LCARS_BIND_HOST")
    assert listener_ip() == {127, 0, 0, 1}
  end

  test "override global LCARS_BIND_HOST → ip threadée dans le listener" do
    System.put_env("LCARS_BIND_HOST", "0.0.0.0")
    assert listener_ip() == {0, 0, 0, 0}
  end
end
