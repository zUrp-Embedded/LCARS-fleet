defmodule Fleet.Pilot.WorkflowMapNav do
  @moduledoc """
  Navigates loaded maps by step name, allowing repeated roles on distinct steps.

  Intended for linear workflows: first_step rejects multiple roots and next_step
  rejects multiple immediate successors. These local checks do not validate the whole
  graph for cycles, joins or disconnected components. Missing role can return nil.
  A soft gate on a business step is valid and does not require a gatekeeper-named step.
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
  Calls a module/function loader and wraps its return in ok without validating its shape.
  Exceptions become {:error, {:workflow_map_load_failed, name, message}}; throws/exits propagate.

  Binary functions or load!/2 receive opts so the same card name can resolve in the
  project's catalogue. Unary loaders remain supported but drop opts, so they cannot
  receive catalogue selection through this call. Wrong-catalogue cards can surface later
  as forge permission failures under the wrong role identity.
  """
  @spec safe_load(
          module() | (String.t() -> map()) | (String.t(), keyword() -> map()),
          String.t(),
          keyword()
        ) :: {:ok, map()} | {:error, {:workflow_map_load_failed, String.t(), String.t()}}
  def safe_load(loader, name, opts \\ []) when is_binary(name) do
    map =
      cond do
        is_function(loader, 2) -> loader.(name, opts)
        is_function(loader, 1) -> loader.(name)
        module_takes_opts?(loader) -> loader.load!(name, opts)
        true -> loader.load!(name)
      end

    {:ok, map}
  rescue
    e -> {:error, {:workflow_map_load_failed, name, Exception.message(e)}}
  end

  # Prefer load!/2 when exported; preserve unary fixtures that intentionally ignore options.
  defp module_takes_opts?(mod),
    do: Fleet.Opts.exported?(mod, :load!, 2)
end
