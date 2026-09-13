defmodule Fleet.Pilot.ColdForgeStub do
  @moduledoc """
  Forge fixture for `Spawn.repo_id/3` with an available but unloaded module.
  It must compile to a `.beam` on disk: the test purges it, then relies on the code
  server to reload it. A module created only by `Code.compile_*` cannot serve this test.
  """

  @repo_id 4242

  @doc "The numeric forge id this stub answers, so the test asserts a value and not just a shape."
  @spec expected_id() :: pos_integer()
  def expected_id, do: @repo_id

  @doc false
  def repo_id(_repo, _opts), do: {:ok, @repo_id}
end
