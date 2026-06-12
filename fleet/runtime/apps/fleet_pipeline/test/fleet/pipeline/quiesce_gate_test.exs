defmodule Fleet.Pipeline.QuiesceGateTest do
  @moduledoc """
  Gate de quiescence sur le chokepoint « nouveau pipeline top-level »
  (brique R4 D5 2/3). async: false — flag global ; on_exit resume! impératif.
  """
  use ExUnit.Case, async: false

  alias Fleet.Shutdown.Quiesce

  setup do
    on_exit(&Quiesce.resume!/0)
    :ok
  end

  test "start_pipeline refuse {:error, :quiescing} pendant un drain (avant tout effet)" do
    Quiesce.refuse!()

    assert {:error, :quiescing} =
             Fleet.Pipeline.start_pipeline("intensity-low", %{ticket_id: "fleet/lcars#1"})
  end

  test "count_running/0 rend un entier >= 0" do
    n = Fleet.Pipeline.count_running()
    assert is_integer(n) and n >= 0
  end
end
