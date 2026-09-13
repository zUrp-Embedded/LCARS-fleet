defmodule Fleet.Test.OsProbeTest do
  use ExUnit.Case, async: true

  alias Fleet.Test.OsProbe

  describe "alive?/1" do
    test "the current BEAM is running" do
      assert OsProbe.alive?(System.pid())
      assert OsProbe.state(System.pid()) in ["R", "S"]
    end

    test "a pid that cannot exist is dead, not an error" do
      # This value exceeds Linux pid_max.
      refute OsProbe.alive?(1_073_741_824)
      assert OsProbe.state(1_073_741_824) == nil
    end

    test "accepts a pid as a string — fixtures read it back from a file" do
      assert OsProbe.alive?(System.pid())
      assert OsProbe.alive?(String.to_integer(System.pid()))
    end
  end

  @tag :tmp_dir
  test "A ZOMBIE IS DEAD — the distinction `kill -0` cannot make", %{tmp_dir: tmp} do
    parent_file = Path.join(tmp, "parent.pid")
    child_file = Path.join(tmp, "child.pid")

    # exec sleep leaves its background child unreaped independently of pid 1 behavior.
    # Pass paths through env: the test-derived tmp path contains backticks that shell
    # interpolation would execute.
    script = ~S(echo $$ > "$PARENTFILE"; sleep 0.2 & echo $! > "$CHILDFILE"; exec sleep 30)

    spawn(fn ->
      System.cmd("bash", ["-c", script],
        env: [{"PARENTFILE", parent_file}, {"CHILDFILE", child_file}],
        stderr_to_stdout: true
      )
    end)

    parent = read_pid_eventually(parent_file)
    child = read_pid_eventually(child_file)

    # Kill the 30-second holder on exit. Reaping the reparented zombie depends on pid 1.
    on_exit(fn -> System.cmd("kill", ["-KILL", parent], stderr_to_stdout: true) end)

    assert eventually_state?(child, "Z", 60),
           "the child (pid #{child}) never became a zombie — state #{inspect(OsProbe.state(child))}; " <>
             "the fixture proves nothing if it cannot produce the case under test"

    assert {_, 0} = System.cmd("kill", ["-0", child], stderr_to_stdout: true)

    refute OsProbe.alive?(child)
    assert OsProbe.eventually_dead?(child, 1)
  end

  @tag :tmp_dir
  test "a `)` in the process NAME is not read as the state", %{tmp_dir: tmp} do
    # comm may contain ); splitting at the first one reads part of the name as state.
    # Copy bash: renamed multicall uutils sleep can dispatch incorrectly on argv[0].
    # A loop prevents bash from exec-replacing itself with its last command.
    weird = Path.join(tmp, "ev) il")
    File.cp!(System.find_executable("bash"), weird)
    File.chmod!(weird, 0o755)

    port =
      Port.open({:spawn_executable, weird}, [:binary, args: ["-c", "while :; do sleep 1; done"]])

    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true) end)

    # Wait for exec to set comm; Port.open can return while /proc still shows the parent name.
    assert eventually_comm?(pid, "(ev) il)", 100),
           "the fixture never produced a `)` inside comm — it proves nothing " <>
             "(stat: #{inspect(File.read("/proc/#{pid}/stat"))})"

    assert OsProbe.state(pid) in ["R", "S"]
    assert OsProbe.alive?(pid)
  end

  test "eventually_dead?/2 gives up rather than reporting a death it did not see" do
    refute OsProbe.eventually_dead?(System.pid(), 0)
    refute OsProbe.eventually_dead?(System.pid(), 2)
  end

  defp read_pid_eventually(path, tries \\ 100)
  defp read_pid_eventually(path, 0), do: flunk("pid file never appeared: #{path}")

  defp read_pid_eventually(path, tries) do
    case File.read(path) do
      {:ok, raw} ->
        case String.trim(raw) do
          "" ->
            Process.sleep(20)
            read_pid_eventually(path, tries - 1)

          pid ->
            pid
        end

      {:error, _} ->
        Process.sleep(20)
        read_pid_eventually(path, tries - 1)
    end
  end

  defp eventually_comm?(_pid, _needle, 0), do: false

  defp eventually_comm?(pid, needle, tries) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        if String.contains?(stat, needle) do
          true
        else
          Process.sleep(20)
          eventually_comm?(pid, needle, tries - 1)
        end

      {:error, _} ->
        Process.sleep(20)
        eventually_comm?(pid, needle, tries - 1)
    end
  end

  defp eventually_state?(_pid, _want, 0), do: false

  defp eventually_state?(pid, want, tries) do
    if OsProbe.state(pid) == want do
      true
    else
      Process.sleep(20)
      eventually_state?(pid, want, tries - 1)
    end
  end
end
