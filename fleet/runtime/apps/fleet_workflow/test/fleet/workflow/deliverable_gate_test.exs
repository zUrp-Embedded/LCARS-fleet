defmodule Fleet.Workflow.DeliverableGateTest do
  # Gate I-CBC du livrable (O5). Fixture git RÉELLE. Chaque finding consultant (F-01/F-02/F-03) doit
  # être MÉCANIQUEMENT bloqué : un livrable invalide est irreprésentable au push.
  use ExUnit.Case, async: false

  alias Fleet.Workflow.DeliverableGate, as: Gate

  @moduletag :tmp_dir

  @role_emails ["engineer@lcars.local"]

  defp g(dir, args), do: System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)

  # Repo avec un commit `base` (identité engineer) + un commit code propre. Retourne {dir, base_sha}.
  defp setup_repo(dir) do
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", dir], stderr_to_stdout: true)
    {_, 0} = g(dir, ["config", "user.email", "engineer@lcars.local"])
    {_, 0} = g(dir, ["config", "user.name", "LCARS-engineer"])
    File.write!(Path.join(dir, "base.txt"), "base")
    {_, 0} = g(dir, ["add", "."])
    {_, 0} = g(dir, ["commit", "-q", "-m", "base"])
    {out, 0} = g(dir, ["rev-parse", "HEAD"])
    {dir, String.trim(out)}
  end

  defp commit_file(dir, name, content, msg) do
    File.write!(Path.join(dir, name), content)
    {_, 0} = g(dir, ["add", "."])
    {_, 0} = g(dir, ["commit", "-q", "-m", msg])
  end

  test "commit propre (identité rôle, zéro secret) → verify OK", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "clean"))
    commit_file(dir, "feature.py", "def blink(): pass  # GPIO5", "feat: blink")

    assert {:ok, :verified} = Gate.verify(dir, base, @role_emails)
  end

  test "F-02 — token OAuth (JWT) dans le diff → scan_secrets BLOQUE", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "leak-jwt"))
    # ce que ferait `env > t.txt && git add` : un JWT dans un fichier
    commit_file(dir, "t.txt", "TOKEN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload-stuff", "oops")

    assert {:error, {:secret_detected, "jwt_token", _}} = Gate.scan_secrets(dir, base)
    assert {:error, {:secret_detected, _, _}} = Gate.verify(dir, base, @role_emails)
  end

  test "F-02 — clé sk-ant- dans le diff → BLOQUE", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "leak-skant"))
    commit_file(dir, "cfg.txt", "key = sk-ant-api03-AbCdEf12345678", "cfg")

    assert {:error, {:secret_detected, "anthropic_key", _}} = Gate.scan_secrets(dir, base)
  end

  test "F-02 — fichier blacklist (.credentials.json) → BLOQUE par nom", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "leak-file"))
    commit_file(dir, ".credentials.json", "{}", "creds")

    assert {:error, {:secret_detected, "blacklisted_file", ".credentials.json"}} =
             Gate.scan_secrets(dir, base)
  end

  test "F-01 — commit avec identité usurpée → check_identity BLOQUE", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "fraud-id"))
    File.write!(Path.join(dir, "x.py"), "x = 1")
    {_, 0} = g(dir, ["add", "."])
    # le pod commite en se faisant passer pour un autre rôle / un humain
    {_, 0} =
      g(dir, [
        "-c",
        "user.email=architect@lcars.local",
        "-c",
        "user.name=evil",
        "commit",
        "-q",
        "-m",
        "fraud"
      ])

    assert {:error, {:bad_identity, ["architect@lcars.local"]}} =
             Gate.check_identity(dir, base, @role_emails)
  end

  test "F-03 — réécriture d'historique (base plus ancêtre) → check_base_ancestor BLOQUE",
       %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "rewrite"))
    # le pod réécrit le commit racine → nouveau SHA, base original non-atteignable depuis HEAD
    {_, 0} = g(dir, ["commit", "--amend", "-q", "-m", "rewritten-root", "--allow-empty"])

    assert {:error, {:base_not_ancestor, _}} = Gate.check_base_ancestor(dir, base)
  end

  test "F-03 / F-PARALLEL — message base_not_ancestor embarque le base_sha (diagnostique, plus de tuple muet)",
       %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "diag"))
    {_, 0} = g(dir, ["commit", "--amend", "-q", "-m", "rewritten", "--allow-empty"])

    assert {:error, {:base_not_ancestor, msg}} = Gate.check_base_ancestor(dir, base)

    # le live `{:base_not_ancestor, ""}` (sortie merge-base vide) a coûté une traque entière : le message
    # DOIT maintenant nommer la base fautive (12 hex) → la cause saute aux yeux dans un seul log.
    assert msg =~ String.slice(base, 0, 12)
  end

  test "F-PARALLEL — résolution par rebase : la gate ACCEPTE avec base=main, REJETTE avec base=feature_tip (déconflation clone/gate)",
       %{tmp_dir: tmp} do
    {dir, _c0} = setup_repo(Path.join(tmp, "rebase-resolve"))
    # le PRODUCTEUR a livré sur sa feature-branch (depuis C0).
    {_, 0} = g(dir, ["checkout", "-q", "-b", "feature"])
    commit_file(dir, "feature.py", "def blink(): pass  # GPIO5", "feat: blink")
    {ft, 0} = g(dir, ["rev-parse", "HEAD"])
    feature_tip = String.trim(ft)

    # un issue PARALLÈLE a fusionné → `main` avance (C1). Fichier DIFFÉRENT : la gate ne vérifie QUE
    # l'ascendance + l'identité + les secrets ; la RÉSOLUTION du conflit de contenu est le boulot du pod.
    {_, 0} = g(dir, ["checkout", "-q", "main"])
    commit_file(dir, "parallel.md", "# autre issue", "feat: issue parallèle")
    {m1, 0} = g(dir, ["rev-parse", "HEAD"])
    main_c1 = String.trim(m1)

    # l'eng de RÉSOLUTION rebase sa feature sur `main` (C1) → HEAD = feat REJOUÉ sur C1 (SHA neuf).
    {_, 0} = g(dir, ["checkout", "-q", "feature"])
    {_, 0} = g(dir, ["rebase", "-q", "main"])

    # LE BUG (clone-base) : `base_branch=head` pinnait base_sha sur l'ANCIEN tip de feature, que le rebase
    # a réécrit → plus ancêtre de HEAD → `base_not_ancestor` (live PR#4, publish jamais atteint).
    assert {:error, {:base_not_ancestor, msg}} = Gate.check_base_ancestor(dir, feature_tip)
    assert msg =~ String.slice(feature_tip, 0, 12)

    # LE FIX (gate_base_sha = main, cible du rebase) : HEAD descend de `main` → la gate ACCEPTE, et la
    # vérif COMPLÈTE passe (le commit feat rejoué porte l'identité engineer, zéro secret → publish + push).
    assert :ok = Gate.check_base_ancestor(dir, main_c1)
    assert {:ok, :verified} = Gate.verify(dir, main_c1, @role_emails)
  end

  test "range vide (aucun nouveau commit) → identité OK (vacuité), scan OK", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "empty"))
    # base == HEAD, aucun commit depuis
    assert :ok = Gate.check_identity(dir, base, @role_emails)
    assert :ok = Gate.scan_secrets(dir, base)
    assert :ok = Gate.check_base_ancestor(dir, base)
  end

  # ============================================================
  # MA-09 — F-01 contournée par email VIDE (anti-régression du piège %x00)
  # ============================================================

  test "MA-09 — commit à email auteur/committer VIDE → check_identity REJETTE {:bad_identity}",
       %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "blank-email"))
    File.write!(Path.join(dir, "x.py"), "x = 1")
    {_, 0} = g(dir, ["add", "."])

    # le pod commite avec author ET committer email VIDES (`env -i` / `user.email=""`) → AVANT MA-09, le
    # split `trim: true` droppait les lignes vides → l'email vide n'était jamais comparé → gate `:ok`.
    {_, 0} =
      g(dir, [
        "-c",
        "user.email=",
        "-c",
        "user.name=ghost",
        "commit",
        "-q",
        "-m",
        "blank identity"
      ])

    assert {:error, {:bad_identity, bad}} = Gate.check_identity(dir, base, @role_emails)
    assert "<empty-email>" in bad
    # la vérif COMPLÈTE bloque aussi (le push n'a pas lieu).
    assert {:error, {:bad_identity, _}} = Gate.verify(dir, base, @role_emails)
  end

  test "MA-09 (anti-régression %x00) — un livrable PROPRE multi-commit passe TOUJOURS", %{
    tmp_dir: tmp
  } do
    {dir, base} = setup_repo(Path.join(tmp, "clean-multi"))
    commit_file(dir, "a.py", "a = 1", "feat: a")
    commit_file(dir, "b.py", "b = 2", "feat: b")
    commit_file(dir, "c.py", "c = 3", "feat: c")

    # AUCUN faux positif terminal `[""]` : tous les emails sont engineer@lcars.local → :ok.
    assert :ok = Gate.check_identity(dir, base, @role_emails)
    assert {:ok, :verified} = Gate.verify(dir, base, @role_emails)
  end

  # ============================================================
  # MA-10 — scan secret PAR-COMMIT (introduce-then-remove)
  # ============================================================

  test "MA-10 — secret INTRODUIT puis RETIRÉ dans la chaîne → scan_secrets BLOQUE (par-commit)",
       %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "introduce-remove"))

    # C1 : introduit un JWT dans un fichier.
    commit_file(
      dir,
      "leak.txt",
      "TOKEN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload-stuff",
      "wip"
    )

    # C2 : retire le fichier → le diff NET base..HEAD est VIDE (aucune trace), mais le PUSH transfère C1.
    File.rm!(Path.join(dir, "leak.txt"))
    {_, 0} = g(dir, ["add", "-A"])
    {_, 0} = g(dir, ["commit", "-q", "-m", "cleanup"])

    # Sanity : le diff NET ne voit RIEN (c'est précisément le trou MA-10).
    {net_diff, 0} = g(dir, ["diff", "#{base}..HEAD"])
    assert net_diff == "" or not (net_diff =~ "eyJ")

    # Le scan PAR-COMMIT, lui, voit le secret dans C1.
    assert {:error, {:secret_detected, "jwt_token", _}} = Gate.scan_secrets(dir, base)
  end

  test "MA-10 — fichier secret par NOM introduit puis retiré → BLOQUE par-commit", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "introduce-remove-file"))
    commit_file(dir, ".env", "SECRET=1", "wip env")
    File.rm!(Path.join(dir, ".env"))
    {_, 0} = g(dir, ["add", "-A"])
    {_, 0} = g(dir, ["commit", "-q", "-m", "remove env"])

    assert {:error, {:secret_detected, "blacklisted_file", ".env"}} = Gate.scan_secrets(dir, base)
  end

  # ============================================================
  # F-02 evil-merge — secret/fichier dans l'ARBRE RÉSOLU d'un merge (absent des deux parents)
  # ============================================================

  # Construit un evil-merge : base → (feature: feat.txt) et (main: mainwork.txt) → merge no-ff dont
  # l'ARBRE résolu contient `extra_files` (présents dans NI l'un NI l'autre parent ; base reste ancêtre ;
  # auteur = identité engineer légitime). Retourne {dir, base_sha}.
  defp setup_evil_merge(dir, extra_files) do
    {dir, base} = setup_repo(dir)
    {_, 0} = g(dir, ["checkout", "-q", "-b", "feature"])
    commit_file(dir, "feat.txt", "feat", "feat")
    {_, 0} = g(dir, ["checkout", "-q", "main"])
    commit_file(dir, "mainwork.txt", "mainwork", "mainwork")
    {_, 0} = g(dir, ["checkout", "-q", "feature"])
    # merge no-ff de main dans feature (le HEAD livré est ce merge).
    {_, 0} = g(dir, ["merge", "-q", "--no-ff", "-m", "merge main into feature", "main"])

    # EVIL : on injecte dans l'arbre du merge des fichiers absents des DEUX parents, en amendant le
    # commit de merge (il garde ses deux parents → reste un merge ; auteur engineer inchangé).
    Enum.each(extra_files, fn {name, content} ->
      File.write!(Path.join(dir, name), content)
    end)

    {_, 0} = g(dir, ["add", "-A"])
    {_, 0} = g(dir, ["commit", "-q", "--amend", "--no-edit"])
    {dir, base}
  end

  test "F-02 evil-merge — secret dans l'arbre résolu du merge (NI parent) → scan_secrets BLOQUE",
       %{tmp_dir: tmp} do
    # Distinct de MA-10 (chaîne LINÉAIRE, chaque commit a son diff). Ici le secret n'apparaît dans le
    # diff d'AUCUN parent : il n'existe QUE dans l'arbre résolu du commit de MERGE. AVANT le fix
    # `--diff-merges=first-parent`, `git log -p` n'émet aucun diff pour un merge → le scan ne voyait
    # rien → le secret passait et était poussé. APRÈS, le delta du merge vs son 1er parent est scanné.
    {dir, base} =
      setup_evil_merge(Path.join(tmp, "evil-merge-secret"), [
        {"f.txt", "key = sk-ant-api03-EvilMergeTree123"}
      ])

    # Sanity : f.txt n'existe dans AUCUN des deux parents du merge (le secret est UNIQUEMENT dans
    # l'arbre résolu) → `git show HEAD^N:f.txt` échoue (rc 128, chemin inconnu du parent). C'est
    # précisément ce qui rend `git log -p` aveugle sans `--diff-merges`.
    {_p1, rc1} = g(dir, ["show", "HEAD^1:f.txt"])
    {_p2, rc2} = g(dir, ["show", "HEAD^2:f.txt"])
    assert rc1 != 0, "f.txt ne devrait PAS exister dans le 1er parent"
    assert rc2 != 0, "f.txt ne devrait PAS exister dans le 2e parent"

    assert {:error, {:secret_detected, "anthropic_key", _}} = Gate.scan_secrets(dir, base)
    assert {:error, {:secret_detected, _, _}} = Gate.verify(dir, base, @role_emails)
  end

  test "F-02 evil-merge — fichier blacklisté (id_rsa) dans l'arbre résolu → BLOQUE par nom",
       %{tmp_dir: tmp} do
    {dir, base} =
      setup_evil_merge(Path.join(tmp, "evil-merge-file"), [{"id_rsa", "-----PRIV-----"}])

    assert {:error, {:secret_detected, "blacklisted_file", "id_rsa"}} =
             Gate.scan_secrets(dir, base)
  end

  test "evil-merge PROPRE (arbre résolu sans secret) → verify OK (pas de faux positif sur les merges)",
       %{tmp_dir: tmp} do
    # `--diff-merges=first-parent` ne doit pas faire échouer un merge LÉGITIME : un merge dont l'arbre
    # résolu ne contient ni secret ni fichier interdit, identité engineer, base ancêtre → :ok.
    {dir, base} =
      setup_evil_merge(Path.join(tmp, "clean-merge"), [{"notes.txt", "résumé du merge propre"}])

    assert {:ok, :verified} = Gate.verify(dir, base, @role_emails)
  end

  # ============================================================
  # MA-24 — check_base_ancestor : rc TYPÉ (rc1 pas ancêtre / rc128 git_error / rc124 timeout)
  # ============================================================

  test "MA-24 — base_sha BIDON (rc128) → {:git_error}, PAS {:base_not_ancestor}", %{tmp_dir: tmp} do
    {dir, _base} = setup_repo(Path.join(tmp, "bogus-base"))
    commit_file(dir, "f.py", "x = 1", "feat")

    # un sha qui n'existe pas → `merge-base --is-ancestor` rc128 (objet invalide), PAS rc1.
    bogus = "0000000000000000000000000000000000000000"
    assert {:error, {:git_error, _}} = Gate.check_base_ancestor(dir, bogus)
  end

  test "MA-24 — vraie base pas-ancêtre (rc1) reste {:base_not_ancestor}", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "real-not-ancestor"))
    {_, 0} = g(dir, ["commit", "--amend", "-q", "-m", "rewritten", "--allow-empty"])

    assert {:error, {:base_not_ancestor, msg}} = Gate.check_base_ancestor(dir, base)
    assert msg =~ String.slice(base, 0, 12)
  end
end
