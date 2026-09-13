defmodule Fleet.Observation.BindAddressTest do
  @moduledoc """
  Checks the UNIX listener child spec, configured path and independence from
  LCARS_BIND_HOST. Does not bind sockets, verify permissions or authenticate the
  directory owner. The path test only establishes root/pattern, not the actual UID.
  """
  use ExUnit.Case, async: false

  setup do
    prev = Application.get_env(:lcars_fleet, :observation_start_listener)
    Application.put_env(:lcars_fleet, :observation_start_listener, true)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:lcars_fleet, :observation_start_listener)
        v -> Application.put_env(:lcars_fleet, :observation_start_listener, v)
      end

      System.delete_env("LCARS_BIND_HOST")
    end)

    :ok
  end

  defp child do
    [c] = Fleet.Observation.Application.listener_children()
    c
  end

  test "the deck is served by the AF_UNIX listener, not by a TCP child spec" do
    assert {Fleet.EventRouter.UnixListener, opts} = child()
    assert Keyword.fetch!(opts, :plug) == Fleet.Observation.Deck
    assert is_binary(Keyword.fetch!(opts, :socket))
  end

  test "no port, and no IP — there is no address to get wrong" do
    {_mod, opts} = child()

    refute Keyword.has_key?(opts, :port)
    refute Keyword.has_key?(opts, :ip)
    refute Keyword.has_key?(opts, :options)
  end

  test "the socket sits beside the terminals', under the console root of THIS human" do
    root = Application.get_env(:lcars_fleet, :console_sock_root, "/run/lcars/console")
    sock = Fleet.Observation.Application.deck_socket()

    assert String.starts_with?(sock, root <> "/")
    assert Path.basename(sock) == "deck.sock"
    assert Path.basename(Path.dirname(sock)) != ""
  end

  test "6-072: LCARS_BIND_HOST no longer reaches this listener — nothing left to widen" do
    System.delete_env("LCARS_BIND_HOST")
    without = child()

    System.put_env("LCARS_BIND_HOST", "0.0.0.0")
    assert child() == without
  end

  test "start_listener: false still yields no child at all" do
    Application.put_env(:lcars_fleet, :observation_start_listener, false)
    assert Fleet.Observation.Application.listener_children() == []
  end
end
