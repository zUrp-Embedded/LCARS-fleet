defmodule Fleet.Pilot.BriefBuilder do
  @moduledoc """
  Authority over the FORMAT of briefs: worker / judge / brief-review / rework, plus the
  eng voice instructions. `StepDispatcher` CALLS (it chooses WHICH brief based on the forge state),
  it does not FORM the brief itself. (No conflict-resolution brief — merge conflicts are
  ESCALATED to the architect; the forge-blind pod cannot rebase.)

  Judge-ness (and a judge's target) is a SECURITY property: it is NEVER inferred by
  omission of a clause. `build_brief/9` is a TOTAL sum and fail-loud on out-of-vocab `brief_kind`/`judge_target`
  (raise) — a judge must NEVER receive an executable issue body. A judge's brief is
  DEFUSED (`Fleet.Workflow.GateBrief`: `request` rendered as context, not as an executable instruction).

  `forge` is an injected ARG (seam) — never hard-wired. The other deps (`Fleet.CapProfile`,
  `Fleet.Workflow.GateBrief`, `Fleet.Credentials.ForgeIdentity`) are called as-is.
  """

  require Logger

  # Rework brief: the PRODUCER (engineer) resumes on a REQUEST_CHANGES PR.
  # CARRIES THE SAME git-native instruction as `build_worker_brief` (otherwise `:no_deliverable_commit`: the
  # rework "re-pushes" but the pod is FORGE-BLIND and without the order to COMMIT it delivers nothing —
  # twin of the producer brief). The pod fixes + commits LOCALLY; the SYSTEM pushes (forge
  # boundary). Trailer mandatory (push gate).
  #
  # INFO STARVATION, rework half: without the BODY of the REQUEST_CHANGES reviews,
  # "fix according to the review" is hollow — the forge-blind pod does NOT see the review → it guesses
  # blind (a cautious eng refuses to guess → `blocked_dep` → wedge). We read the feedback on the forge
  # (the runtime, not the pod: forge boundary preserved) and inject it. If the read fails / no body,
  # we fall back to the generic instruction (the pod still has the cloned PR + its code).
  @doc """
  Brief of a PRODUCER resuming on a PR that carries REQUEST_CHANGES, conflict sections included.

  Carries the same git-native commit instruction as the initial work order: the pod is forge-blind,
  so a rework told only to "re-push" delivers nothing. `opts[:conflict]` selects the voice — the
  OWNER resumes work the judges approved, an OUTSIDER arrives on someone else's branch after that
  budget ran out, and telling the second "ton brief est INCHANGÉ" names a brief it never had.
  """
  def rework_brief(role, forge, repo, pr, forge_opts, _route, opts \\ []) do
    # The eng-voice prose (OUTGOING info, twin of the incoming info starvation) lives IN the
    # template (F-23): the summary posted on the PR is the producer's only voice for the human.
    Fleet.Workflow.BriefTemplate.render("work-order-rework", %{
      "role" => role,
      "pr" => to_string(pr),
      "feedback_section" =>
        conflict_section(opts) <> render_rework_feedback(forge, repo, pr, forge_opts)
    })
  end

  # Conflict-rework lead section (`conflict: true` — Remediation tier 1): the jury APPROVED,
  # main simply moved under the branch (sibling bricks landed). FR: agent-facing work-order
  # prose, same stance as the feedback sections. HONEST about the refs: the pod cannot fetch
  # (forge-blind) — if its workspace's `origin/main` is stale and un-refreshable, the doctrine
  # answer is `blocked`, never a guessed resolution.
  # Two voices for ONE mechanic. The steps are identical (merge, resolve, commit, the system pushes,
  # the jury re-judges); what differs is WHO is being addressed. The producer resumes work it wrote
  # and that the judges approved. The exception pass arrives on someone else's branch after that
  # budget ran out — telling it "ton brief est INCHANGÉ" names a brief it never had, and invites it
  # to guess at an intention it does not hold.
  #
  # The axis is OWNER vs OUTSIDER, never a role name: it held when the outsider was the gatekeeper
  # and it holds now that it is `chief`.
  defp conflict_section(opts) do
    case Keyword.get(opts, :conflict, false) do
      false -> ""
      :exception -> exception_conflict_section(Keyword.fetch!(opts, :base_branch))
      _producer -> producer_conflict_section(Keyword.fetch!(opts, :base_branch))
    end
  end

  # ⚠ `main` ETAIT ECRIT EN DUR DANS UNE PROCEDURE DONNEE A UN AGENT. La plomberie, elle, connaît la
  # vraie base depuis toujours (`:pr_base_branch`, pose par `dispatch_review` depuis `pr.base.ref`, et
  # c'est deja elle qui choisit le worktree de resolution). Sur une PR qui ne vise pas la face code,
  # le producteur recevait donc une commande INEXECUTABLE — et s'il improvisait un `fetch main`, il
  # composait son livrable contre la mauvaise face.
  #
  # `fetch!` et non `get` : ce chemin n'existe que sous `dispatch_review`, qui pose toujours la base.
  # Une absence serait un bypass, et un brief qui invente une branche coute plus cher qu'un refus.
  #
  # ⚠ ET LE NOM CORRIGE NE SUFFISAIT PAS (6-135). La procedure disait `git merge origin/<base>`, avec
  # la BONNE base — mais `RoleDispatch` pose `base_branch: head` pour tout pod de review, donc son
  # clone est `--branch <head> --single-branch` et `origin/<base>` n'y est PAS. La commande restait
  # inexecutable ; seule la raison avait change. Elle vise desormais `lcars/base`, le ref que le
  # bootstrap rapatrie sur la base REELLE de la PR — et son garde-fou dit maintenant l'ABSENCE
  # (l'etat possible) et non la peremption (celui qu'on avait suppose).
  #
  # La prose garde le NOM de la face : c'est ce qui dit au producteur contre quoi il compose, et
  # c'est aussi ce qui distingue une base qui suit la PR d'un ref renomme.
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

  # Renders the feedback of the REQUEST_CHANGES reviews (verdict body of each judge) as an actionable
  # block.
  #
  # F-C083 again, in its OTHER shape. The seam is three-valued (`{:ok, [_|_]} | {:ok, []} |
  # {:error, _}`) and a single `_ -> ""` clause used to collapse the last two: a transient read
  # failure produced the SAME brief as "this PR carries no actionable feedback". The producer then
  # reworks blind while the PR holds detailed REQUEST_CHANGES it never sees — and, believing there
  # was nothing to address, it plausibly ships the same defect and burns another review cycle.
  #
  # The remedy is NOT fail-closed here, and the asymmetry with `judge_outputs/4` is the point: a
  # judge given the wrong matter renders a WRONG VERDICT, so it must never run; a producer without
  # its feedback merely works WORSE. Deferring every rework on a transient forge hiccup would wedge
  # the rail to avoid a degradation. So we proceed — and we make the gap VISIBLE on both sides: a
  # warning on the operator rail, and a line in the brief itself, because the pod cannot read our
  # logs and an unexplained absence is exactly what made this defect silent.
  defp render_rework_feedback(forge, repo, pr, forge_opts) do
    case forge.change_request_feedback(repo, pr, forge_opts) do
      {:ok, [_ | _] = feedbacks} ->
        sections =
          Enum.map_join(feedbacks, "\n\n", fn fb ->
            "### Review de `#{fb["login"]}`\n#{fb["body"]}"
          end)

        "## Feedback de review à traiter (REQUEST_CHANGES)\n\n#{sections}"

      {:ok, []} ->
        ""

      {:error, reason} ->
        # Rail prefix = the FACADE this module was extracted from (StepDispatcher), not its own
        # last segment: extracting a cluster must never fragment the trace an operator greps.
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

  # The shape of the brief is a property of the role (cap-profile `brief_kind`), NOT a magic
  # role name. `judge` → defused GateBrief; everything else (`worker`, default) → issue body.
  #
  # Returns `{:ok, brief, kind}` (`kind` = the EFFECTIVE `"worker" | "judge"` — step override
  # resolved, so the caller routes the physical object without re-deriving judge-ness) |
  # `{:error, {:criterion_unavailable, reason}}`. The error is reachable ONLY on
  # the DELIVERABLE-judge path, when the criterion (issue body) can't be READ from the forge (F-C083:
  # read-error ≠ absence → the dispatch DEFERS rather than spawn a criterion-less judge). Out-of-vocab
  # `brief_kind`/`judge_target` still `raise` (structural config bug, fail-loud).
  @doc """
  Builds the brief a pod receives, and its `brief_kind` — the SUM over the four shapes.

  TOTAL and fail-loud on an out-of-vocabulary `brief_kind`/`judge_target`: judge-ness is a security
  property, so it is never inferred by the omission of a clause. A judge that received an executable
  issue body would produce instead of judging, and nothing downstream distinguishes the two.

  `{:error, {:criterion_unavailable, _}}` when the judging criterion cannot be read: a judge without
  a criterion approves, which is the false green this rail fail-closes against everywhere else.
  """
  @spec build_brief(
          Fleet.CapProfile.t(),
          String.t(),
          module(),
          String.t(),
          integer(),
          map(),
          keyword(),
          {String.t(), String.t()} | term(),
          map(),
          keyword()
        ) :: {:ok, String.t(), String.t()} | {:error, {:criterion_unavailable, term()}}
  def build_brief(
        profile,
        role,
        forge,
        repo,
        number,
        issue,
        forge_opts,
        route,
        step_spec,
        opts \\ []
      ) do
    # POINTER resolution FIRST (E4): a consequential brief lives as a doc committed in
    # ops; the ticket body then carries summary + `Brief: <ref> @ <commit>` (composed by
    # the delegation tool, notation in Fleet.Layout). Resolved HERE, once, for every path
    # (worker order, brief judge, deliverable-judge criterion): the pinned doc BECOMES the
    # brief downstream. Unresolvable pointer → DEFER (`:criterion_unavailable` — the existing
    # rail; never a guessed brief). `:none` → the body IS the brief (inline PoC path, both
    # channels honest, same downstream).
    with {:ok, issue} <- resolve_issue_brief(issue, repo, opts) do
      do_build_brief(
        profile,
        role,
        forge,
        repo,
        number,
        issue,
        forge_opts,
        route,
        step_spec,
        opts
      )
    end
  end

  defp do_build_brief(
         profile,
         role,
         forge,
         repo,
         number,
         issue,
         forge_opts,
         route,
         step_spec,
         opts
       ) do
    # The STEP's `brief_kind` (workflow_map) TAKES PRECEDENCE over the profile's (per-step override) — it
    # drives a worker profile as a JUDGE for one step without duplicating the profile. NO canon role uses
    # it today: `scoper` was its only user and became a NATIVE judge at the 2026-07-30 split (the override
    # described a dual nature it never had). The mechanism stays because it is the generic way to answer
    # "this step judges", and removing it would force a duplicate profile the day one is needed.
    # ABSENT at the step → profile default
    # (itself "worker" by default, fail-safe) via the `||`: absence is NOT an anomaly. What
    # follows handles the PRESENT-but-out-of-vocab value, distinct from absence.
    kind = Map.get(step_spec, "brief_kind") || Fleet.CapProfile.brief_kind(profile)

    # TOTAL sum and fail-loud. Judge-ness (and a judge's target) is a
    # SECURITY property: it is NEVER inferred by omission of a clause. An out-of-vocab kind/target (typo, or
    # value from a future vocabulary) MUST NOT silently fall back to worker — otherwise a judge
    # role would receive an EXECUTABLE issue body (active brief) instead of a defused brief. We
    # reject loudly (raise) rather than build a dangerous brief silently.
    case {kind, Map.get(step_spec, "judge_target")} do
      # BRIEF judge (judge_target:brief) → judges the issue.body (executable?), NOT a deliverable
      # (no code upstream). The brief is in hand (poller-listed) → no criterion read-error path.
      {"judge", "brief"} ->
        {:ok, build_brief_review_brief(role, issue, forge, repo, number, forge_opts, route, opts),
         "judge"}

      # DELIVERABLE judge: judge_target ABSENT (nil → canonical default) or explicit "deliverable" →
      # judges a deliverable (PR). Already TYPED {:ok, brief} | {:error, {:criterion_unavailable, _}}
      # (F-C083: a read-error on the criterion DEFERS, it never yields a criterion-less judge).
      {"judge", target} when target in [nil, "deliverable"] ->
        with {:ok, brief} <- build_judge_brief(role, forge, repo, number, forge_opts, route, opts) do
          {:ok, brief, "judge"}
        end

      # judge_target PRESENT but outside {brief, deliverable} → anomaly: we don't guess the target.
      {"judge", other} ->
        raise ArgumentError,
              "judge_target #{inspect(other)} out of vocabulary {brief, deliverable} — a judge's target is not inferred"

      {"worker", _} ->
        {:ok, build_worker_brief(role, issue), "worker"}

      # kind ∉ {worker, judge} (brief_kind present but out-of-vocab) → fail-loud.
      {other, _} ->
        raise ArgumentError,
              "brief_kind #{inspect(other)} out of vocabulary {worker, judge} — judge-ness is not inferred"
    end
  end

  # Producer brief = a structured WORK ORDER document (template `work-order-build`, F-23/E1:
  # same visual family as the gate-briefs — the prose lives in priv, the code fills slots):
  # the issue's brief + the git-native DELIVERY instruction. Without the delivery contract,
  # the pod "submits the contents" instead of COMMITTING → the git_native publish finds no
  # commit (`:no_deliverable_commit`). The pod commits LOCALLY; the SYSTEM pushes + opens the
  # PR (forge-blind).
  #
  # NO SIGNATURE SLOT (removed 2026-08-05). The role trailer is appended MECHANICALLY by a
  # `prepare-commit-msg` hook installed at clone time, so the pod has no action to take on it — and
  # a thing an agent has no action to take on does not belong in its world. The order used to demand
  # it, which cost a full producer run the day a line landed mid-message; then it briefly ANNOUNCED
  # it, which was the same mistake one step quieter. Minimal world: only what it needs, and all of
  # what it needs.
  defp build_worker_brief(role, issue) do
    Fleet.Workflow.BriefTemplate.render("work-order-build", %{
      "role" => role,
      "issue" => to_string(issue["number"] || "?"),
      "brief_body" => issue["body"] || "",
      "brief_source" => brief_source_line(issue)
    })
  end

  # F-25 — the order CITES its source: a pointer-resolved brief names the authored doc
  # (`ref @ commit`, the walkable link into ops history); an inline brief says so
  # honestly (never a fabricated citation). FR: rendered to the human eye via the forge.
  defp brief_source_line(%{"_brief_source" => {ref, sha}}),
    do: "`#{ref} @ #{sha}` (doc d'auteur commité dans ops — version pinnée ci-dessus)"

  defp brief_source_line(_issue), do: "brief inline du ticket (pas de doc d'auteur séparé)"

  # A **judge** pod must know WHAT
  # to judge AND how to render its verdict. We reuse the canonical brief `Fleet.Workflow.GateBrief`
  # (context + deliverable + question + **`gate-decision-v1.json` contract + canonical
  # options**). The `result_K` to judge is read from the previous step_run's comment (engraved by
  # StepRunCompleter); the pod stays forge-blind (the runtime reads the comment, no
  # clone).
  # The brief-pointer resolution (E4) applied to a ticket body: `:none` → body unchanged
  # (inline brief); a well-formed pointer → the PINNED doc replaces the body (the doc IS the
  # brief — summary stays human-facing on the forge); unresolvable/invalid → DEFER via the
  # criterion rail (the pointer can lie, git cannot; never a guessed brief).
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
          # F-25 — the resolved pointer is KEPT alongside the pinned content: the work order
          # cites its source doc (`ref @ commit`) instead of consuming the link silently.
          {:ok, content} ->
            {:ok, issue |> Map.put("body", content) |> Map.put("_brief_source", {ref, sha})}

          {:error, reason} ->
            {:error, {:criterion_unavailable, {:brief_pointer, reason}}}
        end

      {:error, reason} ->
        {:error, {:criterion_unavailable, {:brief_pointer, reason}}}
    end
  end

  # THE JUDGE'S CRITERION IS THE CRITERIA DOC, NOT THE BRIEF — and that is the whole fix. A single
  # authored brief used to serve both the producer and the judge, so the judge received the
  # producer's PROCEDURAL order, which may reference the workshop the judge does not mount. The arch
  # now authors a separate `criteria` (declarative, self-contained), pointed to by `Criteria:`.
  #
  # When that pointer is present, the judge's criterion is the criteria doc, resolved and pinned —
  # written into `_brief_source` so `judge_criterion/1` renders it and cites ITS sha, unchanged.
  # Absent (an old ticket, a workshop ticket, a degraded materialize) → the judge falls back to the
  # brief, exactly as before: no regression, the split is additive at the consumer.
  #
  # Read-error fail-closes (`criterion_unavailable`) — a judge without its criterion approves, the
  # false GREEN this rail refuses everywhere.
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

  # THE MACHINE FACT, HANDED TO THE JUDGE — the other half of `CiGate`. The gate refuses to summon
  # a jury on red; when it summons, it says on WHAT the rail already ruled. Without this line the
  # judge re-derives "does it run?" from a diff it cannot execute, i.e. it guesses — and the whole
  # point of a runner is that guessing stops.
  #
  # It is NOT the judge's verdict. `success` answers "it executes"; the judge answers "it proves"
  # — coverage of the brief, hollow assertions, oracles that assert nothing. Naming the boundary in
  # the brief itself is what keeps a green CI from being read as a green review.
  #
  # ⚠ ET LA PHRASE ELLE-MEME FRANCHISSAIT LA FRONTIERE QUE CE PARAGRAPHE POSE : elle disait « le
  # rail machine a EXECUTE **la preuve** ». Le rail livre avec le template de projet execute deux
  # `echo` — ni build, ni test, ni assertion, et il le dit dans son propre en-tete. Sur tout projet
  # fraichement onboarde, le juge recevait donc « une preuve a ete executee » alors qu'aucune ne
  # l'avait ete, et la seule chose que `success` etablit est qu'un runner a repondu vert (6-140).
  #
  # LES CONTEXTES SONT LA REPONSE HONNETE. On ne peut pas verifier qu'un harnais attendu a tourne ;
  # on peut nommer ce qui A tourne, et laisser le juge conclure : un `CI / no-harness-yet` n'est
  # plus indistinguable d'une suite.
  #
  # ⚠ CE PARAGRAPHE DISAIT « RIEN NE DECLARE LE HARNAIS ATTENDU D'UN PROJET ». PLUS VRAI DEPUIS LE
  # 2026-08-20 : le template porte une section `## Harness` — les chemins qui sont de la PREUVE — et
  # la sonde `probe-test-relevance` s'en sert. Elle ne repond PAS a la meme question que ce fait-ci :
  # `success` dit « ca s'execute », la sonde dit « la suite s'apercoit-elle de l'absence du code
  # livre ». Les deux restent distincts, et leurs rails aussi — le fait CI voyage POUSSE dans ce
  # brief, la sonde est TIREE par le juge (arbitrage Q1). L'un ne peut pas charger le tick, l'autre
  # ne peut pas bloquer le pipeline.
  #
  # Absent key = the card does not require the CI (`spec.ci: ignore`): we add NOTHING rather than
  # writing "CI: unknown", which a judge would rightly read as a fact about the code.
  defp with_ci(outputs, opts) do
    case Keyword.get(opts, :ci_fact) do
      %{state: :success, sha: sha} = fact when is_binary(sha) ->
        Map.put(outputs, "ci", ci_line(sha, Map.get(fact, :contexts, [])))

      _ ->
        outputs
    end
  end

  # C3 — LES MESURES QUE L'ARBITRE DOIT TRANCHER, et rien d'autre. Threadées comme le fait CI par
  # `VerdictException` : le gate a lu les findings et la courbe, le brief les CITE. Sans elles, un
  # gatekeeper convoqué sur une zone grise ne saurait pas ce qui est gris — il re-jugerait le
  # livrable à l'aveugle et rendrait un troisième avis au lieu d'arbitrer les deux existants.
  defp with_gray_zone(outputs, opts) do
    case Keyword.get(opts, :gray_zone) do
      %{findings: findings, policy: policy} when map_size(findings) > 0 ->
        Map.put(outputs, "zone_grise", gray_zone_line(findings, policy))

      _ ->
        outputs
    end
  end

  @doc false
  # PUBLIC pour le test, et la propriété qu'il tient n'est observable que d'ici : le brief de
  # l'arbitre est composé en profondeur (outputs → sections → rendu), et la seule chose qui compte
  # dans cette ligne est qu'elle distingue trois états d'un rapport de juge. La rendre atteignable
  # coûte un `@doc false` ; la tenir par le brief complet coûterait une couture de forge entière.
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

  # Le DIGEST, pas les rapports : leur substance vit dans les reviews de la PR, que le pod lit déjà.
  # Recopier ici des findings complets ferait du brief une seconde source de la même donnée — et
  # celle qu'on lit n'est jamais celle qu'on a corrigée.
  defp findings_digest(findings) do
    Enum.map_join(findings, " ; ", fn {role, payload} ->
      "`#{role}` (#{digest_detail(payload)})"
    end)
  end

  # TROIS ÉTATS, PAS DEUX — et le troisième est celui que l'arbitre doit pouvoir distinguer.
  # La version d'avant rangeait « ce juge a mesuré et n'a RIEN trouvé » sous « aucune sévérité
  # lisible », qui se lit comme un défaut de sa charge. Mesuré au banc le 2026-08-19 (PR71) : le
  # reviewer avait rendu `{"findings": [], "severity_max": "none"}` — une mesure valide, explicite,
  # et le brief du gatekeeper la lui a présentée comme illisible. Un arbitre convoqué pour trancher
  # une contradiction entre une approbation et une mesure ne peut pas travailler si le rail lui
  # décrit une mesure claire comme du bruit.
  # L'arbitre doit savoir qu'il arbitre sur un TROU, pas sur une mesure. C'est le seul état où la
  # zone grise ne vient pas d'un désaccord entre un juge et la carte, mais d'une charge illisible.
  defp digest_detail(%{"findings_unreadable" => true}),
    do: "a mesuré, mais sa charge est ILLISIBLE — c'est ce trou qui bloque, pas un finding"

  defp digest_detail(payload) when is_map(payload) do
    case Map.get(payload, "findings") do
      [] ->
        "a mesuré, aucun finding"

      list when is_list(list) ->
        case list |> Enum.map(& &1["severity"]) |> Enum.reject(&is_nil/1) |> Enum.frequencies() do
          sev when map_size(sev) == 0 -> "#{length(list)} finding(s), sévérités non lisibles"
          sev -> Enum.map_join(sev, ", ", fn {s, n} -> "#{n}× #{s}" end)
        end

      _ ->
        "charge de forme inattendue"
    end
  end

  defp digest_detail(_), do: "pas de mesure"

  defp ci_line(sha, contexts) do
    "CI VERTE sur `#{String.slice(sha, 0, 8)}` — le rail machine a rendu VERT. Ce fait t'est " <>
      "FOURNI : ne le re-derive pas, ne le re-execute pas. #{ran_line(contexts)} " <>
      "⚠ VERT ne veut pas dire PROUVE : il dit qu'un runner a repondu, pas que ce qu'il a " <>
      "execute couvre le critere du brief. Ton travail commence exactement la — couverture du " <>
      "critere, assertions creuses, oracles qui n'assertent rien, faux-verts. Et si ce qui a " <>
      "tourne ne prouve rien du livrable, cette absence EST une constatation a rendre."
  end

  # On ne fabrique pas une liste : si le seam n'a pas su la donner, on le DIT plutot que d'ecrire
  # une phrase qui laisserait croire a une verification qu'on n'a pas faite.
  defp ran_line([]), do: "(les contextes executes n'ont pas pu etre lus.)"

  defp ran_line(contexts),
    do: "Ce qui a tourne, exactement : #{Enum.map_join(contexts, ", ", &"`#{&1}`")}."

  # F-C083 — READ-ERROR ≠ ABSENCE, applied to the PREDECESSOR read. The rule is stated 35 lines
  # below for the CRITERION read and was NOT applied here: a bare `_ -> nil` collapsed the seam's
  # three-valued contract (`{:ok, map} | :none | {:error, term}`) into two branches, so a TRANSIENT
  # forge failure landed in the git-native fallback. Consequence, and it is the worst shape a bug
  # can take here: the judge grades the BRANCH CODE instead of the payload its predecessor actually
  # produced — a verdict rendered on the wrong matter, silently, and INDISTINGUISHABLE from the
  # legitimate git-native case. Nothing downstream can catch it: the brief is well-formed, the judge
  # answers confidently, and the answer is about something else.
  #
  #   {:ok, non-empty}      the payload IS the deliverable
  #   :none / {:ok, %{}}    genuinely no predecessor → git-native, the CODE is the deliverable
  #   {:error, _}           fail-closed, exactly like the criterion: DEFER, never a blind judge
  defp judge_outputs(forge, repo, number, forge_opts) do
    case forge.get_predecessor_result(repo, number, forge_opts) do
      {:ok, result} when is_map(result) and map_size(result) > 0 -> {:ok, result}
      {:error, reason} -> {:error, {:criterion_unavailable, {:predecessor, reason}}}
      _ -> {:ok, git_native_outputs()}
    end
  end

  # GIT-NATIVE (no predecessor): the deliverable IS NOT a payload — it's the branch CODE. The judge
  # clones the feature-branch + has `Bash(git diff/log/show)` → we POINT it at its workspace instead
  # of giving it `{}` (on which it would fail-close `halt_wait_input`). Otherwise it judges emptiness
  # → infinite rework (the Reviewer can NEVER say `continue` on `{}`).
  # ⚠ CINQUIEME PORTEUR DE LA MEME INSTRUCTION, et le seul qui vive dans `lib/` — les quatre autres
  # sont le bloc SP et ses copies. Elle nommait `origin/main`, qui N'EST PAS dans le workspace d'un
  # juge : `RoleDispatch` pose `base_branch: head`, donc le clone est `--branch <head>
  # --single-branch`. Les deux commandes prescrites echouaient sur une revision inconnue (6-135).
  # `refs/lcars/base` est pose par le bootstrap sur la base REELLE, et il est le meme nom pour tous
  # les pods — c'est la condition pour qu'une instruction puisse le nommer sans dire « selon les cas ».
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

    # SUCCESS CRITERION = the issue body (the brief). Passed via `:request` → GateBrief renders it DEFUSED
    # (blockquote "CONTEXT — already handled, DO NOT execute" + banner "JUDGE, DO NOT PRODUCE" → the
    # executable state is made unrepresentable) → the judge knows AGAINST WHAT to judge. The risk of a
    # RE-executing judge targets a **base-worker** judge (noop profile, gatekeeper) that receives its brief
    # via `dispatch_gatekeeper` (step_run_consumer) which does NOT pass `request` — not affected here.
    # `build_judge_brief` only serves PERSONA judges (qualifier/reviewer, `subagent_template`
    # spec-reviewer/code-quality-reviewer): GateBrief knows how to render `request` defused.
    #
    # F-C083 — READ-ERROR ≠ ABSENCE. The criterion read can FAIL (forge unreachable/transient). A bare
    # `_ -> nil` clause would CONFLATE a read-error with a genuinely-empty body → the judge gets the
    # deliverable (diff via `outputs`) with NO criterion → a CRITERION-LESS approval (false GREEN). We FAIL-CLOSED on a
    # read-error: `{:error, {:criterion_unavailable, reason}}` → the dispatch DEFERS (skip, retry next tick),
    # it NEVER spawns a blind judge. A genuinely-absent body (`{:ok, issue}`, body nil) is a REAL (rare)
    # state → we PROCEED: the judge still has the diff, the empty criterion is the arch's degenerate brief,
    # not a transient failure (a persona judge fail-closes `halt_wait_input` on emptiness, it does not RE-build).
    case forge.get_issue(repo, number, forge_opts) do
      {:ok, issue} ->
        # The criterion goes through the SAME pointer resolution as the dispatch entry (E4):
        # a pointer-ticket's criterion is the PINNED doc, never the pointer line itself. The judge
        # prefers the `Criteria:` doc (self-contained, authored for it); it falls back to the brief
        # only when no criteria was authored.
        with {:ok, issue} <- resolve_judge_criterion(issue, repo, opts) do
          {:ok,
           Fleet.Workflow.GateBrief.build(%{
             step: step,
             workflow_map_id: workflow_map_name,
             gate: nil,
             outputs: outputs,
             request: judge_criterion(issue)
           })}
        end

      {:error, reason} ->
        {:error, {:criterion_unavailable, reason}}
    end
  end

  # THE CRITERION TRAVELS AS TEXT, and the address travels beside it. The dedup this used to do —
  # cite the doc, let the judge `git show` it through a mounted ops — bought one copy and cost
  # the mount: every project pod had to carry the runtime's own record so that ONE role could read
  # ONE file out of it. The record is where what was asked and what was judged is kept; handing it
  # to every producer to save a paragraph is the wrong side of that trade.
  #
  # WHAT IS LOST, stated: the judge can no longer VERIFY that the text matches the sha. What
  # replaces it is that the runtime resolved the pin itself, at dispatch, and the sha stays in the
  # work item and on the forge — so a third party still audits the pairing. The pod stops being
  # able to check an address it could only ever check against a tree the architect writes into.
  #
  # DRIFT is not the risk it was either: the copy is made AT dispatch from the pinned object, not
  # frozen at authoring time, so it cannot lag the pointer the way a committed gate-brief could.
  #
  # This value lands in the `request` section, rendered under "CONTEXT — already handled, DO NOT
  # execute" — a defusing that is CORRECT (the doc is a brief; a judge that executes it produces
  # instead of judging), so the sentence says read-and-evaluate explicitly. A judge without a
  # criterion approves: that is the false GREEN this rail fail-closes against everywhere else.
  # THE CRITERION IS A MOUNTED FILE, READ — not inline text, trusted. When a pointer resolved
  # (`_brief_source` present), the spawner materialized the pinned doc at `~/issues/mandate.md` via
  # `git archive` at that sha: the judge READS its criterion from a content-addressed file, so what
  # it acts on is exactly what was authored — nothing to hash, nothing to trust. The inline text is
  # gone from the order; a pointer that resolved is always accompanied by its materialized mount
  # (both read the same ops worktree — resolve fail-closes the dispatch if it is unreachable, and
  # then there is no spawn to mis-mount).
  defp judge_criterion(%{"_brief_source" => {ref, sha}}) do
    "Ton critère de succès est le fichier `~/issues/mandate.md`, monté en lecture seule dans ton " <>
      "pod. C'est le doc d'auteur `#{ref}`, matérialisé à sa version pinnée `#{String.slice(sha, 0, 7)}` " <>
      "par `git archive` — adressé par contenu, donc exactement ce qui a été écrit : lis-le, rien à " <>
      "vérifier. Juge le livrable contre lui ; ne l'exécute pas, il décrit un travail déjà livré. " <>
      "Cite `#{String.slice(sha, 0, 7)}` dans ton verdict — l'adresse de ce que tu as jugé."
  end

  # Inline brief (degraded dispatch, no authored doc) → embedded as before: there is nothing else to
  # point at, and an invented citation would be worse than a copy.
  defp judge_criterion(issue), do: Map.get(issue, "body")

  # Brief of a BRIEF judge (brief-review, judge_target:brief). The scoper judges the BRIEF
  # (issue.body written by the arch) BEFORE the engineer sets off: executable without a new question? We
  # reuse the SAME GateBrief (gate-decision-v1 contract + canonical options) as the other judges — only
  # `subject: :brief` reframes the "thing to judge". The BRIEF goes into `outputs` (the thing TO JUDGE; ≠
  # build_judge_brief where outputs = the deliverable/code); no `request` (the executability criterion is
  # carried by the :brief framing). The judge is PRE-PR (no clone, no deliverable) → N0-consistent.
  defp build_brief_review_brief(role, issue, forge, repo, number, forge_opts, route, opts) do
    # The brief = the ISSUE body, ALREADY in hand AND already pointer-resolved (the entry
    # resolution of `build_brief`). Fallback fetch if body absent (robustness) — the fetched
    # body gets the same resolution, best-effort.
    brief = issue_body_in_hand_or_fetch(issue, forge, repo, number, forge_opts, opts)

    {workflow_map_name, step} =
      case route do
        {p, s} -> {p, s}
        _ -> {nil, role}
      end

    # THE BRIEF TRAVELS, the address travels WITH it. This used to send only `{ref, sha}` and let
    # the judge read the doc through a mounted ops — which is what made that mount necessary
    # on every project pod. Sending the text costs a paragraph; the mount cost every producer a
    # read handle on the record of what was asked of it and what was judged of its work.
    #
    # Both keys when a pin exists: the text is WHAT to judge, the pin is what to CITE. Keeping the
    # pin is not decoration — it is how a third party ties a verdict back to a version, from the
    # forge, without the pod having had to hold the tree.
    outputs =
      case Map.get(issue, "_brief_source") do
        {ref, sha} -> %{"brief" => brief, "brief_ref" => ref, "brief_sha" => sha}
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

  # Body of the issue ALREADY listed by the poller → used directly (pointer-resolved at the
  # `build_brief` entry); fetch ONLY as a fallback (body absent/empty — defensive). The
  # FETCHED body gets the pointer resolution too, best-effort: an unresolvable pointer here
  # degrades to "" (the existing degenerate-empty path — the persona judge fail-closes
  # `halt_wait_input`, never judges the pointer line as prose).
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
