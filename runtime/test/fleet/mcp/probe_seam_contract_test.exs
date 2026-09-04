defmodule Fleet.MCP.ProbeSeamContractTest do
  use ExUnit.Case, async: true

  @moduledoc """
  LE SEAM PAR DÉFAUT DE LA SONDE PORTE-T-IL CE QUE LA SONDE APPELLE DESSUS ?

  `Fleet.MCP.PodTools.Probe` ne passe pas par `Delegation` : il s'est fabriqué ses DEUX propres
  seams (`Application.get_env(:lcars_fleet, :forge_client, …)` et `:forge_actions`), donc aucun des
  cross-checks du behaviour `Delegation.ForgeClient` ne le couvre. Il peut appeler n'importe quelle
  fonction sur le module injecté, et rien ne mord AVANT le runtime.

  C'est exactement ce qui est arrivé au banc le 2026-08-20 : `probe.ex` appelait
  `forge().get_file/3`, qui vit dans `.Files` et n'existait PAS sur le défaut `Fleet.Forge.Client`.
  Les stubs de test définissaient `get_file`, donc la suite restait verte pendant que les deux
  juges plantaient — `{:tool_crashed, "run_probe", "…get_file/3 is undefined or private"}`.

  Un stub qui offre une fonction que le vrai module n'a pas est un mensonge silencieux. Ce mur
  confronte la liste des appels de `probe.ex` à ses seams RÉELS (défauts), pas aux stubs.

  ⚠ LA LISTE EST TENUE À LA MAIN, ET C'EST VOULU. Un test qui re-dérive les appels depuis l'AST de
  `probe.ex` prouverait « probe s'appelle lui-même », pas « le seam tient sa promesse ». En cas
  d'ajout d'un appel de seam dans `probe.ex`, cette liste est le second geste — et si on l'oublie,
  le trou n'est pas couvert : le commentaire au-dessus de `@forge_calls` le dit.
  """

  # Les défauts des deux seams, lus dans `probe.ex` (`defp forge/0`, `defp forge_actions/0`).
  @forge_client Fleet.Forge.Client
  @forge_actions Fleet.Forge.Client.Actions

  # {fonction, arité} que `probe.ex` tape sur `forge()`. Toute addition d'un `forge().x(...)` dans
  # `probe.ex` s'ajoute ICI dans le même geste, sinon ce mur ne la couvre pas.
  @forge_calls [get_file: 3, pr_refs: 3, repo_full_name: 2]

  # Idem pour `forge_actions()`.
  @actions_calls [dispatch_workflow: 5, run: 3, run_logs: 3]

  # `function_exported?/3` rend `false` sur un module PAS ENCORE CHARGÉ — ce qui ferait passer ce
  # mur pour un « fonction absente » alors que le module dort. On le charge d'abord ; s'il n'existe
  # carrément pas, `ensure_loaded?` rend `false` et l'assertion le dit franchement.
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
