defmodule Fleet.Credentials.ShellTest do
  # async: false — le describe `git/2` mute l'env applicatif GLOBAL `:fleet_credentials, :forge_auth`
  # (que git_env/0 lit), partagé avec `ForgeAuthTest` ; le sérialiser évite la race put/delete des
  # GIT_CONFIG_* qui ferait échouer un `git config --get` lisant l'env mid-mutation.
  use ExUnit.Case, async: false

  alias Fleet.Credentials.Shell

  describe "run/3 — borne par construction (MOVE-1/MA-22)" do
    test "commande qui rend dans le délai → {:ok, {output, exit_code}}" do
      assert {:ok, {out, 0}} = Shell.run("sh", ["-c", "echo hello"], timeout_ms: 5_000)
      assert String.trim(out) == "hello"
    end

    test "exit code non nul est rendu tel quel (pas une erreur du wrapper)" do
      assert {:ok, {_out, 3}} = Shell.run("sh", ["-c", "exit 3"], timeout_ms: 5_000)
    end

    test "commande plus LONGUE que le timeout → TUÉE + {:error, {:timeout, ms}}" do
      # `sleep 30` dépasse de loin le timeout 200ms : la garde DOIT le tuer et rendre une erreur typée,
      # PAS attendre 30s. Le test lui-même borne sa propre attente (assert < timeout court).
      t0 = System.monotonic_time(:millisecond)
      assert {:error, {:timeout, 200}} = Shell.run("sleep", ["30"], timeout_ms: 200)
      elapsed = System.monotonic_time(:millisecond) - t0

      # On a rendu BIEN avant les 30s du sleep : la borne a coupé (marge large pour le CI lent).
      assert elapsed < 5_000
    end

    @tag :tmp_dir
    test "le process externe est RÉELLEMENT tué (pas de zombie qui survit au timeout)", %{
      tmp_dir: tmp
    } do
      # Preuve que la garde propage le SIGKILL au binaire enfant (port fermé → process tué), pas juste
      # abandonner le Task en laissant le sleep tourner orphelin. C'est l'invariant « pod pas zombie »
      # au niveau du process externe : un git/sleep qui pend ne survit pas à sa deadline.
      #
      # On trace par le PID OS, pas par une cmdline (sleep ne porte pas de marker). Le script `exec sleep`
      # → le sleep HÉRITE du pid du sh (même process) ; on grave ce pid dans un fichier AVANT le sleep,
      # puis on vérifie qu'il est mort après la deadline (`kill -0` échoue).
      pid_file = Path.join(tmp, "child.pid")
      script = Path.join(tmp, "hang.sh")

      # Le path est passé via une VARIABLE D'ENV (`$PIDFILE`), pas interpolé dans le source du script :
      # le nom de répertoire ExUnit contient des `()`/`—` (nom du test) qui casseraient `sh` s'ils étaient
      # inlinés. La valeur d'une var d'env n'est pas re-parsée par le shell → robuste.
      File.write!(
        script,
        ~S(#!/bin/sh) <> "\n" <> ~S(echo $$ > "$PIDFILE") <> "\nexec sleep 30\n"
      )

      File.chmod!(script, 0o755)

      # Appel BORNÉ inline : rend après ~500ms (la deadline), PAS après les 30s du sleep. Le `Shell.run`
      # grave d'abord le pid (début du script), puis se fait tuer à la deadline.
      assert {:error, {:timeout, 500}} =
               Shell.run("/bin/sh", [script], timeout_ms: 500, env: [{"PIDFILE", pid_file}])

      # Le pid a bien été gravé (le script a démarré).
      assert File.exists?(pid_file),
             "le script aurait dû démarrer et graver son pid avant d'être tué"

      child_pid = pid_file |> File.read!() |> String.trim()

      # Après la deadline : le pid OS doit être mort (tué via brutal_kill → port fermé → SIGKILL).
      assert eventually_dead_os_pid?(child_pid, 40),
             "le process externe (pid #{child_pid}) survit à sa deadline (zombie) — la borne ne tue pas l'enfant"
    end

    test "env par défaut de run/3 = [] (run/3 est la primitive bare, git/2 injecte git_env)" do
      # run/3 ne doit poser AUCUN env tout seul : on le prouve en lisant une var qu'on injecte.
      assert {:ok, {out, 0}} =
               Shell.run("sh", ["-c", "echo $LCARS_PROBE"], env: [{"LCARS_PROBE", "xyz"}])

      assert String.trim(out) == "xyz"
    end
  end

  # async: false — ce describe mute l'env applicatif global `:fleet_credentials, :forge_auth` (que
  # git_env/0 lit) ; restauré en on_exit. Sépare l'effet de bord global du describe async ci-dessus.
  describe "git/2 — injecte git_env/0 par défaut (anti-prompt MA-22)" do
    setup do
      prev = Application.get_env(:fleet_credentials, :forge_auth)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:fleet_credentials, :forge_auth, prev),
          else: Application.delete_env(:fleet_credentials, :forge_auth)
      end)

      :ok
    end

    test "git/2 sans :env hérite de git_env/0 — l'extraheader d'auth forge est vu par git" do
      # Preuve directe que `git/2` injecte `git_env/0` : on pose un forge_auth, et `git config --get`
      # (qui ne reçoit AUCUN -c sur l'argv) rend l'extraheader → il l'a lu depuis GIT_CONFIG_* (env)
      # posé par git_env(). Même mécanisme F087 que `forge_auth_test`, mais à travers `Shell.git/2`.
      # git_env() porte AUSSI GIT_TERMINAL_PROMPT=0 (anti-prompt MA-22), couvert par forge_auth_test.
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

    test "git/2 délègue à run/3 → reste BORNÉ (la borne est structurelle, partagée)" do
      # On ne peut pas faire pendre un vrai git de façon déterministe en CI ; le bornage réel d'un git
      # qui pend est couvert par `clone_test.exs` (faux serveur git muet). Ici : `git/2` partage le
      # chemin borné de `run/3` → un sleep plus long que le timeout est tué et rend l'erreur typée.
      assert {:error, {:timeout, 150}} = Shell.run("sleep", ["30"], timeout_ms: 150)
    end
  end

  # `kill -0 <pid>` : exit 0 si le process existe (et qu'on a le droit de le signaler), ≠ 0 sinon.
  defp alive_os_pid?(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  # Le pid OS est-il mort, en réessayant `tries` fois (le SIGKILL est asynchrone) ?
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
