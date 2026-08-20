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
      Regex.run(
        ~r/- name: Sonder\n(?:\s+env:\n(?:\s+\S+:.*\n)+)?\s+run: \|\n(.*?)(?=\n\s{6}- name: |\z)/s,
        yaml
      )

    # ⚠ L'INDENTATION SE MESURE, ELLE NE SE DEVINE PAS. Elle était codée en dur à dix espaces : une
    # ré-indentation du YAML aurait produit un script mal désindenté — bruyamment rouge dans un
    # sens, silencieusement inchangé dans l'autre. On lit le retrait de la première ligne non vide.
    lines = String.split(block, "\n")

    indent =
      lines
      |> Enum.find("", &(String.trim(&1) != ""))
      |> then(&(String.length(&1) - String.length(String.trim_leading(&1))))

    prefix = String.duplicate(" ", indent)

    assert indent > 0, "aucun retrait mesuré : l'extraction ne rend pas le script du runner"

    Enum.map_join(lines, "\n", &String.replace_prefix(&1, prefix, ""))
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
  #
  # ⚠ ET ON FABRIQUE UNE VRAIE ORIGINE, DEPUIS LE 2026-08-20. La récupération vivait dans un step à
  # part que ces fixtures n'exerçaient pas ; elle est descendue dans le script, donc elles la jouent
  # maintenant — `git fetch` par SHA, avec la configuration serveur que ça exige
  # (`uploadpack.allowReachableSHA1InWant`). C'est la seule façon de mesurer le script que le runner
  # recevra plutôt qu'une portion choisie de ce script.
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
    # LA CONFIGURATION QUE LE SCRIPT EXIGE DE LA FORGE, posée ici explicitement : sans elle,
    # `git fetch origin <sha>` répond « Server does not allow request for unadvertised object ».
    # La fixture la déclare, donc le test dit AUSSI ce que le déploiement doit fournir.
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

    # Le script clone lui-même, depuis `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git` — donc on
    # lui donne une origine locale. Le jeton est vide EXPRÈS : le script ne doit l'injecter que
    # dans une URL http(s), et un `file://` qui recevrait un `user:pass@` deviendrait invalide.
    # Ce test est donc aussi la preuve de ce refus.
    work = Path.join(tmp, "job")
    File.mkdir_p!(work)

    # ⚠ ON PLANTE DE VRAIS SECRETS. Sans eux, la fixture de fuite passerait sans rien mesurer :
    # l'environnement d'un test ExUnit n'en porte aucun, donc « zéro secret survivant » serait vrai
    # avant comme après le nettoyage. `ACTIONS_RUNTIME_TOKEN` est celui que le runner Gitea injecte
    # réellement ; les deux autres représentent ce qu'un opérateur y met.
    env = [
      {"GITHUB_SERVER_URL", "file://" <> Path.dirname(origin)},
      {"GITHUB_REPOSITORY", Path.basename(origin, ".git")},
      {"FORGE_TOKEN", ""},
      {"ACTIONS_RUNTIME_TOKEN", "runner-secret"},
      {"NPM_TOKEN", "publish-secret"},
      {"DB_PASSWORD", "hunter2"}
    ]

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

    # ⚠ LE SECRET NE DOIT PLUS ÊTRE LÀ QUAND LE CODE JUGÉ S'EXÉCUTE.
    #
    # La commande de test vient du `CLAUDE.md` de la TÊTE JUGÉE — donc du livrable qu'on évalue. Elle
    # tournait dans un répertoire dont `.git/config` portait le jeton de forge en clair (écrit par
    # `git remote add origin "$auth"`), et dans un shell qui portait `FORGE_TOKEN`. Un
    # `cat .git/config` suffisait.
    #
    # « Pas de privilège nouveau » restait vrai — qui contrôle `tests/run.sh` exécute déjà du code
    # arbitraire ici. Ça justifiait de ne pas paniquer, pas de laisser le geste.
    #
    # Ce test s'exécute DEPUIS LA PLACE DE L'ATTAQUANT : le harnais lui-même va chercher les deux.
    @leak_check """
    #!/bin/sh
    echo "LEAKCHECK remote=[$(git config --get remote.origin.url)] token=[${FORGE_TOKEN}]"
    echo "LEAKSCAN=[$(env | sed -n 's/^\\([A-Za-z_][A-Za-z0-9_]*\\)=.*/\\1/p' | grep -cE '(TOKEN|SECRET|PASSWORD)$')]"
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

      # Les deux vecteurs, dans une seule ligne écrite par le code jugé lui-même.
      #
      # ⚠ CE QUE CETTE FIXTURE PROUVE, ET CE QU'ELLE NE PROUVE PAS. Mutation jouée : en retirant les
      # deux lignes du workflow, `remote=[file:///…/projet.git]` apparaît et ce test devient rouge —
      # donc la moitié `remote` MORD.
      #
      # La moitié `token`, elle, ne discrimine PAS ici : l'origine du test est un `file://` et
      # `FORGE_TOKEN` y vaut `""` par construction, donc `token=[]` serait vrai même sans `unset`.
      # Elle reste écrite parce qu'elle épingle la FORME de ce qu'on interdit, et parce qu'un jour
      # une fixture http la rendra discriminante. Elle ne compte pas comme preuve aujourd'hui, et
      # ce paragraphe est là pour qu'on ne la lise pas comme telle.
      assert r.out =~ "LEAKCHECK remote=[] token=[]",
             "le livrable jugé voit encore un secret : #{r.out}"

      # ⚠ ET PAS SEULEMENT LE NÔTRE. Le runner injecte ses propres secrets — `ACTIONS_RUNTIME_TOKEN`
      # et ce que l'opérateur y met. Le harnais compte lui-même, DEPUIS LA PLACE DE L'ATTAQUANT,
      # combien de variables au nom de secret survivent dans son environnement. La réponse doit être
      # zéro, et le compte discrimine là où `token=[]` ne discriminait pas.
      assert r.out =~ "LEAKSCAN=[0]", "des variables de secret survivent : #{r.out}"

      # ⚠ ET LA SONDE MARCHE TOUJOURS. Couper le remote après les `fetch` ne doit rien casser :
      # tout ce qui suit est du `checkout` local. Sans cette moitié, on aurait pu « corriger » en
      # cassant la mesure sans que rien ne le dise.
      assert r.facts["witness_exit"] == "0"
      assert r.facts["verdict"] in ["relevant", "blind"]
      assert r.code == 0
    end

    test "commande de test VIDE → inapplicable, jamais un `blind` fabriqué", %{tmp_dir: tmp} do
      # ⚠ LE SEUL MENSONGE QUE CETTE SONDE POUVAIT PRODUIRE, trouvé par relecture adversariale.
      # `( )` est une sous-shell POSIX valide et sort en 0 : sans garde, le témoin passait, la
      # mesure passait, et la sonde annonçait « la suite reste verte sans le code livré » à un
      # projet qui n'a AUCUNE suite. Un fait faux présenté comme une mesure.
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

    test "une commande MULTI-LIGNES s'arrête à la première erreur", %{tmp_dir: tmp} do
      # ⚠ MESURÉ LE 2026-08-20. Le corps d'un `## Test` était joint par des ESPACES, donc
      # « make build \n make test » devenait `make build make test` — une commande avec des
      # arguments, ni l'une ni l'autre. Et substituée en ligne dans `( … )`, une version
      # multi-lignes aurait pris le code de retour de la DERNIÈRE : la première étape pouvait
      # échouer et le témoin rester vert.
      #
      # Ici la première ligne ÉCHOUE. La suite doit être vue rouge — c'est la sémantique de la CI
      # (première erreur, arrêt), et le template exige que `## Test` et `ci.yml` portent la même
      # commande.
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
      # Le témoin du témoin : sans lui, « multi-lignes → rouge » passerait aussi si le multi-lignes
      # était cassé de bout en bout.
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
      # ⚠ `$harness` est délibérément NON quoté — c'est ainsi qu'on obtient plusieurs chemins — et
      # sans `set -f` le shell y appliquait AUSSI l'expansion de motifs : un projet déclarant
      # `*.test` aurait vu la sonde travailler sur ce que le répertoire contient au moment du run,
      # pas sur ce qu'il a déclaré. Ici, `*.sh` ne doit désigner AUCUN fichier existant.
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
