defmodule Fleet.Workflow.DeliverableTest do
  # Publication unifiée O5 — fixture git RÉELLE (workspace + bare remote). Les 2 modes (payload /
  # git_native) passent par la MÊME gate + le MÊME push ; seul le temps CONTENU diverge. Un livrable
  # invalide (secret, identité usurpée, historique réécrit) est irreprésentable au push.
  use ExUnit.Case, async: false

  alias Fleet.Workflow.Deliverable

  @moduletag :tmp_dir

  defp g(dir, args), do: System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)

  # Bare remote + workspace cloné, avec un commit base (identité engineer). Retourne {ws, bare, base}.
  defp setup_ws(tmp, name) do
    bare = Path.join(tmp, "#{name}.git")
    File.mkdir_p!(bare)
    {_, 0} = System.cmd("git", ["init", "--bare", "-b", "main", bare], stderr_to_stdout: true)

    ws = Path.join(tmp, "#{name}-ws")
    File.mkdir_p!(ws)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", ws], stderr_to_stdout: true)
    {_, 0} = g(ws, ["config", "user.email", "engineer@lcars.local"])
    {_, 0} = g(ws, ["config", "user.name", "LCARS-engineer"])
    {_, 0} = g(ws, ["remote", "add", "origin", bare])
    File.write!(Path.join(ws, "base.txt"), "base")
    {_, 0} = g(ws, ["add", "."])
    {_, 0} = g(ws, ["commit", "-q", "-m", "base"])
    {_, 0} = g(ws, ["push", "-q", "origin", "main"])
    {out, 0} = g(ws, ["rev-parse", "HEAD"])
    {ws, bare, String.trim(out)}
  end

  # Identité système-side du commit payload (D-04 : author=rôle, committer=système).
  defp payload_identity do
    %{
      author_name: "LCARS-engineer",
      author_email: "engineer@lcars.local",
      committer_name: "Fixture Committer",
      committer_email: "committer@fixture.test"
    }
  end

  defp payload_allowed, do: ["engineer@lcars.local", "committer@fixture.test"]

  describe "mode :payload" do
    test "écrit + commite (système) + gate OK + push sur la branche système-choisie (F-04)",
         %{tmp_dir: tmp} do
      {ws, bare, base} = setup_ws(tmp, "payload-ok")

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/engineer/m-42",
        files: [%{"path" => "src/blink.py", "content" => "def blink(): pass  # GPIO5\n"}],
        identity: payload_identity(),
        message: "feat: blink"
      }

      assert {:ok, %{commit_sha: <<_::binary-size(40)>> = sha, pushed?: true, mode: :payload}} =
               Deliverable.publish(opts)

      # F-04 : la ref poussée est celle choisie par le système, pas "main".
      {pushed, 0} = g(bare, ["rev-parse", "deliverables/engineer/m-42"])
      assert String.trim(pushed) == sha
      # base/main du remote n'a pas bougé.
      {main, 0} = g(bare, ["rev-parse", "main"])
      assert String.trim(main) == base

      # D-04 : author=rôle, committer=système.
      {who, 0} = g(ws, ["log", "-1", "--format=%ae|%ce"])
      assert String.trim(who) == "engineer@lcars.local|committer@fixture.test"
    end

    test "secret dans le payload → gate BLOQUE, AUCUN push", %{tmp_dir: tmp} do
      {ws, bare, base} = setup_ws(tmp, "payload-secret")
      {before, 0} = g(bare, ["rev-parse", "main"])

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/x",
        files: [%{"path" => "leak.txt", "content" => "TOKEN=sk-ant-api03-LEAKED123456\n"}],
        identity: payload_identity(),
        message: "oops"
      }

      assert {:error, {:secret_detected, "anthropic_key", _}} = Deliverable.publish(opts)

      # Le commit local a eu lieu (temps 1) mais le push N'A PAS eu lieu (temps 3 jamais atteint).
      {after_push, 0} = g(bare, ["rev-parse", "main"])
      assert before == after_push
      assert {_, 1} = g(bare, ["rev-parse", "--verify", "-q", "deliverables/x"])
    end

    test "payload sans fichiers → :no_files_in_payload", %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "payload-empty")

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/x",
        files: [],
        identity: payload_identity(),
        message: "nothing"
      }

      assert {:error, :no_files_in_payload} = Deliverable.publish(opts)
    end

    test "F-07 — hooks .git/hooks/ posés par le pod NE s'exécutent PAS côté monde (commit+push)",
         %{tmp_dir: tmp} do
      {ws, bare, base} = setup_ws(tmp, "payload-hooks")
      sentinel = Path.join(tmp, "pwned")
      hooks = Path.join([ws, ".git", "hooks"])
      File.mkdir_p!(hooks)
      # Le pod (adversaire) pose pre-commit ET pre-push qui exécuteraient du code côté monde.
      for h <- ["pre-commit", "pre-push"] do
        p = Path.join(hooks, h)
        File.write!(p, "#!/bin/sh\ntouch #{sentinel}\n")
        File.chmod!(p, 0o755)
      end

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/x",
        files: [%{"path" => "a.txt", "content" => "a\n"}],
        identity: payload_identity(),
        message: "feat: a"
      }

      assert {:ok, %{pushed?: true}} = Deliverable.publish(opts)
      # core.hooksPath=/dev/null sur les ops système-side → aucun hook exécuté.
      refute File.exists?(sentinel)
      # Le livrable est quand même bien poussé (le fix ne casse pas la publication).
      {_pushed, 0} = g(bare, ["rev-parse", "deliverables/x"])
    end

    test "path traversal dans le payload → BLOQUE avant écriture", %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "payload-traversal")

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/x",
        files: [%{"path" => "../escape.txt", "content" => "x"}],
        identity: payload_identity(),
        message: "evil"
      }

      assert {:error, {:path_traversal, "../escape.txt"}} = Deliverable.publish(opts)
    end

    test "WI-1 — payload `.gitattributes filter=` + filtre clean armé → REFUSÉ, le filtre NE tourne PAS",
         %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "payload-clean-filter")

      # Vecteur RCE : un filtre `clean` à commande arbitraire est armé dans `.git/config` du repo. Le
      # payload tente d'ajouter le `.gitattributes` qui MAPPE `*.txt` vers ce filtre. Si le livrable n'est
      # pas refusé, le `git add` système-side qui suit EXÉCUTE la commande du filtre côté monde (hors bwrap).
      sentinel = Path.join(tmp, "clean_filter_ran")
      File.rm(sentinel)

      {_, 0} =
        g(ws, ["config", "filter.pwn.clean", "sh -c 'touch #{sentinel}; cat'"])

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/x",
        files: [
          %{"path" => ".gitattributes", "content" => "*.txt filter=pwn\n"},
          %{"path" => "x.txt", "content" => "hello\n"}
        ],
        identity: payload_identity(),
        message: "evil filter"
      }

      # Étage CONTENU (load-bearing) : le `.gitattributes` armant `filter=` est refusé AVANT toute écriture.
      assert {:error, {:dangerous_gitattributes, ".gitattributes"}} = Deliverable.publish(opts)

      # Le filtre n'a JAMAIS tourné (aucun git add système-side n'a eu lieu).
      refute File.exists?(sentinel)
      # Rien n'a été écrit (validation 2-passes : tout valider avant tout write).
      refute File.exists?(Path.join(ws, ".gitattributes"))
      refute File.exists?(Path.join(ws, "x.txt"))
    end

    test "WI-1 — payload écrivant sous `.git/` (ex. `.git/config`) → REFUSÉ avant écriture",
         %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "payload-dotgit")

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/x",
        files: [
          %{
            "path" => ".git/config",
            "content" => "[filter \"pwn\"]\n\tclean = touch /tmp/pwned\n"
          }
        ],
        identity: payload_identity(),
        message: "evil config"
      }

      assert {:error, {:dotgit_path, ".git/config"}} = Deliverable.publish(opts)
    end

    test "WI-1 — un `.gitattributes` BÉNIN (sans filter=/diff=) reste autorisé",
         %{tmp_dir: tmp} do
      {ws, bare, base} = setup_ws(tmp, "payload-benign-attrs")

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/benign",
        # `text`/`eol` n'exécutent aucune commande externe → non bloqués (pas de faux positif).
        files: [%{"path" => ".gitattributes", "content" => "*.txt text eol=lf\n"}],
        identity: payload_identity(),
        message: "benign attrs"
      }

      assert {:ok, %{pushed?: true}} = Deliverable.publish(opts)
      {_pushed, 0} = g(bare, ["rev-parse", "deliverables/benign"])
    end

    test "F081 — symlink checké-in dans le workspace → BLOQUE (pas d'évasion via File.write)",
         %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "payload-symlink")
      # Vecteur : un repo cloné avec un symlink piège `out` -> hors workspace. Le check lexical
      # (Path.expand) passe ; File.write SUIVRAIT le lien → évasion. Doit être bloqué.
      escape = Path.join(tmp, "escape-target")
      File.mkdir_p!(escape)
      File.ln_s!(escape, Path.join(ws, "out"))

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/x",
        files: [%{"path" => "out/escape.txt", "content" => "x"}],
        identity: payload_identity(),
        message: "evil"
      }

      assert {:error, {:symlink_escape, "out/escape.txt"}} = Deliverable.publish(opts)
      refute File.exists?(Path.join(escape, "escape.txt"))
    end
  end

  describe "mode :git_native" do
    test "l'agent a commité → gate OK + push (système ne réécrit rien)", %{tmp_dir: tmp} do
      {ws, bare, base} = setup_ws(tmp, "native-ok")
      # Le pod commite lui-même (identité rôle, injectée immuable en vrai — ici simulée).
      File.write!(Path.join(ws, "feature.py"), "x = 1\n")
      {_, 0} = g(ws, ["add", "."])
      {_, 0} = g(ws, ["commit", "-q", "-m", "feat: agent work"])

      opts = %{
        mode: :git_native,
        workspace: ws,
        base_sha: base,
        allowed_emails: ["engineer@lcars.local"],
        remote: "origin",
        target_branch: "deliverables/engineer/native"
      }

      assert {:ok, %{pushed?: true, mode: :git_native, commit_sha: sha}} =
               Deliverable.publish(opts)

      {pushed, 0} = g(bare, ["rev-parse", "deliverables/engineer/native"])
      assert String.trim(pushed) == sha
    end

    test "aucun commit produit (HEAD == base) → :no_deliverable_commit", %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "native-empty")

      opts = %{
        mode: :git_native,
        workspace: ws,
        base_sha: base,
        allowed_emails: ["engineer@lcars.local"],
        remote: "origin",
        target_branch: "deliverables/x"
      }

      assert {:error, :no_deliverable_commit} = Deliverable.publish(opts)
    end

    test "identité usurpée par l'agent → gate BLOQUE, AUCUN push", %{tmp_dir: tmp} do
      {ws, bare, base} = setup_ws(tmp, "native-fraud")
      {before, 0} = g(bare, ["rev-parse", "main"])
      File.write!(Path.join(ws, "x.py"), "x = 1\n")
      {_, 0} = g(ws, ["add", "."])

      {_, 0} =
        g(ws, [
          "-c",
          "user.email=architect@lcars.local",
          "-c",
          "user.name=evil",
          "commit",
          "-q",
          "-m",
          "fraud"
        ])

      opts = %{
        mode: :git_native,
        workspace: ws,
        base_sha: base,
        allowed_emails: ["engineer@lcars.local"],
        remote: "origin",
        target_branch: "deliverables/x"
      }

      assert {:error, {:bad_identity, ["architect@lcars.local"]}} = Deliverable.publish(opts)
      {after_push, 0} = g(bare, ["rev-parse", "main"])
      assert before == after_push
    end
  end

  describe "validation" do
    test "mode inconnu → :invalid_mode", %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "bad-mode")

      assert {:error, {:invalid_mode, :wat}} =
               Deliverable.publish(%{
                 mode: :wat,
                 workspace: ws,
                 base_sha: base,
                 allowed_emails: []
               })
    end

    test "target_branch malformé (F-04 gardé) → :invalid_ref, aucune écriture", %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "bad-ref")

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "../evil",
        files: [%{"path" => "a.txt", "content" => "a\n"}],
        identity: payload_identity(),
        message: "x"
      }

      assert {:error, {:invalid_ref, "../evil"}} = Deliverable.publish(opts)
      # validation AVANT temps 1 : rien n'a été écrit/commité.
      {st, 0} = g(ws, ["status", "--porcelain"])
      assert String.trim(st) == ""
    end

    test "push? false → commit local, pas de push, target_branch facultatif", %{tmp_dir: tmp} do
      {ws, bare, base} = setup_ws(tmp, "no-push")
      {before, 0} = g(bare, ["rev-parse", "main"])

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        push?: false,
        files: [%{"path" => "a.txt", "content" => "a\n"}],
        identity: payload_identity(),
        message: "local only"
      }

      assert {:ok, %{pushed?: false, mode: :payload}} = Deliverable.publish(opts)
      {after_push, 0} = g(bare, ["rev-parse", "main"])
      assert before == after_push
    end
  end
end
