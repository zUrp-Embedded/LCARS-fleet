defmodule Fleet.MCP.PodTools.Delegation.Dependencies do
  @moduledoc """
  Adds/removes same-repository dependency edges and attaches creation-time blockers.
  Validates positive distinct ids for individual edits, then delegates to the forge;
  it does not read both endpoints or provide a transaction. Retirement owns carry-over.
  """

  require Logger

  alias Fleet.MCP.PodTools.Delegation.{DependencyForge, Gate}

  # Public for testing partial-failure result shape without full issue creation fixtures.
  # The issue already exists: returned edge failures add a warning rather than losing its id.
  @doc false
  @spec attach_dependencies(module(), String.t(), map(), term()) :: map()
  def attach_dependencies(_forge, _repo, result, nil), do: result
  def attach_dependencies(_forge, _repo, result, []), do: result

  def attach_dependencies(forge, repo, result, blockers) when is_list(blockers) do
    n = Map.get(result, "issue")

    # Missing callbacks degrade the result. Callback exceptions are not caught here.
    case Gate.conforming(DependencyForge, forge) do
      {:ok, _} ->
        failed =
          Enum.reject(blockers, fn b ->
            match?({:ok, _}, forge.add_issue_dependency(repo, n, b, []))
          end)

        report_edges(result, blockers, failed)

      {:error, {:seam_misconfigured, mod, missing}} ->
        Logger.error(
          "Delegation: dependency seam #{inspect(mod)} is missing #{inspect(missing)} — " <>
            "no edge written for issue #{n}"
        )

        report_edges(result, blockers, blockers)
    end
  end

  defp report_edges(result, blockers, []), do: Map.put(result, "depends_on", blockers)

  defp report_edges(result, blockers, failed) do
    result
    |> Map.put("depends_on", blockers -- failed)
    |> Map.put(
      "depends_on_warning",
      "arêtes NON posées sur la forge : #{inspect(failed)} — la contrainte n'est portée que par " <>
        "la prose du brief, fais-la poser par ton humain"
    )
  end

  @doc """
  Adds number's blocker after creation. Does not stop work already admitted;
  admission reads dependencies when the step starts. The returned scope describes
  the forge's closure constraint, not a cancellation of running pods.
  """
  @spec add_dependency(integer(), integer(), map()) :: {:ok, map()} | {:error, term()}
  def add_dependency(number, blocker, state) do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         do: edge(:add, repo, number, blocker)
  end

  @doc """
  Removes number's blocker. Removing the last dependency releases that dependency
  constraint; it does not establish that every other closure condition is satisfied.
  """
  @spec remove_dependency(integer(), integer(), map()) :: {:ok, map()} | {:error, term()}
  def remove_dependency(number, blocker, state) do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         do: edge(:remove, repo, number, blocker)
  end

  # Keep gates visible in the public entry points for mcp.tools_gated's AST check.
  defp edge(op, repo, number, blocker)
       when is_integer(number) and number > 0 and is_integer(blocker) and blocker > 0 and
              number != blocker do
    with {:ok, forge} <- Gate.conforming_forge(),
         {:ok, _} <- Gate.conforming(DependencyForge, forge),
         {:ok, _} <- apply_edge(op, forge, repo, number, blocker) do
      {:ok,
       %{
         "issue" => number,
         "blocker" => blocker,
         "edge" => if(op == :add, do: "added", else: "removed"),
         "portee" => edge_scope(op, number)
       }}
    end
  end

  # Reject a self-edge locally to avoid an unresolvable dependency.
  defp edge(_op, _repo, number, blocker) when number == blocker,
    do: {:error, {:self_dependency, number}}

  defp edge(_op, _repo, _number, _blocker), do: {:error, :invalid_arguments}

  defp apply_edge(:add, forge, repo, number, blocker),
    do: forge.add_issue_dependency(repo, number, blocker, [])

  defp apply_edge(:remove, forge, repo, number, blocker),
    do: forge.remove_issue_dependency(repo, number, blocker, [])

  defp edge_scope(:add, n),
    do:
      "L'arête est posée sur la forge. Si ##{n} est DÉJÀ en vol, elle ne l'arrête pas — la porte " <>
        "d'admission lit les bloqueurs au DÉMARRAGE du step, et cette lecture a eu lieu. Ce qu'elle " <>
        "bloque est la FERMETURE de ##{n} tant que le bloqueur est ouvert."

  defp edge_scope(:remove, n),
    do:
      "L'arête est levée. Si c'était le dernier bloqueur de ##{n}, il devient fermable " <>
        "immédiatement — la forge ne retient plus rien."
end
