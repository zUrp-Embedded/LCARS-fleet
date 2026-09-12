defmodule Fleet.OptsExportedTest do
  use ExUnit.Case, async: true

  # The fixture must have a compiled beam (test/support/probe_seam.ex) to reload after deletion.
  # An inline module would test unavailability, not the unloaded-but-exported case.
  alias Fleet.Test.ProbeSeam, as: Seam

  test "an unloaded module answers false to function_exported?/3, true to exported?/3" do
    :code.purge(Seam)
    :code.delete(Seam)

    refute function_exported?(Seam, :pod_info, 1), "the trap: not loaded reads as not exported"
    assert Fleet.Opts.exported?(Seam, :pod_info, 1)
    refute Fleet.Opts.exported?(Seam, :missing, 1)
    refute Fleet.Opts.exported?(Fleet.OptsExportedTest.NoSuchModule, :pod_info, 1)
  end
end
