defmodule Fleet.Workflow.GraphValidatorPropertyTest do
  @moduledoc """
  Samples valid chains and mutations violating individual graph constraints.
  Generated graphs have one to six step maps with list-valued needs, excluding
  empty graphs and malformed nested values. Checks diagnostics and positive
  controls without proving totality or soundness over all maps.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Workflow.GraphValidator

  # The kinds from GraphValidator's @type — the output contract, locked here.
  @kinds [:phantom_edge, :no_root, :multiple_roots, :unreachable, :cycle, :fan_out]

  # ── generators ──

  # Underscore is excluded, so fresh prefixed tokens cannot collide with declared names.
  defp step_name, do: string([?a..?z], min_length: 1, max_length: 4)

  # Fresh token guaranteed NOT declared (contains `_`, outside the generated-name charset).
  defp fresh(prefix), do: map(step_name(), &(prefix <> "_" <> &1))

  defp spec(needs), do: %{"needs" => needs, "role" => "engineer"}

  # List-valued needs can contain phantom names, self-loops and duplicates.
  defp steps_gen do
    gen all(
          names <- uniq_list_of(step_name(), min_length: 1, max_length: 6),
          needs_lists <-
            list_of(
              list_of(one_of([member_of(names), step_name()]), max_length: 3),
              length: length(names)
            )
        ) do
      names |> Enum.zip(needs_lists) |> Map.new(fn {n, needs} -> {n, spec(needs)} end)
    end
  end

  # Chain pairs allow the shuffled Map.new call below.
  defp chain_pairs(names) do
    [root | rest] = names

    [
      {root, spec([])}
      | Enum.map(Enum.zip(names, rest), fn {prev, cur} -> {cur, spec([prev])} end)
    ]
  end

  defp chain_names(min_length),
    do: uniq_list_of(step_name(), min_length: min_length, max_length: 6)

  # ── P1 — TOTALITY ──

  # Check result shapes and Loader's diagnostic renderer on the generated domain.
  property "P1 TOTALITY — validate/1 never raises and always returns a kind from the contract" do
    check all(steps <- steps_gen(), max_runs: 300) do
      case GraphValidator.validate(steps) do
        :ok ->
          :ok

        {:error, {kind, detail}} ->
          assert kind in @kinds, "kind outside @type: #{inspect(kind)}"
          assert is_map(detail)

          # describe/1 must know how to speak of EVERYTHING validate/1 returns (the Loader calls it).
          assert is_binary(GraphValidator.describe({kind, detail}))
      end
    end
  end

  # ── P2 — SOUNDNESS ──

  # Shuffling pairs reconstructs the same map; it does not vary map traversal order.
  property "P2a — linear chain (permuted insertion order) → always :ok" do
    check all(names <- chain_names(1)) do
      pairs = chain_pairs(names)

      assert :ok = GraphValidator.validate(Map.new(pairs))
      assert :ok = GraphValidator.validate(Map.new(Enum.shuffle(pairs)))
    end
  end

  # A fresh phantom name tests inter-step references beyond schema validation.
  property "P2b — `needs` mutation → undeclared name → :phantom_edge (never :ok)" do
    check all(
            names <- chain_names(2),
            idx <- integer(0..5),
            ghost <- fresh("phantom")
          ) do
      pairs = chain_pairs(names)
      # We mutate a NON-root step (index ≥ 1): the root has `needs: []`, it has no edge.
      victim = Enum.at(names, 1 + rem(idx, length(names) - 1))
      steps = pairs |> Map.new() |> Map.put(victim, spec([ghost]))

      assert {:error, {:phantom_edge, %{step: ^victim, needs: ^ghost}}} =
               GraphValidator.validate(steps)
    end
  end

  # Two roots leave no unique sequential entry point.
  property "P2c — added-root mutation → :multiple_roots (never :ok)" do
    check all(names <- chain_names(1), extra <- fresh("phantom")) do
      steps = names |> chain_pairs() |> Map.new() |> Map.put(extra, spec([]))

      assert {:error, {:multiple_roots, %{roots: roots}}} = GraphValidator.validate(steps)
      assert extra in roots
      assert hd(names) in roots
    end
  end

  # Reachability takes precedence over cycle detection for the disconnected component.
  property "P2d — orphan blob disconnected from the root → :unreachable (never :ok)" do
    check all(names <- chain_names(1), a <- fresh("orphana"), b <- fresh("orphanb")) do
      steps =
        names
        |> chain_pairs()
        |> Map.new()
        |> Map.put(a, spec([b]))
        |> Map.put(b, spec([a]))

      assert {:error, {:unreachable, %{steps: orphans}}} = GraphValidator.validate(steps)
      assert Enum.sort([a, b]) == orphans
    end
  end

  # Reject branches at load, before WorkflowMapNav encounters unsupported fan-out.
  property "P2e — parallel-branch mutation → :fan_out (never :ok)" do
    check all(names <- chain_names(2), idx <- integer(0..5), leaf <- fresh("phantom")) do
      # The forked step must ALREADY have a successor → anything but the terminal.
      forked = Enum.at(names, rem(idx, length(names) - 1))
      steps = names |> chain_pairs() |> Map.new() |> Map.put(leaf, spec([forked]))

      assert {:error, {:fan_out, %{step: ^forked, successors: succs}}} =
               GraphValidator.validate(steps)

      assert leaf in succs
      assert length(succs) == 2
    end
  end

  # ── P3 — CYCLE ──

  # Keep the root and reachability intact while introducing a cycle.
  property "P3 — chain + terminal loop-back → :cycle (never :ok)" do
    check all(names <- chain_names(3)) do
      [s0, s1 | _] = names
      terminal = List.last(names)

      # s1 `needs` [s0, terminal] → cycle s1 → s2 → … → terminal → s1, root s0 intact.
      steps = names |> chain_pairs() |> Map.new() |> Map.put(s1, spec([s0, terminal]))

      assert {:error, {:cycle, %{steps: cyclic}}} = GraphValidator.validate(steps)
      assert s1 in cyclic
      assert terminal in cyclic
      refute s0 in cyclic, "the root is outside the cycle — it must not be incriminated"
    end
  end
end
