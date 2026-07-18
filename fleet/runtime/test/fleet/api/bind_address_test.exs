defmodule Fleet.API.BindAddressTest do
  @moduledoc """
  Bind contract of the REST/WS listener `:8080`.

  The Cowboy child-spec MUST carry `ip: {127,0,0,1}` by default: the surface is
  no-auth (boundary = network isolation, cf. Rest § Auth) and its only remaining
  write, `/api/admin/spawn`, is guarded but unauthenticated — exposing it on 0.0.0.0
  by default would be a hole. Public exposure is a named opt-in (`LCARS_BIND_HOST`),
  never the default. This test catches any future regression that would forget to thread the ip.
  """
  use ExUnit.Case, async: false

  # `listener_children/0` reads `:start_listener` (false in :test) → force it for
  # the duration of the test to materialize the real child-spec, then restore.
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

  test "binds loopback by default (no exposure env)" do
    System.delete_env("LCARS_BIND_HOST")
    assert listener_ip() == {127, 0, 0, 1}
  end

  test "global LCARS_BIND_HOST override → explicit exposure threaded into the ip" do
    System.put_env("LCARS_BIND_HOST", "0.0.0.0")
    assert listener_ip() == {0, 0, 0, 0}
  end
end
