defmodule Fleet.MCP.PodTools.Delegation.DependencyForge do
  @moduledoc """
  Dependency callbacks, separate from ForgeClient so stubs can declare the surfaces
  they use. Check the already-resolved module with Gate.conforming; resolving again
  could validate a different implementation.

  Retirement checks this surface before carrying edges and closing the old issue.
  Its PR may already be closed when that check fails, so the result is a partial
  retirement warning, not an atomic rollback.
  """

  @doc "The issues BLOCKING `number` — what it waits on (raw Gitea maps)."
  @callback issue_dependencies(repo :: String.t(), number :: integer(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "The issues `number` BLOCKS — the inverse edge (raw Gitea maps)."
  @callback issue_blocks(repo :: String.t(), number :: integer(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc ~S"""
  Adds number's dependency on blocker in the same repo.
  Retirement carry-over treats HTTP 409 as replay success without readback;
  direct edits and creation-time attachment do not normalize that error here.
  """
  @callback add_issue_dependency(
              repo :: String.t(),
              number :: integer(),
              blocker :: integer(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  Removes number's dependency on blocker. Retirement without a replacement uses
  removal to detach edges; this does not preserve a blocker on the dependent ticket.
  """
  @callback remove_issue_dependency(
              repo :: String.t(),
              number :: integer(),
              blocker :: integer(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}
end
