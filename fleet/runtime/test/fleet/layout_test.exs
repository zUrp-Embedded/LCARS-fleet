defmodule Fleet.LayoutTest do
  @moduledoc """
  `Fleet.Layout` — the single authority for the imposed container layout. These paths are
  the contract: pinning them here catches a silent regression if a root literal is ever
  changed (the whole point of a single-source module is that the value IS the contract).
  The structural enforcement (no other module hardcodes these roots) belongs to
  `mix lcars.contracts.check`; this only pins the values and the fail-loud state_dir shape.
  """
  use ExUnit.Case, async: true

  alias Fleet.Layout

  test "projects_root/work_root are the imposed container roots" do
    assert Layout.projects_root() == "/home/projects"
    assert Layout.work_root() == "/home/projects.work"
  end

  test "state_dir is `.lcars` under the resolved HOME (never fabricated)" do
    dir = Layout.state_dir()
    assert String.starts_with?(dir, System.user_home!())
    assert String.ends_with?(dir, "/.lcars")
  end
end
