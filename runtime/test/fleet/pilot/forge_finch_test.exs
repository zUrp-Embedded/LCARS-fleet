defmodule Fleet.Pilot.ForgeFinchTest do
  @moduledoc """
  Checks that the dedicated forge HTTP pool is running. Connection idle-timeout
  behavior and recovery from stale connections require transport-level observation.
  """
  use ExUnit.Case, async: true

  test "the dedicated forge pool runs in the tree (started unconditionally by the Application)" do
    assert is_pid(Process.whereis(Fleet.Forge.Finch))
  end
end
