defmodule Fleet.MCP.PodTools.Delegation.ForgeClient do
  @moduledoc """
  Forge-client behaviour — the CONTRACT of the `:forge_client` runtime seam, consumed
  by `Fleet.MCP.PodTools.Delegation` (DELEGATION / TRACKING channels).

  The contract belongs to the CONSUMER: the callbacks are EXACTLY the
  functions that `Delegation` calls (create_issue, add_label, get_issue,
  list_open_pulls, parse_feature_branch, pr_review_verdicts) — not the full
  surface of the pilot's forge client.

  ## Why a RUNTIME seam (and not a compile dep)

  `fleet_mcp` is Ring 2, `fleet_pilot` is Ring 3 (above): a compile dep
  `fleet_mcp → fleet_pilot` would be UPWARD, forbidden (the boundary compiler would reject it). The module is resolved at
  RUNTIME (`resolved/0`: app-env + default as a literal atom → no compile-time
  dep, no cycle). Seam declared in
  `priv/event_router/allowed_graph.yaml` (`seams` section, direction `up`).

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
  """

  @doc "Creates an issue → `{:ok, number}` (author/assignee/token passed in `opts`)."
  @callback create_issue(
              repo :: String.t(),
              title :: String.t(),
              body :: String.t(),
              opts :: keyword()
            ) :: {:ok, issue_number :: integer()} | {:error, term()}

  @doc "Labels an issue (best-effort on the Delegation side: result ignored)."
  @callback add_label(
              repo :: String.t(),
              issue_number :: integer(),
              label :: String.t(),
              opts :: keyword()
            ) :: {:ok, :added | :already_present} | {:error, term()}

  @doc "Reads an issue (raw Gitea API map — Delegation reads `\"state\"`)."
  @callback get_issue(repo :: String.t(), number :: integer(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "OPEN PRs of the repo (raw Gitea API maps — Delegation reads `head.ref`/`head.sha`)."
  @callback list_open_pulls(repo :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Parses a system feature-branch `lcars/issue-<n>-<role>` → `{:ok, {n, role}}`,
  `:error` if the ref is not a fleet feature-branch. Carried by the seam so that
  `Delegation` never calls `Fleet.Pilot.ForgeProtocol` directly (compile dep).
  """
  @callback parse_feature_branch(head :: String.t()) ::
              {:ok, {issue_number :: integer(), role :: String.t()}} | :error

  @doc "PR review verdicts (last review per reviewer, scoped to `head_sha`)."
  @callback pr_review_verdicts(repo :: String.t(), index :: integer(), opts :: keyword()) ::
              {:ok, %{optional(String.t()) => :approved | :changes_requested}}
              | {:error, term()}

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
