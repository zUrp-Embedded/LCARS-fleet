defmodule Fleet.EventRouter.BindAddressTest do
  @moduledoc """
  Source unique de l'ip de bind (`Fleet.EventRouter.BindAddress`) + contrat de bind
  du listener webhook Gitea `:8081`.

  Invariant : loopback `{127,0,0,1}` par défaut, exposition = opt-in nommé. Le
  webhook est la seule surface avec un override DE SURFACE (`LCARS_WEBHOOK_BIND_HOST`)
  car une forge distante doit pouvoir POST. La précédence (surface > global) est
  testée ici : c'est elle qui permet d'exposer le webhook SANS exposer les surfaces
  de commande.
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

  describe "BindAddress.ip/1 — source unique" do
    test "défaut = loopback (aucune env)" do
      System.delete_env("LCARS_BIND_HOST")
      System.delete_env("LCARS_WEBHOOK_BIND_HOST")
      assert BindAddress.ip() == {127, 0, 0, 1}
      assert BindAddress.ip("LCARS_WEBHOOK_BIND_HOST") == {127, 0, 0, 1}
    end

    test "env vide (\"\") ne compte pas comme override → reste loopback" do
      System.put_env("LCARS_BIND_HOST", "   ")
      assert BindAddress.ip() == {127, 0, 0, 1}
    end

    test "override global LCARS_BIND_HOST sur toutes les surfaces" do
      System.put_env("LCARS_BIND_HOST", "0.0.0.0")
      assert BindAddress.ip() == {0, 0, 0, 0}
      assert BindAddress.ip("LCARS_WEBHOOK_BIND_HOST") == {0, 0, 0, 0}
    end

    test "override de surface l'emporte sur le global" do
      System.put_env("LCARS_BIND_HOST", "10.0.0.1")
      System.put_env("LCARS_WEBHOOK_BIND_HOST", "0.0.0.0")
      # Le webhook prend son override de surface ; une surface sans override nommé
      # (api/deck appellent ip()/0) reste sur le global.
      assert BindAddress.ip("LCARS_WEBHOOK_BIND_HOST") == {0, 0, 0, 0}
      assert BindAddress.ip() == {10, 0, 0, 1}
    end

    test "host invalide → raise clair (jamais retomber en silence sur loopback)" do
      System.put_env("LCARS_BIND_HOST", "pas-un-host-..-invalide")
      assert_raise ArgumentError, ~r/invalid/, fn -> BindAddress.ip() end
    end
  end

  describe "listener webhook — ip threadée dans le child-spec Cowboy" do
    setup do
      Fleet.EventRouter.TestEnv.put_env_restoring(:fleet_event_router, :start_webhooks, true)
      :ok
    end

    defp webhook_ip do
      [{Plug.Cowboy, opts}] = Fleet.EventRouter.Application.webhook_children()
      opts |> Keyword.fetch!(:options) |> Keyword.fetch!(:ip)
    end

    test "bind loopback par défaut" do
      System.delete_env("LCARS_BIND_HOST")
      System.delete_env("LCARS_WEBHOOK_BIND_HOST")
      assert webhook_ip() == {127, 0, 0, 1}
    end

    test "LCARS_WEBHOOK_BIND_HOST expose le webhook seul" do
      System.put_env("LCARS_WEBHOOK_BIND_HOST", "0.0.0.0")
      assert webhook_ip() == {0, 0, 0, 0}
    end
  end
end
