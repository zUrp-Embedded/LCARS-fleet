defmodule Fleet.MCP.PodTools.PodResolver do
  @moduledoc """
  Shared identity resolver for Delegation and Probe. `resolved/0` returns the
  function configured under `:mcp_pod_resolver`, defaulting to Spawner lookup.
  Both consumers share this default; injected functions are not validated here.
  """

  @typedoc """
  Consumer-facing identity fields, more precise than Spawner's map return type.
  Delegation uses role/repo; Probe also accepts repo_id and resolves it through the forge.
  Keep repo_id in this type so Dialyzer can reach that numeric-identity branch.
  """
  @type identity :: %{
          optional(:role) => String.t(),
          optional(:repo) => String.t() | nil,
          optional(:repo_id) => pos_integer() | nil
        }

  @doc """
  Expected result shape for resolver implementations.
  """
  @callback resolve(pod_id :: String.t()) :: {:ok, identity()} | {:error, term()}

  @doc false
  @spec resolved() :: (String.t() -> {:ok, identity()} | {:error, term()})
  def resolved, do: Application.get_env(:lcars_fleet, :mcp_pod_resolver, &__MODULE__.default/1)

  # Only the default catches lookup failures (including an absent or restarting Spawner).
  @doc false
  @spec default(String.t()) :: {:ok, identity()} | {:error, term()}
  def default(pod_id) when is_binary(pod_id) do
    Fleet.Spawner.pod_info(pod_id)
  rescue
    _ -> {:error, :pod_unknown}
  catch
    _, _ -> {:error, :pod_unknown}
  end

  def default(_pod_id), do: {:error, :pod_unknown}
end
