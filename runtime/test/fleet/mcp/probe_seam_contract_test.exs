defmodule Fleet.MCP.ProbeSeamContractTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Check Probe's manually listed calls against real default modules, not injected stubs.
  Delegation behaviours do not cover this separate forge seam. A stub can export
  get_file/3 while the production facade lacks it, so stubbed tests alone are insufficient.
  Keep the call lists below synchronized when Probe adds a call; coverage is not derived.
  """

  # Les défauts des deux seams, lus dans `probe.ex` (`defp forge/0`, `defp forge_actions/0`).
  @forge_client Fleet.Forge.Client
  @forge_actions Fleet.Forge.Client.Actions

  # {fonction, arité} que `probe.ex` tape sur `forge()`. Toute addition d'un `forge().x(...)` dans
  # `probe.ex` s'ajoute ICI dans le même geste, sinon ce mur ne la couvre pas.
  @forge_calls [get_file: 3, pr_refs: 3, repo_full_name: 2]

  # Idem pour `forge_actions()`.
  @actions_calls [dispatch_workflow: 5, run: 3, run_logs: 3]

  # Load modules before checking exports to distinguish unloaded code from missing functions.
  defp missing_calls(mod, calls) do
    assert Code.ensure_loaded?(mod), "le module de seam #{inspect(mod)} n'existe pas"

    for {fun, arity} <- calls,
        not function_exported?(mod, fun, arity),
        do: "#{inspect(mod)}.#{fun}/#{arity}"
  end

  test "le seam :forge_client par défaut exporte tout ce que la sonde appelle dessus" do
    missing = missing_calls(@forge_client, @forge_calls)

    assert missing == [],
           "le rail réel plantera sur ces appels (absents du seam par défaut) : #{Enum.join(missing, ", ")}"
  end

  test "le seam :forge_actions par défaut exporte tout ce que la sonde appelle dessus" do
    missing = missing_calls(@forge_actions, @actions_calls)

    assert missing == [],
           "le rail réel plantera sur ces appels (absents du seam par défaut) : #{Enum.join(missing, ", ")}"
  end
end
