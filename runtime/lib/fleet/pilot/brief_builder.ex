defmodule Fleet.Pilot.BriefBuilder do
  @moduledoc """
  Formats worker, judge, brief-review and rework orders; StepDispatcher selects the path.
  Forge access is injected through `Access` or explicit arguments.

  Unknown brief kinds and judge targets raise rather than silently selecting a worker.
  GateBrief frames judge material as context to evaluate, not an instruction to execute.
  Conflict rework uses local `lcars/base`: pods commit locally and the system publishes.
  """

  require Logger

  defmodule Access do
    @moduledoc """
    Groups the forge module, repository and transport options so callers pass them together.
    """
    @enforce_keys [:forge, :repo, :forge_opts]
    defstruct @enforce_keys

    @type t :: %__MODULE__{forge: module(), repo: String.t(), forge_opts: keyword()}
  end

  # Share mount filenames between order text and spawn metadata to prevent mismatches.
  @brief_mount "brief.md"
  @criteria_mount "criteria.md"

  @doc """
  Rework order with review feedback and optional conflict instructions.
  The template requires local commits because the pod cannot publish to the forge.
  `opts[:conflict] == :exception` addresses an outsider; other truthy values address
  the original producer. Conflict orders require `:base_branch`.
  """
  @spec rework_brief(String.t(), module(), String.t(), integer(), keyword(), term(), keyword()) ::
          String.t()
  def rework_brief(role, forge, repo, pr, forge_opts, _route, opts \\ []) do
    # The template carries the summary instruction: the PR summary is the producer's voice to the human.
    Fleet.Workflow.BriefTemplate.render("work-order-rework", %{
      "role" => role,
      "pr" => to_string(pr),
      "feedback_section" =>
        conflict_section(opts) <> render_rework_feedback(forge, repo, pr, forge_opts)
    })
  end

  # Conflict voice depends on ownership, not role name; an outsider has no original brief to resume.
  defp conflict_section(opts) do
    case Keyword.get(opts, :conflict, false) do
      false -> ""
      :exception -> exception_conflict_section(Keyword.fetch!(opts, :base_branch))
      _producer -> producer_conflict_section(Keyword.fetch!(opts, :base_branch))
    end
  end

  # Review clones are single-branch: origin/<base> may be absent, so commands use lcars/base.
  # The supplied base name remains in prose; never invent it when :base_branch is missing.
  defp producer_conflict_section(base) do
    """
    ## Conflit de merge à résoudre (prioritaire)

    Ta branche a divergé de `#{base}` : des briques sœurs ont été mergées depuis ta coupe, et le
    merge automatique de ta PR est impossible. Ton brief est INCHANGÉ — le travail livré est
    déjà approuvé par les juges, seul le conflit bloque.

    1. Intègre l'état actuel de `#{base}` : `git merge lcars/base` dans ton workspace. (`lcars/base`
       est le ref que le runtime a posé sur `#{base}` avant ton démarrage — ton clone est
       mono-branche, `origin/#{base}` n'y est pas.)
    2. Résous les conflits en préservant l'intention de TON brief ET le contenu déjà mergé
       des briques sœurs (leur travail est livré : tu composes avec, tu n'écrases pas).
    3. Commite la résolution — le système pousse, les juges re-jugeront le nouveau head.

    Si `lcars/base` est absent, ou s'il ne contient PAS les briques sœurs (tu n'as pas le réseau
    pour le rafraîchir), rends `blocked` en le disant : n'invente JAMAIS le contenu d'une brique
    sœur, et ne bricole pas une autre base.

    """
  end

  defp exception_conflict_section(base) do
    """
    ## Passe d'exception : conflit de merge non résolu par le producteur

    Ce n'est PAS ton travail et tu n'as pas de brief à reprendre. Le producteur a épuisé son
    budget de rework sur ce conflit ; tu interviens en dernière passe avant escalade humaine.

    Le fond des deux côtés est déjà ACCEPTÉ — les juges ont rendu un AVIS FAVORABLE, le rail l'a
    scellé, et les briques sœurs sont mergées sur `#{base}`. Il n'y a donc rien à arbitrer sur le
    fond : la seule question est de composer les deux intentions sans en sacrifier une.

    1. Intègre l'état actuel de `#{base}` : `git merge lcars/base` dans ton workspace. (`lcars/base`
       est le ref que le runtime a posé sur `#{base}` avant ton démarrage — ton clone est
       mono-branche, `origin/#{base}` n'y est pas.)
    2. Résous en PRÉSERVANT les deux apports. Tu n'as pas écrit ce code : tu ne connais pas les
       raisons derrière chaque ligne, donc tu ne choisis pas un camp — tu composes.
    3. Commite la résolution — le système pousse, les juges re-jugeront le nouveau head.

    Rends `blocked` en disant pourquoi dès que la composition demande une DÉCISION que le code ne
    porte pas (deux intentions réellement incompatibles, ou un `lcars/base` absent ou périmé que tu
    ne peux pas rafraîchir). C'est le résultat attendu d'une passe d'exception qui bute : l'escalade
    humaine existe pour ça, et une résolution devinée coûte plus cher qu'un refus motivé.

    """
  end

  # Distinguish empty feedback from failed reads. Unlike missing judging material,
  # unreadable rework feedback degrades the order, with a warning in both log and brief.
  defp render_rework_feedback(forge, repo, pr, forge_opts) do
    case forge.change_request_feedback(repo, pr, forge_opts) do
      {:ok, [_ | _] = feedbacks} ->
        sections =
          Enum.map_join(feedbacks, "\n\n", fn fb ->
            "### Review de `#{fb["login"]}`\n#{fb["body"]}"
          end)

        "## Feedback de review à traiter (REQUEST_CHANGES)\n\n#{sections}"

      {:ok, []} ->
        ci_failure_section(forge, repo, pr, forge_opts)

      {:error, reason} ->
        # Keep the StepDispatcher log prefix stable for operational searches.
        Logger.warning(
          "StepDispatcher: rework feedback UNREADABLE repo=#{repo} pr=#{pr} " <>
            "reason=#{inspect(reason)} — the producer reworks without the reviews (degraded, not deferred)"
        )

        "## Feedback de review — NON LU\n\n" <>
          "Les reviews REQUEST_CHANGES de cette PR n'ont pas pu être lues sur la forge " <>
          "(erreur transitoire). Elles EXISTENT : cette PR a été retoquée. Lis-les toi-même sur " <>
          "la PR avant de corriger — ne suppose pas qu'il n'y avait rien à traiter."
    end
  end

  # Without review feedback, inspect head CI for a rework reason; read errors remain visible.
  defp ci_failure_section(forge, repo, pr, forge_opts) do
    with {:ok, %{"head" => %{"sha" => sha}}} when is_binary(sha) <-
           forge.get_pull(repo, pr, forge_opts),
         {:ok, state} <- forge.commit_ci_state(repo, sha, forge_opts) do
      ci_state_section(state, forge, repo, sha, forge_opts)
    else
      err ->
        Logger.warning(
          "StepDispatcher: rework CI state UNREADABLE repo=#{repo} pr=#{pr} " <>
            "(#{inspect(err)}) — le brief ne peut pas nommer la raison (dégradé, pas différé)"
        )

        "## Raison du rework — NON LUE\n\n" <>
          "Ni review REQUEST_CHANGES, ni état CI lisible sur la forge (erreur transitoire). " <>
          "Ouvre l'onglet Actions de la PR : si la CI est ROUGE, c'est ÇA qu'il faut corriger."
    end
  end

  # Include failing contexts because the pod cannot query CI itself; do not accuse green jobs.
  defp ci_state_section(:failure, forge, repo, sha, forge_opts) do
    "## CI ROUGE — c'est ÇA qu'il faut corriger (pas une review)\n\n" <>
      "Aucun juge n'a demandé de changement : ce rework vient de la CI, ROUGE sur la tête de la PR." <>
      red_contexts_lines(forge, repo, sha, forge_opts) <>
      "Le job nommé vit dans `.gitea/workflows/` de CE dépôt : c'est là que tu corriges, et le " <>
      "runner rejoue le fichier de TA branche au push suivant — le fix se consomme sur la PR qu'il " <>
      "débloque. Piège récurrent : un `actions/checkout` qui meurt = l'image du job n'a pas `node` " <>
      "— vise une image grasse via `container:` (cf. l'en-tête du `ci.yml`)."
  end

  defp ci_state_section(_green_or_pending, _forge, _repo, _sha, _forge_opts), do: ""

  # An empty context list is distinct from a failed read and must not invent a failing job.
  defp red_contexts_lines(forge, repo, sha, forge_opts) do
    case forge.commit_ci_failures(repo, sha, forge_opts) do
      {:ok, [_ | _] = reds} ->
        "\n\nContexte(s) en ÉCHEC :\n" <>
          Enum.map_join(reds, "\n", &red_context_line/1) <> "\n\n"

      {:ok, []} ->
        "\n\n"

      {:error, reason} ->
        Logger.warning(
          "StepDispatcher: rework CI contexts UNREADABLE repo=#{repo} sha=#{sha} " <>
            "reason=#{inspect(reason)} — le brief dit le rouge sans pouvoir le nommer"
        )

        "\n\nLes contextes en échec n'ont pas pu être lus sur la forge : le rouge est certain, " <>
          "son nom ne l'est pas.\n\n"
    end
  end

  defp red_context_line(%{context: ctx} = red) do
    "  - `#{ctx}`" <>
      case red.description do
        nil -> ""
        d -> " — #{d}"
      end <>
      case red.target_url do
        nil -> ""
        u -> " (#{u})"
      end
  end

  @doc """
  Returns `{:ok, brief, effective_kind, mount}`. The effective kind includes the step
  override; mount is `%{ref, sha, ops_path, filename}` or nil for inline material.
  Callers must pass that mount to the spawner, not resolve the source independently.

  Invalid or unreadable entry pointers return `:criterion_unavailable` on every path.
  Deliverable judges also reject failed predecessor/criterion reads. Missing readable
  material can still use fallback paths; this is not universal validation of content.
  Unknown kinds or judge targets raise.
  """
  @spec build_brief(
          Fleet.CapProfile.t(),
          String.t(),
          Access.t(),
          integer(),
          map(),
          {String.t(), String.t()} | term(),
          map(),
          keyword()
        ) ::
          {:ok, String.t(), String.t(), map() | nil}
          | {:error, {:criterion_unavailable, term()}}
  def build_brief(profile, role, %Access{} = access, number, issue, route, step_spec, opts \\ []) do
    %Access{repo: repo} = access
    # Resolve entry pointers once for every kind. No pointer preserves inline content;
    # an invalid or unreadable pointer returns a typed error before brief selection.
    with {:ok, issue} <- resolve_issue_brief(issue, repo, opts) do
      case do_build_brief(profile, role, access, number, issue, route, step_spec, opts) do
        # Return the same source and filename used to render the order.
        {:ok, brief, kind, source, filename} ->
          {:ok, brief, kind, mandate_from_source(source, filename, repo, opts)}

        other ->
          other
      end
    end
  end

  # Pair the resolved pin with the project's ops worktree and the order's mount filename.
  defp mandate_from_source({ref, sha}, filename, repo, opts) do
    ops_root = Keyword.get(opts, :ops_root, Fleet.Layout.ops_root())

    %{
      ref: ref,
      sha: sha,
      ops_path: Path.join(ops_root, Fleet.Layout.project_name(repo)),
      filename: filename
    }
  end

  defp mandate_from_source(_source, _filename, _repo, _opts), do: nil

  defp do_build_brief(profile, role, %Access{} = access, number, issue, route, step_spec, opts) do
    %Access{forge: forge, repo: repo, forge_opts: forge_opts} = access

    # The STEP's `brief_kind` (workflow_map) TAKES PRECEDENCE over the profile's (per-step override) — it
    # drives a worker profile as a JUDGE for one step without duplicating the profile. NO canon role
    # uses it today. The mechanism stays because it is the generic way to answer
    # "this step judges", and removing it would force a duplicate profile the day one is needed.
    # Nil or false step overrides fall back to the profile; unknown truthy values reach the error clause.
    kind = Map.get(step_spec, "brief_kind") || Fleet.CapProfile.brief_kind(profile)

    case {kind, Map.get(step_spec, "judge_target")} do
      # Brief judges evaluate the entry material; their fallback fetch is best-effort.
      {"judge", "brief"} ->
        # Only the entry issue's resolved source supplies this path's mount.
        {:ok, build_brief_review_brief(role, issue, forge, repo, number, forge_opts, route, opts),
         "judge", Map.get(issue, "_brief_source"), @brief_mount}

      {"judge", target} when target in [nil, "deliverable"] ->
        with {:ok, brief, mount} <-
               build_judge_brief(role, forge, repo, number, forge_opts, route, opts) do
          {:ok, brief, "judge", mount, @criteria_mount}
        end

      {"judge", other} ->
        raise ArgumentError,
              "judge_target #{inspect(other)} out of vocabulary {brief, deliverable} — a judge's target is not inferred"

      {"worker", _} ->
        {:ok, build_worker_brief(role, issue), "worker", Map.get(issue, "_brief_source"),
         @brief_mount}

      {other, _} ->
        raise ArgumentError,
              "brief_kind #{inspect(other)} out of vocabulary {worker, judge} — judge-ness is not inferred"
    end
  end

  # Template instructions require local commits; the system pushes and opens the PR.
  # Do not request a role-signature action: the clone's prepare-commit-msg hook appends it.
  defp build_worker_brief(role, issue) do
    Fleet.Workflow.BriefTemplate.render("work-order-build", %{
      "role" => role,
      "issue" => to_string(issue["number"] || "?"),
      "brief_body" => worker_order_body(issue)
    })
  end

  # Resolved pointers become file instructions; unpinned material remains inline.
  defp worker_order_body(%{"_brief_source" => _source}),
    do: mounted_mandate("Ton ordre de mission est", @brief_mount, ". Lis-le : c'est ta tâche.")

  defp worker_order_body(issue), do: issue["body"] || ""

  # Name the mounted file, not a pin for the agent to repeat. Runtime metadata carries the pin.
  # tail supplies its own separator so callers control the sentence continuation.
  defp mounted_mandate(lead, file, tail) do
    "#{lead} le fichier `~/issues/#{file}`, monté en lecture seule dans ton pod : le doc " <>
      "d'auteur figé pour toi, adressé par contenu — exactement ce qui a été écrit, rien à " <>
      "vérifier ni recalculer#{tail}"
  end

  # Human provenance remains on the ticket and in ops commit metadata.

  # A resolved brief replaces the body and retains its source for mount metadata.
  # Invalid or unreadable pointers return :criterion_unavailable; absent pointers stay inline.
  defp resolve_issue_brief(issue, repo, opts) do
    case Fleet.Layout.parse_brief_pointer(issue["body"]) do
      :none ->
        {:ok, issue}

      {:ok, {ref, sha}} ->
        case Fleet.Workflow.BriefArtifact.resolve(
               repo,
               ref,
               sha,
               Keyword.take(opts, [:ops_root])
             ) do
          # Retain the source for the mount; the order text itself does not cite the pin.
          {:ok, content} ->
            {:ok, issue |> Map.put("body", content) |> Map.put("_brief_source", {ref, sha})}

          {:error, reason} ->
            {:error, {:criterion_unavailable, {:brief_pointer, reason}}}
        end

      {:error, reason} ->
        {:error, {:criterion_unavailable, {:brief_pointer, reason}}}
    end
  end

  # Prefer a self-contained Criteria document over the producer's procedural brief.
  # Without a criteria pointer, fall back to brief resolution; a broken criteria pointer is an error.
  defp resolve_judge_criterion(issue, repo, opts) do
    case Fleet.Layout.parse_criteria_pointer(issue["body"]) do
      {:ok, {ref, sha}} ->
        case Fleet.Workflow.BriefArtifact.resolve(
               repo,
               ref,
               sha,
               Keyword.take(opts, [:ops_root])
             ) do
          {:ok, content} ->
            {:ok, issue |> Map.put("body", content) |> Map.put("_brief_source", {ref, sha})}

          {:error, reason} ->
            {:error, {:criterion_unavailable, {:criteria_pointer, reason}}}
        end

      :none ->
        resolve_issue_brief(issue, repo, opts)

      {:error, reason} ->
        {:error, {:criterion_unavailable, {:criteria_pointer, reason}}}
    end
  end

  defp build_judge_brief(role, forge, repo, number, forge_opts, route, opts) do
    with {:ok, outputs} <- judge_outputs(forge, repo, number, forge_opts) do
      step_judge_brief(
        role,
        forge,
        repo,
        number,
        forge_opts,
        route,
        opts,
        outputs |> with_ci(opts) |> with_gray_zone(opts)
      )
    end
  end

  # CI success reports execution, not coverage or proof; name the contexts for the judge to assess.
  # Missing, non-success or malformed facts add no section here.
  defp with_ci(outputs, opts) do
    case Keyword.get(opts, :ci_fact) do
      %{state: :success, sha: sha} = fact when is_binary(sha) ->
        Map.put(outputs, "ci", ci_line(sha, Map.get(fact, :contexts, [])))

      _ ->
        outputs
    end
  end

  # Give the arbiter the existing findings and policy so it can arbitrate their contradiction.
  defp with_gray_zone(outputs, opts) do
    case Keyword.get(opts, :gray_zone) do
      %{findings: findings, policy: policy} when map_size(findings) > 0 ->
        Map.put(outputs, "zone_grise", gray_zone_line(findings, policy))

      _ ->
        outputs
    end
  end

  @doc false
  # Exposed for focused rendering tests without constructing the full forge-backed brief.
  @spec gray_zone_line_for_test(keyword()) :: String.t()
  def gray_zone_line_for_test(opts) do
    %{findings: f, policy: p} = Keyword.fetch!(opts, :gray_zone)
    gray_zone_line(f, p)
  end

  defp gray_zone_line(findings, policy) do
    seuil =
      case policy do
        %{"block_at" => at} when is_binary(at) -> at
        _ -> "inconnu"
      end

    "ARBITRAGE — les juges ont rendu un AVIS FAVORABLE sur ce livrable, et la carte du projet le " <>
      "refuse : au moins un " <>
      "finding rendu par un juge atteint la sévérité `#{seuil}`, seuil au-delà duquel cette " <>
      "criticité ne tolère rien. Personne ne s'oppose au livrable ; ce sont une approbation et une " <>
      "mesure, du MÊME juge, qui se contredisent. Tu es convoqué pour trancher CETTE " <>
      "contradiction — pas pour rendre un troisième avis sur le travail. Approuver signifie « la " <>
      "mesure est juste et ce livrable peut vivre avec » ; refuser signifie « la courbe a raison, " <>
      "le producteur doit reprendre ». Les rapports, par rôle : #{findings_digest(findings)}"
  end

  # Summarize findings rather than duplicating full review reports.
  defp findings_digest(findings) do
    Enum.map_join(findings, " ; ", fn {role, payload} ->
      "`#{role}` (#{digest_detail(payload)})"
    end)
  end

  # Keep unreadable reports, measured-empty reports and missing measurements distinct.
  defp digest_detail(%{"findings_unreadable" => true}),
    do: "a mesuré, mais sa charge est ILLISIBLE — c'est ce trou qui bloque, pas un finding"

  defp digest_detail(payload) when is_map(payload) do
    case Map.get(payload, "findings") do
      [] -> "a mesuré, aucun finding"
      list when is_list(list) -> severity_tally(list)
      _ -> "charge de forme inattendue"
    end
  end

  defp digest_detail(_), do: "pas de mesure"

  # Nonempty findings with no readable severity must not be reported as zero findings.
  defp severity_tally(list) do
    case list |> Enum.map(& &1["severity"]) |> Enum.reject(&is_nil/1) |> Enum.frequencies() do
      sev when map_size(sev) == 0 -> "#{length(list)} finding(s), sévérités non lisibles"
      sev -> Enum.map_join(sev, ", ", fn {s, n} -> "#{n}× #{s}" end)
    end
  end

  defp ci_line(sha, contexts) do
    "CI VERTE sur `#{String.slice(sha, 0, 8)}` — le rail machine a rendu VERT. Ce fait t'est " <>
      "FOURNI : ne le re-derive pas, ne le re-execute pas. #{ran_line(contexts)} " <>
      "⚠ VERT ne veut pas dire PROUVE : il dit qu'un runner a repondu, pas que ce qu'il a " <>
      "execute couvre le critere du brief. Ton travail commence exactement la — couverture du " <>
      "critere, assertions creuses, oracles qui n'assertent rien, faux-verts. Et si ce qui a " <>
      "tourne ne prouve rien du livrable, cette absence EST une constatation a rendre."
  end

  # An empty contexts list cannot substantiate a list of executed checks.
  defp ran_line([]), do: "(les contextes executes n'ont pas pu etre lus.)"

  defp ran_line(contexts),
    do: "Ce qui a tourne, exactement : #{Enum.map_join(contexts, ", ", &"`#{&1}`")}."

  # Nonempty predecessor maps are the deliverable. Returned errors defer judgment;
  # all other values fall back to code, including :none, empty maps and unexpected shapes.
  defp judge_outputs(forge, repo, number, forge_opts) do
    case forge.get_predecessor_result(repo, number, forge_opts) do
      {:ok, result} when is_map(result) and map_size(result) > 0 -> {:ok, result}
      {:error, reason} -> {:error, {:criterion_unavailable, {:predecessor, reason}}}
      _ -> {:ok, git_native_outputs()}
    end
  end

  # Without a predecessor payload, point at branch code rather than an empty deliverable.
  # Review clones are single-branch: compare with bootstrap's lcars/base, not origin/main.
  # The order must require stopping if this base is absent.
  defp git_native_outputs do
    %{
      "livrable" =>
        "git-native — le code à juger est checkout dans TON workspace. Le clone est mono-branche : " <>
          "ni `main` ni la branche de base ne sont là sous leur nom. Ta base est le ref `lcars/base`, " <>
          "posé par le runtime sur la base RÉELLE de ce travail. Le diff de la PR = " <>
          "`git diff lcars/base...HEAD` (trois points — point de divergence auto). `git log lcars/base..HEAD` " <>
          "pour les commits, `git show <sha>` pour le détail. Si `lcars/base` est absent, ne bricole PAS " <>
          "une comparaison de remplacement : dis que la base n'est pas matérialisée et arrête-toi. " <>
          "Juge ces changements contre le critère ci-dessous."
    }
  end

  defp step_judge_brief(role, forge, repo, number, forge_opts, route, opts, outputs) do
    {workflow_map_name, step} =
      case route do
        {p, s} -> {p, s}
        _ -> {nil, role}
      end

    # GateBrief frames request as context to evaluate. A failed get_issue read is an error;
    # a successfully read issue with no body proceeds with an empty criterion.
    # These instructions do not mechanically guarantee the judge's behavior.
    case forge.get_issue(repo, number, forge_opts) do
      {:ok, issue} ->
        # Resolve the fetched criterion independently, preferring Criteria over Brief.
        with {:ok, issue} <- resolve_judge_criterion(issue, repo, opts) do
          # Export the resolved criterion source with the rendered order.
          {:ok,
           Fleet.Workflow.GateBrief.build(%{
             step: step,
             workflow_map_id: workflow_map_name,
             gate: nil,
             outputs: outputs,
             request: judge_criterion(issue)
           }), Map.get(issue, "_brief_source")}
        end

      {:error, reason} ->
        {:error, {:criterion_unavailable, reason}}
    end
  end

  # The judge reads the mounted criterion but does not independently verify its pin.
  # Runtime resolution and exported mount metadata bind the file; the caller must materialize it.
  # Explicit read-and-evaluate wording complements GateBrief's do-not-execute framing.
  defp judge_criterion(%{"_brief_source" => _source}) do
    mounted_mandate(
      "Ton critère de succès est",
      @criteria_mount,
      " : lis-le, rien à vérifier. Juge le livrable contre lui ; ne l'exécute pas, il décrit un " <>
        "travail déjà livré. Tu n'as pas à citer sa version — le runtime la grave lui-même, il " <>
        "l'a résolue et il la connaît."
    )
  end

  defp judge_criterion(issue), do: Map.get(issue, "body")

  # Brief judges evaluate executability before production: the brief goes in outputs,
  # with subject :brief and no request. GateBrief supplies the common decision contract.
  defp build_brief_review_brief(role, issue, forge, repo, number, forge_opts, route, opts) do
    # Prefer the entry body; fallback fetch and pointer resolution may degrade to an empty string.
    brief = issue_body_in_hand_or_fetch(issue, forge, repo, number, forge_opts, opts)

    {workflow_map_name, step} =
      case route do
        {p, s} -> {p, s}
        _ -> {nil, role}
      end

    # The entry source selects mounted versus inline output; a fallback fetch does not
    # propagate its resolved source back into the entry issue.
    outputs =
      case Map.get(issue, "_brief_source") do
        {_ref, _sha} -> %{"brief_mount" => @brief_mount}
        _ -> %{"brief" => brief}
      end

    Fleet.Workflow.GateBrief.build(%{
      step: step,
      workflow_map_id: workflow_map_name,
      gate: nil,
      subject: :brief,
      outputs: outputs
    })
  end

  # Fallback read/resolution errors become empty content here, unlike entry-pointer failures.
  defp issue_body_in_hand_or_fetch(issue, forge, repo, number, forge_opts, opts) do
    case Map.get(issue, "body") do
      body when is_binary(body) and body != "" ->
        body

      _ ->
        with {:ok, fetched} <- forge.get_issue(repo, number, forge_opts),
             {:ok, resolved} <- resolve_issue_brief(fetched, repo, opts) do
          Map.get(resolved, "body") || ""
        else
          _ -> ""
        end
    end
  end
end
