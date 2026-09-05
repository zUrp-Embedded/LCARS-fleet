defmodule Fleet.OptsExportedTest do
  use ExUnit.Case, async: true

  # The trap `exported?/3` closes: a module that exists but is not loaded yet answers `false` to
  # `function_exported?/3`. Every seam probe of the pilot used to read that `false` as « the seam
  # does not implement it » — and a live pipe became a pod without `pod_info/1` (2026-09-05).
  # The seam lives in `_build` (`test/support/probe_seam.ex`): a module defined in this file
  # could not be reloaded once deleted, and the trap is precisely « exists on disk, not loaded ».
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
