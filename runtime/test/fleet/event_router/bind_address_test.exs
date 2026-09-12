defmodule Fleet.EventRouter.BindAddressTest do
  @moduledoc """
  Checks loopback default, surface-over-global precedence and the webhook's child-spec IP.
  No listener is started; this does not prove live network exposure or DNS/IPv6 behaviour.
  """
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.BindAddress

  setup do
    on_exit(fn ->
      System.delete_env("LCARS_BIND_HOST")
      System.delete_env("LCARS_WEBHOOK_BIND_HOST")
    end)

    :ok
  end

  describe "BindAddress.ip/1 — single source" do
    test "default = loopback (no env)" do
      System.delete_env("LCARS_BIND_HOST")
      System.delete_env("LCARS_WEBHOOK_BIND_HOST")
      assert BindAddress.ip() == {127, 0, 0, 1}
      assert BindAddress.ip("LCARS_WEBHOOK_BIND_HOST") == {127, 0, 0, 1}
    end

    test "empty env (\"\") does not count as an override → stays loopback" do
      System.put_env("LCARS_BIND_HOST", "   ")
      assert BindAddress.ip() == {127, 0, 0, 1}
    end

    test "global LCARS_BIND_HOST override applies to every surface" do
      System.put_env("LCARS_BIND_HOST", "0.0.0.0")
      assert BindAddress.ip() == {0, 0, 0, 0}
      assert BindAddress.ip("LCARS_WEBHOOK_BIND_HOST") == {0, 0, 0, 0}
    end

    test "surface override wins over the global one" do
      System.put_env("LCARS_BIND_HOST", "10.0.0.1")
      System.put_env("LCARS_WEBHOOK_BIND_HOST", "0.0.0.0")
      # The webhook takes its surface override; a surface without a named override
      # (api/deck call ip()/0) stays on the global one.
      assert BindAddress.ip("LCARS_WEBHOOK_BIND_HOST") == {0, 0, 0, 0}
      assert BindAddress.ip() == {10, 0, 0, 1}
    end

    test "invalid host → clear raise (never fall back silently to loopback)" do
      System.put_env("LCARS_BIND_HOST", "not-a-host-..-invalid")
      assert_raise ArgumentError, ~r/invalid/, fn -> BindAddress.ip() end
    end
  end

  describe "webhook listener — ip threaded into the Cowboy child-spec" do
    setup do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :event_router_start_webhooks, true)
      :ok
    end

    defp webhook_ip do
      [{Plug.Cowboy, opts}] = Fleet.EventRouter.Application.webhook_children()
      opts |> Keyword.fetch!(:options) |> Keyword.fetch!(:ip)
    end

    test "binds loopback by default" do
      System.delete_env("LCARS_BIND_HOST")
      System.delete_env("LCARS_WEBHOOK_BIND_HOST")
      assert webhook_ip() == {127, 0, 0, 1}
    end

    test "LCARS_WEBHOOK_BIND_HOST exposes the webhook alone" do
      System.put_env("LCARS_WEBHOOK_BIND_HOST", "0.0.0.0")
      assert webhook_ip() == {0, 0, 0, 0}
    end
  end
end
