defmodule Fleet.MCP.PodTools.Delegation.Workshop do
  @moduledoc """
  Where a project's drafting matter lives on disk — the `workshop` face, and the per-project
  workspace inside it.

  UNE clef pour la racine, tous ses lecteurs. Deux clefs seraient deux facons de brancher une
  moitie du rail et pas l'autre ; un chemin de lot recalcule dans le rail scratchpad
  (`Path.join(workshop_root(), Layout.project_name(repo))`) serait une seconde copie du meme chemin,
  dont une seule suivrait un changement de layout.
  """

  # The lot is sourced from the WORKSHOP face — a layout fact, not a privilege of the calling role:
  # `workshop` is where a project's drafting matter lives (`Fleet.Layout`), which is what a lot is
  # made of. The root is overridable the same way the brief's ops root is, for tests that own a
  # temporary clone.
  @doc false
  @spec lot_workspace(String.t()) :: String.t()
  def lot_workspace(repo), do: Path.join(root(), Fleet.Layout.project_name(repo))

  # UNE clef pour la racine des faces atelier, deux lecteurs. Deux clefs seraient deux facons de
  # brancher une moitie et pas l'autre.
  @doc false
  @spec root() :: String.t()
  def root,
    do: Application.get_env(:lcars_fleet, :mcp_workshop_root) || Fleet.Layout.workshop_root()
end
