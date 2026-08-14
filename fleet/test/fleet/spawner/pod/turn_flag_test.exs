defmodule Fleet.Spawner.Pod.TurnFlagTest do
  @moduledoc """
  `delivered?/1` — the carrier DELIVERY ack: `turn.flag.seen` (written by `watch.sh` right after it
  emits the wake) matching the live `turn.flag`. It is what the wake fallback keys on instead of the
  agent's RESPONSE (`get_work_item`), which the agent may legitimately withhold.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.TurnFlag

  @tag :tmp_dir
  test "delivered? is true iff turn.flag.seen matches the live turn.flag", %{tmp_dir: dir} do
    flag = Path.join(dir, "turn.flag")
    seen = Path.join(dir, "turn.flag.seen")

    # No flag, no seen -> not delivered (fail-open to the send-keys / wake.failed rails).
    refute TurnFlag.delivered?(dir)

    # Flag written, but watch.sh has not recorded a delivery yet -> not delivered.
    TurnFlag.write(dir, nil)
    refute TurnFlag.delivered?(dir)

    # watch.sh delivered THIS token (it copies the flag content into .seen) -> delivered.
    File.write!(seen, File.read!(flag))
    assert TurnFlag.delivered?(dir)

    # A NEW turn (fresh token) the Monitor has not yet emitted -> seen lags -> not delivered.
    TurnFlag.write(dir, nil)
    refute TurnFlag.delivered?(dir)

    # Trailing-whitespace tolerance: flag and seen differ only by a trailing newline -> delivered.
    File.write!(seen, File.read!(flag) <> "\n")
    assert TurnFlag.delivered?(dir)
  end

  test "delivered? never raises on a bad or nil path -> false" do
    refute TurnFlag.delivered?("/no/such/pod/dir/xyz-#{System.unique_integer([:positive])}")
    refute TurnFlag.delivered?(nil)
  end
end
