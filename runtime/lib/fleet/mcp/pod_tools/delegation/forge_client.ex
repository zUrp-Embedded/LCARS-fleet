defmodule Fleet.MCP.PodTools.Delegation.ForgeClient do
  @moduledoc """
  Forge-client behaviour — the CONTRACT of the `:forge_client` runtime seam, consumed
  by `Fleet.MCP.PodTools.Delegation` (DELEGATION / TRACKING channels).

  The contract belongs to the CONSUMER: the 13 callbacks are EXACTLY the functions that
  `Delegation` calls (create_issue, add_label, repo_label_id, get_issue, list_pulls,
  list_open_issues, parse_feature_branch, pr_review_state, get_route, post_comment, close_issue,
  close_pr, merged_pr_of_issue) — not the full surface of `Fleet.Forge.Client`.

  `get_route/3` est au CONTRAT (C2), et l'y déclarer plutôt que l'appeler en douce est le fond de
  l'affaire : la surface arch doit résoudre la politique de verdict d'une PR par la MÊME fonction
  que le gate (`Roles.verdict_policy_for/4`), sinon elle affiche « approuvé » pendant que le rail
  renvoie en rework. Cette résolution lit la carte gravée sur l'issue, donc elle a besoin de la
  route — et une dépendance qu'un implémenteur découvre par un `UndefinedFunctionError` en
  production n'est pas un contrat, c'est un piège.

  ## Why a seam at all

  `Fleet.Forge` is a compile dep of this domain (`lib/fleet/mcp.ex`); the module is still resolved
  at RUNTIME (`resolved/0`: app-env + default) so a test injects a stub, and `Gate.conforming/2`
  refuses a stub that lies about the contract.

  ## Implementations

    * `Fleet.Forge.Client` — the REAL impl (canonical default). It lives in `Fleet.Forge`, which
      sits BELOW `Fleet.MCP` and does not depend on it: it CANNOT adopt this behaviour
      (`@behaviour` = a compile reference, an upward edge) and stays DUCK-TYPED with a
      cross-reference comment. This module is the source of truth of the contract as seen by the
      consumer; the callback types are aligned on the client's real `@spec`s (`Fleet.Forge.Client`,
      `Fleet.Forge.Client.Jury`, `Fleet.Forge.Protocol`).
    * Test stubs `Fleet.MCP.PodToolsTest.{StubForge, RecordingForge}` — same app →
      adopt the behaviour (the compiler checks conformance, anti lying-stub).
  """

  @doc "Creates an issue → `{:ok, number}` (author/assignee/token passed in `opts`)."
  @callback create_issue(
              repo :: String.t(),
              title :: String.t(),
              body :: String.t(),
              opts :: keyword()
            ) :: {:ok, issue_number :: integer()} | {:error, term()}

  @doc """
  Labels an issue. Delegation's only call site posts the VISUAL type derived from the destination
  (`Fleet.Labels.type_for_destination/1`) and discards the result: the label is human-facing decoration,
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
  CREATE call as an id, and the destination label MUST ride it (a post-create add leaves a window where
  a poller tick burns the project card on a documentary ticket).

  Declared, like every call the seam carries: the seam is duck-typed, so an undeclared call
  compiles fine against the real module and raises `UndefinedFunctionError` against every stub —
  the branch that calls it then cannot be exercised at all. A contract with a hole does not merely
  fail to check that branch, it FORBIDS testing it.
  """
  @callback repo_label_id(repo :: String.t(), name :: String.t(), opts :: keyword()) ::
              {:ok, integer()} | {:error, term()}

  @doc "Reads an issue (raw Gitea API map — Delegation reads `\"state\"`)."
  @callback get_issue(repo :: String.t(), number :: integer(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  ALL the PRs of the repo, open + closed/merged (raw Gitea API maps — Delegation reads
  `head.ref`/`head.sha`/`state`/`merged`/`number`). The full-state read is the point: the
  review trail must survive the merge in `issue_status`.
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
  `Delegation` never calls `Fleet.Forge.Protocol` directly (compile dep).
  """
  @callback parse_feature_branch(head :: String.t()) ::
              {:ok, {issue_number :: integer(), role :: String.t()}} | :error

  @doc """
  Jury state of a PR: `verdicts` (last decisive review per reviewer, scoped to `head_sha`),
  `reviewers` (stable jury set), `outcome` — the SAME routing predicate the merge gate runs on
  (`Jury.review_outcome/2`), computed pilot-side and carried as DATA so no seam consumer (nor any
  test stub) re-implements the rule — and `records`.

  `records` is what `verdicts` structurally cannot say: the in-force review of each judge with its
  `body` and `submitted_at`. Two approvals are the same value in `verdicts` and were never the same
  thing on the forge — one cites its gate-brief, the other lands a second after being asked. A seam
  that omits the key is rendered as such (verdicts without substance), NEVER as an unreachable
  forge: a stub behind an outage message is how a missing implementation stays invisible.
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
  NEVER closes anything itself (no close tool); it expresses `supersedes: N` on `issue_create`
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
