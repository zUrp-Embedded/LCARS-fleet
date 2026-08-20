defmodule Fleet.MCP.PodTools.Probe do
  @moduledoc """
  Le juge DEMANDE une mesure ; il n'obtient jamais d'accès. Le rail exécute, lit, et rend un FAIT.

  ## Ce que ce module refuse de faire, et pourquoi c'est l'essentiel

  Trois formes étaient possibles pour cet outil. Deux sont écartées, et la raison ne se rattrape pas
  plus tard :

    * `check_test_relevance(fichier)` — l'outil EST la sonde. Plus court aujourd'hui, condamné
      demain : chaque question nouvelle demanderait un déploiement de flotte, et l'angle mort
      resterait permanent. Une carotte qui ne peut poser qu'UNE question mesure ce qu'elle sait
      mesurer, pas ce qui compte ;
    * `run_script(script)` — le juge écrit la mesure qui soutient son verdict. C'est un RNG en
      uniforme avec une couche d'exécution pour le crédibiliser.

  Retenu : **`run_probe(probe, inputs)`**, où `probe` est un NOM. Ajouter une sonde devient alors une
  DONNÉE dans un projet — un fichier de workflow de plus — et non une livraison de flotte. C'est la
  condition d'architecture, payée à la première ligne ou jamais.

  ## Ce que le juge ne fournit PAS, et ne peut pas fournir

  Le dépôt, la PR, les SHAs et les chemins de preuve viennent tous du CANAL et des DÉCLARATIONS du
  projet, jamais du fil. Un juge qui pourrait nommer sa base nommerait la base qui l'arrange, et la
  mesure censée le contraindre serait redevenue son opinion (§10c — juge et partie).

  Ce qu'il peut passer, ce sont les `inputs` déclarés par la sonde elle-même. Ils sont
  ADDITIONNELS : les clés que le rail calcule ne sont jamais écrasées (`Map.merge` dans ce
  sens-là, et c'est délibéré).

  ## Le résultat est un fait, pas un verdict

  La sonde sort toujours en 0 et écrit ses lignes `LCARS-PROBE` (cf. le workflow du template). Ce
  module les extrait, les rend en clés/valeurs, et **n'interprète rien** : `blind` ne devient pas
  « mauvaise livraison », `inapplicable` ne devient pas `blind`, et l'absence de fait ne devient pas
  un vert. Le juge lit et tranche.
  """

  require Logger

  # LE CATALOGUE DE SONDES EST UNE DONNÉE, ET IL EST VOLONTAIREMENT MINUSCULE.
  #
  # Une entrée = un nom public → le fichier de workflow que le projet porte. C'est le seul endroit
  # de la flotte qui connaisse des noms de sondes, et il ne connaît QUE des noms : ce que la sonde
  # fait vit dans le dépôt du projet, relisible et modifiable par lui. Une deuxième sonde s'ajoute
  # ici en une ligne, ou — mieux — un jour, en lisant `.gitea/workflows/probe-*` du projet.
  #
  # Le préfixe `probe-` n'est pas cosmétique : un contexte de statut `probe-… / …` ne matche pas le
  # glob `CI / *` de la protection de `main` (cf. `Onboard.main_status_check_contexts/0`), donc une
  # sonde ne peut pas devenir un mur. Ajouter ici un workflow nommé autrement contournerait cette
  # garde par le catalogue.
  @probes %{
    "test-relevance" => "probe-test-relevance.yml"
  }

  @fact_prefix "LCARS-PROBE"
  @poll_ms 1_000
  @max_wait_ms 120_000

  @doc "Les noms de sondes que le rail sait résoudre."
  @spec known() :: [String.t()]
  def known, do: Map.keys(@probes)

  @doc """
  Joue `probe` pour le pod `pod_id` et rend le fait mesuré.

  Le pod est un JUGE sur une PR : son `pod_id` porte le dépôt et le numéro de PR (`PodId.for_pr/3`),
  donc l'identité EST le canal. Toute la résolution en découle.
  """
  @spec run(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(pod_id, probe, inputs \\ %{}, opts \\ [])
      when is_binary(pod_id) and is_binary(probe) and is_map(inputs) do
    with {:ok, workflow} <- resolve_probe(probe),
         {:ok, %{repo: repo}} <- identity(pod_id, opts),
         {:ok, pr} <- pr_of(pod_id, repo),
         {:ok, refs} <- forge().pr_refs(repo, pr, forge_opts(opts)),
         {:ok, declared} <- declarations(repo, refs.head_sha, opts),
         {:ok, %{run_id: run_id}} <-
           forge_actions().dispatch_workflow(
             repo,
             workflow,
             refs.base_ref,
             rail_inputs(refs, declared, inputs),
             forge_opts(opts)
           ),
         {:ok, logs, run_state} <- await_logs(repo, run_id, opts) do
      facts =
        logs
        |> facts()
        |> Map.merge(run_state)
        |> Map.put("probe", probe)
        |> Map.put("run_id", run_id)

      {:ok, facts}
    end
  end

  # ── Résolution ─────────────────────────────────────────────────────────────────────────────────

  defp resolve_probe(probe) do
    case Map.fetch(@probes, probe) do
      {:ok, wf} -> {:ok, wf}
      # Le refus ÉNUMÈRE, parce qu'un refus qui ne dit pas quoi écrire à la place renvoie l'appelant
      # par le même appel (même leçon que `declarable_card/3`).
      :error -> {:error, {:unknown_probe, probe, known()}}
    end
  end

  # LE DÉPÔT D'UN POD DISPATCHÉ NE S'ÉCRIT PAS `owner/name` DANS SON LIEN DE SPAWN, ET C'EST VOULU :
  # le `slot_key` du spawner se clef sur `:repo_id`, donc y mettre la chaîne mettrait tous les
  # producteurs et tous les juges de tous les projets dans un même seau. Conséquence pour ici :
  # `identity.repo` est `nil` pour un juge, et ne l'est PAS pour un architecte.
  #
  # On lit donc les deux, dans cet ordre — la chaîne quand elle est là, sinon la traduction de l'ID
  # par la forge. Refuser sur l'absence de `:repo` aurait rendu cet outil inutilisable par
  # exactement les rôles pour lesquels il est écrit.
  defp identity(pod_id, opts) do
    resolver = Application.get_env(:lcars_fleet, :mcp_pod_resolver, &default_resolver/1)

    case resolver.(pod_id) do
      {:ok, %{repo: repo}} when is_binary(repo) and repo != "" ->
        {:ok, %{repo: repo}}

      {:ok, %{repo_id: id}} when is_integer(id) and id > 0 ->
        case forge().repo_full_name(id, forge_opts(opts)) do
          {:ok, full} -> {:ok, %{repo: full}}
          {:error, _} = err -> err
        end

      {:ok, _unbound} ->
        {:error, :repo_unbound}

      {:error, _} = err ->
        err
    end
  end

  # Même couture et même résolveur que `Delegation` (`:mcp_pod_resolver`) : deux résolveurs de la
  # même identité de canal donneraient deux avis sur « à quel dépôt ce pod est lié ».
  defp default_resolver(pod_id) do
    Fleet.Spawner.pod_info(pod_id)
  rescue
    _ -> {:error, :pod_unknown}
  catch
    _, _ -> {:error, :pod_unknown}
  end

  # LE NUMÉRO DE PR VIENT DU POD_ID, PAS DU FIL. Un juge de livrable est minté `for_pr/3`, donc son
  # identité de canal porte déjà la PR qu'il juge. Un pod dont l'id ne porte PAS de PR n'est pas un
  # juge de livrable : le refus le dit plutôt que de sonder au hasard.
  defp pr_of(pod_id, repo) do
    case Fleet.PodId.parse_ref(pod_id, repo) do
      {:ok, {:pr, n}} -> {:ok, n}
      {:ok, {:issue, _}} -> {:error, :not_a_deliverable_judge}
      :error -> {:error, :pr_unresolvable}
    end
  end

  # ── Déclarations du projet ─────────────────────────────────────────────────────────────────────

  @doc """
  Lit `## Harness` et `## Test` dans le `CLAUDE.md` du dépôt, AU SHA LIVRÉ.

  Au SHA et pas sur `main`, et c'est une correction de sens : une livraison qui déplace ses tests
  met à jour sa déclaration DANS LA MÊME PR. Lire `main` mesurerait la livraison d'aujourd'hui avec
  la carte d'hier.

  Une déclaration absente n'est pas une erreur — c'est le cas `inapplicable` que la sonde sait dire.
  On rend donc `""`, et c'est le workflow qui le nomme.
  """
  @spec declarations(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def declarations(repo, ref, opts \\ []) do
    case forge().get_file(repo, "CLAUDE.md", Keyword.put(forge_opts(opts), :ref, ref)) do
      {:ok, %{content: md}} ->
        {:ok, %{harness: section(md, "Harness"), test_cmd: section(md, "Test")}}

      {:error, :not_found} ->
        {:ok, %{harness: "", test_cmd: ""}}

      {:error, _} = err ->
        err
    end
  end

  # Extraction d'une section de niveau 2, corps jusqu'au prochain `##`. On ne réutilise PAS
  # `SPBuilder.RepoSections` : celui-là répond à « que voyage-t-il jusqu'au pod », question dont la
  # réponse est close à sept noms et dont `Harness` est délibérément absent. Emprunter son parseur
  # ferait dépendre une mesure de rail d'une liste faite pour autre chose, et le jour où la liste
  # bouge la mesure bougerait sans raison.
  #
  # ⚠ DEUX FAUTES CORRIGÉES LE 2026-08-20, TROUVÉES PAR RELECTURE ADVERSARIALE. Les deux étaient
  # des cas où ce parseur lisait CONFIANT quelque chose qui n'était pas la déclaration du projet.
  #
  # 1. LES BLOCS DE CODE SONT MASQUÉS AVANT LA RECHERCHE. Le `CLAUDE.md` du template DOCUMENTE la
  #    section `## Harness` et en montre un exemple dans un bloc `` ``` `` — dont la ligne
  #    `## Harness` est en colonne 0. Avec le drapeau `m`, `^` matche à l'intérieur du bloc : la
  #    sonde lisait l'EXEMPLE DE LA DOC, puis toute la prose qui suit, au lieu de la déclaration
  #    écrite par le projet. Mesuré sur le template réel — `harness` valait
  #    `"tests/ ``` **À quoi elle sert.** La sonde …"`. Un projet qui écrit sa section SOUS la
  #    documentation (le geste naturel) ne la voyait jamais lue.
  #
  # 2. LE TITRE EST ANCRÉ EN FIN DE LIGNE, et le `\b` d'avant ne protégeait rien. Le commentaire
  #    disait « sans lui, demander "Test" attraperait `## Test paths` » — c'est FAUX et c'est
  #    l'inverse de ce que ce dépôt a mesuré ailleurs : `\b` tombe entre `t` et l'espace, DONC
  #    `## Test paths` matchait. Un projet portant `## Test suite` avant son `## Test` faisait
  #    tourner la sonde avec la mauvaise commande.
  #
  # La règle est maintenant : le titre est le nom, SEUL sur sa ligne (espaces de fin tolérés), ET
  # hors de tout bloc de code.
  #
  # ⚠ LECTURE LIGNE À LIGNE, ET PAS UNE REGEX SUR UN TEXTE MASQUÉ. La première correction masquait
  # les blocs avant la recherche — ce qui aurait effacé le CORPS d'une section dont la valeur est
  # légitimement encadrée (`## Test` suivi d'un bloc contenant `mix test`, forme parfaitement
  # normale). Le titre doit être cherché hors des blocs ; le corps doit être rendu tel qu'il est
  # écrit. Une seule passe qui suit l'état de fence répond aux deux sans en sacrifier une.
  defp section(md, name) do
    md
    |> String.split("\n")
    |> Enum.reduce({[], false, :before}, &scan_line(&1, &2, name))
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim()
    |> strip_fences()
  end

  # Trois etats — `:before`, `:capturing`, `:done` — et un drapeau de bloc. Un titre ne compte que
  # HORS bloc ; le corps, lui, est rendu tel qu'il est ecrit, blocs compris.
  defp scan_line(_line, {acc, in_fence?, :done}, _name), do: {acc, in_fence?, :done}

  defp scan_line(line, {acc, in_fence?, state}, name) do
    fence? = String.starts_with?(String.trim_leading(line), "```")
    next_fence? = if fence?, do: not in_fence?, else: in_fence?
    heading? = not in_fence? and not fence? and String.starts_with?(line, "## ")

    case {state, heading?} do
      # Un titre HORS bloc termine la capture en cours.
      {:capturing, true} -> {acc, in_fence?, :done}
      {:capturing, false} -> {[line | acc], next_fence?, :capturing}
      # C'est le NOTRE qui la commence, a condition d'etre seul sur sa ligne.
      {:before, true} -> {acc, in_fence?, if(ours?(line, name), do: :capturing, else: :before)}
      {:before, false} -> {acc, next_fence?, :before}
    end
  end

  # `## Harness` oui ; `## Harness paths`, `## Harnessing` non. Le nom est SEUL sur sa ligne.
  defp ours?(line, name), do: String.trim_trailing(line) == "## " <> name

  # Une commande ou des chemins écrits dans un bloc de code restent une commande et des chemins : la
  # recherche du titre ignore les blocs, celui-ci nettoie le CORPS d'une section dont la valeur est
  # légitimement encadrée.
  #
  # ⚠ ON JOINT PAR DES SAUTS DE LIGNE, PAS PAR DES ESPACES. Le corps d'un `## Test` est un SCRIPT :
  #
  #     ## Test
  #     make build
  #     make test
  #
  # Joint par un espace, ça rendait `"make build make test"` — UNE commande avec des arguments, qui
  # n'est ni l'une ni l'autre. La sonde tournait, rendait un verdict, et il portait sur autre chose
  # que la suite du projet. Même classe que la commande vide : un fait faux présenté comme mesure.
  #
  # `## Harness`, lui, est une LISTE de chemins, et le workflow la découpe sur tout blanc — un saut
  # de ligne y est aussi bon qu'un espace. Les deux sections partagent donc ce nettoyage sans que
  # l'une paie pour l'autre.
  defp strip_fences(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim(&1), "```"))
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.trim()
  end

  # LES CLÉS DU RAIL GAGNENT SUR CELLES DU JUGE, et c'est le sens du `Map.merge`. Un juge qui
  # passerait `base_sha` choisirait la base qui l'arrange ; ses entrées à lui s'ajoutent, elles ne
  # remplacent pas.
  defp rail_inputs(refs, declared, judge_inputs) do
    judge_inputs
    |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
    |> Map.merge(%{
      "base_sha" => refs.base_sha,
      "head_sha" => refs.head_sha,
      "harness" => declared.harness,
      "test_cmd" => declared.test_cmd
    })
  end

  # ── Attente et lecture ─────────────────────────────────────────────────────────────────────────

  # ATTENTE BORNÉE, ET DANS LE TOUR D'OUTIL DU JUGE — jamais dans le tick du pilote. C'est tout
  # l'arbitrage Q1 : trois secondes sont négligeables pour un agent qui attend son propre appel, et
  # coûteuses dans une boucle qui sert plusieurs dépôts. Le plafond existe parce qu'un runner mort
  # ne rend pas d'erreur : il ne rend rien.
  defp await_logs(repo, run_id, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :max_wait_ms, @max_wait_ms)
    poll(repo, run_id, deadline, opts)
  end

  defp poll(repo, run_id, deadline, opts) do
    case forge_actions().run(repo, run_id, forge_opts(opts)) do
      {:ok, %{"status" => status} = run} when status in ~w(success failure cancelled skipped) ->
        # ⚠ L'ETAT DU RUN VOYAGE AVEC LES FAITS. Un run ANNULE avant d'avoir ecrit ses lignes
        # `LCARS-PROBE` rend une map vide — indiscernable de « la sonde a tourne et n'a rien
        # conclu ». Deux faits opposes, une meme forme. Le juge doit pouvoir les separer, et ca
        # coute deux cles.
        case forge_actions().run_logs(repo, run_id, forge_opts(opts)) do
          {:ok, logs} -> {:ok, logs, Map.take(run, ["status", "conclusion"])}
          {:error, _} = err -> err
        end

      {:ok, _still_going} ->
        if System.monotonic_time(:millisecond) >= deadline do
          # On NOMME l'attente épuisée. Un `{:ok, %{}}` ici ferait passer « on n'a pas attendu assez »
          # pour « la sonde n'a rien trouvé », et le juge lirait une absence de fait comme un fait.
          {:error, {:probe_timeout, run_id}}
        else
          Process.sleep(Keyword.get(opts, :poll_ms, @poll_ms))
          poll(repo, run_id, deadline, opts)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Extrait les faits `LCARS-PROBE` des logs, en clés/valeurs.

  Les lignes tardives gagnent : la sonde écrit son contexte puis son verdict, dans cet ordre.
  Aucune interprétation — ce module ne sait pas ce que « blind » veut dire, et c'est voulu.
  """
  @spec facts(String.t()) :: map()
  def facts(logs) when is_binary(logs) do
    logs
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, @fact_prefix))
    |> Enum.flat_map(&pairs/1)
    |> Map.new()
  end

  defp pairs(line) do
    line
    |> String.split(@fact_prefix, parts: 2)
    |> List.last()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.flat_map(fn token ->
      case String.split(token, "=", parts: 2) do
        [k, v] when k != "" -> [{k, v}]
        _ -> []
      end
    end)
  end

  # ── Coutures ───────────────────────────────────────────────────────────────────────────────────

  defp forge, do: Application.get_env(:lcars_fleet, :forge_client, Fleet.Forge.Client)

  defp forge_actions,
    do: Application.get_env(:lcars_fleet, :forge_actions, Fleet.Forge.Client.Actions)

  defp forge_opts(opts), do: Keyword.get(opts, :forge_opts, [])
end
