defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGate do
  @moduledoc """
  The CI verdict as a PRE-CONDITION of summoning the jury.

  WHY THIS EXISTS. Without it the machine rail and the judgement rail never meet before the spend:
  the runner posts a state on the head sha, and the first reader is
  `Remediation.reconverge_policy/3`, at the very END — after the forge refuses the merge. That
  reading is correct and it stays; it is simply the LAST net, and the most expensive place to learn
  that the code does not build, since the jury has already run on red.

  WHAT IT IS NOT. It is not "the judge reads the CI". A CI verdict is a MACHINE fact, per-sha,
  binary; a judge attests something else — that the proof PROVES (coverage of the brief, hollow
  assertions, false greens). Making an LLM relay a fact a machine attests better would break the
  forge-blind model of the judges for nothing. So the gate reads it, and the FACT TRAVELS INTO THE
  BRIEF (`BriefBuilder`): the judge is told "it executes and passes, your work starts after that".

  THE CARD GOVERNS, THE ENGINE STAYS AGNOSTIC (F-C061, same rule as the jury). `spec.ci` on the
  workflow map: `required` (the gate applies) or `ignore` (the pre-`ci` rail). MANDATORY, with no
  default on either side — the twin of `jury` and `max_rework_rounds`, which already carried the
  rule ("no hidden default in code: the map's author declares"). Any default makes a card that
  FORGOT indistinguishable from a card that DECIDED, and the silent branch would be the permissive
  one: the omission would wear the face of a decision to skip. The answer is not a better default
  but the ABSENCE of one, so that the un-declared card cannot be loaded at all.

  THE THREE STATES, AND WHY `:none` IS NOT `:success`. `ForgeClient.commit_ci_state/3` answers
  `:success | :pending | :failure | :none`, worst-of across contexts (two triggers -> two contexts
  on one sha). `:none` means NO status at all — a repo whose `ci.yml` was deleted, or a run not yet
  created. Collapsing it into `:success` would let "the rail never ran" wear the face of "the rail
  is green", which is the exact failure this module exists to end. Under `required` it is therefore
  treated as `:pending` — a bounded WAIT, never a pass.

  THE DEADLINE IS THE POINT, NOT A COMFORT. A `pending` with no runner waits forever, in silence.
  The bound is stateless on purpose: it compares the head
  commit's own date to now, so nothing has to be remembered between ticks and a new push (new sha,
  new date) restarts the clock by construction. Past the deadline the gate ESCALATES LOUD instead
  of waiting one more tick forever.
  """

  alias Fleet.Forge.Payload
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx

  # A run that has not finished after this long is not slow, it is orphaned (no runner registered,
  # runner dead, or a workflow nobody can serve). Wide enough for a real Elixir gate (~5 min on the
  # bench), short enough that a dead rail is named the same hour.
  @pending_deadline_sec 45 * 60

  # ⚠ UN JOB QUE PERSONNE N'A PRIS N'EST PAS UNE CI LENTE, et lui donner la patience d'une CI lente
  # coute des heures a un operateur : le job affiche « Waiting », 0 s, avec un `runs-on:` qu'aucun
  # runner du conteneur ne sert — indiscernable d'un job en cours, et bloquant la fusion sans jamais
  # rougir. Un rouge dit quelque chose ; une attente ressemble a du travail.
  #
  # CE DELAI EST COURT PARCE QUE LA MESURE EST DIFFERENTE. On n'attend plus « que la CI finisse » :
  # on attend qu'un runner la RECLAME, ce qui prend des secondes quand un runner sert le label. Au
  # dela, soit aucun ne le sert — impasse structurelle — soit tous sont occupes, et le message pose
  # la question au lieu de la garder pour dans trois quarts d'heure.
  @unclaimed_deadline_sec 5 * 60

  # Where a repository DECLARES its workflows. Both, because Gitea serves both, and because being
  # wrong in this direction only costs the bounded wait we already had — while missing one would
  # escalate a repo that does have a rail.
  @workflow_dirs [".gitea/workflows", ".github/workflows"]

  # The wait shapes are SPELLED OUT, not summarised as `:ci_pending`: the caller pattern-matches
  # each one to keep it visible to the BL-6-48 reverse wall, and a spec that hid them made dialyzer
  # declare those clauses unreachable — a typespec that lies turns a wall into a false alarm.
  @type wait_reason ::
          :ci_pending
          | {:ci_head_unreadable, term()}
          | {:ci_unreadable, term()}
          | {:ci_deadline_unreachable, term()}

  @type decision ::
          {:proceed, ci_fact :: map() | nil}
          | {:refuse, :ci_red, String.t()}
          | {:wait, wait_reason()}
          | {:escalate, {:ci_stalled, atom()} | {:ci_impossible, :no_workflow}, String.t()}

  @doc """
  Decides whether the jury may be summoned for `pr_number` at `head`.

  Returns `{:proceed, fact}` where `fact` is `nil` when the card does not require the CI (nothing
  to tell the judge) and a map when it does — that map is what `BriefBuilder` renders for the
  judge, so the judge never has to ask the forge anything.
  """
  @spec decide(integer(), String.t(), Ctx.t(), (-> :required | :ignore)) :: decision()
  def decide(pr_number, head, %Ctx{} = ctx, policy_fun) do
    case policy_fun.() do
      :required -> gate(pr_number, head, ctx)
      _ -> {:proceed, nil}
    end
  end

  defp gate(pr_number, head, %Ctx{} = ctx) do
    case head_commit(pr_number, head, ctx) do
      {:ok, sha, committed_at} ->
        classify(sha, committed_at, pr_number, ctx)

      # The PR object is unreadable: we do NOT guess a state. Same stance as everywhere else on
      # this rail — a transient forge failure defers, it never fabricates a verdict.
      {:error, reason} ->
        {:wait, {:ci_head_unreadable, reason}}
    end
  end

  # LES CONTEXTES VOYAGENT AVEC LE VERT, et c'est tout ce qui se ferme honnetement ici (6-140). Le
  # gate ne peut pas savoir ce qu'il FAUDRAIT avoir execute : rien ne declare le harnais d'un projet
  # (le template dit lui-meme que chaque projet le REECRIT quand il sait ce qu'il est). Il peut en
  # revanche dire ce qui a REELLEMENT tourne, et laisser le juge en tirer la conclusion — un vert
  # produit par le rail placeholder livre avec le template n'est plus indistinguable d'un vert
  # produit par une suite.
  defp classify(sha, committed_at, pr_number, %Ctx{} = ctx) do
    case ci_report(sha, ctx) do
      {:ok, :success, contexts} ->
        {:proceed, %{state: :success, sha: sha, contexts: contexts}}

      {:ok, :failure, _} ->
        {:refuse, :ci_red,
         "CI ROUGE sur #{String.slice(sha, 0, 8)} — aucun juge n'est convoqué sur du rouge. " <>
           "Le rail machine a rendu son verdict avant le jury : corrige, pousse, la CI se relance."}

      {:ok, :pending, _} ->
        stalled_or_wait(:pending, sha, committed_at, pr_number)

      {:ok, :none, _} ->
        no_status_yet_or_never(sha, committed_at, pr_number, ctx)

      # Unreadable status = unknown, and unknown is not green. Deferring costs one tick; assuming
      # green costs a jury spent on unmeasured code.
      {:error, reason} ->
        {:wait, {:ci_unreadable, reason}}
    end
  end

  # UNE DOUBLURE QUI NE CONNAIT QUE `commit_ci_state/3` RESTE VALIDE, et c'est deliberé : la lecture
  # des contextes est un AJOUT, pas un changement de contrat. Un seam qui ne l'expose pas rend un
  # verdict sans contextes — le brief dira alors ce qu'il sait, et rien de plus.
  defp ci_report(sha, %Ctx{} = ctx) do
    if Fleet.Opts.exported?(ctx.forge, :commit_ci_report, 3) do
      case ctx.forge.commit_ci_report(ctx.repo, sha, ctx.forge_opts) do
        {:ok, {state, contexts}} -> {:ok, state, contexts}
        {:error, _} = err -> err
      end
    else
      case ctx.forge.commit_ci_state(ctx.repo, sha, ctx.forge_opts) do
        {:ok, state} -> {:ok, state, []}
        {:error, _} = err -> err
      end
    end
  end

  # `:none` HAS TWO CAUSES AND THEY DO NOT DESERVE THE SAME PATIENCE. "No status yet" is a run that
  # has not reported — wait. "No workflow in this repository" is a status that will NEVER come, and
  # waiting 45 minutes for it is waiting for something structurally impossible.
  #
  # A repo imported from another forge ships no `.gitea/workflows/` at all, and its card may still
  # declare `ci: required`: the question is answerable at the FIRST tick, for one read, instead of
  # three quarters of an hour spent suspecting a runner that is fine.
  #
  # UNREADABLE IS NOT ABSENT. A listing we could not fetch says nothing about what the repo
  # declares, so it keeps the bounded wait — the same stance the rest of this gate takes on every
  # unknown: defer, never fabricate a verdict.
  defp no_status_yet_or_never(sha, committed_at, pr_number, %Ctx{} = ctx) do
    case declares_workflow?(sha, ctx) do
      :no ->
        {:escalate, {:ci_impossible, :no_workflow},
         "AUCUN WORKFLOW dans ce depot (#{Enum.join(@workflow_dirs, " ni ")}) au sha " <>
           "#{String.slice(sha, 0, 8)} (PR ##{pr_number}), et la carte de ce projet exige la CI. " <>
           "Aucun statut ne viendra jamais : ce n'est pas une attente, c'est une impasse. " <>
           "Ajoute un workflow, ou declare une carte dont `ci` vaut `ignore`."}

      _yes_or_unknown ->
        unclaimed_or_wait(sha, committed_at, pr_number, ctx)
    end
  end

  # LA TROISIEME CAUSE DE `:none`, ET ELLE SE MESURE AU LIEU DE S'ATTENDRE. Un workflow existe, donc
  # `no_workflow` ne mord pas — mais si AUCUN runner ne reclame le job, aucun statut ne viendra non
  # plus. L'API le dit en une lecture : un statut d'attente et `runner_id: 0`, avec les `labels` que
  # le job demande.
  #
  # ⚠ ON NE CONCLUT PAS « AUCUN RUNNER NE SERT CE LABEL » — on rapporte ce qui est mesure. Tous les
  # runners occupes produisent la meme observation, et affirmer la premiere cause enverrait reparer
  # une configuration intacte. Le message NOMME le label et laisse la question ouverte : c'est ce
  # qu'il faut pour agir, et c'est tout ce qui est prouve.
  defp unclaimed_or_wait(sha, committed_at, pr_number, %Ctx{} = ctx) do
    with true <- past?(committed_at, @unclaimed_deadline_sec),
         {:ok, [_ | _] = labels} <- unclaimed_labels(sha, ctx) do
      {:escalate, {:ci_stalled, :unclaimed},
       "AUCUN RUNNER n'a reclame ce job depuis plus de " <>
         "#{div(@unclaimed_deadline_sec, 60)} min sur #{String.slice(sha, 0, 8)} " <>
         "(PR ##{pr_number}) — il demande #{inspect(labels)}. Un runner sert-il ce label ? " <>
         "Un job jamais reclame ne rougit jamais : il bloque la fusion en ressemblant a du travail."}
    else
      _ -> stalled_or_wait(:none, sha, committed_at, pr_number)
    end
  end

  # Les labels des jobs que rien n'a pris, sur les runs de ce sha. Liste vide = tout est reclame (ou
  # il n'y a rien a lire), et l'attente bornee d'origine reprend la main.
  defp unclaimed_labels(sha, %Ctx{} = ctx) do
    runs_fun = Keyword.get(ctx.opts, :runs_for_sha_fun, &default_runs_for_sha/4)
    jobs_fun = Keyword.get(ctx.opts, :run_jobs_fun, &default_run_jobs/3)

    with {:ok, runs} <- runs_fun.(ctx.repo, sha, [], ctx.forge_opts) do
      labels =
        runs
        |> Enum.flat_map(fn run ->
          case jobs_fun.(ctx.repo, Map.get(run, "id"), ctx.forge_opts) do
            {:ok, jobs} -> jobs
            _ -> []
          end
        end)
        |> Enum.filter(&unclaimed?/1)
        |> Enum.flat_map(&Payload.labels/1)
        |> Enum.uniq()

      {:ok, labels}
    end
  end

  # ⚠ `"queued"` EST CE QUE L'API REND ; `"waiting"` EST LE NOM INTERNE DE GITEA. MESURE sur une
  # forge 1.26 portant sept courses qu'aucun runner ne servait : `/actions/runs/<id>/jobs` a rendu
  # SEPT FOIS `status: "queued", runner_id: 0, labels: ["shell"]`, et jamais `"waiting"`. Lire le
  # vocabulaire du code source de la forge donne l'autre mot, et un predicat qui ne teste que
  # celui-la n'est JAMAIS vrai : tout le chemin des cinq minutes meurt sans un bruit, et un job que
  # personne ne reclame retombe dans l'attente generique puis sort en `{:ci_stalled, :pending}` —
  # « echec de merge non classifie », c'est-a-dire le refus muet que ce garde remplace.
  #
  # LES DEUX SONT ACCEPTES parce qu'aucun des deux n'est garanti par un contrat : c'est une
  # conversion interne de Gitea, libre de changer dans un sens comme dans l'autre. Un garde qui ne
  # reconnait qu'un seul mot meurt en silence a la version suivante.
  @unclaimed_statuses ["queued", "waiting"]

  defp unclaimed?(job) do
    Map.get(job, "status") in @unclaimed_statuses and Map.get(job, "runner_id") in [nil, 0]
  end

  defp past?(nil, _sec), do: false
  defp past?(committed_at, sec), do: age_sec(committed_at) > sec

  # ⚠ PAR LE SEAM RUNTIME, ET PAS PAR UN APPEL DIRECT. `Fleet.Forge.Client.Actions` n'est pas exporte
  # par la boundary de `Fleet.Forge` : `Pilot` ne l'atteint jamais a la compilation. Son voisin
  # `MergeAndPromote` resout le meme module par `:forge_actions`, et c'est la forme prevue —
  # elargir la boundary pour se donner raison serait reparer le mur au lieu de l'appel.
  #
  # MEME CLEF QUE `MergeAndPromote` ET QUE LA SONDE DES JUGES, deliberement : la sonde et sa
  # verification interrogent le meme sous-domaine, et deux clefs en donneraient deux avis en test.
  defp forge_actions,
    do: Application.get_env(:lcars_fleet, :forge_actions, Fleet.Forge.Client.Actions)

  defp default_runs_for_sha(repo, sha, filters, opts),
    do: forge_actions().runs_for_sha(repo, sha, filters, opts)

  defp default_run_jobs(repo, run_id, opts), do: forge_actions().jobs(repo, run_id, opts)

  defp declares_workflow?(ref, %Ctx{} = ctx) do
    lister = Keyword.get(ctx.opts, :list_dir_fun, &Fleet.Forge.Client.Files.list_dir/3)
    opts = Keyword.put(ctx.forge_opts, :ref, ref)

    Enum.reduce_while(@workflow_dirs, :no, fn dir, acc ->
      case lister.(ctx.repo, dir, opts) do
        {:ok, names} ->
          if Enum.any?(names, &workflow_file?/1), do: {:halt, :yes}, else: {:cont, acc}

        # The directory is absent — that is an ANSWER, and it is "not here".
        {:error, :not_found} ->
          {:cont, acc}

        # Anything else is a forge we could not read. Unknown, and unknown is not absent.
        {:error, _} ->
          {:cont, :unknown}
      end
    end)
  end

  defp workflow_file?(name) when is_binary(name),
    do: String.ends_with?(name, ".yml") or String.ends_with?(name, ".yaml")

  defp workflow_file?(_), do: false

  # « ON ATTEND » ET « ON ATTEND DEPUIS TOUJOURS » NE RENDENT PAS LE MEME MOTIF. Sans date, le
  # calcul d'age vaut 0, donc `0 > 2700` est faux A JAMAIS : le ticket n'escalade pas, ne progresse
  # pas, et sans motif distinct il porte le meme que celui d'une CI qui tourne depuis dix secondes.
  #
  # Le motif est donc distinct, et il porte l'ETIQUETTE DE SA PORTE — `wait/ci`, comme ses deux
  # voisins `{:ci_head_unreadable, _}` et `{:ci_unreadable, _}` : du cote du ticket c'est le meme
  # fait (il est arrete a la porte CI), et la distinction vit dans la RAISON du skip, ou elle est
  # actionnable. Rien n'est bloque : escalader ici poserait `lcars-awaits-arch` et parquerait le
  # ticket, ce que l'arbitrage d'origine refuse explicitement.
  defp stalled_or_wait(_state, _sha, nil, _pr_number),
    do: {:wait, {:ci_deadline_unreachable, :no_pull_date}}

  defp stalled_or_wait(state, sha, committed_at, pr_number) do
    if age_sec(committed_at) > @pending_deadline_sec do
      {:escalate, {:ci_stalled, state},
       "CI #{state} depuis plus de #{div(@pending_deadline_sec, 60)} min sur " <>
         "#{String.slice(sha, 0, 8)} (PR ##{pr_number}) — un runner sert-il ce label ? " <>
         "Le gate n'attend pas indéfiniment : il le DIT."}
    else
      {:wait, :ci_pending}
    end
  end

  # The head sha AND the date the gate measures its patience against. Both come from the same read:
  # the PR object carries the head sha, and the commit carries its own date. `head` (the branch ref)
  # is the fallback for the sha only — a ref Gitea also resolves.
  #
  # ⚠ SEUL LE SHA ILLISIBLE REND UNE ERREUR. La date, elle, tombe a `nil` (`pull_updated_at/1`) et
  # `stalled_or_wait/4` rend alors `{:ci_deadline_unreachable, :no_pull_date}` — une attente qui se
  # dit, jamais une escalade sur une date qu'on n'a pas lue.
  #
  # L'attente reste NON BORNEE — la borner exigerait un `first_seen_at` persiste, et les seuls
  # porteurs sont l'outbox durable (arbitrage ouvert) ou un commentaire-marqueur ecrit a CHAQUE tick
  # d'une branche defensive. `commit_ci_state/3` jetterait la date des statuts, donc l'horloge
  # per-sha bon marche n'existe pas non plus. Ce qui est ferme ici, c'est le SILENCE : le motif
  # d'attente dit maintenant que l'echeance est hors d'atteinte.
  defp head_commit(pr_number, head, %Ctx{} = ctx) do
    case ctx.forge.get_pull(ctx.repo, pr_number, ctx.forge_opts) do
      {:ok, pull} ->
        # Nested rather than a flat `with`: an outer shape that is neither {:ok,_} nor {:error,_}
        # must keep raising. A `with/else` would funnel it into {:no_head_sha, _} — a precise
        # diagnosis of the wrong failure.
        case Payload.head_sha(pull) do
          sha when is_binary(sha) -> {:ok, sha, pull_updated_at(pull)}
          _ -> {:error, {:no_head_sha, head}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `updated_at` of the PR moves on every push (new head) — which is the clock we want: the wait is
  # per-sha, and a new push restarts it. Absent/unparseable → `nil` → treated as "just now", i.e.
  # we wait rather than escalate on a date we could not read.
  defp pull_updated_at(pull) do
    with str when is_binary(str) <- Payload.updated_at(pull),
         {:ok, dt, _} <- DateTime.from_iso8601(str) do
      dt
    else
      _ -> nil
    end
  end

  # ⚠ PAS DE CLAUSE `age_sec(nil), do: 0` ICI, ET C'EST LE MECANISME ENTIER DU DEFAUT QU'ELLE
  # OUVRE : sans date, l'age vaut 0, donc `0 > @pending_deadline_sec` est faux a jamais.
  # `stalled_or_wait/4` intercepte l'absence de date AVANT le calcul, ce qui rend une telle clause
  # inatteignable — dialyzer le dit —, et la poser quand meme remettrait le zero a portee du
  # prochain appelant.
  defp age_sec(%DateTime{} = dt), do: DateTime.diff(DateTime.utc_now(), dt, :second)

  @doc """
  La CI attend-elle depuis trop longtemps sur la tête de `pr_number` ?

  `Remediation.reconverge_on_ci/3` lit l'état CI APRÈS un merge refusé ; sans borne sur son
  `:pending`, un job qu'aucun runner ne réclame y boucle en silence, tick après tick, sans jamais
  rougir. Ce gate-ci porte déjà la doctrine et le nombre — les exposer évite un second cadran qui
  dériverait du premier.

  Même horloge : `updated_at` de la PR, qui bouge à chaque push, donc per-sha et sans état à
  retenir. `:unknown` quand la date est illisible — on attend plutôt que d'escalader sur ce qu'on
  n'a pas lu, exactement comme `stalled_or_wait/4`.
  """
  @spec pending_stalled?(integer(), String.t(), Ctx.t()) :: :stalled | :waiting | :unknown
  def pending_stalled?(pr_number, head, %Ctx{} = ctx) do
    case head_commit(pr_number, head, ctx) do
      {:ok, _sha, %DateTime{} = committed_at} ->
        if age_sec(committed_at) > @pending_deadline_sec, do: :stalled, else: :waiting

      _ ->
        :unknown
    end
  end

  @doc """
  The deadline, exposed so ONE witness can pin it — `ci_gate_test`, describe "the deadline is the
  point". NOT for fixtures to borrow: a fixture built on `pending_deadline_sec() + 60` is green for
  ANY value of the constant, and four of them were (measured 2026-09-07: 45 min → 18 h, whole suite
  green). Fixtures carry their own number; this reader exists so exactly one place compares.
  """
  @spec pending_deadline_sec() :: pos_integer()
  def pending_deadline_sec, do: @pending_deadline_sec
end
