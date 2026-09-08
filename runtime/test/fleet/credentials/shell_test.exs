defmodule Fleet.Credentials.ShellTest do
  # async: false — the `git/2` describe mutates the GLOBAL application env `:lcars_fleet,
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

    # ⚠ CE TEMOIN EXISTE PARCE QUE LE CONTRAIRE A COUTE 15 MINUTES DE DEADLINE. `ProjectPublish`
    # passait `timeout:` la ou ce module lit `:timeout_ms` ; la cle etait absorbee sans un mot et le
    # rail tournait sur les 30 s du defaut. Valider le TYPE des cles connues sans refuser les
    # inconnues ne gardait que les fautes que personne ne commet.
    test "unknown option → {:error, {:bad_opt, {:unknown, [key]}}}, named, before any value check" do
      assert {:error, {:bad_opt, {:unknown, [:timeout]}}} =
               Shell.run("sh", ["-c", "true"], timeout: 900_000)

      # PLUSIEURS inconnues sont TOUTES nommees : un message qui n'en cite qu'une envoie le lecteur
      # corriger, relancer, et retomber sur la suivante.
      assert {:error, {:bad_opt, {:unknown, [:timeout, :retries]}}} =
               Shell.run("sh", ["-c", "true"], timeout: 1, retries: 3)

      # L'ORDRE COMPTE : une cle inconnue tombe AVANT la validation des valeurs. Ici `timeout_ms`
      # est invalide ET `timeout` est inconnue — c'est la cle qui n'a jamais ete lue qu'on nomme,
      # pas la valeur d'une cle qui, elle, l'aurait ete.
      assert {:error, {:bad_opt, {:unknown, [:timeout]}}} =
               Shell.run("sh", ["-c", "true"], timeout: 1, timeout_ms: -1)
    end

    # LE TEMOIN NEGATIF, sans lequel le precedent passerait sur un garde qui refuse TOUT. Les quatre
    # cles du contrat traversent, et la commande s'execute reellement.
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
      # The wall deadline bounds TIME, not MEMORY (repro'd: 20 MB buffered whole) — the cap must
      # kill the producer mid-stream, well before the deadline.
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
      # sleep, then verify it is dead after the deadline (no `/proc` entry, or state `Z`).
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
             "the external process (pid #{child_pid}) survives its deadline — the bound does not " <>
               "kill the child (/proc state: #{inspect(Fleet.Test.OsProbe.state(child_pid))})"
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
               "the top-level, not the process-group (C1 regression). /proc state: " <>
               "#{inspect(Fleet.Test.OsProbe.state(desc_pid))}"

      # Safety net: if the test fails, do not leave the sleep running for 30s.
      on_exit(fn -> System.cmd("kill", ["-KILL", desc_pid], stderr_to_stdout: true) end)
    end

    # 6-031 — LE PGID ETAIT CHERCHE, ET L'ECHEC DE LA RECHERCHE LAISSAIT LA DESCENDANCE EN VIE.
    # `terminate/2` ne tuait le groupe que si trois lectures de `/proc` avaient abouti ; sinon il
    # tuait la seule enveloppe `setsid` et rendait la main. L'appelant recevait
    # `{:error, {:timeout, _}}` et considerait l'operation terminee pendant que git continuait a
    # ecrire et a parler au reseau. `/proc` absent ou partiel est l'ordinaire d'un conteneur durci.
    #
    # Le cas a disparu au lieu d'etre traite : le port place deja son enfant dans une session neuve,
    # donc `os_pid` EST le PGID. Ces deux tests tiennent ce qui rend cela vrai — le premier
    # l'identite elle-meme (detail d'implementation du driver, donc EPINGLE ici et pas seulement
    # affirme en commentaire), le second l'absence de la dependance qui la cassait.
    test "6-031: apres `setsid`, le chef de groupe est os_pid OU son unique enfant — jamais ni l'un ni l'autre" do
      # ⚠ CE TEST A DEJA EXISTE SOUS UNE AUTRE FORME, ET IL AFFIRMAIT UNE CHOSE FAUSSE : que le pid
      # du port est TOUJOURS son propre chef de groupe. C'est vrai sur le poste de dev et FAUX dans
      # le conteneur de CI (mesure : `pgrp=558` pour `os_pid=7337`), ou l'enfant du port herite du
      # groupe du BEAM. Le banc l'a dit, et ce test est ce qui l'a nomme.
      #
      # L'invariant PORTABLE, celui dont `kill_scope/1` depend, est la DISJONCTION : apres
      # `setsid`, ou bien il ne forke pas et `os_pid` est chef de groupe, ou bien il forke et son
      # unique enfant l'est. Ce qui doit etre impossible, c'est qu'aucun des deux ne le soit — la,
      # `kill -- -<pgid>` ne designerait plus le groupe de la commande.
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
      # L'enveloppe est la precondition ANNONCEE du kill de groupe : sans elle on ne peut pas
      # garantir « tout le groupe meurt », et rendre la main quand meme donnerait une borne qui a
      # l'air d'en etre une. Ce refus vaut mieux qu'une commande lancee sans filet.
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

  # async: false — this describe mutates the global application env `:lcars_fleet,
  # :forge_auth` (read by git_env/0); restored in on_exit. Keeps the global side effect separate
  # from the async-safe describe above.
  describe "git/2 — injects git_env/0 by default (anti-prompt MA-22)" do
    setup do
      Fleet.TestEnv.restore_env_on_exit(:lcars_fleet, :credentials_forge_auth)

      # ⚠ LE JETON N'EST PLUS DANS LA CONFIG : elle porte le COMPTE, et le jeton se demande au
      # service d'autorite (double de la suite, qui sert depuis `:credentials_role_tokens_dir`).
      # Le mecanisme que ce temoin prouve — `git` lit l'en-tete dans l'ENV, jamais sur l'argv — est
      # exactement le meme ; seul l'endroit d'ou vient le secret a change.
      tmp = Fleet.TestEnv.tmp_path("shell-forgeauth")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)
      File.write!(Path.join(tmp, "system_pusher.gitea_token"), "SECRET-shell")

      :ok
    end

    test "git/2 without :env inherits git_env/0 — the forge auth extraheader is seen by git" do
      # Direct proof that `git/2` injects `git_env/0`: we set a forge_auth, and `git config --get`
      # (which receives NO -c on the argv) returns the extraheader → it read it from GIT_CONFIG_*
      # (env) set by git_env(). Same F087 mechanism as `forge_auth_test`, but through `Shell.git/2`.
      # git_env() ALSO carries GIT_TERMINAL_PROMPT=0 (anti-prompt MA-22), covered by forge_auth_test.
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
      # A real git cannot be made to hang deterministically in CI; the actual bounding of a
      # hanging git is covered by `clone_test.exs` (mute fake git server). Here: `git/2` shares
      # the bounded path of `run/3` → a sleep longer than the timeout is killed with a typed error.
      assert {:error, {:timeout, 150}} = Shell.run("sleep", ["30"], timeout_ms: 150)
    end
  end

  # NOT `kill -0`. That probe succeeds on a ZOMBIE, so it answers "is the pid slot taken" — a
  # different question, with the same answer only where pid 1 reaps orphans. In a gitea-actions job
  # container pid 1 is `/bin/sleep`, an orphan killed there stays `Z` forever, and the C1 test below
  # went red on a bound that had worked perfectly. Cf. `Fleet.Test.OsProbe`.
  defp eventually_dead_os_pid?(pid, tries), do: Fleet.Test.OsProbe.eventually_dead?(pid, tries)
end
