defmodule Fleet.API.GitCommitterTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.API.GitCommitter

  setup %{tmp_dir: tmp_dir} do
    System.cmd("git", ["init", "--quiet"], cd: tmp_dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

    System.cmd("git", ["commit", "--allow-empty", "-m", "initial"],
      cd: tmp_dir,
      stderr_to_stdout: true
    )

    Application.put_env(:fleet_api, :git_repo_path, tmp_dir)

    on_exit(fn ->
      Application.delete_env(:fleet_api, :git_repo_path)
    end)

    :ok
  end

  describe "commit_config_change/3" do
    test "atomic write + git commit retourne SHA", %{tmp_dir: tmp_dir} do
      assert {:ok, sha} =
               GitCommitter.commit_config_change("intensity.json", ~s|{"level":"low"}|, "user1")

      assert sha =~ ~r/^[0-9a-f]{40}$/

      assert File.read!(Path.join(tmp_dir, "intensity.json")) == ~s|{"level":"low"}|

      {log, 0} = System.cmd("git", ["log", "--oneline", "-1"], cd: tmp_dir)
      assert log =~ "config: intensity.json updated by user1"
    end

    test "modification subséquente → nouveau commit" do
      {:ok, sha1} = GitCommitter.commit_config_change("a.json", ~s|{"v":1}|, "u1")
      {:ok, sha2} = GitCommitter.commit_config_change("a.json", ~s|{"v":2}|, "u2")

      assert sha1 != sha2
    end

    test "atomic write : pas de fichier .tmp restant après commit", %{tmp_dir: tmp_dir} do
      {:ok, _} = GitCommitter.commit_config_change("clean.json", "{}", "u")

      refute File.exists?(Path.join(tmp_dir, "clean.json.tmp"))
    end

    test "git fail (no commits possible) → {:error, _} cleanup tmp", %{tmp_dir: tmp_dir} do
      :ok = File.write!(Path.join(tmp_dir, "stable.json"), "{}", [:append])
      System.cmd("git", ["add", "stable.json"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "stable"], cd: tmp_dir, stderr_to_stdout: true)

      # Re-write same content → git commit fails (nothing to commit)
      assert {:error, msg} = GitCommitter.commit_config_change("stable.json", "{}", "u1")
      assert msg =~ "git command failed"

      # tmp file cleaned up
      refute File.exists?(Path.join(tmp_dir, "stable.json.tmp"))
    end

    test "confinement : path traversal `..` rejeté, aucun fichier écrit hors repo", %{
      tmp_dir: tmp_dir
    } do
      escapee = Path.expand(Path.join(tmp_dir, "../pwned.json"))
      File.rm(escapee)

      assert {:error, msg} =
               GitCommitter.commit_config_change("../pwned.json", ~s|{"x":1}|, "attacker")

      assert msg =~ "invalid file_path"
      refute File.exists?(escapee)
    end

    test "confinement : chemin absolu rejeté" do
      assert {:error, msg} =
               GitCommitter.commit_config_change("/etc/pwned.json", "x", "attacker")

      assert msg =~ "invalid file_path"
    end

    test "atomicité : échec git AVANT commit → fichier restauré à l'état d'origine", %{
      tmp_dir: tmp_dir
    } do
      {:ok, _} = GitCommitter.commit_config_change("r.json", ~s|{"v":"old"}|, "u")
      assert File.read!(Path.join(tmp_dir, "r.json")) == ~s|{"v":"old"}|

      # Un `.git/index.lock` résiduel fait échouer `git add` (rc128) APRÈS le rename, AVANT que le commit
      # ne land — déclencheur hook-INDÉPENDANT (les hooks sont désormais neutralisés `core.hooksPath=/dev/null`,
      # un `pre-commit exit 1` ne s'exécuterait plus → l'ancien mécanisme de test ne marche plus).
      lock = Path.join([tmp_dir, ".git", "index.lock"])
      File.write!(lock, "")
      on_exit(fn -> File.rm(lock) end)

      assert {:error, _} = GitCommitter.commit_config_change("r.json", ~s|{"v":"new"}|, "u")

      # le fichier disque est restauré à l'origine, PAS laissé sur "new" (atomicité)
      assert File.read!(Path.join(tmp_dir, "r.json")) == ~s|{"v":"old"}|
      refute File.exists?(Path.join(tmp_dir, "r.json.tmp"))
    end
  end

  # ============================================================
  # Durcissement confinement + hooks + rollback (Lot D1, WI-2)
  # ============================================================

  describe "confinement réel (non-lexical)" do
    test "WI-2.1 — un symlink dans le repo ne permet PAS d'écrire hors-repo (refusé)", %{
      tmp_dir: tmp_dir
    } do
      # Vecteur : le repo de config porte un symlink `link` -> un dossier HÔTE hors-repo. Un confinement
      # lexical (Path.expand) passe le préfixe ; File.write/File.rename SUIVRAIENT le lien → écriture hôte
      # arbitraire. La résolution non-lexicale (lstat par composant) doit refuser AVANT toute écriture.
      escape = Path.join(System.tmp_dir!(), "gc_escape_#{System.unique_integer([:positive])}")
      File.mkdir_p!(escape)
      File.ln_s!(escape, Path.join(tmp_dir, "link"))
      on_exit(fn -> File.rm_rf(escape) end)

      assert {:error, msg} =
               GitCommitter.commit_config_change("link/pwned.json", ~s|{"x":1}|, "attacker")

      assert msg =~ "invalid file_path"
      # le fichier n'a PAS été écrit derrière le symlink (pas d'évasion).
      refute File.exists?(Path.join(escape, "pwned.json"))
    end

    test "WI-2.1 — file_path avec composant `.git` refusé (pas de réécriture plomberie)", %{
      tmp_dir: _tmp_dir
    } do
      for p <- [".git/config", ".git/hooks/pre-commit", "sub/.git/config"] do
        assert {:error, msg} = GitCommitter.commit_config_change(p, "pwn", "attacker"),
               "path #{inspect(p)}"

        assert msg =~ "invalid file_path"
      end
    end

    test "WI-2.1 — `.gitignore` / `foo.git` (PAS un composant `.git`) restent autorisés", %{
      tmp_dir: _tmp_dir
    } do
      # Anti faux-positif du check composant : un basename qui CONTIENT `.git` n'est pas le dossier `.git`.
      assert {:ok, _} = GitCommitter.commit_config_change(".gitignore", "*.tmp\n", "u")
      assert {:ok, _} = GitCommitter.commit_config_change("foo.git", "x", "u")
    end

    test "WI-2.2 — file_path == racine refusé (pas de `.tmp` sibling créé hors-repo)", %{
      tmp_dir: tmp_dir
    } do
      sibling = Path.expand(tmp_dir) <> ".tmp"
      File.rm(sibling)

      for root_path <- ["", "."] do
        assert {:error, msg} = GitCommitter.commit_config_change(root_path, "x", "attacker"),
               "root path #{inspect(root_path)}"

        assert msg =~ "invalid file_path"
      end

      # le sibling `<root>.tmp` HORS du repo confiné n'a jamais été créé.
      refute File.exists?(sibling)
    end
  end

  describe "hooks neutralisés + rollback correct" do
    test "WI-2.3 — un hook pre-commit exécutable préexistant NE s'exécute PAS pendant un update",
         %{
           tmp_dir: tmp_dir
         } do
      sentinel = Path.join(System.tmp_dir!(), "gc_hook_#{System.unique_integer([:positive])}")
      File.rm(sentinel)
      on_exit(fn -> File.rm(sentinel) end)

      hooks = Path.join([tmp_dir, ".git", "hooks"])
      File.mkdir_p!(hooks)
      pre = Path.join(hooks, "pre-commit")
      File.write!(pre, "#!/bin/sh\ntouch '#{sentinel}'\n")
      File.chmod!(pre, 0o755)

      assert {:ok, _sha} = GitCommitter.commit_config_change("h.json", ~s|{"v":1}|, "u")

      # core.hooksPath=/dev/null → le hook posé dans le repo ne tourne pas côté monde.
      refute File.exists?(sentinel)
    end

    test "WI-2.4 — échec git AVANT commit : l'index ne garde PAS de blob fantôme", %{
      tmp_dir: tmp_dir
    } do
      {:ok, _} = GitCommitter.commit_config_change("g.json", ~s|{"v":"old"}|, "u")

      # On laisse `git add` réussir (stage un blob) mais `git commit` échouer : un `commit.gpgSign=true`
      # local sans clé de signature fait échouer le commit APRÈS le staging → on exerce la désindexation.
      System.cmd("git", ["config", "commit.gpgSign", "true"], cd: tmp_dir)
      System.cmd("git", ["config", "user.signingkey", "DOESNOTEXIST"], cd: tmp_dir)
      on_exit(fn -> System.cmd("git", ["config", "--unset", "commit.gpgSign"], cd: tmp_dir) end)

      assert {:error, _} = GitCommitter.commit_config_change("g.json", ~s|{"v":"new"}|, "u")

      # worktree restauré...
      assert File.read!(Path.join(tmp_dir, "g.json")) == ~s|{"v":"old"}|

      # ...ET l'index est PROPRE pour ce fichier (pas de blob `new` resté staged → un commit ultérieur
      # non-pathspec ne le matérialiserait pas). `git diff --cached --quiet -- g.json` rc0 = rien de staged.
      {_, idx_rc} =
        System.cmd("git", ["diff", "--cached", "--quiet", "--", "g.json"],
          cd: tmp_dir,
          stderr_to_stdout: true
        )

      assert idx_rc == 0, "blob fantôme resté dans l'index pour g.json"
    end

    test "WI-2.5 — commit RÉUSSI : le worktree n'est PAS rollback (égal à HEAD, pas à l'ancien)",
         %{
           tmp_dir: tmp_dir
         } do
      # Régression du bug « post-commit short-circuit » : sur un commit qui LAND, le worktree doit porter
      # le NOUVEAU contenu (jamais restauré à l'ancien). Le code distingue pre-commit (rollback) de
      # post-commit (commit durable, pas de rollback) ; un succès est la borne saine de cette distinction.
      {:ok, _} = GitCommitter.commit_config_change("p.json", ~s|{"v":"old"}|, "u")
      {:ok, sha} = GitCommitter.commit_config_change("p.json", ~s|{"v":"new"}|, "u")

      # worktree = nouveau contenu, et HEAD porte ce même contenu (commit durable, cohérent).
      assert File.read!(Path.join(tmp_dir, "p.json")) == ~s|{"v":"new"}|
      {head_blob, 0} = System.cmd("git", ["show", "#{sha}:p.json"], cd: tmp_dir)
      assert head_blob == ~s|{"v":"new"}|
    end
  end

  describe "garde content non-binaire" do
    test "content non-binaire refusé proprement (pas de crash File.write)", %{tmp_dir: _tmp_dir} do
      # La route REST matche la PRÉSENCE de la clé `content`, pas son type ; un map/list ferait crasher
      # File.write. Le guard rend `{:error, ...}` au lieu de laisser remonter une exception.
      assert {:error, msg} =
               GenServer.call(
                 GitCommitter,
                 {:commit, "c.json", %{"not" => "a binary"}, "u"},
                 5_000
               )

      assert msg =~ "invalid content"
    end
  end
end
