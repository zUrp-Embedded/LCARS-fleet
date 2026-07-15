defmodule Fleet.MCP.PodTools.Delegation.EscalationForge do
  @moduledoc """
  Escalation-inbox behaviour — the CONTRACT of the forge ops the arch's escalation channel
  (`list_escalations` / `comment_issue`) needs, DISTINCT from the DELEGATION `ForgeClient`
  behaviour (create_issue/…). DR-012: a seam contract must be inspectable in ONE place — these
  four ops used to live as an ad-hoc `function_exported?` list HIDDEN inside `Delegation`, a
  SECOND contract next to the official behaviour. Declared here as a behaviour, `conforming_escalation_forge/0`
  now checks against `behaviour_info(:callbacks)`, same mechanical guard as `conforming_forge/0`.

  Why a SEPARATE behaviour (not extending `ForgeClient`): adding these to `ForgeClient` would cascade
  onto every DELEGATION stub (StubForge/RecordingForge) that adopts it — their create_issue-only tests
  would break on missing callbacks. Two behaviours = each stub adopts only the surface it must satisfy.

  Resolves to the SAME seam module as `ForgeClient` (`:fleet_mcp, :forge_client`): the real
  `Fleet.Pilot.ForgeClient` implements BOTH surfaces; a stub used on the escalation path adopts THIS
  behaviour. Runtime (upward mcp → pilot) seam, like `ForgeClient` — no compile dep.
  """

  @doc "Repos of the escalation org — `{:ok, [full_name]}` (`\"owner/name\"`)."
  @callback list_org_repos(org :: String.t(), opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc "OPEN issues of `repo` (raw Gitea maps; `opts[:assigned_by]` scopes to the human)."
  @callback list_open_issues(repo :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Comments of an issue (raw Gitea maps)."
  @callback list_comments(repo :: String.t(), number :: integer(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Posts a comment on an issue (author/token in `opts`)."
  @callback post_comment(
              repo :: String.t(),
              number :: integer(),
              body :: String.t(),
              opts :: keyword()
            ) :: {:ok, :posted | :already} | {:error, term()}

  @doc """
  Resolved escalation forge — the SAME seam module as the delegation `ForgeClient`
  (`:fleet_mcp, :forge_client`): the two contracts describe two surfaces of ONE forge client.
  Single source of the default via `ForgeClient.resolved/0`.
  """
  @spec resolved() :: module()
  def resolved, do: Fleet.MCP.PodTools.Delegation.ForgeClient.resolved()
end
