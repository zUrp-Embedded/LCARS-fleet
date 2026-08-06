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

  describe "brief pointer trailer — the ticket says which text is the order" do
    test "the block names the summary as a summary, and the parser still reads the line" do
      sha = String.duplicate("a", 40)
      block = Layout.brief_pointer_trailer("briefs/issue-7-engineer.md", sha)

      # The sentence exists and says the load-bearing part: editing the summary changes nothing.
      # Without it, a ticket shows a summary and a pointer with nothing saying which one runs — and
      # the summary is the half a human can edit.
      assert block =~ "résumé"
      assert block =~ "éditer ce résumé ne le change pas"

      # And it costs the machine nothing: the `Brief:` line keeps its exact shape, the parser
      # anchors per line. A prose line above it must not become a parse hazard.
      body = "Résumé humain sur plusieurs\nlignes.\n\n---\n" <> block
      assert {:ok, {"briefs/issue-7-engineer.md", ^sha}} = Layout.parse_brief_pointer(body)
    end
  end

  describe "project_name vs project_slug — a coincidence turned into a contract" do
    # Two derivations of the same thing coexist. `project_name/1` is the DIRECTORY authority (its
    # own @doc says so, and fourteen sites build paths from it); `project_slug/1` folds anything
    # outside `[A-Za-z0-9-]` into `-` and exists for shell/tmux names. They diverge on `_`, `.` and
    # uppercase — and `LaunchSpec` derives HOST paths (the work/ops mount, the code reference) from
    # the SLUG, which the plan first read as a live bug.
    #
    # It is not one, and the reason is worth pinning rather than remembering: all SEVEN onboarding
    # entry points go through `validate_name`, whose charset is `^[a-z0-9][a-z0-9-]*[a-z0-9]$` —
    # strictly inside what the slug preserves. So every project that HAS a directory has a name
    # where the two derivations agree, and since the poller now refuses a repo without one, no
    # served project can reach the divergence.
    #
    # That makes today's equality a property of the charset, not a contract. This test makes it a
    # contract: widen `validate_name` and it goes red at the exact place the two part company,
    # instead of a pod booting healthy on a directory that does not exist.
    @onboardable_charset ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/

    test "every name the onboarding admits derives IDENTICALLY through both" do
      for name <- ~w(tetris poc-8 a1 lcars-fleet x9y my-long-project-name 42 a-b-c-d) do
        assert Regex.match?(@onboardable_charset, name),
               "fixture #{inspect(name)} is not onboardable — the test would prove nothing"

        repo = "fleet/#{name}"

        assert Layout.project_name(repo) == Layout.project_slug(repo),
               "onboardable name #{inspect(name)} derives to two different directories"
      end
    end

    test "and OUTSIDE that charset they genuinely differ — the guard is not vacuous" do
      # Without this, the test above would still pass if someone made `project_slug/1` the identity
      # function, and the invariant it claims to hold would be empty.
      assert Layout.project_name("fleet/my_project") == "my_project"
      assert Layout.project_slug("fleet/my_project") == "my-project"
      refute Regex.match?(@onboardable_charset, "my_project")
    end
  end

  test "state_dir is `.lcars` under the resolved HOME (never fabricated)" do
    dir = Layout.state_dir()
    assert String.starts_with?(dir, System.user_home!())
    assert String.ends_with?(dir, "/.lcars")
  end

  describe "project reference — the single `owner/name → name`/`slug` authority (C-06)" do
    test "project_name: last `/`-segment of a repo (or a bare name unchanged)" do
      assert Layout.project_name("lordzurp/lcars-test") == "lcars-test"
      assert Layout.project_name("bare-name") == "bare-name"
    end

    test "project_slug: project_name with anything outside [A-Za-z0-9-] folded to `-`" do
      # `.`/`_` (legal in a name) become `-` so the slug is safe as a tmux/rc_name segment
      # (`<slug>_<role>`): the `_` separator stays unambiguous.
      assert Layout.project_slug("owner/my.proj_v2") == "my-proj-v2"
      assert Layout.project_slug("owner/clean-name") == "clean-name"
    end
  end

  describe "work/ops artifact layout (the producer/validator shared truth)" do
    test "brief_ref: worker → briefs/, judge → gate-briefs/, name sanitized" do
      assert Layout.brief_ref(nil, "issue-3-engineer") == "briefs/issue-3-engineer.md"
      assert Layout.brief_ref("worker", "issue-3-engineer") == "briefs/issue-3-engineer.md"

      assert Layout.brief_ref("judge", "issue-3-consultant") ==
               "gate-briefs/issue-3-consultant.md"

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

    test "sanitize_artifact_name: ONE dash per CHARACTER, not per byte" do
      # The regex ran on bytes, so an accented character — two bytes in UTF-8 — produced TWO
      # dashes. Never unsafe (deterministic, path-safe, accepted by valid_brief_ref?/1), which is
      # exactly why it survived: nothing broke, the names were only wrong to a human reading them.
      # And this name becomes a `brief_ref` that the pointer work-order interpolates TWICE, with no
      # truncation anywhere — a French title paid two characters per accent for nothing.
      assert Layout.sanitize_artifact_name("D: placement latéral des pièces") ==
               "D--placement-lat-ral-des-pi-ces"

      # A whole word of accents: SIX characters, six dashes — not twelve. The `x` prefix is the
      # leading-char guard doing its job on a name that now starts with a dash; the two rules
      # compose, they do not overlap.
      assert Layout.sanitize_artifact_name("éèêàçù") == "x------"
    end

    test "brief pointer notation: trailer round-trips through parse (one truth, two domains)" do
      sha = String.duplicate("a", 40)
      body = "Résumé humain.\n\n---\n" <> Layout.brief_pointer_trailer("briefs/my-slug.md", sha)

      assert {:ok, {"briefs/my-slug.md", ^sha}} = Layout.parse_brief_pointer(body)
    end

    test "parse_brief_pointer: no pointer line → :none (inline brief, the normal PoC path)" do
      assert Layout.parse_brief_pointer("just a plain brief") == :none
      assert Layout.parse_brief_pointer("Brief: not-a-pointer @ short") == :none
      assert Layout.parse_brief_pointer(nil) == :none
    end

    test "parse_brief_pointer: full pointer shape with an out-of-scheme ref → LOUD error, never prose" do
      sha = String.duplicate("a", 40)

      assert {:error, {:invalid_pointer_ref, "../evil.md"}} =
               Layout.parse_brief_pointer("Brief: ../evil.md @ #{sha}")
    end
  end

  describe "project faces (chantier face-projet — the branch half of the layout)" do
    test "face_branch/1: the card vocabulary maps to the two structural branches" do
      assert Layout.face_branch("code") == "main"
      assert Layout.face_branch("ops") == "work/ops"
      assert Layout.code_branch() == "main"
      assert Layout.ops_branch() == "work/ops"
    end

    test "face_branch/1: an unknown face RAISES — it bypassed the schema enum, never soften it" do
      err = assert_raise ArgumentError, fn -> Layout.face_branch("doc") end
      assert err.message =~ "unknown face"
      assert err.message =~ "schema enum"
    end

    test "ops_branch?/1: feature branches and nil are NOT the ops face (code-face treatment)" do
      assert Layout.ops_branch?("work/ops")
      refute Layout.ops_branch?("main")
      # A judge clones the producer's branch, whatever face it forked from: neither face → the
      # code-face treatment (work-ops RO mount, reset realignment) — deliberate, cf. @doc.
      refute Layout.ops_branch?("lcars/issue-3-scribe")
      refute Layout.ops_branch?(nil)
    end
  end
end
