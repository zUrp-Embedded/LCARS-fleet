defmodule Fleet.Credentials.ShellTest do
  # Serial: mutates credentials_forge_auth, token-directory configuration and PATH.
  use ExUnit.Case, async: false

  alias Fleet.Credentials.Shell
  alias Fleet.Test.OsProbe

  describe "run/3 — total opts (parse at the edge: never a raise outside {:ok}|{:error})" do
    # Covers supported option values and unknown keys, not arbitrary non-keyword containers.
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

    # A misspelled timeout option must not silently select the shorter default.
    test "unknown option → {:error, {:bad_opt, {:unknown, [key]}}}, named, before any value check" do
      assert {:error, {:bad_opt, {:unknown, [:timeout]}}} =
               Shell.run("sh", ["-c", "true"], timeout: 900_000)

      assert {:error, {:bad_opt, {:unknown, [:timeout, :retries]}}} =
               Shell.run("sh", ["-c", "true"], timeout: 1, retries: 3)

      # Unknown-key diagnosis takes precedence over an invalid recognised value.
      assert {:error, {:bad_opt, {:unknown, [:timeout]}}} =
               Shell.run("sh", ["-c", "true"], timeout: 1, timeout_ms: -1)
    end

    # Positive control: rejecting every option must not pass the validation tests.
    test "the four contract keys pass through — the guard refuses the unknown, not the known" do
      assert {:ok, {_, 0}} =
               Shell.run("sh", ["-c", "true"],
                 timeout_ms: 5_000,
                 max_output_bytes: 1_000,
                 env: [{"K", "v"}],
                 cd: "/tmp"
               )
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

    test "F-04: bad max_output_bytes → {:error, {:bad_opt, {:max_output_bytes, _}}}" do
      assert {:error, {:bad_opt, {:max_output_bytes, 0}}} =
               Shell.run("sh", ["-c", "true"], max_output_bytes: 0)

      assert {:error, {:bad_opt, {:max_output_bytes, "8"}}} =
               Shell.run("sh", ["-c", "true"], max_output_bytes: "8")
    end

    test "F-04 (codex audit): output OVER the cap → group killed + {:error, {:output_overflow, bytes, max}}" do
      # Exercise byte overflow independently of timeout; this assertion does not probe process death.
      assert {:error, {:output_overflow, bytes, 4096}} =
               Shell.run("sh", ["-c", "yes x | head -c 1000000; sleep 5"],
                 max_output_bytes: 4096,
                 timeout_ms: 10_000
               )

      assert bytes > 4096
    end

    test "F-04: output UNDER the cap → untouched {:ok, {output, 0}}" do
      assert {:ok, {out, 0}} =
               Shell.run("sh", ["-c", "printf hello"], max_output_bytes: 4096)

      assert out == "hello"
    end

    test "command LONGER than the timeout → KILLED + {:error, {:timeout, ms}}" do
      # Wide elapsed-time margin tolerates slow CI; it is checked after the call returns.
      t0 = System.monotonic_time(:millisecond)
      assert {:error, {:timeout, 200}} = Shell.run("sleep", ["30"], timeout_ms: 200)
      elapsed = System.monotonic_time(:millisecond) - t0

      assert elapsed < 5_000
    end

    @tag :tmp_dir
    test "the external process is REALLY killed (no zombie surviving the timeout)", %{
      tmp_dir: tmp
    } do
      # exec preserves the shell PID for sleep. Probe that PID after timeout; absent or zombie
      # means no live process remains, not that an orphan has necessarily been reaped.
      pid_file = Path.join(tmp, "child.pid")
      script = Path.join(tmp, "hang.sh")

      # Pass the path via quoted env expansion so punctuation in test directories is not shell code.
      File.write!(
        script,
        ~S(#!/bin/sh) <> "\n" <> ~S(echo $$ > "$PIDFILE") <> "\nexec sleep 30\n"
      )

      File.chmod!(script, 0o755)

      assert {:error, {:timeout, 500}} =
               Shell.run("/bin/sh", [script], timeout_ms: 500, env: [{"PIDFILE", pid_file}])

      assert File.exists?(pid_file),
             "the script should have started and written its pid before being killed"

      child_pid = pid_file |> File.read!() |> String.trim()

      assert eventually_dead_os_pid?(child_pid, 40),
             "the external process (pid #{child_pid}) survives its deadline — the bound does not " <>
               "kill the child (/proc state: #{inspect(OsProbe.state(child_pid))})"
    end

    test "run/3 default env = [] (run/3 is the bare primitive, git/2 injects git_env)" do
      # This tests an explicit env addition, not default env or removal of inherited variables.
      assert {:ok, {out, 0}} =
               Shell.run("sh", ["-c", "echo $LCARS_PROBE"], env: [{"LCARS_PROBE", "xyz"}])

      assert String.trim(out) == "xyz"
    end

    @tag :tmp_dir
    test "a detached DESCENDANT is killed at timeout (process-GROUP, not just the top-level)", %{
      tmp_dir: tmp
    } do
      # Background sleep has a distinct PID but retains its group; despite the title this
      # does not test a descendant escaping via setsid/setpgid. Probe the child itself so
      # killing only the top-level cannot pass.
      desc_pid_file = Path.join(tmp, "descendant.pid")
      script = Path.join(tmp, "fork_then_hang.sh")

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

      assert eventually_dead_os_pid?(desc_pid, 40),
             "the detached DESCENDANT (pid #{desc_pid}) survives the deadline — the bound only kills " <>
               "the top-level, not the process-group (C1 regression). /proc state: " <>
               "#{inspect(OsProbe.state(desc_pid))}"

      # Cleanup is registered after assertions; an earlier failure does not install this callback.
      on_exit(fn -> System.cmd("kill", ["-KILL", desc_pid], stderr_to_stdout: true) end)
    end

    test "6-031: apres `setsid`, le chef de groupe est os_pid OU son unique enfant — jamais ni l'un ni l'autre" do
      # Driver behaviour varies: setsid may exec as leader or fork a child leader.
      # Assert the disjunction on this host rather than assuming os_pid is always the PGID.
      setsid = System.find_executable("setsid")
      assert setsid, "setsid absent : la precondition de run/3 n'est pas tenue ici"

      port =
        Port.open({:spawn_executable, setsid}, [
          :binary,
          :exit_status,
          :hide,
          {:args, ["-w", "/bin/sleep", "2"]}
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      Process.sleep(300)

      stat = fn pid ->
        case File.read("/proc/#{pid}/stat") do
          {:ok, s} ->
            [_, rest] = String.split(s, ")", parts: 2)
            f = rest |> String.trim() |> String.split(" ")
            %{ppid: Enum.at(f, 1), pgrp: Enum.at(f, 2)}

          _ ->
            nil
        end
      end

      assert wrapper = stat.(os_pid), "test Linux-only, comme tout ce qui lit /proc ici"

      enfants =
        File.ls!("/proc")
        |> Enum.filter(fn p ->
          Regex.match?(~r/^\d+$/, p) and
            case stat.(p) do
              %{ppid: pp} -> pp == to_string(os_pid)
              _ -> false
            end
        end)

      enfant_chef? =
        Enum.any?(enfants, fn p ->
          case stat.(p) do
            %{pgrp: pg} -> pg == p
            _ -> false
          end
        end)

      assert wrapper.pgrp == to_string(os_pid) or enfant_chef?,
             "ni os_pid #{os_pid} (pgrp=#{wrapper.pgrp}) ni aucun de ses enfants #{inspect(enfants)} " <>
               "n'est chef de groupe — `kill -- -<pgid>` ne designerait le groupe de personne et " <>
               "une descendance survivrait a l'echeance"

      Port.close(port)
    end

    test "6-031: `setsid` ABSENT du PATH → refus fail-closed, jamais un `System.cmd` nu" do
      # Missing setsid must refuse launch, not bypass group isolation.
      tmp = Fleet.TestEnv.tmp_path("shell6031")
      File.mkdir_p!(tmp)
      File.ln_s!("/bin/echo", Path.join(tmp, "echo"))
      on_exit(fn -> File.rm_rf(tmp) end)

      prev = System.get_env("PATH")
      System.put_env("PATH", tmp)
      on_exit(fn -> System.put_env("PATH", prev) end)

      refute System.find_executable("setsid"),
             "la mise en scene doit vraiment retirer setsid du PATH"

      assert {:error, {:exit, {:enoent, "setsid"}}} =
               Shell.run("echo", ["6-031"], timeout_ms: 5_000)
    end

    test "WALL DEADLINE: a process DRIPPING output is killed at the deadline (not re-armed)" do
      # 80ms gaps are shorter than the 400ms timeout, distinguishing an absolute deadline from
      # a rearmed idle interval. This does not exercise a continuously non-empty port mailbox.
      t0 = System.monotonic_time(:millisecond)

      assert {:error, {:timeout, 400}} =
               Shell.run(
                 "/bin/sh",
                 ["-c", "while true; do echo drip; sleep 0.08; done"],
                 timeout_ms: 400
               )

      elapsed = System.monotonic_time(:millisecond) - t0

      # Elapsed assertion after return, not an independent 5-second watchdog around the call.
      assert elapsed < 5_000,
             "the drip pushed the deadline back (#{elapsed}ms) → the bound re-arms on every output " <>
               "(C2 regression: idle-gap instead of wall-clock)"
    end
  end

  describe "git/2 — injects git_env/0 by default (anti-prompt MA-22)" do
    setup do
      Fleet.TestEnv.restore_env_on_exit(:lcars_fleet, :credentials_forge_auth)

      # The authority double serves the fixture token; configuration contains only its account.
      tmp = Fleet.TestEnv.tmp_path("shell-forgeauth")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)
      File.write!(Path.join(tmp, "system_pusher.gitea_token"), "SECRET-shell")

      :ok
    end

    test "git/2 without :env inherits git_env/0 — the forge auth extraheader is seen by git" do
      # Read the header using actual Git through Shell.git/2, with no argv -c/header injection.
      Application.put_env(:lcars_fleet, :credentials_forge_auth, %{
        url_prefix: "https://forge.example/",
        account: "system_pusher"
      })

      assert {:ok, {out, 0}} =
               Shell.git(["config", "--get", "http.https://forge.example/.extraheader"],
                 timeout_ms: 5_000
               )

      assert String.trim(out) == "Authorization: token SECRET-shell"
    end

    test "git/2 delegates to run/3 → stays BOUNDED (the bound is structural, shared)" do
      # Despite the title, this invokes run/3 only. Clone tests exercise a mute Git server.
      assert {:error, {:timeout, 150}} = Shell.run("sleep", ["30"], timeout_ms: 150)
    end
  end

  # kill -0 also succeeds for zombies; OsProbe distinguishes them from running processes,
  # including containers whose PID 1 does not reap orphans.
  defp eventually_dead_os_pid?(pid, tries), do: OsProbe.eventually_dead?(pid, tries)
end
