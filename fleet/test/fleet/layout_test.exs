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

  test "the three face roots are the imposed container roots" do
    assert Layout.code_root() == "/home/projects"
    assert Layout.ops_root() == "/home/projects.ops"
    assert Layout.workshop_root() == "/home/projects.workshop"
  end

  describe "brief pointer trailer — the ticket says which text is the order" do
    test "the block names the summary as a summary, and the parser still reads the line" do
      sha = String.duplicate("a", 40)
      block = Layout.brief_pointer_trailer("briefs/issue-7-engineer.md", sha, "fleet/demo")

      # The sentence exists and says the load-bearing part: editing the summary changes nothing.
      # Without it, a ticket shows a summary and a pointer with nothing saying which one runs — and
      # the summary is the half a human can edit.
      assert block =~ "résumé"
      assert block =~ "éditer ce résumé ne le change pas"

      # transport_brief_v2 — the pointer is a CLICKABLE link (clean label + commit-browse URL), not
      # a bare `ref @ sha`. The human sees neither the illegible filename nor the 40-hex sha as text.
      assert block =~
               "Brief: [le brief](/fleet/demo/src/commit/#{sha}/briefs/issue-7-engineer.md)"

      refute block =~ "Brief: briefs/issue-7-engineer.md @"

      # And it costs the machine nothing: the parser reads ref+sha back OUT of the link URL.
      body = "Résumé humain sur plusieurs\nlignes.\n\n---\n" <> block
      assert {:ok, {"briefs/issue-7-engineer.md", ^sha}} = Layout.parse_brief_pointer(body)
    end
  end

  describe "project_name vs project_slug — a coincidence turned into a contract" do
    # Two derivations of the same thing coexist. `project_name/1` is the DIRECTORY authority (its
    # own @doc says so, and fourteen sites build paths from it); `project_slug/1` folds anything
    # outside `[A-Za-z0-9-]` into `-` and exists for shell/tmux names. They diverge on `_`, `.` and
    # uppercase — and `LaunchSpec` derives HOST paths (the ops mount, the code reference) from
    # the SLUG, which the plan first read as a live bug.
    #
    # It is not one, and the reason is worth pinning rather than remembering: every entry point that
    # INTRODUCES a project name goes through `validate_name`, whose charset is
    # `^[a-z0-9][a-z0-9-]*[a-z0-9]$` — strictly inside what the slug preserves. So every project
    # that HAS a directory has a name where the two derivations agree, and since the poller refuses
    # a repo without one, no served project can reach the divergence.
    #
    # THE RULE, NOT A COUNT. This paragraph said "all SEVEN onboarding entry points" and the number
    # had drifted — an inventory in a comment ages the moment someone adds a door. What holds is the
    # property: a name enters through validation, or it does not enter. `migrate/3` is the one public
    # function that skips `validate_name`, and it cannot introduce a name — it takes the full_name of
    # a project that already exists, with its three local faces, and repoints them.
    #
    # That makes today's equality a property of the charset, not a contract. This test makes it a
    # contract: widen `validate_name` and it goes red at the exact place the two part company,
    # instead of a pod booting healthy on a directory that does not exist.
    #
    # ⚠ CETTE PHRASE ETAIT FAUSSE JUSQU'AU 6-079, et par un detail : le motif etait RECOPIE ici.
    # Elargir la vraie charte ne faisait donc rien rougir — mesure du 2026-08-14, en la modifiant
    # pour de bon. Un test qui epingle une inclusion contre sa propre copie de l'ensemble n'epingle
    # rien du tout. On lit la source.
    @onboardable_charset Fleet.Project.Onboard.name_charset()

    test "every name the onboarding admits derives IDENTICALLY through both" do
      for name <- ~w(tetris poc-8 a1 lcars-fleet x9y my-long-project-name 42 a-b-c-d) do
        assert Regex.match?(@onboardable_charset, name),
               "fixture #{inspect(name)} is not onboardable — the test would prove nothing"

        repo = "fleet/#{name}"

        assert Layout.project_name(repo) == Layout.project_slug(repo),
               "onboardable name #{inspect(name)} derives to two different directories"
      end
    end

    # JG-078 — CE QUE PERSONNE N'EPINGLAIT. Le test ci-dessus compare les deux DERIVATIONS entre
    # elles ; il ne dit rien du VALIDATEUR. Or `Fleet.Slug` refuse la majuscule
    # (`\A[a-z0-9][a-z0-9_-]*\z`) la ou `project_slug/1` la conserve (`[^A-Za-z0-9-]`), et c'est ce
    # couple-la qui casse : un slug que le producteur rend et que le validateur refuse fait
    # `{:error, :project_required}` au point d'etranglement du spawn — le projet n'est pas prive de
    # sa reprise de session, il n'est pas dispatchable du tout.
    #
    # Inatteignable aujourd'hui, et c'est justement pourquoi ca se pin : rien ne le tient. Elargir
    # `validate_name` d'une seule majuscule rend le defaut vivant, et il se manifesterait comme un
    # refus de spawn sans rapport apparent avec le nom du depot.
    test "tout nom onboardable produit un slug que le VALIDATEUR accepte" do
      for name <- ~w(tetris poc-8 a1 lcars-fleet x9y my-long-project-name 42 a-b-c-d) do
        slug = Layout.project_slug("fleet/#{name}")

        assert Fleet.Slug.valid?(slug),
               "project_slug/1 rend #{inspect(slug)}, que Fleet.Slug refuse — " <>
                 "producteur et validateur ont diverge"
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

  describe "ops artifact layout (the producer/validator shared truth)" do
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

      body =
        "Résumé humain.\n\n---\n" <> Layout.brief_pointer_trailer("briefs/my-slug.md", sha, "o/r")

      assert {:ok, {"briefs/my-slug.md", ^sha}} = Layout.parse_brief_pointer(body)
    end

    test "unified link pointer: one notation for Brief/Criteria/Verdict, parsed back from the URL" do
      sha = String.duplicate("b", 40)

      # ONE renderer, one parser. The link carries a clean label + a commit-browse URL; the machine
      # reads ref+sha OUT of the URL. Mutation-verified: a renderer that dropped the URL (or a parser
      # that only knew the legacy shape) would fail the round-trip below.
      brief = Layout.pointer_line("Brief", "briefs/x.md", sha, "o/r")
      crit = Layout.criteria_pointer_line("gate-briefs/x--criteria.md", sha, "o/r")

      assert brief == "Brief: [le brief](/o/r/src/commit/#{sha}/briefs/x.md)"
      assert crit == "Criteria: [les critères](/o/r/src/commit/#{sha}/gate-briefs/x--criteria.md)"
      assert {:ok, {"briefs/x.md", ^sha}} = Layout.parse_brief_pointer(brief)
      assert {:ok, {"gate-briefs/x--criteria.md", ^sha}} = Layout.parse_criteria_pointer(crit)
    end

    test "legacy pointer shape is STILL parsed (tickets written before the link notation)" do
      sha = String.duplicate("c", 40)

      assert {:ok, {"briefs/old.md", ^sha}} =
               Layout.parse_brief_pointer("Brief: briefs/old.md @ #{sha}")

      assert {:ok, {"gate-briefs/old.md", ^sha}} =
               Layout.parse_criteria_pointer("Criteria: gate-briefs/old.md @ #{sha}")
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
    test "face_branch/1: each declared face maps to its structural branch" do
      assert Layout.face_branch("code") == "main"
      assert Layout.face_branch("workshop") == "workshop"
      assert Layout.face_branch("ops") == "ops"
      assert Layout.code_branch() == "main"
      assert Layout.workshop_branch() == "workshop"
      assert Layout.ops_branch() == "ops"
    end

    test "face_root/1: each face pairs with its own host root — three branches, three clones" do
      # Git allows one worktree per branch, so the pairing is not a convention that could be
      # collapsed: two faces sharing a root is not a tidier layout, it is an impossible one.
      assert Layout.face_root("code") == Layout.code_root()
      assert Layout.face_root("workshop") == Layout.workshop_root()
      assert Layout.face_root("ops") == Layout.ops_root()

      assert [Layout.code_root(), Layout.workshop_root(), Layout.ops_root()]
             |> Enum.uniq()
             |> length() == 3,
             "two faces sharing a root would make one of them uncheckoutable"
    end

    test "face_branch/1 and face_root/1: an unknown face RAISES — never soften a schema bypass" do
      for fun <- [&Layout.face_branch/1, &Layout.face_root/1] do
        err = assert_raise ArgumentError, fn -> fun.("backlog") end
        assert err.message =~ "unknown face"
      end
    end

    test "`ops` is NOT a card face — the enum is where that invariant lives" do
      # The project HAS an ops branch; a producer may never be pointed at it. The wall is the
      # workflow-map schema enum (`code | doc`) plus `additionalProperties: false`, not a check in
      # code: an unwritable state needs no verification. This test reads the SHIPPED schema, so
      # widening that enum breaks here rather than at the first pod handed a workspace on the
      # record of its own judgement.
      enum =
        :code.priv_dir(:lcars_fleet)
        |> to_string()
        |> Path.join("workflow/schema/workflow-map-v2.5.json")
        |> File.read!()
        |> Jason.decode!()
        |> get_in([
          "properties",
          "spec",
          "properties",
          "steps",
          "patternProperties",
          "^[a-zA-Z0-9_-]+$",
          "properties",
          "face",
          "enum"
        ])

      assert Enum.sort(enum) == ["code", "workshop"]
      refute "ops" in enum
    end

    test "face_of/1 NAMES the face — a non-face answers nil, never another face by default" do
      assert Layout.face_of("ops") == "ops"
      assert Layout.face_of("workshop") == "workshop"
      assert Layout.face_of("main") == "code"

      # The distinction a per-face predicate cannot draw: a producer's feature branch is not the
      # ops face, and it is not the code face either. A boolean answers `false` to both questions,
      # and a caller reads that `false` as "the other face". Here it answers `nil`, and a caller
      # that wants the code treatment for it has to write that clause itself.
      assert Layout.face_of("lcars/issue-3-scribe") == nil
      assert Layout.face_of(nil) == nil
    end

    test "face_of/1 covers EVERY face in the map — the two directions cannot drift apart" do
      # The clauses are generated from `@face_branches`, so this holds by construction today. It is
      # written down because the construction is the guarantee: a face added to the map without a
      # `face_of/1` clause would be a branch the runtime routes and cannot name, and the generation
      # is the only thing standing between here and that. If the `for` comprehension is ever
      # unrolled into hand-written clauses, this test is what notices the one that was forgotten.
      for face <- ["code", "workshop", "ops"] do
        assert Layout.face_of(Layout.face_branch(face)) == face,
               "#{face}: face_branch/1 and face_of/1 must be inverse on every declared face"
      end
    end
  end
end
