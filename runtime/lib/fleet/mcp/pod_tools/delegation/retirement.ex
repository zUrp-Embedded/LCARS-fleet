defmodule Fleet.MCP.PodTools.Delegation.Retirement do
  @moduledoc """
  Taking a delegated ticket OUT: retired, superseded by a replacement, or swept away with the
  whole project in an emergency stop.

  A retirement touches four things that can each fail on their own — the live PR, the dependency
  edges, the pods still running on the ticket, and the ticket itself. The order is the invariant:
  the PR is closed BEFORE the edges are lifted, because an edge lifted under a live PR leaves the
  forge advertising a merge nobody is waiting for.
  """

  require Logger

  alias Fleet.MCP.PodTools.Delegation.{DependencyForge, Gate, IssuePR}

  # Carries BOTH directions over to the replacement. A failure PROPAGATES (the `with` above will not
  # go on to close): a half-rewired supersede that closes anyway is exactly the hole this plugs — the
  # old ticket stays open, the warning says so, and a human arbitrates. Noisy rather than false.
  #
  # The replacement may already carry an edge (replay): the forge then answers with an error on that
  # duplicate, and it is a NOMINAL state — not counted as a carry failure.
  #
  # SEAM CONFORMANCE, load-bearing side. This runs INSIDE the retirement, AFTER the live PR has been
  # closed: a missing callback raising here would leave the old ticket closed by a crash, edges
  # dropped — and closing RELEASES everything it blocked. The guard turns that into the same refusal
  # as any other carry failure, which the caller already knows not to close through.
  defp carry_dependencies(forge, repo, old_n, new_n) do
    with {:ok, _} <- Gate.conforming(DependencyForge, forge),
         {:ok, blockers} <- forge.issue_dependencies(repo, old_n, []),
         {:ok, blocked} <- forge.issue_blocks(repo, old_n, []),
         :ok <- copy_edges(blockers, fn b -> forge.add_issue_dependency(repo, new_n, b, []) end),
         :ok <- copy_edges(blocked, fn b -> forge.add_issue_dependency(repo, b, new_n, []) end) do
      :ok
    else
      {:error, reason} -> {:error, {:dependencies_not_carried, reason}}
    end
  end

  defp copy_edges(issues, write_fun) do
    Enum.reduce_while(issues, :ok, fn issue, :ok ->
      case Map.get(issue, "number") do
        n when is_integer(n) ->
          case write_fun.(n) do
            {:ok, _} -> {:cont, :ok}
            # Already written (replay): the target carries the edge, which is what we wanted.
            {:error, {:http, 409, _}} -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end

        _ ->
          {:halt, {:error, {:edge_without_number, issue}}}
      end
    end)
  end

  @doc """
  Stops everything in flight, fleet-wide: a brake, not a kill.

  It CLOSES tickets, it does not kill pods, and the difference is the whole design. Killing pods
  resets nothing — the tickets stay open, the poller re-dispatches on the next tick, and the runaway
  resumes with fresh pods. Closing is what actually stops it: a closed ticket leaves the poller by
  construction (every inbox lists open only) and the reaper collects its pods on its own.

  So this is `issue_retire` applied in bulk, with the same two gestures per ticket: the live PR
  closes first (the pulls rail is independent and would otherwise judge and merge into a dead
  ticket), then `closure: :retired` — the trace says nothing was delivered, because nothing was.

  ONE SEMANTIC DIFFERENCE from the unit gesture, and it inverts its rule. A single retirement ABORTS
  on the first failure: a half-retired ticket is worse than an open one. A brake does not get to
  stop halfway because one ticket resisted — leaving the rest running is the failure mode it exists
  to prevent. So the sweep CONTINUES and every failure is NAMED in the result. Re-running finishes
  the job: what was retired is closed and no longer listed.

  Two exclusions, both load-bearing:

    * PARKED projects are skipped. They have nothing in flight by definition, and their state IS an
      open marker issue assigned to the same human — sweeping it would CLOSE the marker, which means
      UNPARK. An emergency stop that reopens a deliberately closed project is the opposite of a stop.
    * the parked marker is excluded by title as well, for the project being closed while this runs.

  Scope is what the poller itself dispatches: the open issues assigned to the human owner. A ticket
  outside that scope is not something this fleet was going to act on.
  """
  @spec emergency_stop(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def emergency_stop(reason, state) when is_binary(reason) and reason != "" do
    with {:ok, _role} <- Gate.require_onboarder(state),
         {:ok, forge} <- Gate.conforming_forge(),
         {:ok, _} <- Gate.conforming(DependencyForge, forge),
         {:ok, onboard} <- Gate.conforming_onboard(),
         {:ok, projects} <- onboard.list_projects([]) do
      targets = Enum.filter(projects, &(&1["state"] == "open"))
      skipped = Enum.map(projects -- targets, & &1["repo"])

      swept = Enum.map(targets, &sweep_project(forge, onboard, &1["repo"], reason))

      {:ok,
       %{
         "stopped" => Enum.sum(Enum.map(swept, &length(&1["retired"]))),
         "failed" => Enum.sum(Enum.map(swept, &length(&1["failures"]))),
         "projects" => swept,
         "skipped_not_open" => skipped
       }}
    end
  end

  def emergency_stop(_reason, _state), do: {:error, :invalid_arguments}

  defp sweep_project(forge, onboard, repo, reason) do
    case onboard.list_stoppable_issues(repo, []) do
      {:ok, numbers} ->
        Enum.reduce(numbers, %{"repo" => repo, "retired" => [], "failures" => []}, fn n, acc ->
          record_sweep(acc, n, stop_one(forge, repo, n, reason))
        end)

      {:error, why} ->
        %{
          "repo" => repo,
          "retired" => [],
          "failures" => [%{"issue" => nil, "error" => inspect(why)}]
        }
    end
  end

  defp record_sweep(acc, n, {:ok, %{"retired" => true}}),
    do: Map.update!(acc, "retired", &(&1 ++ [n]))

  defp record_sweep(acc, _n, {:ok, _already_closed}), do: acc

  defp record_sweep(acc, n, {:error, why}),
    do: Map.update!(acc, "failures", &(&1 ++ [%{"issue" => n, "error" => inspect(why)}]))

  defp stop_one(forge, repo, n, reason) do
    case IssuePR.target_state_preflight(forge, repo, n) do
      {:ok, target} -> do_retire_issue(forge, repo, n, reason, target)
      {:error, _} = err -> err
    end
  end

  # ❌ AUCUN OUTIL N'OUVRE `ops/` A L'ECRITURE, ET IL N'Y A PAS DE SOUS-ARBRE D'EXCEPTION. C'est le
  # registre de ce qu'on a demande a un agent et de ce qu'on a juge de son travail : une porte
  # dedans, fut-elle « du materiau d'auteur que rien ne lit comme preuve », est une porte dans le
  # seul arbre qui doit rester en lecture seule pour tout le monde.
  #
  # La MATIERE, elle, a une destination : une note de conception est de la DOC. Elle vit sur la face
  # `doc`, que l'architecte monte en RW — il y ecrit directement, sans outil, comme il ecrit le
  # reste de la documentation avec l'humain.

  @doc """
  Retires a ticket WITHOUT inventing a replacement.

  Every piece of this gesture already existed — closing the live PR, lifting the pods, `stage/retired`,
  the comment — as a SIDE EFFECT of `create_issue(supersedes:)`. The cost was measured on the bench:
  to retire a ticket the architect had to create another one, which then went out to dispatch and
  landed on a producer with nothing to produce. A real gesture the fleet knows how to execute, that
  one had to disguise as a ticket for want of a door.

  Where it DIVERGES from the supersede, and why: a supersede moves the edges onto the replacement.
  A retirement has no replacement, so it LIFTS them. Leaving them would be worse than either — a
  closed blocker counts as satisfied on the forge, so every dependent would silently become closable
  as if the work had landed, while nothing was delivered.

  Order is the contract, three times over:

    * the live PR dies FIRST. The pulls rail is INDEPENDENT of the issues rail (`dispatch_review`
      polls pulls outside the lease and never reads the issue state), so a PR left open on a retired
      ticket goes on being judged and merged.
    * every dependent is TOLD before anything releases it. A silent unblock is the defect this
      order exists to prevent, and the announcement is what prevents it — not the lifting of the
      edge.
    * the edges are lifted AFTER the close, because the CLOSE is the point of no return.

  ⚠ **CE PARAGRAPHE ENONÇAIT LA REGLE QUE L'ORDRE VIOLAIT.** Il disait — et il dit toujours, deux
  lignes plus bas — « Any failure ABORTS before the close: closing RELEASES, so a half-executed
  retirement is worse than none ». Or `release_dependents/4` levait les aretes AVANT ce close. Un
  echec du commentaire ou de la fermeture abandonnait donc la sequence avec les dependants DEJA
  liberes et le bloqueur TOUJOURS OUVERT — l'etat exact que cette phrase declare pire que rien,
  produit un cran plus tot que la ou elle regardait.

  MESURE QUI DECIDE DE L'ORDRE : `Lease.open_blockers/2` filtre `state == "open"`. Une arete
  residuelle vers un ticket FERME ne bloque donc rien — c'est le CLOSE qui libere, la levee d'arete
  ne fait que dire la verite au read-model (la brique ne sera jamais livree). Les deux gestes n'ont
  pas le meme poids, et l'ordre suit ce poids :

    * echec AVANT le close → rien n'est libere, le bloqueur reste ouvert, les aretes sont intactes.
      Coherent, et reparable par un simple re-emission.
    * echec de la levee APRES le close → les dependants sont liberes (par le close) et TOUS
      annonces ; il reste une arete perimee vers un ticket ferme, que l'admission ignore. Le retrait
      est SIGNALE incomplet dans son resultat, jamais avale.

  L'annonce prealable est ce qui rend cet ordre acceptable : au moment ou le close libere, chaque
  dependant porte deja le commentaire qui le lui dit. Un dependant dont le numero n'est pas
  adressable HALTE avant tout ecrit — une arete qu'on ne sait pas adresser est une arete qu'on ne
  saura pas lever, et on ne ferme pas un bloqueur en la laissant derriere soi.

  Any failure before the close ABORTS: closing RELEASES, so a half-executed retirement is worse than
  none. An already-closed target is a no-op success, not an error — the stdio bridge times out a
  mutation at 30s while the forge call continues, and the agent re-emits.
  """
  @spec retire_issue(integer(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def retire_issue(number, reason, state)
      when is_integer(number) and number > 0 and is_binary(reason) and reason != "" do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         {:ok, forge} <- Gate.conforming_forge(),
         {:ok, _} <- Gate.conforming(DependencyForge, forge),
         {:ok, target} <- IssuePR.target_state_preflight(forge, repo, number) do
      do_retire_issue(forge, repo, number, reason, target)
    end
  end

  def retire_issue(_number, _reason, _state), do: {:error, :invalid_arguments}

  defp do_retire_issue(_forge, _repo, n, _reason, :closed) do
    {:ok,
     %{
       "issue" => n,
       "retired" => false,
       "note" => "##{n} etait deja ferme — rien fait, le retrait est idempotent"
     }}
  end

  defp do_retire_issue(forge, repo, n, reason, target) do
    pr = if match?({:open, _}, target), do: elem(target, 1)

    with :ok <- IssuePR.close_live_pr(forge, repo, pr),
         {:ok, dependents} <- forge.issue_blocks(repo, n, []),
         {:ok, numbers} <- addressable_dependents(dependents),
         :ok <- announce_release(forge, repo, n, numbers),
         {:ok, _} <- forge.post_comment(repo, n, retire_comment(reason), []),
         {:ok, _} <- forge.close_issue(repo, n, closure: :retired) do
      # ══ POINT DE NON-RETOUR FRANCHI ══ Le close a LIBERE les dependants (`open_blockers/2` ne
      # compte que les bloqueurs ouverts) et chacun porte deja son annonce. La levee des aretes qui
      # suit dit la verite au read-model ; son echec laisse une arete perimee vers un ticket ferme,
      # que l'admission ignore. Ce n'est plus un motif d'abandon — le ticket EST ferme — mais ce
      # n'est pas non plus un silence : ca voyage dans le resultat.
      {released, unlifted} = lift_edges(forge, repo, n, numbers)

      # A retired ticket is a DEAD ticket: its pods die with it, same arbitrage and same seam as the
      # supersede path.
      _ = pod_reaper().reap_issue(repo, n)

      result = %{"issue" => n, "retired" => true, "released" => released, "pr_closed" => pr}

      {:ok, with_unlifted(result, unlifted)}
    else
      {:error, reason} ->
        Logger.error(
          "Delegation: retirement of #{repo}##{n} ABORTED (#{inspect(reason)}) — " <>
            "the ticket is still OPEN and NOTHING was released: nothing to repair, re-emit"
        )

        {:error, {:retire_aborted, n, reason}}
    end
  end

  # Une arete qu'on ne sait pas ADRESSER est une arete qu'on ne saura pas lever. On l'apprend AVANT
  # le premier ecrit, parce qu'apres le close il serait trop tard pour renoncer.
  defp addressable_dependents(dependents) do
    Enum.reduce_while(dependents, {:ok, []}, fn dep, {:ok, acc} ->
      case Map.get(dep, "number") do
        d when is_integer(d) -> {:cont, {:ok, acc ++ [d]}}
        _ -> {:halt, {:error, {:edge_without_number, dep}}}
      end
    end)
  end

  # L'ANNONCE PRECEDE LA LIBERATION, et c'est elle qui rend l'ordre acceptable. Au moment ou le
  # close libere, chaque dependant porte deja le commentaire qui le lui dit — le « deblocage
  # silencieux » que cet ordre existe pour empecher est ferme ICI, pas par la levee de l'arete.
  # Un echec ABANDONNE : rien n'est encore libere, le bloqueur est ouvert, les aretes sont intactes.
  defp announce_release(forge, repo, n, numbers) do
    Enum.reduce_while(numbers, :ok, fn d, :ok ->
      case forge.post_comment(repo, d, released_comment(n), []) do
        {:ok, _} -> {:cont, :ok}
        {:error, err} -> {:halt, {:error, {:dependent_not_announced, d, err}}}
      end
    end)
  end

  # Apres le point de non-retour : on leve ce qu'on peut et on RAPPORTE ce qu'on n'a pas pu. Pas de
  # `reduce_while` ici — s'arreter au premier echec laisserait des aretes levables en place sans
  # raison, et le ticket est deja ferme.
  defp lift_edges(forge, repo, n, numbers) do
    Enum.reduce(numbers, {[], []}, fn d, {ok, ko} ->
      case forge.remove_issue_dependency(repo, d, n, []) do
        {:ok, _} ->
          {ok ++ [d], ko}

        {:error, err} ->
          Logger.error(
            "Delegation: #{repo}##{n} RETIRE et ferme, mais l'arete du dependant ##{d} n'a pas pu " <>
              "etre levee (#{inspect(err)}) — ##{d} est DEBLOQUE (l'admission ne compte que les " <>
              "bloqueurs ouverts) et il a ete annonce ; l'arete perimee reste a nettoyer a la main"
          )

          {ok, ko ++ [d]}
      end
    end)
  end

  defp with_unlifted(result, []), do: result
  defp with_unlifted(result, unlifted), do: Map.put(result, "edges_not_lifted", unlifted)

  defp retire_comment(reason) do
    "Ticket retiré par l'architecte — aucun remplaçant, rien n'a été livré.\n\nMotif : #{reason}"
  end

  defp released_comment(n) do
    "Le bloqueur ##{n} a été retiré sans remplaçant : la dépendance est levée sur ce ticket. " <>
      "Si ce travail restait nécessaire, il doit être redemandé — le retrait n'a rien livré."
  end

  # Retirement of the replaced ticket — SYSTEM identity (default token: the system executes,
  # the arch only expressed the intent), comment BEFORE close (chronology readable on the forge,
  # same stance as the gatekeeper seal). The awaits-arch label is left as historical trace: a
  # CLOSED issue leaves the poller and the escalation inbox by itself (both list open only).
  # A retirement failure NEVER unwinds the created ticket (it exists): the result says so
  # honestly (`supersede_warning`) and the human closes by hand — loud, no half-lie.
  # PUBLIC (@doc false) so the edge carry-over is testable ON ITS ORDER: the property that matters
  # here is not "the edges exist" but "they are written BEFORE the close", and that is only
  # observable from the caller.
  @doc false
  @spec retire_superseded(module(), String.t(), term(), term(), map()) :: map()
  def retire_superseded(_forge, _repo, nil, _target_state, result), do: result

  def retire_superseded(_forge, _repo, n, :closed, result),
    do: Map.put(result, "supersedes", n)

  # Target with NO live PR: the nominal path.
  def retire_superseded(forge, repo, n, :open, result), do: do_retire(forge, repo, n, nil, result)

  # Target WITH a live PR: the PR is closed in the SAME gesture. The order binds here as it does for
  # the edges — the PR first: while it lives, the pulls rail can judge and merge it, and that rail
  # never reads the issue's state.
  def retire_superseded(forge, repo, n, {:open, pr}, result),
    do: do_retire(forge, repo, n, pr, result)

  defp do_retire(forge, repo, n, pr, result) do
    new_number = Map.get(result, "issue")

    comment =
      "Remplacé par ##{new_number} (brief re-cadré) — ticket retiré par la fleet (supersede)."

    # THE DEPENDENCY EDGES ARE CARRIED BEFORE THE CLOSE, AND THE ORDER IS BINDING.
    # A Gitea dependency links two issue_ids; `supersedes` is NOT a forge primitive,
    # it is an LCARS convention (comment + close). So the forge does not see a
    # replacement: it sees one issue die and another appear, and the edges stay attached to the
    # dead one. Both directions hurt, and the first one is silent:
    #   * what the old ticket BLOCKED is released the instant it closes (a CLOSED blocker counts as
    #     satisfied) — while the work has moved and is not delivered;
    #   * what the old ticket DEPENDED ON vanishes: the replacement is born without its precondition.
    # Measured (A blocks B, supersede A -> A': `B dependencies` still returns A, closed, and A'
    # carries no edge at all).
    # Closing first would release the blocked ones BEFORE the rewiring, and a dispatch can slip into
    # that window. We write onto the replacement, THEN we close.
    with :ok <- IssuePR.close_live_pr(forge, repo, pr),
         :ok <- carry_dependencies(forge, repo, n, new_number),
         {:ok, _} <- forge.post_comment(repo, n, comment, []),
         # `closure: :retired` — a supersede delivers NOTHING: the work moved onto the replacement
         # (its edges were carried there just above). The ticket has to SAY it.
         {:ok, _} <- forge.close_issue(repo, n, closure: :retired) do
      # A superseded ticket is a DEAD ticket: its pods die with it (⚖ user —
      # the three reasons live in `Fleet.Pilot.PodReaper`). Upward seam: MCP may not reference
      # Pilot, same rule and same shape as `:forge_client`.
      _ = pod_reaper().reap_issue(repo, n)
      Map.put(result, "supersedes", n)
    else
      err ->
        Logger.error(
          "Delegation: supersede retirement of #{repo}##{n} FAILED (#{inspect(err)}) — " <>
            "##{new_number} created but ##{n} still open (zombie risk): close it manually"
        )

        result
        |> Map.put("supersedes", n)
        |> Map.put(
          "supersede_warning",
          "le retrait de ##{n} a échoué — il est encore ouvert, fais-le fermer par ton humain"
        )
    end
  end

  # Channel identity supplies role and project binding; missing or unbound identity is refused.
  # Upward seam (MCP -> Pilot): reaping the pods of a retired ticket. Module ATTRIBUTE, never a
  # literal remote call — the boundary forbids `Fleet.MCP -> Fleet.Pilot` (cf. `:forge_client`).
  @default_pod_reaper Fleet.Pilot.PodReaper
  defp pod_reaper, do: Application.get_env(:lcars_fleet, :mcp_pod_reaper, @default_pod_reaper)
end
