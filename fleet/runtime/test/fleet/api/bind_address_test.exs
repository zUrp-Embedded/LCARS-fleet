defmodule Fleet.API.BindAddressTest do
  @moduledoc """
  Contrat de bind du listener REST/WS `:8080`.

  Le child-spec Cowboy DOIT porter `ip: {127,0,0,1}` par défaut : la surface est
  no-auth (frontière = isolation réseau, cf. Rest § Auth) et sa seule écriture
  restante, `/api/admin/spawn`, est gardée mais non authentifiée — l'exposer 0.0.0.0
  par défaut serait un trou. L'exposition publique est un opt-in nommé (`LCARS_BIND_HOST`),
  jamais le défaut. Ce test attrape toute régression future qui oublierait de threader l'ip.
  """
  use ExUnit.Case, async: false

  # `listener_children/0` lit `:start_listener` (false en :test) → on le force le
  # temps du test pour matérialiser le child-spec réel, puis on restaure.
  setup do
    prev = Application.get_env(:fleet_api, :start_listener)
    Application.put_env(:fleet_api, :start_listener, true)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:fleet_api, :start_listener)
        v -> Application.put_env(:fleet_api, :start_listener, v)
      end

      System.delete_env("LCARS_BIND_HOST")
    end)

    :ok
  end

  defp listener_ip do
    [{Plug.Cowboy, opts}] = Fleet.API.Application.listener_children()
    opts |> Keyword.fetch!(:options) |> Keyword.fetch!(:ip)
  end

  test "bind loopback par défaut (pas d'env d'exposition)" do
    System.delete_env("LCARS_BIND_HOST")
    assert listener_ip() == {127, 0, 0, 1}
  end

  test "override global LCARS_BIND_HOST → exposition explicite threadée dans l'ip" do
    System.put_env("LCARS_BIND_HOST", "0.0.0.0")
    assert listener_ip() == {0, 0, 0, 0}
  end
end
