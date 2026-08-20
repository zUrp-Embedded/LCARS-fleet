defmodule Fleet.Project.ProbePredicateTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  @moduledoc """
  LE PRÉDICAT, JOUÉ POUR DE VRAI — sur le fichier que le template LIVRE.

  ## Pourquoi ces tests existent, et pourquoi ils ne sont pas des tests de YAML

  Doctrine : *chaque mur PROUVE qu'il mord.* Un prédicat qui n'a jamais rejeté ne prouve rien, et
  celui-ci vit dans un script shell embarqué dans un workflow — l'endroit du dépôt le plus facile à
  déclarer correct sans l'avoir jamais exécuté.

  Alors on l'exécute. Le script est EXTRAIT du `probe-test-relevance.yml` livré (jamais recopié :
  une copie testerait la copie), ses `${{ inputs.… }}` sont substitués, et il tourne sous `sh` sur
  de vrais dépôts git fabriqués ici.

  ## Les trois fixtures, et la deuxième est celle qui compte

  1. **Une suite qui prouve** — elle devient rouge quand on retire le code : `relevant`.
  2. **LE FAUX-VERT** — la suite appelle bien le livrable, mais jette son résultat
     (`cmd >/dev/null`), donc elle reste verte sans lui : `blind`. C'est la matière du ticket #33,
     absente du dépôt jusqu'ici : sans elle, rien ne prouvait que ce prédicat sait dire non.
  3. **Une suite déjà rouge sur la tête** — rien n'est concluable : `inapplicable`. Le témoin, sans
     lequel le rouge de la fixture 1 pourrait être un rouge de panne.
  """

  @workflow "priv/catalogue/project_template/main/.gitea/workflows/probe-test-relevance.yml"

  # ── Extraction du script LIVRÉ ────────────────────────────────────────────────────────────────

  # On prend le bloc `run: |` de l'étape « Sonder » dans le fichier réel. Un YAML complet serait
  # plus élégant et moins honnête : ce qui doit être mesuré, c'est le texte que le runner recevra.
  defp probe_script do
    yaml = File.read!(Path.join(File.cwd!(), @workflow))

    [_, block] =
      Regex.run(~r/- name: Sonder\n\s+run: \|\n(.*?)(?=\n\s{6}- name: |\z)/s, yaml)

    block
    |> String.split("\n")
    |> Enum.map(&String.replace_prefix(&1, "          ", ""))
    |> Enum.join("\n")
  end

  defp render(script, inputs) do
    Enum.reduce(inputs, script, fn {k, v}, acc ->
      String.replace(acc, "${{ inputs.#{k} }}", v)
    end)
  end

  # ── Fabrication d'un dépôt à deux états ───────────────────────────────────────────────────────

  defp git!(dir, args) do
    {out, code} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    assert code == 0, "git #{Enum.join(args, " ")} → #{out}"
    String.trim(out)
  end

  # BASE = un dépôt sans le livrable, mais AVEC un harnais. HEAD = le livrable ajouté, harnais
  # éventuellement modifié. C'est exactement la forme d'une PR de livraison.
  defp build_repo(tmp, base_files, head_files) do
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@t"])
    git!(repo, ["config", "user.name", "t"])

    write_all(repo, base_files)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-qm", "base"])
    base = git!(repo, ["rev-parse", "HEAD"])

    write_all(repo, head_files)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-qm", "head"])
    head = git!(repo, ["rev-parse", "HEAD"])

    %{dir: repo, base: base, head: head}
  end

  defp write_all(repo, files) do
    Enum.each(files, fn {path, content} ->
      full = Path.join(repo, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
      File.chmod!(full, 0o755)
    end)
  end

  defp sonde(tmp, %{dir: dir, base: base, head: head}, harness, test_cmd) do
    script =
      probe_script()
      |> render(%{
        "harness" => harness,
        "base_sha" => base,
        "head_sha" => head,
        "test_cmd" => test_cmd
      })

    path = Path.join(tmp, "sonde.sh")
    File.write!(path, script)

    # `cwd: tmp` : le script fait `cd repo` lui-même, comme dans le job.
    {out, code} = System.cmd("sh", [path], cd: Path.dirname(dir), stderr_to_stdout: true)
    %{out: out, code: code, facts: Fleet.MCP.PodTools.Probe.facts(out)}
  end

  # ── Les fixtures ──────────────────────────────────────────────────────────────────────────────

  # Une suite HONNÊTE : elle exécute le livrable et compare sa sortie.
  @honest_test """
  #!/bin/sh
  out=$(sh ./hello.sh 2>/dev/null) || exit 1
  [ "$out" = "bonjour" ] || exit 1
  exit 0
  """

  # ⚠ LE FAUX-VERT, ET C'EST LA MATIÈRE DU TICKET #33. La suite APPELLE bien le livrable — un
  # lecteur pressé voit un test qui « couvre » `hello.sh` — mais elle jette sa sortie ET son code
  # de retour. Elle passe donc à l'identique que le livrable existe, soit cassé, soit absent.
  @false_green """
  #!/bin/sh
  sh ./hello.sh >/dev/null 2>&1
  exit 0
  """

  @deliverable "#!/bin/sh\necho bonjour\n"

  describe "le prédicat, exécuté sur le workflow livré" do
    test "une suite qui PROUVE le livrable → verdict=relevant", %{tmp_dir: tmp} do
      repo =
        build_repo(
          tmp,
          %{"tests/run.sh" => @honest_test},
          %{"tests/run.sh" => @honest_test, "hello.sh" => @deliverable}
        )

      r = sonde(tmp, repo, "tests/", "sh tests/run.sh")

      assert r.facts["witness_exit"] == "0", "le témoin devait être vert : #{r.out}"
      assert r.facts["reverted_exit"] == "1"
      assert r.facts["verdict"] == "relevant"
      assert r.code == 0, "la sonde doit TOUJOURS sortir en 0 : #{r.out}"
    end

    test "LE FAUX-VERT : une suite qui jette son résultat → verdict=blind", %{tmp_dir: tmp} do
      # ⚠ LE TEST QUI DONNE SA VALEUR À TOUS LES AUTRES. Sans lui, ce prédicat n'a jamais dit non,
      # et un prédicat qui n'a jamais rejeté ne prouve rien — il pourrait rendre `relevant` par
      # construction sans que personne ne s'en aperçoive.
      repo =
        build_repo(
          tmp,
          %{"tests/run.sh" => @false_green},
          %{"tests/run.sh" => @false_green, "hello.sh" => @deliverable}
        )

      r = sonde(tmp, repo, "tests/", "sh tests/run.sh")

      assert r.facts["witness_exit"] == "0"
      # Le code de base n'a pas `hello.sh`, la suite tourne quand même et reste VERTE.
      assert r.facts["reverted_exit"] == "0"
      assert r.facts["verdict"] == "blind"
      assert r.code == 0
    end

    test "TÉMOIN : une suite déjà rouge sur la tête → inapplicable, pas relevant", %{tmp_dir: tmp} do
      # Sans ce chemin, le rouge de la fixture 1 serait ambigu : on ne saurait pas si la suite a
      # détecté l'absence du code ou si elle était cassée depuis le début.
      broken = "#!/bin/sh\nexit 3\n"

      repo =
        build_repo(
          tmp,
          %{"tests/run.sh" => broken},
          %{"tests/run.sh" => broken, "hello.sh" => @deliverable}
        )

      r = sonde(tmp, repo, "tests/", "sh tests/run.sh")

      assert r.facts["witness_exit"] == "3"
      assert r.facts["verdict"] == "inapplicable"
      assert r.facts["reason"] == "head-suite-red"
      refute r.facts["verdict"] == "relevant"
      assert r.code == 0
    end

    test "aucun harnais déclaré → inapplicable, et la sonde ne devine PAS", %{tmp_dir: tmp} do
      repo =
        build_repo(
          tmp,
          %{"tests/run.sh" => @honest_test},
          %{"tests/run.sh" => @honest_test, "hello.sh" => @deliverable}
        )

      r = sonde(tmp, repo, "", "sh tests/run.sh")

      assert r.facts["verdict"] == "inapplicable"
      assert r.facts["reason"] == "no-harness-declared"

      # Elle n'a même pas essayé : deviner quels fichiers sont de la preuve reviendrait à accuser
      # une livraison à tort.
      refute Map.has_key?(r.facts, "witness_exit")
    end

    test "un chemin déclaré ABSENT de la tête est dit, pas contourné", %{tmp_dir: tmp} do
      repo =
        build_repo(
          tmp,
          %{"tests/run.sh" => @honest_test},
          %{"tests/run.sh" => @honest_test, "hello.sh" => @deliverable}
        )

      r = sonde(tmp, repo, "tests/ spec/", "sh tests/run.sh")

      assert r.facts["verdict"] == "inapplicable"
      assert r.facts["reason"] == "harness-absent"
      assert r.facts["paths"] =~ "spec/"
    end
  end
end
