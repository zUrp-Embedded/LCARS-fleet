defmodule Fleet.MCP.PodTools.Delegation.Issues do
  @moduledoc """
  Creates and reads issues in the channel-bound project behind the delegation gate.
  Creation uses the caller role's token and assigns the configured human. Poller
  admission owns route engraving; this module supplies destination labels and body artifacts.
  Body composition and retry readback stay with their issue/comment callers.
  """

  require Logger

  alias Fleet.Forge.Payload
  alias Fleet.Labels
  alias Fleet.Layout
  alias Fleet.MCP.PodTools.Delegation.{Dependencies, Gate, IssuePR, Render, Retirement, Workshop}
  alias Fleet.Project.GitOps

  # Compile-time dependency on the wire-token authority keeps dispatch aligned with the schema.
  @workshop_destination Labels.destination_workshop_token()

  defmodule Request do
    @moduledoc """
    Named issue_create fields avoid positional swaps between compatible string/nil values.
    Only title and brief are enforced struct keys; optional fields default to nil.
    Downstream validation can still require criteria depending on destination.
    """
    @enforce_keys [:title, :brief]
    defstruct [
      :title,
      :brief,
      :brief_pointer,
      :summary,
      :supersedes,
      :destination,
      :depends_on,
      :lot,
      :criteria
    ]

    @type t :: %__MODULE__{
            title: String.t(),
            brief: String.t(),
            # `{ref, sha}` de l'ordre deja materialise par l'appelant, ou `nil`.
            brief_pointer: {String.t(), String.t()} | nil,
            summary: String.t() | nil,
            # Le NUMERO du ticket que celui-ci remplace (l'ancien est retire par le systeme).
            supersedes: integer() | nil,
            destination: String.t() | nil,
            depends_on: [integer()] | nil,
            lot: String.t() | nil,
            criteria: String.t() | nil
          }
  end

  @doc """
  Creates a bound-project issue as the calling role and assigns the human owner.
  Missing role credentials refuse without a system-token fallback. Supersede state
  is checked before creation; later retirement failures can leave a warning on success.
  Artifact publication precedes issue creation and is not rolled back by a forge error.
  A lot failure refuses creation; brief/criteria materialization have separate degradations.
  """

  @spec create_issue(Request.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_issue(%Request{title: title, brief: brief} = req, state)
      when is_binary(title) and is_binary(brief) do
    %Request{
      brief_pointer: brief_pointer,
      summary: summary,
      supersedes: supersedes,
      destination: destination,
      depends_on: depends_on,
      lot: lot,
      criteria: criteria
    } = req

    # Resolve the forge surface, then gate the channel and obtain its role credentials.
    # Supplied pointers are structurally checked by PodTools; no artifact fetch occurs here.
    with {:ok, forge} <- Gate.conforming_forge(),
         {:ok, %{role: role, repo: repo}} <- Gate.require_architect(state),
         {:ok, identity} <- Fleet.Credentials.RoleIdentity.for_role(role),
         :ok <- refuse_pointing_criteria(criteria),
         :ok <- require_criteria_for_code(destination, criteria),
         {:ok, target_state} <- IssuePR.target_state_preflight(forge, repo, supersedes) do
      # A bridge timeout can outlive its forge write. Read the content marker before
      # republishing artifacts; reuse still retries supersede retirement if needed.
      # Reuse does not reattach depends_on edges or update destination.
      marker = op_marker(title, brief, summary, supersedes, brief_pointer, lot, criteria)

      case find_open_issue_with_marker(forge, repo, marker) do
        {:ok, existing} ->
          {:ok,
           Retirement.retire_superseded(
             forge,
             repo,
             supersedes,
             target_state,
             idempotent_result(existing)
           )}

        dedup ->
          compose_and_create(
            forge,
            repo,
            role,
            {title, brief, brief_pointer, summary, criteria, lot, marker},
            {identity, destination, depends_on, supersedes, target_state},
            dedup
          )
      end
    else
      {:error, :role_token_unavailable} = err ->
        Logger.warning(
          "Delegation: create_issue REFUSED: calling role's token not found (incomplete provisioning) — " <>
            "no system-account fallback"
        )

        err

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Publish the lot first: it has no inline fallback, so refusal should precede brief work.
  # Brief materialization can fall back to full inline text. Criteria is a separate
  # gate-briefs artifact; if its materialization fails, its pointer is omitted and
  # no inline criteria is added here.
  defp compose_and_create(
         forge,
         repo,
         role,
         {title, brief, brief_pointer, summary, criteria, lot, marker},
         {identity, destination, depends_on, supersedes, target_state},
         dedup
       ) do
    with {:ok, lot_pointer} <- publish_lot(repo, role, lot) do
      {corps, pointer} = ensure_pointer(repo, title, brief, brief_pointer, summary)
      criteria_pointer = ensure_criteria_pointer(repo, title, criteria)

      full_body =
        corps
        |> with_pointer(pointer, repo)
        |> with_criteria_pointer(criteria_pointer, repo)
        |> with_lot(lot_pointer)
        |> with_supersedes(supersedes)
        |> with_op_marker(marker)

      with {:ok, created} <-
             create_and_finish(
               forge,
               repo,
               {title, full_body},
               identity,
               %{destination: destination, depends_on: depends_on, supersedes: supersedes},
               target_state
             ) do
        {:ok, with_dedup_unverified(created, dedup)}
      end
    end
  end

  defp create_and_finish(forge, repo, {title, full_body}, identity, routing, target_state) do
    %{destination: destination, depends_on: depends_on, supersedes: supersedes} = routing

    case do_create_issue(forge, repo, title, full_body, [token: identity.token], destination) do
      {:ok, result} ->
        # Creation-time edges are best effort and report failures. Supersede instead
        # keeps the old issue open if carrying its edges fails.
        result = Dependencies.attach_dependencies(forge, repo, result, depends_on)
        {:ok, Retirement.retire_superseded(forge, repo, supersedes, target_state, result)}

      err ->
        err
    end
  end

  # Use shared label vocabulary for merge evidence.
  @merged_label Labels.stage_prefix() <> Labels.stage_merged()

  @doc """
  Reads issue and PR status behind the project-bound delegation gate.
  A closed issue needs a merge label or merged PR to report merged; closed alone
  reports closed_without_merge. Issue-read failure yields unknown. PR absence omits
  pr; PR-read failure renders an error object. This read does not enforce caller sequencing.
  """
  @spec issue_status(integer(), map()) :: {:ok, map()} | {:error, term()}
  def issue_status(number, state) when is_integer(number) do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         {:ok, forge} <- Gate.conforming_forge() do
      {issue_state, issue_labels, title} =
        case forge.get_issue(repo, number, []) do
          {:ok, issue} ->
            {Map.get(issue, "state", "unknown"), Payload.label_names(issue),
             Map.get(issue, "title")}

          # Log before reporting unknown so an outage has an operator trace.
          err ->
            Logger.warning(
              "Delegation: issue_status #{repo}##{number} forge unreachable (get_issue → " <>
                "#{inspect(err)}) — falling back to outcome=unknown"
            )

            {"unknown", [], nil}
        end

      pr = issue_pr_status(forge, repo, number)

      # Omit absent title/PR; the caller already has the project binding.
      # Include a thread-tool pointer in the result, where the caller needs the missing timestamps.
      result =
        %{
          "issue" => number,
          "outcome" => outcome(issue_state, issue_labels, pr),
          "voir_aussi" =>
            "`get_issue(#{number})` rend le fil de commentaires et leurs horodatages — " <>
              "ce status DÉRIVE un état, il ne restitue pas la matière."
        }
        |> Render.put_present("title", title)
        |> put_pr(pr)

      {:ok, result}
    end
  end

  # F-C047 / CI-06: merged requires the seal label or an explicitly merged fleet PR.
  defp outcome("unknown", _labels, _pr), do: "unknown"

  defp outcome("closed", labels, pr),
    do: if(@merged_label in labels or pr_merged?(pr), do: "merged", else: "closed_without_merge")

  defp outcome(_open, _labels, {:ok, %{"state" => "open"}}), do: "in_review"
  defp outcome(_open, _labels, _none_error_or_closed_pr), do: "open"

  defp pr_merged?({:ok, pr}), do: Payload.merged?(pr)
  defp pr_merged?(_), do: false

  # Absence and forge uncertainty retain distinct JSON shapes.
  defp put_pr(map, {:ok, pr}), do: Map.put(map, "pr", pr)
  defp put_pr(map, :none), do: map

  defp put_pr(map, {:error, :forge_unreachable}),
    do: Map.put(map, "pr", %{"error" => "forge_unreachable"})

  @doc """
  Lists the current project's open issue board. An unreadable forge is an error, not an empty board.
  """
  @spec list_issues(map()) :: {:ok, map()} | {:error, term()}
  def list_issues(state) do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         {:ok, forge} <- Gate.conforming_escalation_forge() do
      case forge.list_open_issues(repo, []) do
        {:ok, issues} when is_list(issues) ->
          entries = Enum.map(issues, &issue_entry/1)
          {:ok, %{"count" => length(entries), "issues" => entries}}

        other ->
          Logger.warning(
            "Delegation: list_issues — board unreadable: repo #{repo} (#{inspect(other)}) — " <>
              "surfaced as error, not an empty board"
          )

          {:error, {:issues_unreadable, repo, other}}
      end
    end
  end

  defp issue_entry(issue) do
    %{
      "number" => Map.get(issue, "number"),
      "title" => Map.get(issue, "title"),
      "labels" => issue_label_names(issue)
    }
  end

  defp issue_label_names(issue) do
    Payload.labels(issue)
    |> Enum.filter(&is_map/1)
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  Reads one issue body and thread. A thread outage omits `comments` and sets `comments_error`.
  """
  @spec get_issue(integer(), map()) :: {:ok, map()} | {:error, term()}
  def get_issue(number, state) when is_integer(number) do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         {:ok, forge} <- Gate.conforming_forge(),
         {:ok, esc_forge} <- Gate.conforming_escalation_forge() do
      case forge.get_issue(repo, number, []) do
        {:ok, issue} ->
          base =
            %{
              "issue" => number,
              "state" => Map.get(issue, "state", "unknown"),
              "body" => Map.get(issue, "body") || "",
              "labels" => issue_label_names(issue)
            }
            |> Render.put_present("title", Map.get(issue, "title"))

          {:ok, put_thread(base, esc_forge, repo, number)}

        err ->
          Logger.warning(
            "Delegation: get_issue #{repo}##{number} unreadable (#{inspect(err)}) — typed error"
          )

          {:error, {:issue_unreadable, number, err}}
      end
    end
  end

  defp put_thread(base, forge, repo, number) do
    case forge.list_comments(repo, number, []) do
      {:ok, comments} when is_list(comments) ->
        Map.put(base, "comments", Enum.map(comments, &comment_entry/1))

      other ->
        Logger.warning(
          "Delegation: get_issue — thread of #{repo}##{number} unreadable (#{inspect(other)}) — " <>
            "comments omitted, comments_error set"
        )

        Map.put(base, "comments_error", "forge_unreachable")
    end
  end

  defp comment_entry(c) when is_map(c) do
    %{"body" => Map.get(c, "body")}
    |> Render.put_present("author", Payload.author_login(c))
    |> Render.put_present("created_at", Payload.created_at(c))
  end

  defp comment_entry(_), do: %{"body" => nil}

  @doc """
  Posts an architect-owned issue comment; unavailable role credentials refuse without system fallback.
  """
  @spec comment_issue(integer(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def comment_issue(number, body, state)
      when is_integer(number) and is_binary(body) do
    with {:ok, %{role: role, repo: repo}} <- Gate.require_architect(state),
         {:ok, forge} <- Gate.conforming_escalation_forge(),
         {:ok, identity} <- Fleet.Credentials.RoleIdentity.for_role(role) do
      # Durable marker readback converges bridge retries; intentionally identical comments collapse.
      marker = comment_op_marker(number, body)

      case find_comment_with_marker(forge, repo, number, marker) do
        {:ok, _already_landed} ->
          {:ok, %{"status" => "commented", "number" => number, "idempotent" => true}}

        dedup ->
          repo
          |> forge.post_comment(number, with_op_marker(body, marker), token: identity.token)
          |> comment_outcome(number, dedup)
      end
    else
      {:error, :role_token_unavailable} = err ->
        Logger.warning(
          "Delegation: comment_issue REFUSED: role token not found (incomplete provisioning) — " <>
            "no system-account fallback"
        )

        err

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Failed readback still allows posting, but dedup_unverified distinguishes unknown
  # prior effects from a successful empty read. A reused artifact carries idempotent: true.
  defp with_dedup_unverified(result, {:unverified, why}),
    do: Map.put(result, "dedup_unverified", inspect(why))

  defp with_dedup_unverified(result, _), do: result

  # Reused issues expose their stored assignee and an explicit idempotency flag.
  defp idempotent_result(issue) do
    %{
      "status" => "issue_created",
      "issue" => Map.get(issue, "number"),
      "title" => Map.get(issue, "title"),
      "assignee" => issue_assignee(issue),
      "idempotent" => true
    }
  end

  defp issue_assignee(issue) do
    case Payload.assignee_logins(issue) do
      [login | _] -> login
      [] -> Payload.assignee_login(issue)
    end
  end

  # Resolve the workshop destination label for the initial issue write; adding it
  # later lets a poller tick see the ticket as ordinary project work.
  defp with_destination_label(@workshop_destination, issue_opts, forge, repo, author_opts) do
    case forge.repo_label_id(repo, Labels.destination_workshop(), author_opts) do
      {:ok, id} -> {:ok, Keyword.put(issue_opts, :labels, [id])}
      {:error, reason} -> {:error, {:destination_label_unresolved, inspect(reason)}}
    end
  end

  defp with_destination_label(_destination, issue_opts, _forge, _repo, _author_opts),
    do: {:ok, issue_opts}

  defp do_create_issue(forge, repo, title, brief, author_opts, destination) do
    # Human ownership is distinct from the producing role.
    case Fleet.Credentials.Human.current() do
      {:ok, human} ->
        issue_opts = Keyword.put(author_opts, :assignees, [human])

        # The destination label rides the CREATE so polling cannot route an unlabeled workshop issue as
        # project work.
        issue_opts_result =
          with_destination_label(destination, issue_opts, forge, repo, author_opts)

        with {:ok, issue_opts} <- issue_opts_result do
          forge.create_issue(repo, title, brief, issue_opts)
          |> created_issue(forge, repo, title, human, destination)
        end

      {:error, reason} ->
        {:error, {:human_unresolved, inspect(reason)}}
    end
  end

  # Add the visual type label best effort; the poller owns route engraving.
  # Echo number/title/assignee so the caller can correlate the created issue.
  defp created_issue({:ok, number}, forge, repo, title, human, destination) do
    _ = forge.add_label(repo, number, Labels.type_for_destination(destination), [])

    {:ok,
     %{"status" => "issue_created", "issue" => number, "title" => title, "assignee" => human}}
  end

  defp created_issue({:error, reason}, _forge, _repo, _title, _human, _destination),
    do: {:error, {:issue_creation_failed, inspect(reason)}}

  # Reads the issue PR across open, closed, and merged states.
  defp issue_pr_status(forge, repo, number) do
    case IssuePR.find_issue_pr(forge, repo, number) do
      {:ok, pr} -> {:ok, render_pr(forge, repo, number, pr)}
      other -> other
    end
  end

  # Use the gate's shared policy resolution and computed review outcome;
  # otherwise status could say approved while the same card sends the PR to rework.
  defp render_pr(forge, repo, issue_number, pr) do
    policy = Fleet.Project.Roles.verdict_policy_for(forge, repo, issue_number)

    read_opts = [
      head_sha: Payload.head_sha(pr),
      verdict_policy: policy,
      # Include the arbiter so status reflects a gray-zone decision already made by the gate.
      verdict_arbiter: Fleet.Project.Roles.gatekeeper_role()
    ]

    {verdicts, records, review} =
      case forge.pr_review_state(repo, pr["number"], read_opts) do
        {:ok, %{verdicts: verdicts, outcome: outcome, records: records}} ->
          {verdicts, records, review_string(outcome)}

        # Missing records is a partial result, not an unavailable forge.
        {:ok, %{verdicts: verdicts, outcome: outcome}} ->
          Logger.warning(
            "Delegation: issue_status #{repo} PR##{pr["number"]} — the review seam returned no " <>
              ":records; verdicts rendered WITHOUT their bodies and timings"
          )

          {verdicts, [], review_string(outcome)}

        # Log a failed review read and render unknown, not an empty jury.
        err ->
          Logger.warning(
            "Delegation: issue_status #{repo} PR##{pr["number"]} forge unreachable " <>
              "(pr_review_state → #{inspect(err)}) — falling back to review=unknown"
          )

          {%{}, [], "unknown"}
      end

    # Bodies and timestamps distinguish reviews with the same verdict.
    %{
      "number" => pr["number"],
      "state" => pr["state"],
      "merged" => Payload.merged?(pr),
      "review" => review,
      "verdicts" => verdicts
    }
    |> Render.put_present("reviews", presence(records))
  end

  defp presence([]), do: nil
  defp presence(list), do: list

  defp review_string({:pending, _}), do: "pending"
  defp review_string(:no_jury), do: "no_jury"
  defp review_string(:changes_requested), do: "changes_requested"
  defp review_string(:approved), do: "approved"

  # gray_zone means favorable jury advice still needs policy arbitration;
  # neither approved nor changes_requested expresses that state.
  defp review_string(:gray_zone), do: "gray_zone"

  # A supplied pointer keeps its summary; failed materialization keeps the inline brief.
  defp ensure_pointer(_repo, _title, brief, {_ref, _sha} = pointer, summary),
    do: {summary || brief, pointer}

  defp ensure_pointer(repo, title, brief, nil, summary) do
    opts =
      case Application.get_env(:lcars_fleet, :mcp_brief_ops_root) do
        nil ->
          [name_hint: Layout.sanitize_artifact_name(title), kind: "worker", push: :ops]

        root ->
          [
            name_hint: Layout.sanitize_artifact_name(title),
            kind: "worker",
            push: :ops,
            ops_root: root
          ]
      end

    case Fleet.Workflow.BriefArtifact.physicalize(brief, repo, opts) do
      {ref, sha} when is_binary(sha) -> {summary || excerpt(brief), {ref, sha}}
      _ -> {brief, nil}
    end
  end

  # Forge-facing excerpt when no dedicated summary was supplied.
  defp excerpt(brief) do
    lines = String.split(brief, "\n")
    head = lines |> Enum.take(6) |> Enum.join("\n") |> String.trim_trailing()

    if length(lines) > 6,
      do: head <> "\n\n_(extrait — le brief complet est le doc pointé ci-dessous)_",
      else: head
  end

  defp with_pointer(brief, nil, _repo), do: brief

  defp with_pointer(brief, {ref, sha}, repo),
    do: brief <> "\n\n---\n" <> Layout.brief_pointer_trailer(ref, sha, repo)

  # Criteria uses gate-briefs; absent criteria or failed materialization yields no pointer.
  defp ensure_criteria_pointer(_repo, _title, criteria)
       when not is_binary(criteria) or criteria == "",
       do: nil

  defp ensure_criteria_pointer(repo, title, criteria) do
    # Distinct basenames help humans reading logs without parent paths. Keep the suffix
    # here: the shared brief_ref primitive also names judge work orders that must stay unmarked.
    base = [
      name_hint: Layout.sanitize_artifact_name(title) <> "--criteria",
      kind: "judge",
      push: :ops
    ]

    opts =
      case Application.get_env(:lcars_fleet, :mcp_brief_ops_root) do
        nil -> base
        root -> Keyword.put(base, :ops_root, root)
      end

    case Fleet.Workflow.BriefArtifact.physicalize(criteria, repo, opts) do
      {ref, sha} when is_binary(sha) -> {ref, sha}
      _ -> nil
    end
  end

  defp with_criteria_pointer(body, nil, _repo), do: body

  defp with_criteria_pointer(body, {ref, sha}, repo),
    do: body <> "\n" <> Layout.criteria_pointer_line(ref, sha, repo)

  # Reject canonical embedded Brief/Criteria pointers so the judge's criteria is self-contained.
  # Prose references cannot be distinguished from contextual mentions and remain authoring discipline.
  defp refuse_pointing_criteria(criteria) when is_binary(criteria) and criteria != "" do
    cond do
      match?({:ok, _}, Layout.parse_brief_pointer(criteria)) ->
        {:error, {:criteria_not_self_contained, :embeds_brief_pointer}}

      match?({:ok, _}, Layout.parse_criteria_pointer(criteria)) ->
        {:error, {:criteria_not_self_contained, :embeds_criteria_pointer}}

      true ->
        :ok
    end
  end

  defp refuse_pointing_criteria(_), do: :ok

  # Every destination except workshop requires nonempty criteria; this does not assess their quality.
  defp require_criteria_for_code(destination, criteria) do
    workshop = Labels.destination_workshop_token()

    cond do
      destination == workshop -> :ok
      is_binary(criteria) and criteria != "" -> :ok
      true -> {:error, {:criteria_required_for_code, destination || "code"}}
    end
  end

  # Lots are committed workshop material, not task text. Publish through Deliverable
  # to retain ancestry, identity and secret checks rather than introducing another push path.

  defp publish_lot(_repo, _role, nil), do: {:ok, nil}

  defp publish_lot(repo, role, name) when is_binary(name) do
    dir = Workshop.lot_workspace(repo)
    face = Layout.workshop_branch()

    with {:ok, ref} <- Fleet.Forge.Protocol.lot_branch(name),
         {:ok, identity} <- Fleet.Credentials.ForgeIdentity.for_role(role),
         :ok <- GitOps.run(["-C", dir, "fetch", "origin", face], auth: true),
         {:ok, base_sha} <- GitOps.read(["-C", dir, "rev-parse", "FETCH_HEAD"]),
         {:ok, %{commit_sha: sha}} <- publish_lot_commits(dir, ref, base_sha, identity) do
      {:ok, {ref, sha}}
    else
      {:error, reason} ->
        Logger.warning(
          "Delegation: create_issue REFUSED: lot #{inspect(name)} unpublishable (#{inspect(reason)}) — " <>
            "a ticket that names matter it cannot carry is worse than no ticket"
        )

        {:error, {:lot_unpublishable, name, reason}}
    end
  end

  # No coauthor_role is required: a lot is human/delegator material, not a producer delivery.
  # Allowed author identity, ancestry and secret checks still apply.
  defp publish_lot_commits(dir, ref, base_sha, identity) do
    Fleet.Workflow.Deliverable.publish(%{
      mode: :git_native,
      workspace: dir,
      base_sha: base_sha,
      allowed_emails:
        Fleet.Credentials.ForgeIdentity.allowed_emails(:git_native, identity.author_email),
      remote: "origin",
      target_branch: ref,
      push?: true
    })
  end

  defp with_lot(body, nil), do: body

  defp with_lot(body, {ref, sha}) do
    body <>
      "\n\n---\n" <>
      "_Le paquet ci-dessous est la **matière** de ce ticket : ton espace de travail part de ce " <>
      "commit exact, tu n'as rien à cloner toi-même._\n" <>
      Fleet.Forge.Protocol.lot_pointer_line(ref, sha)
  end

  # Forge body carries supersession correlation across sessions.
  defp with_supersedes(body, nil), do: body

  defp with_supersedes(body, n),
    do: body <> "\n\n---\nRemplace : ##{n} (supersede — l'ancien ticket est retiré par la fleet)"

  # Persisted 64-bit digest prefix over Erlang term encoding. Preserve encoding/input
  # compatibility across deployments (check on OTP upgrades): changing it orphans
  # existing markers and can duplicate retries. This is not collision-free uniqueness.
  # Destination and depends_on are not in the digest; lot is its name, not its current commit.
  defp op_marker(title, brief, summary, supersedes, brief_pointer, lot, criteria) do
    sig =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({title, brief, summary, supersedes, brief_pointer, lot, criteria})
      )
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "<!-- lcars-op:#{sig} -->"
  end

  defp with_op_marker(body, marker), do: body <> "\n" <> marker

  # Retry-stable marker for a comment's issue and body.
  defp comment_op_marker(number, body) do
    sig =
      :crypto.hash(:sha256, :erlang.term_to_binary({:comment, number, body}))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "<!-- lcars-op:#{sig} -->"
  end

  # A failed readback falls through: posting beats silently dropping a reply. Mais L'APPELANT
  # L'APPREND — cf. `find_open_issue_with_marker/3` juste au-dessus, meme arbitrage.
  defp find_comment_with_marker(forge, repo, number, marker) do
    case forge.list_comments(repo, number, []) do
      {:ok, comments} ->
        case Enum.find(comments, &String.contains?(Map.get(&1, "body") || "", marker)) do
          nil -> :none
          comment -> {:ok, comment}
        end

      err ->
        Logger.warning(
          "Delegation: comment_issue idempotency readback on #{repo}##{number} failed " <>
            "(#{inspect(err)}) — proceeding to post (dedup NOT verified, said in the result)"
        )

        {:unverified, err}
    end
  end

  defp comment_outcome({:ok, _}, number, dedup),
    do: {:ok, with_dedup_unverified(%{"status" => "commented", "number" => number}, dedup)}

  defp comment_outcome({:error, reason}, _number, _dedup), do: {:error, {:comment_failed, reason}}

  # Best-effort idempotency: a failed readback falls through to creation.
  defp find_open_issue_with_marker(forge, repo, marker) do
    case forge.list_open_issues(repo, []) do
      {:ok, issues} ->
        case Enum.find(issues, &String.contains?(Map.get(&1, "body") || "", marker)) do
          nil -> :none
          issue -> {:ok, issue}
        end

      err ->
        Logger.warning(
          "Delegation: create_issue idempotency readback on #{repo} failed (#{inspect(err)}) — " <>
            "proceeding to create (dedup NOT verified, said in the result)"
        )

        {:unverified, err}
    end
  end
end
