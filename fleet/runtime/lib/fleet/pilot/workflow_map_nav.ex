defmodule Fleet.Pilot.WorkflowMapNav do
  @moduledoc """
  **Pure** navigation within a workflow_map (pipeline) — the forge-driven chaining of steps.
  Replaces the RAM logic `Executor.next_step_or_done` with a **stateless**
  resolution: given the
  workflow_map (`Fleet.Workflow.Loader` output) + the **current step name**, computes the
  next step (or terminal).

  ## Why keyed by step NAME, not by role

  Naive key "the step whose `role` = assignee": **insufficient** —
  a workflow_map can have the same role on several steps (e.g. `standard-qa`:
  `architect` is on `brainstorm` AND `plan`). The assignee (= role) alone
  **does not identify** the step. The canonical position is therefore the **step name**, which
  the runtime engraves on the forge (enriched lock comment `[lock:role:step:ts]`) and
  re-reads to navigate. `WorkflowMapNav` is keyed by step name; where
  the name comes from (forge) is the caller's concern.

  ## Cardinality (linear MVP)

  The MVP chain is **linear**: each step has 0 or 1 successor (the step that
  `needs` it). A DAG with parallel branches (≥2 successors) is **out-of-scope** →
  explicit `{:error, :dag_not_supported}` (no silent choice). Same for entry:
  exactly 1 root (`needs: []`).

  ## Consumed workflow_map format

  `Loader` output: `%{"name" => ..., "steps" => %{name => %{"role", "needs", "gate"?, ...}}}`.
  String keys (the Loader normalizes v1/v2.5 to this form). `WorkflowMapNav` does not load —
  the caller passes the already-loaded workflow_map.
  """

  @type workflow_map :: %{required(String.t()) => any()}
  @type step_name :: String.t()
  @type role :: String.t()

  @doc """
  Entry step = the single root (`needs: []`). `{:error, :no_root}` if none,
  `{:error, :multiple_roots}` if ≥2 (parallel entry = out-of-scope).
  """
  @spec first_step(workflow_map()) :: {:ok, {step_name(), role()}} | {:error, atom()}
  def first_step(workflow_map) do
    steps = steps(workflow_map)

    roots =
      Enum.filter(steps, fn {_name, spec} -> needs(spec) == [] end)

    case roots do
      [{name, spec}] -> {:ok, {name, role(spec)}}
      [] -> {:error, :no_root}
      _ -> {:error, :multiple_roots}
    end
  end

  @doc """
  Step following the current step (by `needs`). `:terminal` if no successor
  (end of chain); `{:error, :unknown_step}` if the current step does not exist;
  `{:error, :dag_not_supported}` if ≥2 successors (parallel branch, out-of-scope).
  """
  @spec next_step(workflow_map(), step_name()) ::
          {:ok, {step_name(), role()}} | :terminal | {:error, atom()}
  def next_step(workflow_map, current_step) when is_binary(current_step) do
    steps = steps(workflow_map)

    if not Map.has_key?(steps, current_step) do
      {:error, :unknown_step}
    else
      successors =
        Enum.filter(steps, fn {_name, spec} -> current_step in needs(spec) end)

      case successors do
        [] -> :terminal
        [{name, spec}] -> {:ok, {name, role(spec)}}
        _ -> {:error, :dag_not_supported}
      end
    end
  end

  @doc "Role of a named step. `:error` if unknown."
  @spec step_role(workflow_map(), step_name()) :: {:ok, role()} | :error
  def step_role(workflow_map, step_name) do
    case Map.get(steps(workflow_map), step_name) do
      nil -> :error
      spec -> {:ok, role(spec)}
    end
  end

  @doc "Raw spec of a step (to read `gate`, `profile`, `timeout_sec`…). `:error` if unknown."
  @spec step_spec(workflow_map(), step_name()) :: {:ok, map()} | :error
  def step_spec(workflow_map, step_name) do
    case Map.get(steps(workflow_map), step_name) do
      nil -> :error
      spec -> {:ok, spec}
    end
  end

  # No "explicit-step" guardrail (soft⟺gatekeeper biconditional): a `soft` gate
  # on a business step is legitimate — it dispatches the gatekeeper (exception judge), it does
  # NOT designate a `role: gatekeeper` step. There is no gatekeeper step, so nothing to
  # validate. cf. `StepRunConsumer.gate_decide`.

  # ── internals ──
  defp steps(workflow_map), do: Map.get(workflow_map, "steps", %{})
  defp needs(spec), do: Map.get(spec, "needs", [])
  defp role(spec), do: Map.get(spec, "role")

  @doc """
  PROTECTED loading of a workflow_map — SINGLE authority for the rescue of `load!` (consolidates
  3 wrappers that duplicated it across StepDispatcher/Poller/StepRunConsumer, with 2 divergent error
  TAGS for the same failure). `loader` = module (`load!/1`) or 1-arity function (test seams for both forms).
  `{:ok, map}` | `{:error, {:workflow_map_load_failed, name, message}}` — unified tag; the WHY
  of the failure (map removed from catalogue, broken schema) is in `message`.
  """
  @spec safe_load(module() | (String.t() -> map()), String.t()) ::
          {:ok, map()} | {:error, {:workflow_map_load_failed, String.t(), String.t()}}
  def safe_load(loader, name) when is_binary(name) do
    map = if is_function(loader, 1), do: loader.(name), else: loader.load!(name)
    {:ok, map}
  rescue
    e -> {:error, {:workflow_map_load_failed, name, Exception.message(e)}}
  end
end
