defmodule Fleet.Pilot.WorkflowMapNav do
  @moduledoc """
  Navigates a loaded workflow map by step name, never by role.

  The supported graph is linear: exactly one root and at most one successor per step. Parallel entry
  or successors fail explicitly. A soft gate on a business step is valid and does not imply a
  gatekeeper-named step.
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

    if Map.has_key?(steps, current_step) do
      successors =
        Enum.filter(steps, fn {_name, spec} -> current_step in needs(spec) end)

      case successors do
        [] -> :terminal
        [{name, spec}] -> {:ok, {name, role(spec)}}
        _ -> {:error, :dag_not_supported}
      end
    else
      {:error, :unknown_step}
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

  @doc "Raw spec of a step (to read `gate`, `brief_kind`, `judge_target`, `modops`…). `:error` if unknown."
  @spec step_spec(workflow_map(), step_name()) :: {:ok, map()} | :error
  def step_spec(workflow_map, step_name) do
    case Map.get(steps(workflow_map), step_name) do
      nil -> :error
      spec -> {:ok, spec}
    end
  end

  defp steps(workflow_map), do: Map.get(workflow_map, "steps", %{})
  defp needs(spec), do: Map.get(spec, "needs", [])
  defp role(spec), do: Map.get(spec, "role")

  @doc """
  Loads through a module or unary function and normalizes exceptions into
  `{:error, {:workflow_map_load_failed, name, message}}`.
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
