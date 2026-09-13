defmodule Fleet.MCP.PodTools.Delegation.Workshop do
  @moduledoc """
  Shared workshop root/workspace resolution for lots and scratchpad, using
  :mcp_workshop_root or Layout's default. One override keeps both readers aligned.
  """

  # Resolve the project's basename under workshop; this is a layout rule, not an authorization check.
  @doc false
  @spec lot_workspace(String.t()) :: String.t()
  def lot_workspace(repo), do: Path.join(root(), Fleet.Layout.project_name(repo))

  @doc false
  @spec root() :: String.t()
  def root,
    do: Application.get_env(:lcars_fleet, :mcp_workshop_root) || Fleet.Layout.workshop_root()
end
