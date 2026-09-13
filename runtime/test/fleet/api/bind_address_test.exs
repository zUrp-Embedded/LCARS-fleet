defmodule Fleet.API.BindAddressTest do
  @moduledoc """
  Checks listener child-spec selection: a configured control socket is independent
  of api_start_listener and LCARS_BIND_HOST. These structural assertions do not bind
  sockets or exclude a TCP listener hidden inside another child; ControlRouter tests
  exercise its actual UNIX transport.
  """
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> System.delete_env("LCARS_BIND_HOST") end)
    :ok
  end

  test "aucun listener TCP : sans socket de controle configure, le domaine ne demarre RIEN" do
    prev = Application.get_env(:lcars_fleet, :api_control_socket)
    Application.delete_env(:lcars_fleet, :api_control_socket)
    on_exit(fn -> prev && Application.put_env(:lcars_fleet, :api_control_socket, prev) end)

    assert Fleet.API.Application.listener_children() == []
  end

  test "le seul enfant possible est le socket de CONTROLE, et il est AF_UNIX" do
    prev = Application.get_env(:lcars_fleet, :api_control_socket)
    Application.put_env(:lcars_fleet, :api_control_socket, "/tmp/lcars-api-bind-test.sock")

    on_exit(fn ->
      if prev,
        do: Application.put_env(:lcars_fleet, :api_control_socket, prev),
        else: Application.delete_env(:lcars_fleet, :api_control_socket)
    end)

    assert [child] = Fleet.API.Application.listener_children()
    refute match?({Plug.Cowboy, _}, child)
  end

  test "l'ecriture ne depend plus d'un drapeau nomme d'apres une surface de LECTURE" do
    # The retired api_start_listener flag must not disable the control child.
    prev = Application.get_env(:lcars_fleet, :api_control_socket)
    Application.put_env(:lcars_fleet, :api_control_socket, "/tmp/lcars-api-bind-test.sock")
    Application.put_env(:lcars_fleet, :api_start_listener, false)

    on_exit(fn ->
      Application.delete_env(:lcars_fleet, :api_start_listener)

      if prev,
        do: Application.put_env(:lcars_fleet, :api_control_socket, prev),
        else: Application.delete_env(:lcars_fleet, :api_control_socket)
    end)

    assert length(Fleet.API.Application.listener_children()) == 1
  end

  test "LCARS_BIND_HOST n'atteint plus rien — il n'y a plus rien a elargir" do
    prev = Application.get_env(:lcars_fleet, :api_control_socket)
    Application.put_env(:lcars_fleet, :api_control_socket, "/tmp/lcars-api-bind-test.sock")

    on_exit(fn ->
      if prev,
        do: Application.put_env(:lcars_fleet, :api_control_socket, prev),
        else: Application.delete_env(:lcars_fleet, :api_control_socket)
    end)

    System.delete_env("LCARS_BIND_HOST")
    without = Fleet.API.Application.listener_children()

    System.put_env("LCARS_BIND_HOST", "0.0.0.0")
    assert Fleet.API.Application.listener_children() == without

    # Equality alone allows an unconditional extra listener; also check child population.
    # Inspecting the spec for Cowboy does not inspect a child's own descendants.
    for enfants <- [without, Fleet.API.Application.listener_children()] do
      assert length(enfants) == 1, "la population des listeners a change : #{inspect(enfants)}"

      refute inspect(enfants) =~ "Cowboy",
             "un listener TCP est revenu dans le superviseur API : #{inspect(enfants)}"
    end
  end
end
