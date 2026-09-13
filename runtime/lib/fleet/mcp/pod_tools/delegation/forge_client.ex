defmodule Fleet.MCP.PodTools.Delegation.ForgeClient do
  @moduledoc """
  Consumer-owned issue/PR callbacks for the :mcp_forge_client seam.
  Fleet.Forge.Client is the default; Gate.conforming checks exports at runtime.
  The lower Forge domain cannot adopt this MCP behaviour without an upward compile
  dependency, so default-export tests complement behaviours declared by test stubs.
  Neither check establishes callback return values.

  get_route supports the same Project.Roles verdict-policy resolution used by the
  gate, so architect status does not display a bare jury outcome under different policy.
  """

  @doc "Creates an issue → `{:ok, number}` (author/assignee/token passed in `opts`)."
  @callback create_issue(
              repo :: String.t(),
              title :: String.t(),
              body :: String.t(),
              opts :: keyword()
            ) :: {:ok, issue_number :: integer()} | {:error, term()}

  @doc """
  Adds the human-facing type label derived from destination. Creation discards its
  result; routing destination labels instead travel in create_issue's initial options.
  """
  @callback add_label(
              repo :: String.t(),
              issue_number :: integer(),
              label :: String.t(),
              opts :: keyword()
            ) :: {:ok, :added | :already_present} | {:error, term()}

  @doc """
  Resolves a label name to the id required in issue creation. Include destination
  in that initial write: a later add leaves a poller window using the wrong card.
  """
  @callback repo_label_id(repo :: String.t(), name :: String.t(), opts :: keyword()) ::
              {:ok, integer()} | {:error, term()}

  @doc "Reads an issue (raw Gitea API map — Delegation reads `\"state\"`)."
  @callback get_issue(repo :: String.t(), number :: integer(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Lists repository PRs across open and closed/merged states. Status needs historical
  PRs so review information can survive merge; consumers read head, state, merged and number.
  """
  @callback list_pulls(repo :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Lists open issues with pagination. Creation readback searches their lcars-op body
  markers across the repo without assignee scoping to reuse a completed prior attempt.
  Closing that issue removes it from this readback scope.
  """
  @callback list_open_issues(repo :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Parses lcars/issue-<n>-<role> into issue number and role, otherwise :error.
  Kept on the seam so callers do not reach directly into protocol parsing.
  """
  @callback parse_feature_branch(head :: String.t()) ::
              {:ok, {issue_number :: integer(), role :: String.t()}} | :error

  @doc """
  Returns head-scoped decisive verdicts, jury reviewers and the shared computed outcome.
  records adds each in-force review's body and submitted_at, distinguishing approvals
  with different substance/timing. A missing records key degrades status rendering
  without being reported as an unreachable forge.
  """

  @callback pr_review_state(repo :: String.t(), index :: integer(), opts :: keyword()) ::
              {:ok,
               %{
                 verdicts: %{optional(String.t()) => :approved | :changes_requested},
                 reviewers: [String.t()],
                 records: [map()],
                 outcome: {:pending, [String.t()]} | :no_jury | :changes_requested | :approved
               }}
              | {:error, term()}

  @doc """
  The card ROUTE engraved on an issue — `{:ok, {card_name, step}}`, or `:none` when the issue
  carries no route (a human ticket, a PR adopted after the fact).
  """
  @callback get_route(repo :: String.t(), number :: integer(), opts :: keyword()) ::
              {:ok, {String.t(), String.t()}} | :none | {:error, term()}

  @doc """
  Posts a comment. Retirement uses system-authored traces on the old ticket;
  the replacement's filiation trailer records the architect's decision.
  """
  @callback post_comment(
              repo :: String.t(),
              issue_number :: integer(),
              body :: String.t(),
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  @doc """
  Closes an issue. Used by retirement, including explicit issue_retire and supersede.
  """
  @callback close_issue(repo :: String.t(), issue_number :: integer(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Closes a PR without merging. Pull processing is independent of issue retirement;
  leaving the PR open can allow further review and merge after its ticket is retired.
  """
  @callback close_pr(repo :: String.t(), index :: integer(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Resolves a merged PR through its `[merge:pr-N]` seal marker.

  Gitea rewrites deleted merged-branch `head.ref` values (observed live 2026-07-19), so branch
  scanning alone cannot recover them. `:none` means no marker; outages remain errors.
  """
  @callback merged_pr_of_issue(repo :: String.t(), issue_number :: integer(), opts :: keyword()) ::
              {:ok, map()} | :none | {:error, term()}

  @default_client Fleet.Forge.Client

  @doc "Returns the configured forge client or the canonical `Fleet.Forge.Client`."
  @spec resolved() :: module()
  def resolved, do: Application.get_env(:lcars_fleet, :mcp_forge_client, @default_client)
end
