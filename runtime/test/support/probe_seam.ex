defmodule Fleet.Test.ProbeSeam do
  @moduledoc """
  A seam module that lives in `_build` (not in a test file), so a witness can UNLOAD it and prove
  what a probe sees before the first call: `function_exported?/3` says `false`, `Fleet.Opts.exported?/3`
  loads it and says `true`. Used by `Fleet.OptsExportedTest` only.
  """
  use Boundary, deps: [], exports: []

  def pod_info(_pod_id), do: {:ok, %{}}
end
