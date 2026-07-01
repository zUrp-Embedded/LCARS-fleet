defmodule Fleet.ProjectBootstrap.CloneTest do
  # Doc-mount (mundo invocado) : clone branche code (workspace) + branche doc (work/ops) dans le pod.
  # Fixture git RÉELLE (pas de mock) — repo source avec `main` + branche orpheline `work/ops`.
  use ExUnit.Case, async: false

  alias Fleet.ProjectBootstrap.Phase.Clone

  @moduletag :tmp_dir

  defp git(args, dir), do: System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)

  # Repo source : 1 commit sur `main` (src.txt) + branche ORPHELINE `work/ops` (BACKLOG.md).
  defp make_source_repo(dir) do
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", dir], stderr_to_stdout: true)
    {_, 0} = git(["config", "user.email", "t@lcars.local"], dir)
    {_, 0} = git(["config", "user.name", "test"], dir)
    File.write!(Path.join(dir, "src.txt"), "code-branch")
    {_, 0} = git(["add", "."], dir)
    {_, 0} = git(["commit", "-q", "-m", "code"], dir)

    {_, 0} = git(["checkout", "-q", "--orphan", "work/ops"], dir)
    {_, _} = git(["rm", "-rfq", "."], dir)
    File.write!(Path.join(dir, "BACKLOG.md"), "doc-branch")
    {_, 0} = git(["add", "."], dir)
    {_, 0} = git(["commit", "-q", "-m", "doc"], dir)
    {_, 0} = git(["checkout", "-q", "main"], dir)
    dir
  end

  defp cap(project) do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      spec: %{"project" => project},
      metadata: %{"name" => "engineer"}
    }
  end

  test "clone code (workspace) + doc (work) côte à côte", %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src"))
    pod_dir = Path.join(tmp, "pod-test-1")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main", "work_branch" => "work/ops"})

    # branche code → <pod_dir>/workspace
    assert {:ok, ws, feature} = Clone.clone_or_skip(pod_dir, profile, [])
    assert ws == Path.join(pod_dir, "workspace")
    assert File.exists?(Path.join(ws, "src.txt"))
    assert feature =~ "feature/"

    # branche doc → <pod_dir>/work
    assert {:ok, doc} = Clone.clone_work_doc(pod_dir, profile)
    assert doc == Path.join(pod_dir, "work")
    assert File.exists?(Path.join(doc, "BACKLOG.md"))
    refute File.exists?(Path.join(doc, "src.txt"))
  end

  test "idempotence : workspace résiduel (pod prédécesseur mort) → nettoyé + re-cloné, pas de clone_failed",
       %{tmp_dir: tmp} do
    # Régression live 2026-06-22 : un pod timeout/crash laisse son workspace ; le pod_id étant
    # DÉTERMINISTE, le re-dispatch retombe sur le même pod_dir → `git clone` refusait (dest non vide)
    # → wedge permanent du issue. Le fix nettoie le résidu avant de re-cloner.
    src = make_source_repo(Path.join(tmp, "src-idem"))
    pod_dir = Path.join(tmp, "pod-idem-1")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main"})

    # 1er clone OK (pod prédécesseur) + un résidu non committé qu'il aurait laissé en mourant.
    assert {:ok, ws, _} = Clone.clone_or_skip(pod_dir, profile, [])
    File.write!(Path.join(ws, "leftover.txt"), "junk d'un pod mort")

    # re-dispatch sur le MÊME pod_dir : sans rm_rf → {:error, {:clone_failed, _}} ; avec → re-clone propre.
    assert {:ok, ws2, feature2} = Clone.clone_or_skip(pod_dir, profile, [])
    assert ws2 == ws
    assert feature2 =~ "feature/"
    assert File.exists?(Path.join(ws2, "src.txt"))
    refute File.exists?(Path.join(ws2, "leftover.txt"))
  end

  test "#596 R1 — base_sha pinne HEAD sur le commit capturé (pas le tip remote)", %{tmp_dir: tmp} do
    src = Path.join(tmp, "src-pin")
    File.mkdir_p!(src)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", src], stderr_to_stdout: true)
    {_, 0} = git(["config", "user.email", "t@lcars.local"], src)
    {_, 0} = git(["config", "user.name", "test"], src)
    File.write!(Path.join(src, "a.txt"), "1")
    {_, 0} = git(["add", "."], src)
    {_, 0} = git(["commit", "-q", "-m", "c1"], src)
    {c1, 0} = git(["rev-parse", "HEAD"], src)
    c1 = String.trim(c1)

    # C2 = tip courant ; le rail (ls-remote hors-pod) qui a capturé la base AVANT C2 a épinglé C1.
    File.write!(Path.join(src, "b.txt"), "2")
    {_, 0} = git(["add", "."], src)
    {_, 0} = git(["commit", "-q", "-m", "c2"], src)

    pod_dir = Path.join(tmp, "pod-pin-1")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main", "base_sha" => c1})

    assert {:ok, ws, feature} = Clone.clone_or_skip(pod_dir, profile, [])
    {head, 0} = git(["rev-parse", "HEAD"], ws)

    # HEAD du pod COMMENCE garanti à C1 (épinglé), pas au tip C2 → base..HEAD = uniquement ses commits.
    assert String.trim(head) == c1
    assert feature =~ "feature/"
    assert File.exists?(Path.join(ws, "a.txt"))
    refute File.exists?(Path.join(ws, "b.txt"))
  end

  test "work_branch nil → skip (projet sans branche doc)", %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src2"))
    pod_dir = Path.join(tmp, "pod-test-2")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main"})

    assert {:ok, nil} = Clone.clone_work_doc(pod_dir, profile)
    refute File.exists?(Path.join(pod_dir, "work"))
  end

  test "work_branch déclarée mais absente → fail-loud (I-CBC)", %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src3"))
    pod_dir = Path.join(tmp, "pod-test-3")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main", "work_branch" => "work/nope"})

    assert {:error, {:work_doc_clone_failed, {"work/nope", _code, _out}}} =
             Clone.clone_work_doc(pod_dir, profile)
  end

  # MA-22/F-BOOT-FM-03 — parité `rm_rf` : un `work/` résiduel (pod prédécesseur mort) ne doit pas
  # wedger le re-dispatch sur « destination already exists ».
  test "clone_work_doc idempotent : work/ résiduel → nettoyé + re-cloné", %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src-doc-idem"))
    pod_dir = Path.join(tmp, "pod-doc-idem")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main", "work_branch" => "work/ops"})

    assert {:ok, doc} = Clone.clone_work_doc(pod_dir, profile)
    File.write!(Path.join(doc, "stale.txt"), "résidu d'un pod doc mort")

    # re-dispatch sur le MÊME pod_dir : sans rm_rf → clone refuse (dest non vide) ; avec → re-clone propre.
    assert {:ok, ^doc} = Clone.clone_work_doc(pod_dir, profile)
    assert File.exists?(Path.join(doc, "BACKLOG.md"))
    refute File.exists?(Path.join(doc, "stale.txt"))
  end

  # ============================================================
  # MOVE-1/MA-22 — le clone est BORNÉ par construction : un git qui PEND est tué dans la deadline,
  # le pod ne reste PAS zombie (l'appelant reçoit une erreur typée au lieu de figer pour toujours).
  # ============================================================
  test "clone qui pend (serveur git muet) → tué dans le timeout, erreur typée (pas de hang)",
       %{tmp_dir: tmp} do
    # Faux serveur git : un socket TCP qui ACCEPTE la connexion mais ne répond JAMAIS. `git clone
    # git://127.0.0.1:PORT/x` se connecte, envoie sa requête, et attend une réponse qui ne vient pas →
    # hang. Sans la borne, `clone_or_skip` figerait le process appelant (en prod : le Pod GenServer →
    # pod zombie). Avec la borne (`:git_timeout_ms`), git est tué et on rend `{:clone_failed,
    # {:git_timeout, ms}}` RAPIDEMENT.
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    # Un acceptor qui accepte puis dort : la connexion s'établit mais reste muette.
    acceptor =
      spawn(fn ->
        case :gen_tcp.accept(listen, 10_000) do
          {:ok, sock} -> Process.sleep(:infinity) && sock
          _ -> :ok
        end
      end)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end)

    pod_dir = Path.join(tmp, "pod-hang")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => "git://127.0.0.1:#{port}/x", "base_branch" => "main"})

    t0 = System.monotonic_time(:millisecond)
    result = Clone.clone_or_skip(pod_dir, profile, git_timeout_ms: 400)
    elapsed = System.monotonic_time(:millisecond) - t0

    # Erreur TYPÉE (le wrapper a coupé), pas un succès silencieux ni un crash non géré.
    assert {:error, {:clone_failed, {:git_timeout, 400}}} = result

    # On a rendu en ~400ms + marge, PAS attendu indéfiniment → la borne a bien tué le git pendant.
    assert elapsed < 5_000, "le clone a pendu #{elapsed}ms — la borne n'a pas coupé"
  end

  # O5 (Brick 5) — test `set_git_identity` RETIRÉ avec la fonction. L'identité git du pod n'est plus
  # posée par un `git config` mutable dans le workspace (falsifiable F-01) mais injectée en env au
  # lancement (bwrap_launch.sh) ; l'enforcement F-01 est la gate `DeliverableGate` au push (couverte
  # par deliverable_gate_test.exs + executor_post_extract_test.exs cas git_native usurpation).

  # ============================================================
  # SLOT-FREEZE — reset_in_place : reset COLD du workspace d'un pipe RESIDENT pour le issue suivant,
  # SANS rm_rf (le ws est bind-monte dans le sandbox bwrap vivant — rm_rf casserait le mount).
  # ============================================================
  test "reset_in_place — commit + untracked du issue precedent wipes, retour base_sha sur feature/work, .git PRESERVE (pas de rm_rf)",
       %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src-reset"))
    {base, 0} = git(["rev-parse", "HEAD"], src)
    base = String.trim(base)
    pod_dir = Path.join(tmp, "pod-reset")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main", "base_sha" => base})

    # SPAWN : clone -> workspace sur feature/work @ base.
    assert {:ok, ws, "feature/work"} = Clone.clone_or_skip(pod_dir, profile, [])

    # Sentinelle DANS .git : un rm_rf+reclone l'effacerait ; un reset IN-PLACE la preserve.
    sentinel = Path.join(ws, ".git/SENTINEL_INPLACE")
    File.write!(sentinel, "x")

    # L'ENG bosse le issue precedent : un COMMIT (woody) + un fichier UNTRACKED (buzz = le bug de
    # stacking, du travail non committe qui trainait).
    {_, 0} = git(["config", "user.email", "e@lcars.local"], ws)
    {_, 0} = git(["config", "user.name", "eng"], ws)
    File.write!(Path.join(ws, "woody.sh"), "echo woody")
    {_, 0} = git(["add", "."], ws)
    {_, 0} = git(["commit", "-q", "-m", "issue precedent"], ws)
    File.write!(Path.join(ws, "buzz.sh"), "echo buzz")

    # RESET in-place pour le issue suivant (meme base_sha) : retourne le MEME ws.
    assert {:ok, ^ws, "feature/work"} = Clone.reset_in_place(pod_dir, profile, [])

    # 1. retour a base_sha (le commit "issue precedent" est parti).
    {head, 0} = git(["rev-parse", "HEAD"], ws)
    assert String.trim(head) == base
    # 2. le committe ET l'untracked sont nettoyes (plus de stacking possible).
    refute File.exists?(Path.join(ws, "woody.sh"))
    refute File.exists?(Path.join(ws, "buzz.sh"))
    # 3. sur feature/work, propre.
    {branch, 0} = git(["rev-parse", "--abbrev-ref", "HEAD"], ws)
    assert String.trim(branch) == "feature/work"
    {status, 0} = git(["status", "--porcelain"], ws)
    assert String.trim(status) == ""

    # 4. IN-PLACE : la sentinelle .git a SURVECU -> pas de rm_rf (le bind mount serait preserve en vrai).
    assert File.exists?(sentinel)
  end

  test "reset_in_place — base_sha absent → fail-loud {:reset_failed, :no_base_sha} (pas de reset aveugle)",
       %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src-nobase"))
    pod_dir = Path.join(tmp, "pod-nobase")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main"})

    assert {:ok, _ws, _} = Clone.clone_or_skip(pod_dir, profile, [])

    # Sans base_sha le dispatcher n'a rien epingle = bug appelant -> on refuse plutot que reset a l'aveugle.
    assert {:error, {:reset_failed, :no_base_sha}} = Clone.reset_in_place(pod_dir, profile, [])
  end
end
