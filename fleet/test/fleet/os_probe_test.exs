defmodule Fleet.Test.OsProbeTest do
  use ExUnit.Case, async: true

  alias Fleet.Test.OsProbe

  # An instrument with no test is what created the defect this module exists to fix: `kill -0` was
  # documented ("exit 0 if the process exists"), correct, and answering a neighbouring question.
  # Nothing measured the difference, so nothing could report it. What is pinned here is precisely
  # the case the old probe got wrong — a ZOMBIE — and the fact that it got it wrong.

  describe "alive?/1" do
    test "the current BEAM is running" do
      assert OsProbe.alive?(System.pid())
      assert OsProbe.state(System.pid()) in ["R", "S"]
    end

    test "a pid that cannot exist is dead, not an error" do
      # /proc caps at pid_max; 2^30 is above every configuration.
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

    # A zombie on demand, with nothing but coreutils. `exec sleep` REPLACES the shell: the process
    # that remains never calls wait(), so the child it backgrounded stays unreaped for the whole
    # sleep. No dependency on what pid 1 happens to be — which is the very variable that made the
    # old probe agree with reality on a workstation and disagree in a job container.
    # Paths go through the ENVIRONMENT, never interpolated into the script. ExUnit derives the
    # tmp_dir name from the test title, this one contains backticks, and bash would COMMAND-
    # SUBSTITUTE them: the redirect lands somewhere else and the fixture silently produces nothing.
    script = ~S(echo $$ > "$PARENTFILE"; sleep 0.2 & echo $! > "$CHILDFILE"; exec sleep 30)

    spawn(fn ->
      System.cmd("bash", ["-c", script],
        env: [{"PARENTFILE", parent_file}, {"CHILDFILE", child_file}],
        stderr_to_stdout: true
      )
    end)

    parent = read_pid_eventually(parent_file)
    child = read_pid_eventually(child_file)

    # Kill the holder no matter how this test ends: its death reparents the zombie to pid 1, which
    # reaps it. Leaving a 30s sleep behind would leak into the tests that follow.
    on_exit(fn -> System.cmd("kill", ["-KILL", parent], stderr_to_stdout: true) end)

    assert eventually_state?(child, "Z", 60),
           "the child (pid #{child}) never became a zombie — state #{inspect(OsProbe.state(child))}; " <>
             "the fixture proves nothing if it cannot produce the case under test"

    # THE defect, stated as an assertion: the old instrument reports this terminated process as
    # existing. That is not a bug in `kill -0`; it is a bug in reading it as liveness.
    assert {_, 0} = System.cmd("kill", ["-0", child], stderr_to_stdout: true)

    refute OsProbe.alive?(child)
    assert OsProbe.eventually_dead?(child, 1)
  end

  test "eventually_dead?/2 gives up rather than reporting a death it did not see" do
    # A budget of zero must not be read as "dead": a probe that fails open turns every timeout into
    # a green assertion.
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
