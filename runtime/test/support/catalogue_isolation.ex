defmodule Fleet.Test.CatalogueIsolation do
  @moduledoc """
  Temporarily sets both business and system catalogue roots for a test.
  Role resolution combines the roots, so changing only one leaves shipped roles visible.
  These are global Application settings: use in synchronous tests.
  """

  use Boundary, deps: [], exports: []

  @doc """
  Sets both roots to dir, or uses `system: path` for a separate system fixture.
  Registers restoration of the previous values (including absence) on test exit.
  Call from the test process; this does not isolate concurrent readers or clear caches.
  """
  @spec isolate!(Path.t(), keyword()) :: :ok
  def isolate!(dir, opts \\ []) do
    system = Keyword.get(opts, :system, dir)

    prev_business = Application.fetch_env(:lcars_fleet, :cap_profile_root_dir)
    prev_system = Application.fetch_env(:lcars_fleet, :catalogue_system_root)

    Application.put_env(:lcars_fleet, :cap_profile_root_dir, dir)
    Application.put_env(:lcars_fleet, :catalogue_system_root, system)

    ExUnit.Callbacks.on_exit(fn ->
      restore(:lcars_fleet, :cap_profile_root_dir, prev_business)
      restore(:lcars_fleet, :catalogue_system_root, prev_system)
    end)

    :ok
  end

  defp restore(app, key, :error), do: Application.delete_env(app, key)
  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
end
