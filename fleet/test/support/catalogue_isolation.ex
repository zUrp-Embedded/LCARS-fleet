defmodule Fleet.Test.CatalogueIsolation do
  @moduledoc """
  Points BOTH catalogue roots — business and system — at a fixture directory, and restores them.

  ## Why a helper and not two `put_env` calls

  Since the mechanism moved to its own catalogue, a deployment resolves roles from the UNION of the
  two roots. A suite that only swapped `:fleet_cap_profile, :root_dir` therefore no longer measured
  its fixture: it measured the fixture PLUS the four mechanism roles, and the symptom was a
  cheerful "2 roles declare the gatekeeper capability" from a test that had written exactly one.

  Swapping both in one call is what makes "isolated" mean isolated. The system seam exists for this
  and only this — it has no env var and no runtime.exs reader, so no deployment can reach it.

  A suite that wants the REAL deployment (the shipped canon proving spawn-ready, say) simply does
  not call this.
  """

  use Boundary, deps: [], exports: []

  @doc """
  Swaps both roots to `dir` for the duration of the test, restoring the previous values on exit.

  `dir` is usually the `:tmp_dir` tag's directory. Pass `system: <path>` when the fixture wants a
  mechanism half of its own — the default points the system root at the same empty directory,
  which is the common case: a fixture that declares its own roles wants no others.
  """
  @spec isolate!(Path.t(), keyword()) :: :ok
  def isolate!(dir, opts \\ []) do
    system = Keyword.get(opts, :system, dir)

    prev_business = Application.fetch_env(:fleet_cap_profile, :root_dir)
    prev_system = Application.fetch_env(:fleet_catalogue, :system_root)

    Application.put_env(:fleet_cap_profile, :root_dir, dir)
    Application.put_env(:fleet_catalogue, :system_root, system)

    ExUnit.Callbacks.on_exit(fn ->
      restore(:fleet_cap_profile, :root_dir, prev_business)
      restore(:fleet_catalogue, :system_root, prev_system)
    end)

    :ok
  end

  defp restore(app, key, :error), do: Application.delete_env(app, key)
  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
end
