defmodule Fleet.MCP.PodTools.Delegation.EscalationForge do
  @moduledoc """
  Forge callbacks for escalation inbox reads and replies, separate from ForgeClient
  so stubs can declare the surfaces they use. Both resolve the same runtime module.
  """

  @doc "OPEN issues of `repo` (raw Gitea maps; `opts[:assigned_by]` scopes to the human)."
  @callback list_open_issues(repo :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Comments of an issue (raw Gitea maps)."
  @callback list_comments(repo :: String.t(), number :: integer(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Returns the last escalation-marked comment or nil. The client owns marker parsing;
  MCP need not depend on the producer's marker construction. A recurrence brake can
  set the escalation label without a comment, so nil can be a valid result.
  """
  @callback escalation_verdict(repo :: String.t(), number :: integer(), opts :: keyword()) ::
              {:ok, String.t() | nil} | {:error, term()}

  @doc "Posts a comment on an issue (author/token in `opts`)."
  @callback post_comment(
              repo :: String.t(),
              number :: integer(),
              body :: String.t(),
              opts :: keyword()
            ) :: {:ok, :posted | :already} | {:error, term()}

  @doc "Returns the same resolved forge module as `ForgeClient`."
  @spec resolved() :: module()
  def resolved, do: Fleet.MCP.PodTools.Delegation.ForgeClient.resolved()
end
