defmodule Fleet.Forge.Protocol do
  @moduledoc """
  Pure forge protocol vocabulary: branch names, comment markers, parked titles and result blocks.
  HTTP operations live in `Fleet.Forge.Client`; labels, including route position in stage/*,
  live in `Fleet.Labels`. MCP reaches parse_feature_branch through the forge-client seam.

  Keep builders and readers together when changing a format. Most builders interpolate without
  validating inputs, so recognition is not guaranteed for arbitrary arguments allowed by their guards.
  Marker recognition checks text only; author trust must be handled by the caller.
  """

  @feature_branch_prefix "lcars/issue-"
  @feature_branch_rx Regex.compile!("^" <> Regex.escape(@feature_branch_prefix) <> "(\\d+)-(.+)$")

  @doc """
  Builds lcars/issue-n-role without validating Git ref syntax. Negative n or empty role
  are accepted by the builder but not recognized by its parser.
  """
  @spec feature_branch(integer(), String.t()) :: String.t()
  def feature_branch(n, role) when is_integer(n) and is_binary(role),
    do: "#{@feature_branch_prefix}#{n}-#{role}"

  @doc """
  Extracts decimal issue number and nonempty role from the feature-branch pattern, else :error.
  Used to correlate a PR's head.ref with an issue; does not authenticate branch ownership or role.
  """
  @spec parse_feature_branch(String.t()) :: {:ok, {integer(), String.t()}} | :error
  def parse_feature_branch(head) when is_binary(head) do
    case Regex.run(@feature_branch_rx, head) do
      [_, n, role] -> {:ok, {String.to_integer(n), role}}
      _ -> :error
    end
  end

  def parse_feature_branch(_), do: :error

  @doc """
  Returns {issue_number, pull} for each readable head.ref matching the feature pattern,
  preserving order and duplicates. Malformed nested structures can raise.
  Pilot projects these pairs locally; MCP Delegation uses its own loop through the parser seam
  so forge stubs need not implement this selector.
  """
  @spec fleet_prs_by_issue([map()]) :: [{integer(), map()}]
  def fleet_prs_by_issue(pulls) when is_list(pulls) do
    Enum.flat_map(pulls, fn pr ->
      case parse_feature_branch(get_in(pr, ["head", "ref"]) || "") do
        {:ok, {n, _role}} -> [{n, pr}]
        :error -> []
      end
    end)
  end

  # A lot is input material (docs/images/directories) committed on workshop by human/architect.
  # Lot: selects a branch/commit for the producer's starting tree; Brief: selects the task text
  # in ops (Fleet.Layout). Their parsers must remain distinct when both share a ticket body.
  @lot_branch_prefix "lcars/lot-"
  @lot_branch_rx Regex.compile!(
                   "\\A" <> Regex.escape(@lot_branch_prefix) <> "[a-z0-9][a-z0-9_-]*\\z"
                 )
  @lot_pointer_re Regex.compile!("^Lot: (\\S+) @ ([0-9a-f]{40})$", "m")

  @doc """
  Builds lcars/lot-slug after Fleet.Slug.cast validation, without renaming the caller's lot.
  """
  @spec lot_branch(String.t()) :: {:ok, String.t()} | {:error, {:invalid_slug, term()}}
  def lot_branch(name) do
    with {:ok, slug} <- Fleet.Slug.cast(name), do: {:ok, @lot_branch_prefix <> slug}
  end

  @doc """
  Requires the exact lot-branch pattern, rejecting fully qualified refs, face/feature branches
  and an empty slug. This validates text from an editable ticket, not branch existence or authorship.
  """
  @spec valid_lot_branch?(term()) :: boolean()
  def valid_lot_branch?(ref) when is_binary(ref), do: Regex.match?(@lot_branch_rx, ref)
  def valid_lot_branch?(_), do: false

  @doc """
  Builds the ticket line Lot: ref @ sha without validating either argument.
  """
  @spec lot_pointer_line(String.t(), String.t()) :: String.t()
  def lot_pointer_line(ref, sha), do: "Lot: #{ref} @ #{sha}"

  @doc """
  Reads the first matching Lot: line with a 40-character lowercase hex SHA, then validates its ref.
  A matching line with an invalid ref returns an error so dispatch cannot silently discard material.
  Other malformed pointer lines (including invalid SHA) do not match and can yield :none;
  later matching lines are considered only if earlier lines did not match. No Git object lookup.
  """
  @spec parse_lot_pointer(String.t() | nil) ::
          {:ok, {String.t(), String.t()}} | :none | {:error, {:invalid_lot_ref, String.t()}}
  def parse_lot_pointer(nil), do: :none

  def parse_lot_pointer(body) when is_binary(body) do
    case Regex.run(@lot_pointer_re, body) do
      nil ->
        :none

      [_, ref, sha] ->
        if valid_lot_branch?(ref), do: {:ok, {ref, sha}}, else: {:error, {:invalid_lot_ref, ref}}
    end
  end

  @step_run_prefix "[step_run:"
  # Unanchored: markers may occur inside comment prose. Role/SHA must be nonempty without : or ].
  @step_run_marker_rx Regex.compile!(Regex.escape(@step_run_prefix) <> "[^:\\]]+:[^:\\]]+\\]")
  @step_run_role_rx Regex.compile!(Regex.escape(@step_run_prefix) <> "([^:\\]]+):[^:\\]]+\\]")

  @doc """
  Builds [step_run:role:sha] for completion counting and caller deduplication.
  Neither input is escaped or SHA-validated; recognition requires compatible tokens.

      iex> marker = Fleet.Forge.Protocol.step_run_marker("engineer", "deadbeef")
      iex> marker
      "[step_run:engineer:deadbeef]"
      iex> Fleet.Forge.Protocol.step_run_marker?(marker)
      true
      iex> Fleet.Forge.Protocol.step_run_marker?("juste un commentaire")
      false
  """
  @spec step_run_marker(String.t(), String.t()) :: String.t()
  def step_run_marker(role, sha) when is_binary(role) and is_binary(sha) do
    "#{@step_run_prefix}#{role}:#{sha}]"
  end

  # The publish brake groups failures by abbreviated gate base. This format alone does not prove
  # consecutive failures; the caller counts history and decides which group matters.
  @publish_fail_prefix "[publish-fail:issue-"
  # Accept abbreviated test SHAs from 4 through 12 hex digits, not every binary the builder accepts.
  @publish_fail_rx Regex.compile!(
                     Regex.escape(@publish_fail_prefix) <> "(\\d+):base-([0-9a-f]{4,12})\\]"
                   )

  @doc """
  Builds a publish-failure marker for StepRunCompleter and the Remediation brake.
  Slices base_sha to 12 characters without validating hex or issue-number sign.

      iex> m = Fleet.Forge.Protocol.publish_fail_marker(7, String.duplicate("a", 40))
      iex> m
      "[publish-fail:issue-7:base-aaaaaaaaaaaa]"
      iex> Fleet.Forge.Protocol.parse_publish_fail_marker(m)
      {:ok, {7, "aaaaaaaaaaaa"}}
      iex> Fleet.Forge.Protocol.parse_publish_fail_marker("un commentaire")
      :error
      iex> Fleet.Forge.Protocol.parse_publish_fail_marker(
      ...>   Fleet.Forge.Protocol.publish_fail_marker(42, "cafe")
      ...> )
      {:ok, {42, "cafe"}}
  """
  @spec publish_fail_marker(integer(), String.t()) :: String.t()
  def publish_fail_marker(n, base_sha) when is_integer(n) and is_binary(base_sha) do
    "#{@publish_fail_prefix}#{n}:base-#{String.slice(base_sha, 0, 12)}]"
  end

  @doc "First publish-fail match with decimal issue number and 4–12 lowercase hex digits, else :error."
  @spec parse_publish_fail_marker(String.t()) :: {:ok, {integer(), String.t()}} | :error
  def parse_publish_fail_marker(body) when is_binary(body) do
    case Regex.run(@publish_fail_rx, body) do
      [_, n, base12] -> {:ok, {String.to_integer(n), base12}}
      _ -> :error
    end
  end

  def parse_publish_fail_marker(_), do: :error

  # CI failure does not itself create a REQUEST_CHANGES review, so its rework needs a separate
  # marker budget. Posting the marker and dispatching work are caller operations, not atomic here.
  @ci_rework_prefix "[ci-rework:issue-"
  @ci_rework_rx Regex.compile!(
                  Regex.escape(@ci_rework_prefix) <> "(\\d+):head-([0-9a-f]{4,12})\\]"
                )

  @doc """
  Marqueur de rework CI : tete tronquee a 12 caracteres, sans validation hex ni du signe de n.

      iex> m = Fleet.Forge.Protocol.ci_rework_marker(7, String.duplicate("b", 40))
      iex> m
      "[ci-rework:issue-7:head-bbbbbbbbbbbb]"
      iex> Fleet.Forge.Protocol.parse_ci_rework_marker(m)
      {:ok, {7, "bbbbbbbbbbbb"}}
      iex> Fleet.Forge.Protocol.parse_ci_rework_marker("un commentaire")
      :error
  """
  @spec ci_rework_marker(integer(), String.t()) :: String.t()
  def ci_rework_marker(n, head_sha) when is_integer(n) and is_binary(head_sha) do
    "#{@ci_rework_prefix}#{n}:head-#{String.slice(head_sha, 0, 12)}]"
  end

  @doc """
  Prefixe utilise par count_comments_marked/4, partage avec le constructeur du marqueur.

      iex> Fleet.Forge.Protocol.ci_rework_prefix(7)
      "[ci-rework:issue-7:"
  """
  @spec ci_rework_prefix(integer()) :: String.t()
  def ci_rework_prefix(n) when is_integer(n), do: "#{@ci_rework_prefix}#{n}:"

  @doc "Premier ci-rework avec numero decimal et 4–12 caracteres hex minuscules ; :error sinon."
  @spec parse_ci_rework_marker(String.t()) :: {:ok, {integer(), String.t()}} | :error
  def parse_ci_rework_marker(body) when is_binary(body) do
    case Regex.run(@ci_rework_rx, body) do
      [_, n, head12] -> {:ok, {String.to_integer(n), head12}}
      _ -> :error
    end
  end

  def parse_ci_rework_marker(_), do: :error

  @doc """
  BL-6-34: post-push PR-opening failure, distinct from failure to push the deliverable.
  StepRunCompleter.record_pr_open_failure uses it to name the stall on the ticket.
  SHA is sliced to 12 characters, unchecked. No parser or counting brake is attached to this
  marker; adding such a consumer requires a reader here rather than reusing publish-fail counts.
  """
  @spec pr_open_fail_marker(integer(), String.t()) :: String.t()
  def pr_open_fail_marker(n, sha) when is_integer(n) and is_binary(sha) do
    "[pr-open-fail:issue-#{n}:sha-#{String.slice(sha, 0, 12)}]"
  end

  # Inbox lookup needs markers to avoid returning the architect's own later reply as escalation.
  # The recurrence brake can set the label without a comment; no marked comment then means nil.
  @await_marker_rx Regex.compile!(Regex.escape(@step_run_prefix) <> "[^:\\]]+:await:[^:\\]]+\\]")
  @rework_exhausted_prefix "[rework-exhausted-escalation:"
  @rework_exhausted_rx Regex.compile!(Regex.escape(@rework_exhausted_prefix) <> "[^\\]]+\\]")

  @doc """
  Format du marqueur d'attente d'arbitrage `[step_run:<role>:await:<decision>]`.

  Avec des tokens non vides sans : ni ], await distingue une escalade d'un step-run acheve.
  Le constructeur n'echappe pas les arguments ; l'exemple montre les tokens attendus.

      iex> m = Fleet.Forge.Protocol.await_marker("engineer", "escalate_user")
      iex> m
      "[step_run:engineer:await:escalate_user]"
      iex> Fleet.Forge.Protocol.escalation_marker?(m)
      true
      iex> Fleet.Forge.Protocol.step_run_marker?(m)
      false
  """
  @spec await_marker(String.t(), String.t()) :: String.t()
  def await_marker(role, decision) when is_binary(role) and is_binary(decision),
    do: "#{@step_run_prefix}#{role}:await:#{decision}]"

  @doc """
  Format du marqueur d'escalade « budget de rework epuise » `[rework-exhausted-escalation:pr-<n>]`.

      iex> m = Fleet.Forge.Protocol.rework_exhausted_marker(42)
      iex> m
      "[rework-exhausted-escalation:pr-42]"
      iex> Fleet.Forge.Protocol.escalation_marker?(m)
      true
  """
  @spec rework_exhausted_marker(integer()) :: String.t()
  def rework_exhausted_marker(pr_number) when is_integer(pr_number),
    do: "#{@rework_exhausted_prefix}pr-#{pr_number}]"

  @doc """
  Reconnait un motif await ou rework-exhausted n'importe ou dans le corps, sans verifier l'auteur.
  Le second accepte tout contenu non vide sans ], pas seulement pr-numero.
  """
  @spec escalation_marker?(term()) :: boolean()
  def escalation_marker?(body) when is_binary(body),
    do: Regex.match?(@await_marker_rx, body) or Regex.match?(@rework_exhausted_rx, body)

  def escalation_marker?(_), do: false

  @doc """
  Role declare par le premier motif step-run, ou nil. Le lecteur doit ensuite resoudre ce role
  et comparer l'auteur : le texte du marqueur ne prouve aucune identite.

      iex> Fleet.Forge.Protocol.step_run_marker_role("fait [step_run:engineer:deadbeef]")
      "engineer"
      iex> Fleet.Forge.Protocol.step_run_marker_role("rien a signaler")
      nil
  """
  @spec step_run_marker_role(term()) :: String.t() | nil
  def step_run_marker_role(body) when is_binary(body) do
    case Regex.run(@step_run_role_rx, body, capture: :all_but_first) do
      [role] when is_binary(role) -> role
      _ -> nil
    end
  end

  def step_run_marker_role(_), do: nil

  @doc false
  # Text recognition only; count_signed_step_runs handles author trust separately.
  @spec step_run_marker?(term()) :: boolean()
  def step_run_marker?(body) when is_binary(body), do: Regex.match?(@step_run_marker_rx, body)
  def step_run_marker?(_), do: false

  @parked_prefix "[lcars-parked]"

  @doc """
  BL-6-30 parked-issue title. An open issue with this prefix represents project closure;
  suffix/body are free. project_open closes all matching markers because concurrent closes
  may leave several; any remaining open marker keeps the project parked.
  Human UI mutation is intentional state mutation. The title predicate alone does not check open state.
  """
  @spec parked_issue_title() :: String.t()
  def parked_issue_title, do: "#{@parked_prefix} projet fermé — la fleet ne dispatche plus ici"

  @doc "Does this issue TITLE carry the parked prefix? (the state test, prefix-only)"
  @spec parked_issue_title?(term()) :: boolean()
  def parked_issue_title?(title) when is_binary(title),
    do: String.starts_with?(title, @parked_prefix)

  def parked_issue_title?(_), do: false

  @merge_marker_rx ~r/\[merge:pr-(\d+)\]/

  @doc """
  Issue-to-PR correlation posted by the seal, also used for deduplication. On the Gitea 1.26.4
  bench of 2026-07-19, deleting a merged head branch rewrote head.ref to refs/pull/N/head,
  so a later feature-branch scan could no longer recover this link.
  Builder accepts any integer; parser accepts decimal digits only. Neither authenticates authors.

      iex> marker = Fleet.Forge.Protocol.merge_marker(6)
      iex> marker
      "[merge:pr-6]"
      iex> Fleet.Forge.Protocol.parse_merge_marker("scellé.\\n\\n" <> marker)
      {:ok, 6}
      iex> Fleet.Forge.Protocol.parse_merge_marker("juste un commentaire")
      :error
  """
  @spec merge_marker(integer()) :: String.t()
  def merge_marker(pr_number) when is_integer(pr_number), do: "[merge:pr-#{pr_number}]"

  @doc """
  Returns the number in the first [merge:pr-digits] match anywhere in a binary, else :error.
  Recognizing a copied marker does not prove a merge occurred.
  """
  @spec parse_merge_marker(term()) :: {:ok, integer()} | :error
  def parse_merge_marker(body) when is_binary(body) do
    case Regex.run(@merge_marker_rx, body) do
      [_, n] -> {:ok, String.to_integer(n)}
      _ -> :error
    end
  end

  def parse_merge_marker(_), do: :error

  @result_block_rx ~r/```result\n(.*?)\n```/s
  @result_fence_limit 8192

  @doc """
  Encodes a nonempty map with Jason.encode!, fencing JSON up to 8192 bytes and otherwise
  returning a size note without truncated JSON. Empty maps/non-maps return ""; encoding may raise.
  The body separator is included. Round-trip equality requires JSON-compatible string-key data;
  atom keys, for example, decode as strings.

  The builder has test callers only: StepRunBuild retains eng_summary rather than structured
  pod outputs. The parser is used by get_predecessor_result; the next judge's brief falls back
  to branch code when absent. A card's documentary outputs field does not wire up this block.
  """
  @spec result_block(map() | nil) :: String.t()
  def result_block(outputs) when is_map(outputs) and map_size(outputs) > 0 do
    json = Jason.encode!(outputs)

    if byte_size(json) <= @result_fence_limit do
      "\n\n```result\n#{json}\n```"
    else
      "\n\n_(result #{byte_size(json)} o — trop volumineux pour le comment ; livrable complet sur la branche système)_"
    end
  end

  def result_block(_), do: ""

  @doc false
  # First matching LF-delimited result fence, without line anchors or a parser size limit.
  # Invalid/non-map JSON returns nil without trying later fences in that body.
  # get_predecessor_result reverses server comment order to choose the last usable comment.
  @spec parse_result_block(binary()) :: {:ok, map()} | nil
  def parse_result_block(body) when is_binary(body) do
    case Regex.run(@result_block_rx, body) do
      [_, json] ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def parse_result_block(_), do: nil

  @doc false
  # Exact user.login comparison with a nonempty binary bot login, not cryptographic validation.
  # Missing keys yield false; a malformed non-map user can raise during nested access.
  @spec system_authored?(term(), term()) :: boolean()
  def system_authored?(object, bot_login)
      when is_map(object) and is_binary(bot_login) and bot_login != "" do
    get_in(object, ["user", "login"]) == bot_login
  end

  def system_authored?(_object, _bot), do: false
end
