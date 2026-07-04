defmodule Fleet.GitTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # ============================================================
  # Helpers (workspace + bare repo distants en tmp_dir)
  # ============================================================

  defp init_bare_repo(path) do
    File.mkdir_p!(path)
    {_out, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", path])
    path
  end

  defp init_workspace(path, opts \\ []) do
    File.mkdir_p!(path)
    {_out, 0} = System.cmd("git", ["init", "--initial-branch=main", path])

    # Default config local — sinon git refuse les commits sans user.* mais aussi
    # certains hooks. Notre code force GIT_AUTHOR_*/GIT_COMMITTER_* via env, mais
    # git lit user.name/user.email pour le commit même quand l'env est posé sur
    # certaines versions ; on les pose pour neutraliser.
    {_out, 0} = System.cmd("git", ["config", "user.name", "init-only"], cd: path)
    {_out, 0} = System.cmd("git", ["config", "user.email", "init@example.com"], cd: path)

    case Keyword.get(opts, :remote_url) do
      nil -> :ok
      remote -> {_out, 0} = System.cmd("git", ["remote", "add", "origin", remote], cd: path)
    end

    path
  end

  defp commit_initial(workspace, message \\ "initial") do
    File.write!(Path.join(workspace, "seed.txt"), "seed\n")
    {_out, 0} = System.cmd("git", ["add", "."], cd: workspace)
    {_out, 0} = System.cmd("git", ["commit", "-m", message], cd: workspace)
    :ok
  end

  defp valid_opts(workspace) do
    %{
      workspace: workspace,
      author_name: "engineer",
      author_email: "engineer@lcars.local",
      committer_name: "LCARS System",
      committer_email: "system@lcars.local",
      message: "feat: payload from worker",
      branch: "main"
    }
  end

  # ============================================================
  # publish/1 — add+commit (sans push)
  # ============================================================

  describe "publish/1 — commit local sans push" do
    test "commit créé avec auteur et committer corrects (D-04)", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws"))
      commit_initial(ws)
      File.write!(Path.join(ws, "feature.md"), "delivered by worker\n")

      assert {:ok, %{commit_sha: <<_::binary-size(40)>>, pushed?: false}} =
               Fleet.Workflow.Git.publish(valid_opts(ws))

      {author_line, 0} = System.cmd("git", ["log", "-1", "--format=%an <%ae>"], cd: ws)
      {committer_line, 0} = System.cmd("git", ["log", "-1", "--format=%cn <%ce>"], cd: ws)
      {subject, 0} = System.cmd("git", ["log", "-1", "--format=%s"], cd: ws)

      assert String.trim(author_line) == "engineer <engineer@lcars.local>"
      assert String.trim(committer_line) == "LCARS System <system@lcars.local>"
      assert String.trim(subject) == "feat: payload from worker"
    end

    test "add_paths restreint le staging", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-paths"))
      commit_initial(ws)

      File.mkdir_p!(Path.join(ws, "docs"))
      File.write!(Path.join(ws, "docs/X.md"), "doc\n")
      File.write!(Path.join(ws, "ignored.txt"), "should not be committed\n")

      opts = Map.put(valid_opts(ws), :add_paths, ["docs/"])
      assert {:ok, _} = Fleet.Workflow.Git.publish(opts)

      {staged_files, 0} = System.cmd("git", ["show", "--name-only", "--format=", "HEAD"], cd: ws)
      assert String.trim(staged_files) == "docs/X.md"
    end

    test "fail-closed : workspace absent", %{tmp_dir: tmp} do
      assert {:error, :workspace_missing} =
               Fleet.Workflow.Git.publish(valid_opts(Path.join(tmp, "nope")))
    end

    test "fail-closed : workspace pas un repo git", %{tmp_dir: tmp} do
      ws = Path.join(tmp, "not-git")
      File.mkdir_p!(ws)

      assert {:error, :not_a_git_workspace} = Fleet.Workflow.Git.publish(valid_opts(ws))
    end

    test "fail-closed : rien à committer → :nothing_to_commit", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-empty"))
      commit_initial(ws)
      # AUCUNE modification après le seed → git commit refuse.
      assert {:error, :nothing_to_commit} = Fleet.Workflow.Git.publish(valid_opts(ws))
    end

    test "fail-closed : opts manquants", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-bad"))
      commit_initial(ws)

      opts = valid_opts(ws) |> Map.delete(:author_email) |> Map.delete(:message)
      assert {:error, {:missing_opts, missing}} = Fleet.Workflow.Git.publish(opts)
      assert :author_email in missing
      assert :message in missing
    end

    test "fail-closed : branche invalide (espace, --, ..)", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-branch"))
      commit_initial(ws)
      File.write!(Path.join(ws, "x.txt"), "x\n")

      Enum.each(["foo bar", "--force", "..", "foo;rm", ""], fn bad ->
        opts = Map.put(valid_opts(ws), :branch, bad)

        assert {:error, :invalid_branch} = Fleet.Workflow.Git.publish(opts),
               "branch #{inspect(bad)}"
      end)
    end

    test "fail-closed : push? sans remote", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-push-no-remote"))
      commit_initial(ws)
      File.write!(Path.join(ws, "x.txt"), "x\n")

      opts = Map.put(valid_opts(ws), :push?, true)
      assert {:error, :push_requires_remote} = Fleet.Workflow.Git.publish(opts)
    end
  end

  # ============================================================
  # Injection git (F-014 add / F-046 push) — Pattern C
  # ============================================================

  describe "injection git (Pattern C)" do
    test "F-014 : add_paths leading-`-` est un CHEMIN (via `--`), pas une option — `--all` ne stage pas tout",
         %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-f014"))
      commit_initial(ws)
      File.write!(Path.join(ws, "sneaky.txt"), "x\n")

      opts = Map.put(valid_opts(ws), :add_paths, ["--all"])

      # Sans `--`, `git add --all` staterait sneaky.txt → {:ok}. Avec `--`, "--all" est un pathspec
      # littéral (absent) → échec : l'option-injection est neutralisée (rien n'est stagé-en-masse).
      assert {:error, _} = Fleet.Workflow.Git.publish(opts)
    end

    test "F-014 : add_paths invalide (vide / non-binaire / élément vide) → :invalid_add_paths",
         %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-f014b"))
      commit_initial(ws)
      File.write!(Path.join(ws, "x.txt"), "x\n")

      for bad <- [[], [123], ["", "ok"], "not-a-list"] do
        opts = Map.put(valid_opts(ws), :add_paths, bad)

        assert {:error, :invalid_add_paths} = Fleet.Workflow.Git.publish(opts),
               "add_paths #{inspect(bad)}"
      end
    end

    test "F-046 : push remote leading-`-` rejeté fail-closed (`-c`, `--receive-pack=`, `--exec=`)",
         %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-f046"))

      for bad <- ["-c", "--receive-pack=touch /tmp/pwn", "--exec=x"] do
        assert {:error, {:invalid_remote, ^bad}} = Fleet.Workflow.Git.push(ws, bad, "HEAD:main"),
               "remote #{inspect(bad)}"
      end
    end

    test "F-046 : push refspec leading-`-` rejeté", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-f046b"))

      assert {:error, {:invalid_refspec, "--force"}} =
               Fleet.Workflow.Git.push(ws, "origin", "--force")
    end

    test "F-046 : publish avec remote leading-`-` rejeté tôt (check_push_remote)", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-f046c"))
      commit_initial(ws)
      File.write!(Path.join(ws, "x.txt"), "x\n")

      opts = valid_opts(ws) |> Map.merge(%{remote: "--receive-pack=evil", push?: true})
      assert {:error, {:invalid_remote, "--receive-pack=evil"}} = Fleet.Workflow.Git.publish(opts)
    end
  end

  # ============================================================
  # publish/1 — push vers bare repo local
  # ============================================================

  describe "publish/1 — push vers bare repo" do
    test "commit pousse sur le remote (bare repo local)", %{tmp_dir: tmp} do
      bare = init_bare_repo(Path.join(tmp, "bare.git"))
      ws = init_workspace(Path.join(tmp, "ws"), remote_url: bare)
      commit_initial(ws)

      # Premier push pour aligner le bare sur main.
      {_, 0} = System.cmd("git", ["push", "origin", "main"], cd: ws)

      File.write!(Path.join(ws, "feature.md"), "post-extract payload\n")

      opts = valid_opts(ws) |> Map.merge(%{remote: "origin", push?: true})
      assert {:ok, %{commit_sha: sha, pushed?: true}} = Fleet.Workflow.Git.publish(opts)

      # Vérifie côté bare : le commit y est arrivé.
      {bare_sha, 0} = System.cmd("git", ["rev-parse", "main"], cd: bare)
      assert String.trim(bare_sha) == sha
    end

    test "push? false ne touche pas le remote", %{tmp_dir: tmp} do
      bare = init_bare_repo(Path.join(tmp, "bare.git"))
      ws = init_workspace(Path.join(tmp, "ws-nopush"), remote_url: bare)
      commit_initial(ws)
      {_, 0} = System.cmd("git", ["push", "origin", "main"], cd: ws)

      {bare_head_before, 0} = System.cmd("git", ["rev-parse", "main"], cd: bare)
      File.write!(Path.join(ws, "feature.md"), "local only\n")

      opts = valid_opts(ws) |> Map.merge(%{remote: "origin", push?: false})
      assert {:ok, %{pushed?: false}} = Fleet.Workflow.Git.publish(opts)

      {bare_head_after, 0} = System.cmd("git", ["rev-parse", "main"], cd: bare)
      assert bare_head_before == bare_head_after
    end
  end

  describe "push/3 — F-PARALLEL-PR-CONFLICT (force sur historique réécrit)" do
    test "push normal rejeté (non-fast-forward) → retry --force land la branche rebasée", %{
      tmp_dir: tmp
    } do
      bare = init_bare_repo(Path.join(tmp, "remote.git"))
      ws = init_workspace(Path.join(tmp, "ws"), remote_url: bare)
      commit_initial(ws, "C1")

      # push initial → la remote a C1.
      assert {:ok, true} = Fleet.Workflow.Git.push(ws, "origin", "HEAD:main")

      # réécrit l'historique (amend = nouvelle sha qui diverge de la remote — comme un rebase de résolution).
      {_o, 0} = System.cmd("git", ["commit", "--amend", "-m", "C1-rebase"], cd: ws)
      {rewritten, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: ws)

      # un push normal serait « non-fast-forward » → do_push retry `--force` → land (sans ça, le rebase de
      # résolution ne land JAMAIS et la PR reste en conflit, le bug live PR#4).
      assert {:ok, true} = Fleet.Workflow.Git.push(ws, "origin", "HEAD:main")

      {remote_head, 0} = System.cmd("git", ["rev-parse", "main"], cd: bare)
      assert String.trim(remote_head) == String.trim(rewritten)
    end

    # NB nommage : le tmp_dir ExUnit est dérivé du nom du test ; git embarque ce chemin dans sa sortie
    # d'erreur. Le nom NE DOIT PAS contenir les substrings classés par `non_fast_forward?` (sinon le chemin
    # pollue `out` et fait un faux positif). D'où un libellé volontairement neutre.
    test "MA-05 : push refuse par hook serveur ne declenche AUCUN retry brutal", %{tmp_dir: tmp} do
      bare = init_bare_repo(Path.join(tmp, "remote.git"))
      ws = init_workspace(Path.join(tmp, "ws"), remote_url: bare)
      commit_initial(ws, "C1")

      # Hook pre-receive qui REFUSE tout push → git émet « [remote rejected] … pre-receive hook declined »
      # (le substring `rejected` SANS `non-fast-forward`). Avant MA-05 : `non_fast_forward?` matchait
      # `rejected` → retry `--force` à tort (réécriture forcée par-dessus une garde serveur).
      #
      # DISCRIMINANT : le hook COMPTE ses invocations (1 ligne `x`/appel dans un fichier témoin). Un push
      # normal seul → 1 invocation. Si le fix régresse et tente `--force`, git relance le push (le force ne
      # contourne PAS un pre-receive) → 2 invocations. Le COMPTE prouve l'absence de retry-force, là où
      # observer la remote ne le pouvait pas (force-declined échoue comme push-declined).
      # Le counter vit dans un chemin SANS caractères spéciaux : le tmp_dir ExUnit embarque le nom du test
      # (parenthèses, `→`, `≠`) qui, interpolé non-quoté dans le `sh` du hook, casserait la redirection.
      counter =
        Path.join(System.tmp_dir!(), "ma05_hook_calls_#{System.unique_integer([:positive])}")

      File.rm(counter)
      hook = Path.join([bare, "hooks", "pre-receive"])

      File.write!(
        hook,
        "#!/bin/sh\necho x >> '#{counter}'\necho 'policy: pushes are blocked' >&2\nexit 1\n"
      )

      File.chmod!(hook, 0o755)
      on_exit(fn -> File.rm(counter) end)

      assert {:error, {:git_push_failed, rc, out}} =
               Fleet.Workflow.Git.push(ws, "origin", "HEAD:main")

      assert rc != 0
      assert out =~ "declined" or out =~ "rejected"

      # LE test : le hook n'a été invoqué QU'UNE fois → aucun retry `--force` (qui l'aurait re-déclenché).
      invocations = counter |> File.read!() |> String.split("\n", trim: true) |> length()

      assert invocations == 1,
             "hook invoqué #{invocations}× — un retry --force a été tenté (régression MA-05)"

      # Garde-fou complémentaire : la remote n'a jamais reçu le ref.
      {_o, rev_rc} =
        System.cmd("git", ["rev-parse", "--verify", "main"], cd: bare, stderr_to_stdout: true)

      assert rev_rc != 0, "le hook declined ne doit RIEN avoir poussé sur la remote"
    end
  end
end
