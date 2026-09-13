defmodule Fleet.Test.ProbeSeam do
  @moduledoc """
  Compiled support module for OptsExportedTest: it can be unloaded to compare
  function_exported?/3 with Fleet.Opts.exported?/3's load-before-probe behavior.
  """
  use Boundary, deps: [], exports: []

  def pod_info(_pod_id), do: {:ok, %{}}
end
