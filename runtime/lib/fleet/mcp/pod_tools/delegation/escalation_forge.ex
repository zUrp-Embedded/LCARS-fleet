defmodule Fleet.MCP.PodTools.Delegation.EscalationForge do
  @moduledoc """
  Inspectable forge seam for architect escalation inbox reads and replies.

  DR-012 keeps this surface separate from `ForgeClient`, so test stubs implement only the callbacks
  they consume. Both behaviours resolve the same runtime forge module without an upward compile edge.
  """

  @doc "OPEN issues of `repo` (raw Gitea maps; `opts[:assigned_by]` scopes to the human)."
  @callback list_open_issues(repo :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Comments of an issue (raw Gitea maps)."
  @callback list_comments(repo :: String.t(), number :: integer(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  The last comment carrying an ESCALATION marker, or `nil`.

  Separate from `list_comments/3` on purpose: the marker FORMAT belongs to the pilot domain
  (`ForgeProtocol` builds it at both writing sites) and this boundary refuses to reach into it. The
  inbox asks; the client knows the protocol. `nil` is a result — the recurrence brake poses the
  label with no comment at all, so there is nothing to arbitrate on.
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
