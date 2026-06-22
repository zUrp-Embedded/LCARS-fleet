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
end
