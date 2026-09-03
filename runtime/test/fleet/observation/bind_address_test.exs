defmodule Fleet.Observation.BindAddressTest do
  @moduledoc """
  Bind contract of the observation deck listener — 6-072/6-098.

  ## What this file used to pin, and why it could not stay

  It asserted `ip: {127,0,0,1}` by default and that `LCARS_BIND_HOST` was threaded through, so that
  public exposure stayed a NAMED opt-in. That contract is gone, and not by neglect: the deck no
  longer has an address at all. It binds an AF_UNIX socket in the human's console directory, and
  what keeps everyone out is that directory's mode, not a choice of interface.

  A test that kept asserting the old shape beside the new one would pin a contract nothing honours.
  The shape is SUBSTITUTED, per the repo's rule for an unreleased runtime — never added and
  deprecated.

  ## What replaces it, and it is stronger

  The old contract was "the default is safe, and widening it is explicit". The new one is "there is
  nothing to widen": no address means the exposure knob has nothing to act on. The last test below
  is that property stated positively — `LCARS_BIND_HOST=0.0.0.0`, the very setting that used to
  publish this deck to the LAN, now changes nothing about it.
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

    # Stated as an absence ON PURPOSE: these are the two keys a reviewer would reach for to
    # re-publish the deck, and their absence is the whole invariant of the lot.
    refute Keyword.has_key?(opts, :port)
    refute Keyword.has_key?(opts, :ip)
    refute Keyword.has_key?(opts, :options)
  end

  test "the socket sits beside the terminals', under the console root of THIS human" do
    # Same directory as `console.sock` and `pod.sock` — one guarded directory per human rather than
    # three arrangements to keep in step. The landing derives the same path from the login it
    # authenticated, so neither side carries a table of the other's.
    root = Application.get_env(:lcars_fleet, :console_sock_root, "/run/lcars/console")
    sock = Fleet.Observation.Application.deck_socket()

    assert String.starts_with?(sock, root <> "/")
    assert Path.basename(sock) == "deck.sock"
    assert Path.basename(Path.dirname(sock)) != ""
  end

  test "6-072: LCARS_BIND_HOST no longer reaches this listener — nothing left to widen" do
    # THE WITNESS OF THE WHOLE LOT. This is the setting that used to publish the observation deck on
    # every interface. A rule can be forgotten at the next route; a topology cannot — the deck has
    # no address, so the knob has nothing to act on. If this test ever goes red, an address came
    # back, and with it a second origin nobody asks anything of.
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
