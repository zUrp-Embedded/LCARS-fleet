defmodule Fleet.MCP.PodTools.Delegation.Dependencies do
  @moduledoc """
  The dependency edges between delegated tickets — declared, carried over when a ticket is
  replaced, and lifted when it is retired.

  An edge is a fact about TWO tickets, so both ends are resolved before anything is written: an
  edge half-applied would leave a blocked ticket nobody can unblock, and the forge has no
  transaction to roll that back.
  """

  require Logger

  alias Fleet.MCP.PodTools.Delegation.{DependencyForge, Gate}

  # Writes the edges the architect declared at the moment they state the constraint. What fails is
  # SAID in the result (the arch relays it to its human), never swallowed: an edge believed to be
  # there and absent is worse than no edge at all.
  #
  # PUBLIC (@doc false), same reason as `retire_superseded/5`: the property under test is the SHAPE
  # OF THE DEGRADATION (the created issue survives a seam that cannot write edges), and reaching this
  # through `issue_create` would need an arch pod, role credentials and a ops tree — a test that
  # proves the fixture, not the guard.
  @doc false
  @spec attach_dependencies(module(), String.t(), map(), term()) :: map()
  def attach_dependencies(_forge, _repo, result, nil), do: result
  def attach_dependencies(_forge, _repo, result, []), do: result

  def attach_dependencies(forge, repo, result, blockers) when is_list(blockers) do
    n = Map.get(result, "issue")

    # SEAM CONFORMANCE, best-effort side. The issue is already created and CORRECT — a
    # non-conforming seam must degrade the order, not crash a gesture that succeeded. Without this,
    # a stub missing the callback raised deep inside the loop and the caller lost a created ticket
    # to an UndefinedFunctionError.
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
  Declares (or lifts) "`number` depends on `blocker`" AFTER creation.

  `create_issue(depends_on:)` could only state the order at birth, so a dependency discovered later
  had nowhere to go but the prose of a brief — where it holds exactly as long as an agent reads it,
  which is to say not at all.

  WHAT IT DOES NOT DO, and the result says so rather than letting the caller assume. On a ticket
  ALREADY in flight the edge does not stop anything: the admission gate reads its blockers when the
  step STARTS (`wait/depends`), and that reading has happened. What the edge does is block the
  ticket's CLOSURE, forge-side, until the blocker is resolved. An arch told "dependency added" about
  a running ticket would believe it had pulled a brake it never touched.
  """
  @spec add_dependency(integer(), integer(), map()) :: {:ok, map()} | {:error, term()}
  def add_dependency(number, blocker, state) do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         do: edge(:add, repo, number, blocker)
  end

  @doc """
  Lifts "`number` depends on `blocker`". Inverse of `add_dependency/3`, same gate, same caveat —
  and one of its own: lifting the LAST blocker of a ticket makes it closable immediately.
  """
  @spec remove_dependency(integer(), integer(), map()) :: {:ok, map()} | {:error, term()}
  def remove_dependency(number, blocker, state) do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         do: edge(:remove, repo, number, blocker)
  end

  # The gate stays in the two PUBLIC functions rather than here, and the wall is what said so:
  # `mcp.tools_gated` refused this pair when they merely forwarded, because a gate one call deeper
  # is invisible at the site a reader — or the checker — looks at. Factoring the mechanism is fine;
  # factoring the authorization out of sight is how a tool loses its door without anyone noticing.
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

  # A ticket cannot depend on itself, and the forge would accept the write. Refused here rather
  # than discovered as a ticket that can never close.
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
