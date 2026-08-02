defmodule Fleet.Pilot.ColdForgeStub do
  @moduledoc """
  Forge seam used to reproduce the COLD-CODE-TABLE condition of `Spawn.repo_id/3`.

  It has to be a real module compiled to a `.beam` on disk — not one built with `Code.compile_*`
  at test time — because the test deletes and purges it to make `module_loaded?` false, and only a
  module the code server can find again is reloadable. That is the whole point: the resolution must
  survive a module that exists but is not loaded yet.

  **Last revised**: 2026-08-02
  """

  @repo_id 4242

  @doc "The numeric forge id this stub answers, so the test asserts a value and not just a shape."
  @spec expected_id() :: pos_integer()
  def expected_id, do: @repo_id

  @doc false
  def repo_id(_repo, _opts), do: {:ok, @repo_id}
end
