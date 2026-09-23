defmodule Fleet.Project.ProbePredicateTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  @moduledoc """
  Execute sous sh le bloc Sonder extrait du workflow livre, sur des depots Git locaux.
  Couvre une suite sensible au code retire, une suite qui ignore son resultat et
  un temoin deja rouge, ainsi que les commandes/pathspecs et l'environnement du test.
  Ce harnais ne reproduit pas un runner distant, son authentification HTTP ou son isolation.
  """

  @workflow "priv/catalogue/project_template/main/.gitea/workflows/probe-test-relevance.yml"

  # ── Extraction du script LIVRÉ ────────────────────────────────────────────────────────────────

  # Extraction textuelle du bloc Sonder : depend de cette structure YAML, sans parser complet.
  defp probe_script do
    yaml = File.read!(Path.join(File.cwd!(), @workflow))

    [_, block] =
      Regex.run(
        ~r/- name: Sonder\n(?:\s+env:\n(?:\s+\S+:.*\n)+)?\s+run: \|\n(.*?)(?=\n[ ]{2,}- name: |\z)/s,
        yaml
      )

    # Mesurer le retrait pour que la reindentation du YAML ne laisse pas dix espaces en dur.
    lines = String.split(block, "\n")

    indent =
      lines
      |> Enum.find("", &(String.trim(&1) != ""))
      |> then(&(String.length(&1) - String.length(String.trim_leading(&1))))

    prefix = String.duplicate(" ", indent)

    assert indent > 0, "aucun retrait mesuré : l'extraction ne rend pas le script du runner"

    Enum.map_join(lines, "\n", &String.replace_prefix(&1, prefix, ""))
  end

  # The runner hands the inputs over through the step's `env:` (PROBE_*), never inside the script.
  defp input_env(inputs) do
    [
      {"PROBE_HARNESS", inputs["harness"]},
      {"PROBE_BASE", inputs["base_sha"]},
      {"PROBE_HEAD", inputs["head_sha"]},
      {"PROBE_TEST_CMD", inputs["test_cmd"]}
    ]
  end

  # ── Fabrication d'un dépôt à deux états ───────────────────────────────────────────────────────

  defp git!(dir, args) do
    {out, code} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    assert code == 0, "git #{Enum.join(args, " ")} → #{out}"
    String.trim(out)
  end

  # BASE porte le harnais, HEAD ajoute le livrable. Une origine bare locale permet
  # de jouer aussi la recuperation Git contenue dans le script extrait.
  defp build_repo(tmp, base_files, head_files) do
    src = Path.join(tmp, "src")
    File.mkdir_p!(src)
    git!(src, ["init", "-q", "-b", "main"])
    git!(src, ["config", "user.email", "t@t"])
    git!(src, ["config", "user.name", "t"])

    write_all(src, base_files)
    git!(src, ["add", "-A"])
    git!(src, ["commit", "-qm", "base"])
    base = git!(src, ["rev-parse", "HEAD"])

    write_all(src, head_files)
    git!(src, ["add", "-A"])
    git!(src, ["commit", "-qm", "head"])
    head = git!(src, ["rev-parse", "HEAD"])

    origin = Path.join(tmp, "projet.git")
    git!(tmp, ["clone", "-q", "--bare", src, origin])
    # Autoriser explicitement les requetes de SHA atteignables dans cette fixture;
    # ce test ne demontre pas les exigences de tous les protocoles/serveurs.
    git!(origin, ["config", "uploadpack.allowReachableSHA1InWant", "true"])

    %{dir: src, origin: origin, base: base, head: head}
  end

  defp write_all(repo, files) do
    Enum.each(files, fn {path, content} ->
      full = Path.join(repo, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
      File.chmod!(full, 0o755)
    end)
  end

  defp sonde(tmp, %{origin: origin, base: base, head: head}, harness, test_cmd) do
    script = probe_script()

    inputs = %{
      "harness" => harness,
      "base_sha" => base,
      "head_sha" => head,
      "test_cmd" => test_cmd
    }

    path = Path.join(tmp, "sonde.sh")
    File.write!(path, script)

    # Origine file:// et FORGE_TOKEN vide : ne teste pas l'injection d'un vrai jeton HTTP.
    work = Path.join(tmp, "job")
    File.mkdir_p!(work)

    # Planter un .netrc factice donne un temoin au changement de HOME.
    # Changer HOME ne constitue pas une isolation filesystem.
    fake_home = Path.join(tmp, "home")
    File.mkdir_p!(fake_home)
    File.write!(Path.join(fake_home, ".netrc"), "machine forge login x password netrc-secret\n")

    # Secrets factices : les noms en _KEY, DATABASE_URL et KUBECONFIG echappaient
    # au filtre par suffixe TOKEN/SECRET/PASSWORD. Le harnais compte toutes les
    # variables hors liste autorisee, pas seulement ces noms connus.
    env =
      [
        {"GITHUB_SERVER_URL", "file://" <> Path.dirname(origin)},
        {"GITHUB_REPOSITORY", Path.basename(origin, ".git")},
        {"FORGE_TOKEN", ""},
        {"HOME", fake_home},
        {"ACTIONS_RUNTIME_TOKEN", "runner-secret"},
        {"NPM_TOKEN", "publish-secret"},
        {"DB_PASSWORD", "hunter2"},
        {"AWS_SECRET_ACCESS_KEY", "aws-secret"},
        {"DEPLOY_KEY", "deploy-secret"},
        {"DATABASE_URL", "postgres://u:hunter2@db/x"},
        {"KUBECONFIG", "/etc/kube/admin.conf"}
      ] ++ input_env(inputs)

    {out, code} = System.cmd("sh", [path], cd: work, env: env, stderr_to_stdout: true)
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

  # Ticket #33 : appeler le livrable tout en ignorant sortie et code retour reste un faux vert.
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
      # Temoin negatif : un predicat toujours relevant doit echouer ici.
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
      # Le temoin deja rouge distingue une panne preexistante d'une sensibilite au code retire.
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

    # Le harnais inspecte son propre environnement, le remote Git et HOME/.netrc.
    # Compter le complement de la liste autorisee detecte les variables oubliees
    # par un filtre de noms ; PWD/SHLVL/OLDPWD/_ peuvent etre ajoutes par sh.
    @leak_check """
    #!/bin/sh
    echo "LEAKCHECK remote=[$(git config --get remote.origin.url)] token=[${FORGE_TOKEN}]"
    echo "NETRC=[$(cat "$HOME/.netrc" 2>/dev/null)]"
    echo "LEAKSCAN=[$(env | sed -n 's/^\\([A-Za-z_][A-Za-z0-9_]*\\)=.*/\\1/p' |
      grep -cvE '^(PATH|HOME|TMPDIR|TERM|LANG|LC_ALL|CI|LCARS_PROBE|PWD|SHLVL|OLDPWD|_)$')]"
    exit 0
    """

    test "le jeton n'est PLUS accessible quand la commande du livrable tourne", %{tmp_dir: tmp} do
      repo =
        build_repo(
          tmp,
          %{"tests/leak.sh" => @leak_check},
          %{"tests/leak.sh" => @leak_check, "hello.sh" => @deliverable}
        )

      r = sonde(tmp, repo, "tests/", "sh tests/leak.sh")

      # Le remote est present avant nettoyage. Le jeton est vide des le depart,
      # donc token=[] n'est pas un temoin discriminant de son effacement.
      assert r.out =~ "LEAKCHECK remote=[] token=[]",
             "le livrable jugé voit encore un secret : #{r.out}"

      # Verifie HOME/.netrc, pas l'inaccessibilite du fichier par un autre chemin.
      assert r.out =~ "NETRC=[]", "le livrable jugé lit les identifiants sur disque : #{r.out}"

      # Le compte doit aussi voir les variables que l'ancien filtre par suffixe ratait.
      assert r.out =~ "LEAKSCAN=[0]",
             "des variables survivent hors de la liste blanche : #{r.out}"

      # Controle positif : retirer les identifiants ne doit pas empecher la mesure locale.
      assert r.facts["witness_exit"] == "0"
      assert r.facts["verdict"] in ["relevant", "blind"]
      assert r.code == 0
    end

    test "commande de test VIDE → inapplicable, jamais un `blind` fabriqué", %{tmp_dir: tmp} do
      # Une commande absente doit etre inapplicable, pas mesuree comme une suite aveugle.
      repo =
        build_repo(
          tmp,
          %{"tests/run.sh" => @honest_test},
          %{"tests/run.sh" => @honest_test, "hello.sh" => @deliverable}
        )

      r = sonde(tmp, repo, "tests/", "")

      assert r.facts["verdict"] == "inapplicable"
      assert r.facts["reason"] == "no-test-cmd"
      refute r.facts["verdict"] == "blind"
      assert r.code == 0
    end

    test "une commande n'est JAMAIS du script : délimiteur, apostrophe et $(…) passent tels quels",
         %{tmp_dir: tmp} do
      # Les inputs étaient collés dans le script : une ligne égale au délimiteur tronquait la
      # commande, une apostrophe (« C'est ») cassait le shell de la sonde à chaque run (2026-09-23).
      # Par l'environnement, la commande est transcrite octet pour octet et mesurée entière.
      repo =
        build_repo(
          tmp,
          %{"tests/run.sh" => @honest_test},
          %{"tests/run.sh" => @honest_test, "hello.sh" => @deliverable}
        )

      cmd =
        "echo 'C'\"'\"'est'\nLCARS_PROBE_CMD_EOF=1\n: \"$(echo pas-execute-a-la-lecture)\"\nsh tests/run.sh"

      r = sonde(tmp, repo, "tests/", cmd)

      assert r.facts["verdict"] == "relevant"
      refute r.out =~ "Syntax error"
      assert r.code == 0
    end

    test "une commande MULTI-LIGNES s'arrête à la première erreur", %{tmp_dir: tmp} do
      # Preserver les retours a la ligne et constater l'echec de la premiere commande,
      # meme si la suivante aurait reussi. Ce cas ne couvre pas toutes les exceptions de sh -e.
      repo =
        build_repo(
          tmp,
          %{"tests/run.sh" => @honest_test},
          %{"tests/run.sh" => @honest_test, "hello.sh" => @deliverable}
        )

      r = sonde(tmp, repo, "tests/", "false\nsh tests/run.sh")

      assert r.facts["witness_exit"] == "1",
             "la première ligne a échoué et le témoin est vert : #{r.out}"

      assert r.facts["verdict"] == "inapplicable"
      assert r.facts["reason"] == "head-suite-red"
    end

    test "une commande MULTI-LIGNES qui passe entièrement mesure bien", %{tmp_dir: tmp} do
      # Temoin positif du support des commandes multi-lignes.
      repo =
        build_repo(
          tmp,
          %{"tests/run.sh" => @honest_test},
          %{"tests/run.sh" => @honest_test, "hello.sh" => @deliverable}
        )

      r = sonde(tmp, repo, "tests/", "true\nsh tests/run.sh")

      assert r.facts["witness_exit"] == "0"
      assert r.facts["verdict"] == "relevant"
    end

    test "un harnais qui ressemble à un GLOB n'est pas développé par le shell", %{tmp_dir: tmp} do
      # Garder la separation par blancs sans expansion des globs du shell.
      # Le motif absent est refuse avant son eventuelle interpretation comme pathspec Git.
      repo =
        build_repo(
          tmp,
          %{"tests/run.sh" => @honest_test},
          %{"tests/run.sh" => @honest_test, "hello.sh" => @deliverable}
        )

      r = sonde(tmp, repo, "*.sh", "sh tests/run.sh")

      # Le motif est traité comme un chemin littéral, donc absent — et la sonde le DIT.
      assert r.facts["verdict"] == "inapplicable"
      assert r.facts["reason"] == "harness-absent"
      assert r.facts["paths"] == "*.sh"
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
