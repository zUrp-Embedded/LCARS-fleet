defmodule Fleet.Spawner.Pod.TurnFlagTest do
  @moduledoc """
  Monitor delivery acknowledgements and per-launch reset, distinct from an agent's work pull.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.TurnFlag

  @tag :tmp_dir
  test "delivered? is true iff turn.flag.seen matches the live turn.flag", %{tmp_dir: dir} do
    flag = Path.join(dir, "turn.flag")
    seen = Path.join(dir, "turn.flag.seen")

    refute TurnFlag.delivered?(dir)

    TurnFlag.write(dir, nil)
    refute TurnFlag.delivered?(dir)

    # watch.sh delivered THIS token (it copies the flag content into .seen) -> delivered.
    File.write!(seen, File.read!(flag))
    assert TurnFlag.delivered?(dir)

    # A fresh token invalidates the previous acknowledgement.
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

  @tag :tmp_dir
  test "monitor_armed? tracks turn.flag.seen existence; reset clears the per-life rail", %{
    tmp_dir: dir
  } do
    seen = Path.join(dir, "turn.flag.seen")

    # Not armed until watch.sh writes .seen (which it does the moment it arms, before any wake).
    refute TurnFlag.monitor_armed?(dir)
    File.write!(seen, "\n")
    assert TurnFlag.monitor_armed?(dir)

    TurnFlag.write(dir, nil)
    assert File.exists?(Path.join(dir, "turn.flag"))
    :ok = TurnFlag.reset(dir)
    refute TurnFlag.monitor_armed?(dir)
    refute File.exists?(Path.join(dir, "turn.flag"))
    refute File.exists?(seen)
  end

  test "monitor_armed? / reset on a bad or nil path -> false / :ok (never raises)" do
    refute TurnFlag.monitor_armed?(nil)
    assert :ok = TurnFlag.reset(nil)
    assert :ok = TurnFlag.reset("/no/such/dir-#{System.unique_integer([:positive])}")
  end
end
