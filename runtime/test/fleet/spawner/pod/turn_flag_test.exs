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

  # ── watch.sh itself, run for real ──
  # The harness Monitor expires (30 min) and the agent re-arms it. Whatever was written to the flag
  # in between must be DELIVERED at re-arm, never absorbed — and never marked seen unread.
  describe "watch.sh on re-arm" do
    @watch Path.expand("priv/spawner/watch.sh", File.cwd!())

    defp watch_for(dir, seconds) do
      {out, _} =
        System.cmd("timeout", ["#{seconds}", "bash", @watch, Path.join(dir, "turn.flag")],
          stderr_to_stdout: true
        )

      String.split(out, "\n", trim: true)
    end

    @tag :tmp_dir
    test "a wake written while no Monitor was armed is EMITTED at re-arm, then marked seen", %{
      tmp_dir: dir
    } do
      File.write!(Path.join(dir, "turn.flag.seen"), "tok-1\n")
      File.write!(Path.join(dir, "turn.flag"), "tok-2\n")

      lines = watch_for(dir, 3)

      assert "ton tour" in lines, "the pending wake was absorbed: #{inspect(lines)}"
      assert File.read!(Path.join(dir, "turn.flag.seen")) =~ "tok-2"
    end

    @tag :tmp_dir
    test "an INFO written in the gap is delivered verbatim at re-arm", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "turn.flag.seen"), "tok-1\n")
      File.write!(Path.join(dir, "turn.flag"), "tok-2 info : brique #21 LIVRÉE\n")

      assert "info : brique #21 LIVRÉE" in watch_for(dir, 3)
    end

    @tag :tmp_dir
    test "nothing new since the last delivery → no wake, only the arming line", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "turn.flag.seen"), "tok-1\n")
      File.write!(Path.join(dir, "turn.flag"), "tok-1\n")

      assert watch_for(dir, 3) == ["watch arme sur #{Path.join(dir, "turn.flag")}"]
    end

    @tag :tmp_dir
    test "first arming of a pod life: the boot token is the baseline, and .seen marks the arming",
         %{tmp_dir: dir} do
      File.write!(Path.join(dir, "turn.flag"), "boot-kick\n")

      assert watch_for(dir, 3) == ["watch arme sur #{Path.join(dir, "turn.flag")}"]
      assert TurnFlag.monitor_armed?(dir)
    end
  end
end
