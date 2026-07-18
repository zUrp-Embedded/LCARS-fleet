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

  describe "work/ops artifact layout (the producer/validator shared truth)" do
    test "brief_ref: worker → briefs/, judge → gate-briefs/, name sanitized" do
      assert Layout.brief_ref(nil, "issue-3-engineer") == "briefs/issue-3-engineer.md"
      assert Layout.brief_ref("worker", "issue-3-engineer") == "briefs/issue-3-engineer.md"
      assert Layout.brief_ref("judge", "issue-3-consultant") == "gate-briefs/issue-3-consultant.md"
      assert Layout.brief_ref(nil, "a/b c") == "briefs/a-b-c.md"
    end

    test "provenance_ref: provenance/<name>.json, sanitized" do
      assert Layout.provenance_ref("issue-3-abc123d") == "provenance/issue-3-abc123d.json"
      assert Layout.provenance_ref("x/../y") == "provenance/x-..-y.json"
    end

    test "valid_brief_ref?: accepts exactly what brief_ref/2 composes (one truth, two sides)" do
      assert Layout.valid_brief_ref?(Layout.brief_ref(nil, "issue-3-engineer"))
      assert Layout.valid_brief_ref?(Layout.brief_ref("judge", "issue-3-consultant"))
      assert Layout.valid_brief_ref?("briefs/" <> String.duplicate("c", 64) <> ".md")

      refute Layout.valid_brief_ref?("../escape.md")
      refute Layout.valid_brief_ref?("other/x.md")
      refute Layout.valid_brief_ref?("briefs/a/b.md")
      refute Layout.valid_brief_ref?("briefs/.hidden.md")
      refute Layout.valid_brief_ref?("briefs/x.txt")
      refute Layout.valid_brief_ref?(nil)
    end

    test "sanitize_artifact_name: path-unsafe chars → `-`, leading dot never survives" do
      assert Layout.sanitize_artifact_name("issue-3-a/b c") == "issue-3-a-b-c"
      assert Layout.sanitize_artifact_name(".dotfile") == "x.dotfile"
    end
  end
end
