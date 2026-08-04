defmodule Fleet.MCP.PodTools.Delegation.ForgeClient do
  @moduledoc """
  Forge-client behaviour — the CONTRACT of the `:forge_client` runtime seam, consumed
  by `Fleet.MCP.PodTools.Delegation` (DELEGATION / TRACKING channels).

  The contract belongs to the CONSUMER: the callbacks are EXACTLY the
  functions that `Delegation` calls (create_issue, add_label, get_issue,
  list_pulls, list_open_issues, parse_feature_branch, pr_review_state,
  post_comment, close_issue, merged_pr_of_issue) — not the full surface of the
  pilot's forge client.

  ## Why a RUNTIME seam (and not a compile dep)

  `fleet_pilot` sits ABOVE `fleet_mcp` in the boundary ladder: a compile dep
  `fleet_mcp → fleet_pilot` would be UPWARD, forbidden (the boundary compiler would reject it). The module is resolved at
  RUNTIME (`resolved/0`: app-env + default as a literal atom → no compile-time
  dep, no cycle). Assumed UPWARD runtime seam (mcp → pilot).

  ## Implementations

    * `Fleet.Pilot.ForgeClient` — the REAL impl (canonical default). It lives in
      `fleet_pilot`, which does NOT depend on `fleet_mcp`: it CANNOT adopt
      this behaviour (`@behaviour` = a compile reference, would create a new edge)
      and stays DUCK-TYPED with a cross-reference comment. This module is the source
      of truth of the contract as seen by the consumer; the callback types are
      aligned on the pilot's real `@spec`s (`ForgeClient`, `ForgeClient.Jury`,
      `ForgeProtocol`).
    * Test stubs `Fleet.MCP.PodToolsTest.{StubForge, RecordingForge}` — same app →
      adopt the behaviour (the compiler checks conformance, anti lying-stub).

  **Last revised**: 2026-08-04
  """

  @doc "Creates an issue → `{:ok, number}` (author/assignee/token passed in `opts`)."
  @callback create_issue(
              repo :: String.t(),
              title :: String.t(),
              body :: String.t(),
              opts :: keyword()
            ) :: {:ok, issue_number :: integer()} | {:error, term()}

  @doc """
  Labels an issue. Delegation's only call site posts the VISUAL type derived from the genre
  (`Fleet.Labels.type_for_genre/1`) and discards the result: the label is human-facing decoration,
  nothing mechanical reads it, and its absence is directly visible on the issue in the forge UI.
  Derived and not constant — the decoration is the only thing a human scanning a list of issues
  reads, so a fixed `type:feature` on a documentary ticket misleads exactly the reader it exists for.
  """
  @callback add_label(
              repo :: String.t(),
              issue_number :: integer(),
              label :: String.t(),
              opts :: keyword()
            ) :: {:ok, :added | :already_present} | {:error, term()}

  @doc """
  Resolves a repo label NAME to its Gitea id. Needed because a label can only ride the issue
  CREATE call as an id, and the genre label MUST ride it (a post-create add leaves a window where
  a poller tick burns the project card on a documentary ticket).

  Declared here after the fact, and the omission is the reason the genre path had no test
  (2026-08-03): the seam is duck-typed, so an undeclared call compiles fine against the real
  module and raises `UndefinedFunctionError` against every stub — which made the ops branch of
  `do_create_issue` the one branch that could not be exercised. A contract with a hole does not
  merely fail to check that branch, it FORBIDS testing it.
  """
  @callback repo_label_id(repo :: String.t(), name :: String.t(), opts :: keyword()) ::
              {:ok, integer()} | {:error, term()}

  @doc "Reads an issue (raw Gitea API map — Delegation reads `\"state\"`)."
  @callback get_issue(repo :: String.t(), number :: integer(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  ALL the PRs of the repo, open + closed/merged (raw Gitea API maps — Delegation reads
  `head.ref`/`head.sha`/`state`/`merged`/`number`). The full-state read is the point: the
  review trail must survive the merge in `get_issue_status`.
  """
  @callback list_pulls(repo :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  OPEN issues of the repo (raw Gitea API maps — Delegation reads `\"number\"`/`\"title\"`/`\"body\"`).
  Paginated. Delegation call site: the create_issue idempotency readback — a delegation act carries
  an `<!-- lcars-op:<sig> -->` marker in its body; before creating, we list the open issues and reuse
  one already bearing this marker (a prior attempt that the stdio bridge timed out on at 30s while the
  forge write completed). No assignee scoping here (we dedup across the whole repo).
  """
  @callback list_open_issues(repo :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Parses a system feature-branch `lcars/issue-<n>-<role>` → `{:ok, {n, role}}`,
  `:error` if the ref is not a fleet feature-branch. Carried by the seam so that
  `Delegation` never calls `Fleet.Pilot.ForgeProtocol` directly (compile dep).
  """
  @callback parse_feature_branch(head :: String.t()) ::
              {:ok, {issue_number :: integer(), role :: String.t()}} | :error

  @doc """
  Jury state of a PR: `verdicts` (last decisive review per reviewer, scoped to `head_sha`),
  `reviewers` (stable jury set), and `outcome` — the SAME routing predicate the merge gate runs
  on (`Jury.review_outcome/2`), computed pilot-side and carried as DATA so no seam consumer
  (nor any test stub) re-implements the rule.
  """
  @callback pr_review_state(repo :: String.t(), index :: integer(), opts :: keyword()) ::
              {:ok,
               %{
                 verdicts: %{optional(String.t()) => :approved | :changes_requested},
                 reviewers: [String.t()],
                 outcome: {:pending, [String.t()]} | :no_jury | :changes_requested | :approved
               }}
              | {:error, term()}

  @doc """
  Posts a comment on an issue. Delegation call site: the SYSTEM's supersede-retirement trace
  on the replaced ticket (default opts = system token — the system executes the retirement,
  the arch's decision is visible on the NEW ticket's filiation trailer).
  """
  @callback post_comment(
              repo :: String.t(),
              issue_number :: integer(),
              body :: String.t(),
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  @doc """
  Closes an issue (state=closed). Delegation call site: the supersede retirement — the arch
  NEVER closes anything itself (no close tool); it expresses `supersedes: N` on `create_issue`
  and the SYSTEM executes the retirement.
  """
  @callback close_issue(repo :: String.t(), issue_number :: integer(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Ferme une PR SANS la merger. Le retrait d'un ticket doit retirer SON TRAVAIL : le rail des pulls
  est independant (`dispatch_review` scrute les pulls, hors bail), donc une PR laissee ouverte sur
  un ticket retire continue d'etre jugee puis mergee.
  """
  @callback close_pr(repo :: String.t(), index :: integer(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  The MERGED PR of an issue, resolved by the `[merge:pr-N]` seal marker on the issue (raw
  Gitea PR map). Delegation call site: the post-merge fallback of `get_issue_status`'s PR
  resolution — Gitea rewrites a merged PR's `head.ref` once its branch is deleted, so the
  branch scan cannot find it (live 2026-07-19). `:none` = no marker; an outage must stay
  `{:error, _}`, never `:none`.
  """
  @callback merged_pr_of_issue(repo :: String.t(), issue_number :: integer(), opts :: keyword()) ::
              {:ok, map()} | :none | {:error, term()}

  # Canonical default: the real forge client on the fleet_pilot side. Literal atom (not a
  # literal remote call) → no compile-time dep. Set HERE once.
  @default_client Fleet.Pilot.ForgeClient

  @doc """
  Resolved forge client: config `:fleet_mcp, :forge_client` otherwise the canonical
  default `Fleet.Pilot.ForgeClient`. SINGLE SOURCE of the default (same pattern as
  `Fleet.Spawner.LaunchBackend.resolved/0`).
  """
  @spec resolved() :: module()
  def resolved, do: Application.get_env(:fleet_mcp, :forge_client, @default_client)
end
