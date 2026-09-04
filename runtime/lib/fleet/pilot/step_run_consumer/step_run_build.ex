defmodule Fleet.Pilot.StepRunConsumer.StepRunBuild do
  @moduledoc """
  Builds the PR-native step-run map from a completed pod and a resolved route.

  Producers receive git deliverable options for their own feature branch. Judges resolve the unique
  open Fleet PR for the issue and carry a fail-closed native review; an absent or ambiguous producer
  branch remains `nil` for the completer to reject.
  """

  require Logger

  alias Fleet.Forge.Payload
  alias Fleet.Pilot.StepRunConsumer.GateEngine
  alias Fleet.Pilot.StepRunConsumer.Verdict

  defmodule Seams do
    @moduledoc """
    Per-run repository context and dependencies used to build a step run.
    """
    @enforce_keys [:repo, :remote, :role_emails, :deliverable_mode_fun, :forge_opts]
    defstruct [
      :repo,
      :remote,
      :role_emails,
      :deliverable_mode_fun,
      :forge_client,
      :forge_opts
    ]

    @type t :: %__MODULE__{
            repo: String.t() | nil,
            remote: String.t() | nil,
            role_emails: (String.t() -> [String.t()]),
            deliverable_mode_fun: (String.t(), Path.t() | nil ->
                                     {:ok, String.t()} | {:error, term()}),
            forge_client: module() | nil,
            forge_opts: keyword()
          }
  end

  @typedoc """
  Route decided by the gate engine or a judge verdict.
  """
  @type route :: %{
          required(:intent) => atom(),
          required(:next_assignee) => String.t() | nil,
          required(:next_step) => String.t() | nil,
          optional(:comment_body) => String.t() | nil,
          optional(:judge_target) => String.t() | nil
        }

  @doc """
  Builds the map consumed by `StepRunCompleter.complete_pr/2`.
  """
  @spec build(map(), pos_integer(), String.t(), route(), Seams.t()) :: map() | {:error, term()}
  def build(payload, n, role, route, %Seams{} = seams) do
    # DR-013
    case classify_pr_role(payload, n, role, seams) do
      {:error, _} = err ->
        err

      {pr_role, producer_branch} ->
        build_step_run(payload, n, role, route, seams, pr_role, producer_branch)
    end
  end

  defp build_step_run(payload, n, role, route, seams, pr_role, producer_branch) do
    %{
      repo: seams.repo,
      pod_id: payload["pod_id"],
      issue_number: n,
      role: role,
      pr_role: pr_role,
      intent: route.intent,
      next_assignee: route.next_assignee,
      next_step: route.next_step,
      workflow_map: payload["workflow_map"],
      producer_branch: producer_branch,
      base_branch: payload["pr_base_branch"] || payload["base_branch"]
    }
    |> put_unless_nil(:comment_body, Map.get(route, :comment_body))
    |> put_unless_nil(:judge_target, Map.get(route, :judge_target))
    |> put_unless_nil(:brief_sha, payload["brief_sha"])
    |> put_unless_nil(:brief_ref, payload["brief_ref"])
    |> maybe_put_deliverable(pr_role, role, payload, n, seams)
    |> maybe_put_review_event(pr_role, route.intent, payload)
    |> maybe_put_eng_summary(pr_role, payload)
  end

  defp classify_pr_role(payload, n, role, seams) do
    # Meme racine que le rail : le role se resout dans le catalogue du projet, nomme par le `owner`
    # du depot que le payload porte deja.
    root =
      Fleet.Catalogue.root_for_repo(Payload.repository_full_name(payload) || payload["repo"])

    case GateEngine.producer?(role, seams.deliverable_mode_fun, payload["deliverable_mode"], root) do
      {:ok, true} ->
        {:producer, Fleet.Forge.Protocol.feature_branch(n, role)}

      {:ok, false} ->
        {:judge, judge_producer_branch(payload, n, seams)}

      {:error, _} = err ->
        err
    end
  end

  defp judge_producer_branch(_payload, n, seams) do
    forge = seams.forge_client || Fleet.Forge.Client

    with {:ok, pulls} <- forge.list_open_pulls(seams.repo, seams.forge_opts),
         head when is_binary(head) <- producer_head_for_issue(pulls, n) do
      head
    else
      _ -> nil
    end
  end

  defp producer_head_for_issue(pulls, n) do
    case pulls
         |> Fleet.Forge.Protocol.fleet_prs_by_issue()
         |> Enum.filter(&match?({^n, _}, &1)) do
      [] ->
        nil

      [{^n, pr}] ->
        Payload.head_ref(pr)

      several ->
        numbers = Enum.map(several, fn {_n, pr} -> pr["number"] end)

        Logger.error(
          "StepRunConsumer: issue ##{n} has #{length(several)} open fleet PRs #{inspect(numbers)} " <>
            "— one issue = one producer branch; REFUSING to pick one arbitrarily (treated as " <>
            "no-producer-head; close the stray PR to unblock)"
        )

        nil
    end
  end

  defp maybe_put_deliverable(step_run, :producer, role, payload, n, seams),
    do: Map.put(step_run, :deliverable_opts, build_deliverable_opts(role, payload, n, seams))

  defp maybe_put_deliverable(step_run, :judge, _role, _payload, _n, _seams), do: step_run

  # A0.6 — ON LIVRE LA OU ON A REPRIS. Cibler `feature_branch(n, role)` est juste pour un
  # producteur (son build CREE sa branche, son rework la reprend — meme nom, la formule coincide)
  # et FAUX pour la passe d'exception, dont le role differe : la formule pousse alors une
  # resolution PARFAITE sur `lcars/issue-N-<autre-role>`, une branche qu'AUCUNE PR ne regarde. La
  # PR reste conflictee, la passe est consommee (marqueur de round pose), et l'arch est immobilise
  # au-dessus d'un travail deja fait et invisible. Le discriminant est la BASE DE CLONE : un pod qui
  # a clone une branche de feature fleet (rework, exception) re-livre DESSUS ; un pod qui a clone
  # une face (build) livre sur SA branche de formule, qu'il cree.
  defp delivery_branch(role, payload, n) do
    base = payload["base_branch"]

    case is_binary(base) && Fleet.Forge.Protocol.parse_feature_branch(base) do
      {:ok, _} -> base
      _ -> Fleet.Forge.Protocol.feature_branch(n, role)
    end
  end

  defp build_deliverable_opts(role, payload, n, seams) do
    %{
      mode: :git_native,
      workspace: payload["workspace"],
      base_sha: payload["gate_base_sha"] || payload["base_sha"],
      allowed_emails: seams.role_emails.(role),
      coauthor_role: role,
      remote: seams.remote,
      target_branch: delivery_branch(role, payload, n),
      push?: true,
      local_ref: "HEAD",
      # LE TRIPLET SLSA VOYAGE AVEC LE LIVRABLE (BL-6-43). `livrable_sha` manque ici et c'est
      # NORMAL : il n'existe pas encore — `Deliverable.publish/1` le calcule apres la porte, et
      # l'ajoute. Tout le reste est connu au moment ou l'on decrit la publication, donc c'est ici
      # qu'il se declare, pas dans un second geste apres coup.
      provenance: %{
        brief_sha: payload["brief_sha"],
        brief_ref: payload["brief_ref"],
        input_sha: payload["gate_base_sha"] || payload["base_sha"],
        pod_id: payload["pod_id"],
        role: role,
        issue: n,
        debug_visibility: Fleet.Spawner.debug_visibility?()
      }
    }
  end

  defp maybe_put_review_event(step_run, :judge, :reviewed, payload) do
    result = Verdict.unwrap_worker_envelope(payload["result"] || %{})
    event = Verdict.review_event(Verdict.gate_decision(result))
    step_run = Map.put(step_run, :review_event, event)

    # C1: the machine payload leaves the prose HERE, at the flattening point.
    # `take_findings` validates `details.findings` and, when valid, hands the object over
    # (`:review_findings` → engraved by `StepRunCompleter.record_review` next to the prose pin)
    # while stripping it from `result` so `judge_review_body` never inspect-dumps a machine map
    # into a human review. Invalid or absent → `result` untouched, no key: a legacy judge walks
    # today's path byte-for-byte, and a broken optional payload never flips the verdict above.
    {findings, result} = Verdict.take_findings(result)
    step_run = put_unless_nil(step_run, :review_findings, findings)

    # DISTINGUER « rien envoyé » DE « envoyé et refusé », PARCE QUE LE COMPLETER ACCUSE. Son log
    # d'absence dit « judge X submitted NO details.findings » — vrai quand le juge s'est tu,
    # FAUX quand il a émis un payload que le schéma a écarté, et ce second cas est le plus frequent
    # des deux (un JSON sérialisé, un `severity_max` hors énumération). Accuser un juge d'un silence
    # qu'il n'a pas commis envoie corriger le mauvais bout : on cherche pourquoi il n'émet pas alors
    # qu'il émet.
    step_run =
      if findings == nil and is_map(result["details"]) and
           Map.has_key?(result["details"], Verdict.findings_key()) do
        Map.put(step_run, :review_findings_refused, true)
      else
        step_run
      end

    case Verdict.judge_review_body(event, result) do
      body when is_binary(body) and body != "" -> Map.put(step_run, :review_body, body)
      _ -> step_run
    end
  end

  defp maybe_put_review_event(step_run, _pr_role, _intent, _payload), do: step_run

  defp maybe_put_eng_summary(step_run, :producer, payload) do
    case Verdict.eng_summary(payload) do
      "" -> step_run
      summary -> Map.put(step_run, :eng_summary, summary)
    end
  end

  defp maybe_put_eng_summary(step_run, _pr_role, _payload), do: step_run

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
