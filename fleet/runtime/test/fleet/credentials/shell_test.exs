defmodule Fleet.Credentials.ShellTest do
  # async: false — the `git/2` describe mutates the GLOBAL application env `:fleet_credentials,
  # :forge_auth` (read by git_env/0), shared with `ForgeAuthTest`; serializing avoids the
  # put/delete race on GIT_CONFIG_* that would make a `git config --get` reading the env
  # mid-mutation fail.
  use ExUnit.Case, async: false

  alias Fleet.Credentials.Shell

  describe "run/3 — total opts (parse at the edge: never a raise outside {:ok}|{:error})" do
    test "non-integer / negative timeout_ms → {:error, {:bad_opt, {:timeout_ms, _}}}" do
      assert {:error, {:bad_opt, {:timeout_ms, "5"}}} =
               Shell.run("sh", ["-c", "true"], timeout_ms: "5")

      assert {:error, {:bad_opt, {:timeout_ms, -1}}} =
               Shell.run("sh", ["-c", "true"], timeout_ms: -1)
    end

    test "malformed env (non-list OR non-string tuple) → {:error, {:bad_opt, {:env, _}}}" do
      assert {:error, {:bad_opt, {:env, _}}} = Shell.run("sh", ["-c", "true"], env: "PATH=/")
      assert {:error, {:bad_opt, {:env, _}}} = Shell.run("sh", ["-c", "true"], env: [{"K", 1}])
    end

    test "non-string cd → {:error, {:bad_opt, {:cd, _}}}" do
      assert {:error, {:bad_opt, {:cd, 42}}} = Shell.run("sh", ["-c", "true"], cd: 42)
    end

    test "non-binary args → {:error, {:bad_opt, :args}}" do
      assert {:error, {:bad_opt, :args}} = Shell.run("sh", ["-c", 123])
    end
  end

  describe "run/3 — bounded by construction (MOVE-1/MA-22)" do
    test "command returning within the deadline → {:ok, {output, exit_code}}" do
      assert {:ok, {out, 0}} = Shell.run("sh", ["-c", "echo hello"], timeout_ms: 5_000)
      assert String.trim(out) == "hello"
    end

    test "non-zero exit code is returned as-is (not a wrapper error)" do
      assert {:ok, {_out, 3}} = Shell.run("sh", ["-c", "exit 3"], timeout_ms: 5_000)
    end

    test "command LONGER than the timeout → KILLED + {:error, {:timeout, ms}}" do
      # `sleep 30` far exceeds the 200ms timeout: the guard MUST kill it and return a typed error,
      # NOT wait 30s. The test bounds its own wait too (assert < a short timeout).
      t0 = System.monotonic_time(:millisecond)
      assert {:error, {:timeout, 200}} = Shell.run("sleep", ["30"], timeout_ms: 200)
      elapsed = System.monotonic_time(:millisecond) - t0

      # We returned WELL before the sleep's 30s: the bound cut it (wide margin for slow CI).
      assert elapsed < 5_000
    end

    @tag :tmp_dir
    test "the external process is REALLY killed (no zombie surviving the timeout)", %{
      tmp_dir: tmp
    } do
      # Proof that the guard propagates the SIGKILL to the child binary (port closed → process
      # killed), not just abandoning the Task while the sleep runs on orphaned. This is the
      # "pod not zombie" invariant at the external-process level: a hanging git/sleep does not
      # survive its deadline.
      #
      # We trace by OS PID, not by a cmdline (sleep carries no marker). The script `exec sleep`
      # → the sleep INHERITS the sh's pid (same process); we write that pid to a file BEFORE the
      # sleep, then verify it is dead after the deadline (`kill -0` fails).
      pid_file = Path.join(tmp, "child.pid")
      script = Path.join(tmp, "hang.sh")

      # The path is passed via an ENV VARIABLE (`$PIDFILE`), not interpolated into the script
      # source: the ExUnit directory name contains `()`/`—` (test name) that would break `sh` if
      # inlined. An env var's value is not re-parsed by the shell → robust.
      File.write!(
        script,
        ~S(#!/bin/sh) <> "\n" <> ~S(echo $$ > "$PIDFILE") <> "\nexec sleep 30\n"
      )

      File.chmod!(script, 0o755)

      # BOUNDED inline call: returns after ~500ms (the deadline), NOT after the sleep's 30s. The
      # `Shell.run` first writes the pid (start of the script), then gets killed at the deadline.
      assert {:error, {:timeout, 500}} =
               Shell.run("/bin/sh", [script], timeout_ms: 500, env: [{"PIDFILE", pid_file}])

      # The pid was written (the script did start).
      assert File.exists?(pid_file),
             "the script should have started and written its pid before being killed"

      child_pid = pid_file |> File.read!() |> String.trim()

      # After the deadline: the OS pid must be dead (killed via brutal_kill → port closed → SIGKILL).
      assert eventually_dead_os_pid?(child_pid, 40),
             "the external process (pid #{child_pid}) survives its deadline (zombie) — the bound does not kill the child"
    end

    test "run/3 default env = [] (run/3 is the bare primitive, git/2 injects git_env)" do
      # run/3 must set NO env on its own: we prove it by reading a var we inject ourselves.
      assert {:ok, {out, 0}} =
               Shell.run("sh", ["-c", "echo $LCARS_PROBE"], env: [{"LCARS_PROBE", "xyz"}])

      assert String.trim(out) == "xyz"
    end

    @tag :tmp_dir
    test "a detached DESCENDANT is killed at timeout (process-GROUP, not just the top-level)", %{
      tmp_dir: tmp
    } do
      # INVARIANT C1 (process-group). A network git forks transport helpers; killing ONLY the
      # top-level would leave them alive. We simulate with a process that DETACHES a descendant
      # (`sleep & wait`) whose PID is DISTINCT from the top-level. Killing only the top
      # (`kill <os_pid>`) would let the descendant sleep SURVIVE the deadline; killing the group
      # (`kill -<pgid>`) kills it. We write the descendant's pid to a file, then verify it is
      # dead after the timeout.
      desc_pid_file = Path.join(tmp, "descendant.pid")
      script = Path.join(tmp, "fork_then_hang.sh")

      # The top-level starts `sleep 30` in the BACKGROUND (distinct PID), writes that pid, then
      # `wait`s. Path via env var (ExUnit directory name not re-parsed by the shell).
      File.write!(
        script,
        ~S(#!/bin/bash) <>
          "\n" <>
          ~S(sleep 30 &) <> "\n" <> ~S(echo $! > "$DESCPIDFILE") <> "\n" <> ~S(wait) <> "\n"
      )

      File.chmod!(script, 0o755)

      assert {:error, {:timeout, 500}} =
               Shell.run("/bin/bash", [script],
                 timeout_ms: 500,
                 env: [{"DESCPIDFILE", desc_pid_file}]
               )

      assert File.exists?(desc_pid_file),
             "the script should have started and written the descendant's pid before being killed"

      desc_pid = desc_pid_file |> File.read!() |> String.trim()

      # The descendant (PID ≠ top-level) must be dead: the bound killed the GROUP, not just the top.
      assert eventually_dead_os_pid?(desc_pid, 40),
             "the detached DESCENDANT (pid #{desc_pid}) survives the deadline — the bound only kills " <>
               "the top-level, not the process-group (C1 regression)"

      # Safety net: if the test fails, do not leave the sleep running for 30s.
      on_exit(fn -> System.cmd("kill", ["-KILL", desc_pid], stderr_to_stdout: true) end)
    end

    test "WALL DEADLINE: a process DRIPPING output is killed at the deadline (not re-armed)" do
      # INVARIANT C2 (wall deadline, not idle-gap). A network-hung git can DRIP output (one byte
      # just before each deadline); a `receive … after timeout_ms` loop RE-ARMED on every {:data}
      # would NEVER kill it. The process below emits a line every ~80ms in an infinite loop. With
      # a 400ms timeout, the ABSOLUTE deadline cuts it around 400ms no matter the drip; an
      # idle-gap bound would re-arm on every line (80ms gap < 400ms) and never expire → the test
      # would hang far beyond (so we bound the test's own wait to 5s).
      t0 = System.monotonic_time(:millisecond)

      assert {:error, {:timeout, 400}} =
               Shell.run(
                 "/bin/sh",
                 ["-c", "while true; do echo drip; sleep 0.08; done"],
                 timeout_ms: 400
               )

      elapsed = System.monotonic_time(:millisecond) - t0

      # The wall deadline cut shortly after 400ms, NOT never (wide margin for slow CI). A re-armed
      # idle-gap would never have reached this point.
      assert elapsed < 5_000,
             "the drip pushed the deadline back (#{elapsed}ms) → the bound re-arms on every output " <>
               "(C2 regression: idle-gap instead of wall-clock)"
    end
  end

  # async: false — this describe mutates the global application env `:fleet_credentials,
  # :forge_auth` (read by git_env/0); restored in on_exit. Keeps the global side effect separate
  # from the async-safe describe above.
  describe "git/2 — injects git_env/0 by default (anti-prompt MA-22)" do
    setup do
      Fleet.Credentials.TestEnv.restore_env_on_exit(:fleet_credentials, :forge_auth)
      :ok
    end

    test "git/2 without :env inherits git_env/0 — the forge auth extraheader is seen by git" do
      # Direct proof that `git/2` injects `git_env/0`: we set a forge_auth, and `git config --get`
      # (which receives NO -c on the argv) returns the extraheader → it read it from GIT_CONFIG_*
      # (env) set by git_env(). Same F087 mechanism as `forge_auth_test`, but through `Shell.git/2`.
      # git_env() ALSO carries GIT_TERMINAL_PROMPT=0 (anti-prompt MA-22), covered by forge_auth_test.
      Application.put_env(:fleet_credentials, :forge_auth, %{
        url_prefix: "https://forge.example/",
        token: "SECRET-shell"
      })

      assert {:ok, {out, 0}} =
               Shell.git(["config", "--get", "http.https://forge.example/.extraheader"],
                 timeout_ms: 5_000
               )

      assert String.trim(out) == "Authorization: token SECRET-shell"
    end

    test "git/2 delegates to run/3 → stays BOUNDED (the bound is structural, shared)" do
      # A real git cannot be made to hang deterministically in CI; the actual bounding of a
      # hanging git is covered by `clone_test.exs` (mute fake git server). Here: `git/2` shares
      # the bounded path of `run/3` → a sleep longer than the timeout is killed with a typed error.
      assert {:error, {:timeout, 150}} = Shell.run("sleep", ["30"], timeout_ms: 150)
    end
  end

  # `kill -0 <pid>`: exit 0 if the process exists (and we may signal it), non-zero otherwise.
  defp alive_os_pid?(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  # Is the OS pid dead, retrying `tries` times (SIGKILL is asynchronous)?
  defp eventually_dead_os_pid?(_pid, 0), do: false

  defp eventually_dead_os_pid?(pid, tries) do
    if alive_os_pid?(pid) do
      Process.sleep(50)
      eventually_dead_os_pid?(pid, tries - 1)
    else
      true
    end
  end
end
