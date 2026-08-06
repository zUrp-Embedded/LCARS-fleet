defmodule Fleet.MCP.PodTools.Delegation.DependencyForge do
  @moduledoc """
  Dependency-edge behaviour — the CONTRACT of the forge ops that WRITE AND READ the order between
  tickets (`depends_on` at creation, edge carry-over at supersede), DISTINCT from the delegation
  `ForgeClient` behaviour.

  Why it exists: these three ops were called through the seam WITHOUT being declared anywhere. The
  `conforming/2` guard is there so a seam module missing a callback yields a clear
  `{:seam_misconfigured, mod, missing}` instead of an obscure `UndefinedFunctionError` deep in the
  delegation — and for the dependency ops it could not, because it only knows what a behaviour
  declares. The guard was not wrong; it was blind to a surface nobody had written down. Measured
  A seam call with no @callback on its path is vouched for by nothing: `conforming/2` can only
  answer for what a behaviour declares.

  The failure it prevents is not cosmetic. The edge carry-over runs INSIDE the supersede retirement,
  after the live PR has been closed: an `UndefinedFunctionError` there leaves the old ticket closed
  as a side effect of a crash, with its edges dropped — the exact "closing RELEASES what it blocked"
  hazard the carry-over exists to prevent.

  Why a SEPARATE behaviour (same reasoning as `EscalationForge`, DR-012): adding these to
  `ForgeClient` would cascade onto every delegation stub, including the many whose tests never touch
  a dependency. Two behaviours = each stub adopts only the surface it must satisfy.

  Checked against the module the caller was ALREADY HANDED (`conforming(DependencyForge, forge)`),
  not against a fresh resolution: the question is whether THIS module carries the surface, and
  re-resolving could answer about a different one.
  """

  @doc "The issues BLOCKING `number` — what it waits on (raw Gitea maps)."
  @callback issue_dependencies(repo :: String.t(), number :: integer(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "The issues `number` BLOCKS — the inverse edge (raw Gitea maps)."
  @callback issue_blocks(repo :: String.t(), number :: integer(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc ~S"""
  Adds "`number` depends on `blocker`" (same repo).

  A 409 on an edge that already exists is NOMINAL on the replay path, and the callers treat it as
  such — the contract is "the edge is there afterwards", not "this call created it".
  """
  @callback add_issue_dependency(
              repo :: String.t(),
              number :: integer(),
              blocker :: integer(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  Removes "`number` depends on `blocker`" (same repo).

  A retirement without a replacement has nowhere to move its edges, so it LIFTS them. Without this,
  closing the retired blocker would release every dependent as if the work had landed.
  """
  @callback remove_issue_dependency(
              repo :: String.t(),
              number :: integer(),
              blocker :: integer(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}
end
