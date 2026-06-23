defmodule Fleet.Pipeline.DeliverableGateTest do
  # Gate I-CBC du livrable (O5). Fixture git RÉELLE. Chaque finding consultant (F-01/F-02/F-03) doit
  # être MÉCANIQUEMENT bloqué : un livrable invalide est irreprésentable au push.
  use ExUnit.Case, async: false

  alias Fleet.Pipeline.DeliverableGate, as: Gate

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

    # un ticket PARALLÈLE a fusionné → `main` avance (C1). Fichier DIFFÉRENT : la gate ne vérifie QUE
    # l'ascendance + l'identité + les secrets ; la RÉSOLUTION du conflit de contenu est le boulot du pod.
    {_, 0} = g(dir, ["checkout", "-q", "main"])
    commit_file(dir, "parallel.md", "# autre ticket", "feat: ticket parallèle")
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
