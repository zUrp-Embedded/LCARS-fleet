defmodule Fleet.Workflow.GraphValidatorPropertyTest do
  @moduledoc """
  Property-based proof of the graph linter. `graph_validator_test.exs` pins NAMED
  cases (a wired cycle, a wired fan-out); here we prove the two properties that
  examples cannot prove:

    * TOTALITY — `validate/1` never RAISES and never returns a `kind` outside the
      contract, on any `steps` map (needs mixing declared members and phantom tokens).
      The Loader `raise`s on the `{kind, detail}`: an exception here (instead of an
      `{:error, …}`) would surface as an opaque `FunctionClauseError`/`Protocol.UndefinedError`
      instead of the actionable message from `describe/1`.
    * SOUNDNESS — no well-formed chain is refused (false-red), and NO mutation
      breaking an invariant passes as `:ok` (false-GREEN). The false-green is the real
      cost: a workflow_map with a phantom edge loads silently, and the pipeline FREEZES
      in prod on a step waiting for a nonexistent predecessor.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Workflow.GraphValidator

  # The kinds from GraphValidator's @type — the output contract, locked here.
  @kinds [:phantom_edge, :no_root, :multiple_roots, :unreachable, :cycle, :fan_out]

  # ── generators ──

  # Step name: [a-z]{1,4}. Charset WITHOUT `_` → a declared name can NEVER collide with
  # a fresh token (prefixed `phantom_`/`orphan_*`), which makes the mutations unfalsifiable.
  defp step_name, do: string([?a..?z], min_length: 1, max_length: 4)

  # Fresh token guaranteed NOT declared (contains `_`, outside the generated-name charset).
  defp fresh(prefix), do: map(step_name(), &(prefix <> "_" <> &1))

  defp spec(needs), do: %{"needs" => needs, "role" => "engineer"}

  # Arbitrary `steps` map: each step `needs` a mix of declared members and random tokens
  # (phantom edges), with possible self-loops and duplicates — the REAL input domain of
  # validate/1 (the draft-07 schema validates each step in ISOLATION, it lets everything through).
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

  # Linear chain s0 → s1 → … → sn (s0 = root, sn = terminal): the ONLY shape the
  # sequential runtime accepts. The pairs are returned as a LIST (not a map) so the
  # caller can permute the insertion order.
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

  # INVARIANT: on ANY `steps` map (including phantom needs, self-loops, duplicates, empty
  # graph), validate/1 returns :ok | {:error, {kind, detail}} with kind among the 6 of the
  # @type — never an exception, never a kind outside the contract.
  # WHY: the Loader composes describe/1 on the kind and then `raise`s — an unknown kind would
  # make a FunctionClauseError inside describe/1 (opaque crash at load time), and an exception
  # here would bubble up without the actionable diagnostic that is this module's REASON TO EXIST.
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

  # INVARIANT: every linear chain is :ok, whatever the INSERTION ORDER of the keys.
  # WHY: a false-red depending on the map's iteration order would make workflow_map loading
  # non-deterministic (loads here, `raise`s there, for the SAME YAML).
  property "P2a — linear chain (permuted insertion order) → always :ok" do
    check all(names <- chain_names(1)) do
      pairs = chain_pairs(names)

      assert :ok = GraphValidator.validate(Map.new(pairs))
      assert :ok = GraphValidator.validate(Map.new(Enum.shuffle(pairs)))
    end
  end

  # INVARIANT: a `needs` pointing to an undeclared name → always {:error, {:phantom_edge, _}}.
  # WHY: this is THE hole the JSON schema cannot see (typo `needs: [implment]`). A
  # false-green = the step waits for a nonexistent predecessor → pipeline frozen, SILENTLY.
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

  # INVARIANT: a 2nd root (`needs: []`) → always {:error, {:multiple_roots, _}}.
  # WHY: the runtime is sequential and starts on THE root; two entry points =
  # half the graph never starting (or a non-deterministic start).
  property "P2c — added-root mutation → :multiple_roots (never :ok)" do
    check all(names <- chain_names(1), extra <- fresh("phantom")) do
      steps = names |> chain_pairs() |> Map.new() |> Map.put(extra, spec([]))

      assert {:error, {:multiple_roots, %{roots: roots}}} = GraphValidator.validate(steps)
      assert extra in roots
      assert hd(names) in roots
    end
  end

  # INVARIANT: a disconnected blob (orphan cycle, no edge from the root) → :unreachable.
  # WHY: the moduledoc PROMISES that exact diagnostic (reachability checked BEFORE acyclicity)
  # because it is actionable ("these steps are not wired to the entry") where `:cycle` is
  # not. An orphan passing :ok would NEVER run.
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

  # INVARIANT: a step with ≥2 successors → always {:error, {:fan_out, _}}.
  # WHY: WorkflowMapNav already rejects the parallel branch AT NAVIGATION time
  # (`:dag_not_supported`) — here we fail at LOAD, earlier. A false-green would blow up
  # the workflow mid-flight instead of at load time.
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

  # INVARIANT: a chain whose intermediate step loops back onto the TERMINAL → {:error, {:cycle, _}}.
  # The root keeps `needs: []` (hence a single root) and everything stays reachable: the ONLY broken
  # invariant is acyclicity — it is Kahn's sort, and it alone, that must catch this.
  # WHY: a cycle loaded as :ok = pipeline frozen in prod, no reachable terminal, no message
  # at all. That is exactly the silent failure mode this module exists to kill.
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
