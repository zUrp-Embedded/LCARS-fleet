defmodule Fleet.Pilot.BriefBuilderTest do
  @moduledoc """
  Checks brief rendering, pinned mount metadata and read-error handling.
  Deliverable judges distinguish missing content from failed criterion or predecessor
  reads; rework orders instead expose missing feedback in their text and logs.
  These tests inspect orders and metadata, not pod behavior or physical mounts.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.BriefBuilder
  alias Fleet.Workflow.BriefArtifact

  # Configurable predecessor and criterion reads; unexpected calls are not simulated.
  defmodule StubForge do
    def get_predecessor_result(_repo, _n, opts),
      do: Keyword.get(opts, :_pred, {:ok, %{"livrable" => "diff stub"}})

    def get_issue(_repo, _n, opts),
      do: Keyword.get(opts, :_issue, {:ok, %{"body" => "CRITÈRE-XYZ"}})
  end

  # Absent judge_target selects deliverable judgment.
  defp judge_profile do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "reviewer"},
      spec: %{"brief_kind" => "judge"}
    }
  end

  # Text-focused assertions discard the mount; build4 and dispatcher tests retain and check it.
  defp build(forge_opts, opts \\ []) do
    case BriefBuilder.build_brief(
           judge_profile(),
           "reviewer",
           %BriefBuilder.Access{
             forge: StubForge,
             repo: "acme/widget",
             forge_opts: forge_opts
           },
           42,
           %{},
           {"pipe", "review"},
           %{},
           opts
         ) do
      {:ok, brief, kind, _mount} -> {:ok, brief, kind}
      other -> other
    end
  end

  # Keep mount metadata to identify the pinned document, which order text no longer cites.
  defp build4(forge_opts, opts) do
    BriefBuilder.build_brief(
      judge_profile(),
      "reviewer",
      %BriefBuilder.Access{
        forge: StubForge,
        repo: "acme/widget",
        forge_opts: forge_opts
      },
      42,
      %{},
      {"pipe", "review"},
      %{},
      opts
    )
  end

  describe "build_brief — the CI fact rides into the judge brief (porte CI)" do
    test "a measured green CI is HANDED to the judge, with the boundary of what it means" do
      assert {:ok, brief, "judge"} =
               build([], ci_fact: %{state: :success, sha: "cafebabe1234567890"})

      # Assert the supplied CI fact without rereading the forge.
      assert brief =~ "cafebabe"

      assert brief =~ "PROUVE"
    end

    test "no CI fact (card on `ci: ignore`) → NOTHING is said, rather than 'CI: unknown'" do
      assert {:ok, brief, "judge"} = build([])
      refute brief =~ "CI VERTE"
    end

    test "a non-success fact never reaches the judge — the gate does not summon on those" do
      assert {:ok, brief, "judge"} = build([], ci_fact: %{state: :failure, sha: "deadbeef00"})
      refute brief =~ "deadbeef"
    end

    test "6-140 : le brief NOMME ce qui a tourne, et ne dit plus qu'une preuve a ete executee" do
      # A named CI context reports execution without claiming that a meaningful proof ran.
      assert {:ok, brief, "judge"} =
               build([],
                 ci_fact: %{
                   state: :success,
                   sha: "cafebabe1234567890",
                   contexts: ["CI / no-harness-yet (pull_request)"]
                 }
               )

      refute brief =~ "EXECUTE la preuve"
      assert brief =~ "CI / no-harness-yet (pull_request)"

      assert brief =~ "EST une constatation"
    end

    test "6-140 : des contextes illisibles se DISENT, ils ne se fabriquent pas" do
      # Empty contexts must not imply that named checks were verified.
      assert {:ok, brief, "judge"} =
               build([], ci_fact: %{state: :success, sha: "cafebabe1234567890", contexts: []})

      assert brief =~ "n'ont pas pu etre lus"
      refute brief =~ "Ce qui a tourne, exactement"
    end
  end

  describe "build_brief — deliverable-judge, criterion read (F-C083)" do
    test "get_issue OK → {:ok, brief, \"judge\"} that CARRIES the criterion (defused by GateBrief)" do
      assert {:ok, brief, "judge"} = build(_issue: {:ok, %{"body" => "CRITÈRE-XYZ"}})
      assert is_binary(brief)

      assert brief =~ "CRITÈRE-XYZ"

      # Presence alone is insufficient: the do-not-execute framing must precede the criterion.
      assert brief =~ "DO NOT execute",
             "le critere est rendu BRUT : rien ne dit au juge que c'est du CONTEXTE"

      [avant, _apres] = String.split(brief, "CRITÈRE-XYZ", parts: 2)

      assert avant =~ "DO NOT execute",
             "la mention de desamorcage ne PRECEDE pas le critere — elle ne le couvre donc pas"
    end

    test "get_issue READ-ERROR → {:error, {:criterion_unavailable, reason}} (NEVER a criterion-less judge)" do
      assert {:error, {:criterion_unavailable, :boom}} = build(_issue: {:error, :boom})
    end

    test "genuinely absent issue body (get_issue OK, body nil) → {:ok, brief, kind}: absence ≠ read-error" do
      assert {:ok, _brief, "judge"} = build(_issue: {:ok, %{"number" => 42}})
    end

    @tag :tmp_dir
    test "the judge's criterion is the CRITERIA doc, not the brief, when both are pointed",
         %{tmp_dir: tmp} do
      # Distinct documents expose selecting the producer's procedure instead of judging criteria.
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(Path.join(work_dir, "briefs"))
      File.mkdir_p!(Path.join(work_dir, "gate-briefs"))
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.email", "h@l"])
      {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.name", "H"])
      File.write!(Path.join([work_dir, "briefs", "issue-42-engineer.md"]), "PROCEDURAL-BRIEF")

      File.write!(
        Path.join([work_dir, "gate-briefs", "issue-42-reviewer.md"]),
        "ATTENDU-CRITERIA"
      )

      {_, 0} = System.cmd("git", ["-C", work_dir, "add", "."])
      {_, 0} = System.cmd("git", ["-C", work_dir, "commit", "-q", "-m", "docs"])
      {sha, 0} = System.cmd("git", ["-C", work_dir, "rev-parse", "HEAD"])
      sha = String.trim(sha)

      body =
        "résumé\n\n" <>
          Fleet.Layout.brief_pointer_line("briefs/issue-42-engineer.md", sha, "acme/widget") <>
          "\n" <>
          Fleet.Layout.criteria_pointer_line(
            "gate-briefs/issue-42-reviewer.md",
            sha,
            "acme/widget"
          )

      assert {:ok, brief, "judge", mount} =
               build4([_issue: {:ok, %{"body" => body}}], ops_root: tmp)

      # The selected source is observable in mount metadata; text only names the mounted file.
      assert brief =~ "~/issues/criteria.md"
      assert mount.ref == "gate-briefs/issue-42-reviewer.md"

      # Runtime metadata carries the pin; the order must not ask the agent to relay it.
      refute brief =~ "gate-briefs/issue-42-reviewer.md"
      refute brief =~ "briefs/issue-42-engineer.md"
      refute brief =~ sha

      refute brief =~ "ATTENDU-CRITERIA"
      refute brief =~ "PROCEDURAL-BRIEF"
    end

    @tag :tmp_dir
    test "no criteria pointer → the judge falls back to the brief (no regression)",
         %{tmp_dir: tmp} do
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(Path.join(work_dir, "briefs"))
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.email", "h@l"])
      {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.name", "H"])
      File.write!(Path.join([work_dir, "briefs", "issue-42-engineer.md"]), "BRIEF-ONLY-CRITERION")
      {_, 0} = System.cmd("git", ["-C", work_dir, "add", "."])
      {_, 0} = System.cmd("git", ["-C", work_dir, "commit", "-q", "-m", "brief"])
      {sha, 0} = System.cmd("git", ["-C", work_dir, "rev-parse", "HEAD"])

      body =
        "résumé\n\n" <>
          Fleet.Layout.brief_pointer_line(
            "briefs/issue-42-engineer.md",
            String.trim(sha),
            "acme/widget"
          )

      assert {:ok, brief, "judge", mount} =
               build4([_issue: {:ok, %{"body" => body}}], ops_root: tmp)

      # Fallback changes the source to Brief but keeps the judge's filename criteria.md.
      assert brief =~ "~/issues/criteria.md"
      assert mount.ref == "briefs/issue-42-engineer.md"
      assert mount.filename == "criteria.md"
      refute brief =~ "briefs/issue-42-engineer.md"
      refute brief =~ "BRIEF-ONLY-CRITERION"
    end

    @tag :tmp_dir
    test "build_brief SURFACES the mandate mount (4th element) — what every dispatch path materializes",
         %{tmp_dir: tmp} do
      # Returning the referenced source lets dispatch pass :mandate to the spawner.
      # This test checks metadata; it does not prove that every caller materializes it.
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(Path.join(work_dir, "gate-briefs"))
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.email", "h@l"])
      {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.name", "H"])
      File.write!(Path.join([work_dir, "gate-briefs", "issue-42-reviewer.md"]), "L'ATTENDU")
      {_, 0} = System.cmd("git", ["-C", work_dir, "add", "."])
      {_, 0} = System.cmd("git", ["-C", work_dir, "commit", "-q", "-m", "criteria"])
      {sha, 0} = System.cmd("git", ["-C", work_dir, "rev-parse", "HEAD"])
      sha = String.trim(sha)

      body =
        "résumé\n\n" <>
          Fleet.Layout.criteria_pointer_line(
            "gate-briefs/issue-42-reviewer.md",
            sha,
            "acme/widget"
          )

      assert {:ok, _brief, "judge", mount} =
               BriefBuilder.build_brief(
                 judge_profile(),
                 "reviewer",
                 %BriefBuilder.Access{
                   forge: StubForge,
                   repo: "acme/widget",
                   forge_opts: [_issue: {:ok, %{"body" => body}}]
                 },
                 42,
                 %{},
                 {"pipe", "review"},
                 %{},
                 ops_root: tmp
               )

      assert %{ref: "gate-briefs/issue-42-reviewer.md", sha: ^sha, ops_path: ops_path} = mount
      assert String.ends_with?(ops_path, "/widget")
    end
  end

  describe "build_brief — deliverable-judge, PREDECESSOR read (F-C083, l'autre moitié)" do
    # A failed predecessor read must not silently substitute branch code for the intended payload.
    test "prédécesseur PRÉSENT → le payload est le livrable jugé" do
      assert {:ok, brief, "judge"} = build(_pred: {:ok, %{"livrable" => "PAYLOAD-XYZ"}})
      assert brief =~ "PAYLOAD-XYZ"
      refute brief =~ "git-native"
    end

    test "AUCUN prédécesseur (`:none`) → git-native : le CODE est le livrable, et c'est légitime" do
      assert {:ok, brief, "judge"} = build(_pred: :none)
      assert brief =~ "git-native"
    end

    test "prédécesseur VIDE (`{:ok, %{}}`) → git-native aussi : vide ≠ erreur" do
      assert {:ok, brief, "judge"} = build(_pred: {:ok, %{}})
      assert brief =~ "git-native"
    end

    test "READ-ERROR sur le prédécesseur → fail-closed, JAMAIS un juge sur la mauvaise matière" do
      assert {:error, {:criterion_unavailable, {:predecessor, :boom}}} =
               build(_pred: {:error, :boom})
    end
  end

  describe "rework brief — le feedback de review NON LU ne se tait pas" do
    defmodule ReworkForge do
      def change_request_feedback(_repo, _pr, opts), do: Keyword.get(opts, :_fb, {:ok, []})

      # Default successful CI leaves the fallback section empty.
      def get_pull(_repo, _pr, opts),
        do: Keyword.get(opts, :_pull, {:ok, %{"head" => %{"sha" => "deadbeef"}}})

      def commit_ci_state(_repo, _sha, opts), do: Keyword.get(opts, :_ci, {:ok, :success})

      def commit_ci_failures(_repo, _sha, opts), do: Keyword.get(opts, :_reds, {:ok, []})
    end

    defp rework(forge_opts),
      do:
        BriefBuilder.rework_brief(
          "engineer",
          ReworkForge,
          "acme/widget",
          7,
          forge_opts,
          nil,
          []
        )

    test "feedback PRÉSENT → les reviews sont dans le brief, nommées par leur auteur" do
      brief = rework(_fb: {:ok, [%{"login" => "reviewer-bot", "body" => "REVOIR-LE-NOMMAGE"}]})

      assert brief =~ "## Feedback de review à traiter (REQUEST_CHANGES)"
      assert brief =~ "reviewer-bot"
      assert brief =~ "REVOIR-LE-NOMMAGE"
    end

    test "AUCUN feedback + CI VERTE → silence : il n'y a rien à dire, et le dire serait du bruit" do
      brief = rework(_fb: {:ok, []}, _ci: {:ok, :success})

      # The template always mentions REQUEST_CHANGES; distinguish cases by section headings.
      refute brief =~ "## Feedback de review"
      refute brief =~ "## CI ROUGE"
      refute brief =~ "## Raison du rework — NON LUE"
    end

    test "CI ROUGE : les contextes en ECHEC sont NOMMES, et eux seuls" do
      # Names supplied failing contexts; this fixture does not test forge-side filtering.
      brief =
        rework(
          _fb: {:ok, []},
          _ci: {:ok, :failure},
          _reds:
            {:ok,
             [
               %{
                 context: "CI / test (pull_request)",
                 description: "checkout failed",
                 target_url: "http://forge/run/7"
               }
             ]}
        )

      assert brief =~ "Contexte(s) en ÉCHEC"
      assert brief =~ "CI / test (pull_request)"
      assert brief =~ "checkout failed"
      assert brief =~ "http://forge/run/7"
      assert brief =~ ".gitea/workflows/"
    end

    test "CI ROUGE : aucun contexte nommable → le brief ne nomme personne, il ne s'invente rien" do
      brief = rework(_fb: {:ok, []}, _ci: {:ok, :failure}, _reds: {:ok, []})

      assert brief =~ "## CI ROUGE"
      refute brief =~ "Contexte(s) en ÉCHEC"
      refute brief =~ "n'ont pas pu être lus"
    end

    test "CI ROUGE : contextes ILLISIBLES → le rouge est dit, et l'ignorance aussi" do
      brief = rework(_fb: {:ok, []}, _ci: {:ok, :failure}, _reds: {:error, :boom})

      assert brief =~ "## CI ROUGE"
      assert brief =~ "n'ont pas pu être lus"
      refute brief =~ "Contexte(s) en ÉCHEC"
    end

    test "AUCUN feedback + CI ROUGE → le brief DIT que c'est la CI (plus de rework aveugle)" do
      # No review feedback can still mean rework for failed CI.
      brief = rework(_fb: {:ok, []}, _ci: {:ok, :failure})

      assert brief =~ "## CI ROUGE"
      assert brief =~ "checkout"
      refute brief =~ "## Feedback de review à traiter"
      # The failure section supplies CI facts directly; pods cannot query the Actions page.
      refute brief =~ "onglet Actions"
    end

    test "AUCUN feedback + état CI ILLISIBLE → on TRACE et le brief le dit, jamais un ordre muet" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          brief = rework(_fb: {:ok, []}, _ci: {:error, :timeout})

          assert brief =~ "## Raison du rework — NON LUE"
          assert brief =~ "onglet Actions"
          refute brief =~ "## CI ROUGE"
        end)

      assert log =~ "rework CI state UNREADABLE"
      assert log =~ "timeout"
    end

    test "READ-ERROR → le brief DIT que les reviews existent et n'ont pas été lues" do
      # Read failure degrades rework with a visible warning; it does not defer as judging errors do.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          brief = rework(_fb: {:error, :timeout})

          assert brief =~ "## Feedback de review — NON LU"
          assert brief =~ "Elles EXISTENT"
          refute brief =~ "## Feedback de review à traiter"
        end)

      # Keep the facade log prefix stable.
      assert log =~ "StepDispatcher: rework feedback UNREADABLE"
      assert log =~ "timeout"
    end
  end

  describe "brief pointer (E4) — the ticket points at a ops-authored doc" do
    @moduletag :tmp_dir

    defp worker_profile do
      %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "engineer"},
        spec: %{"brief_kind" => "worker"}
      }
    end

    defp build_worker(issue, opts) do
      case BriefBuilder.build_brief(
             worker_profile(),
             "engineer",
             %BriefBuilder.Access{
               forge: StubForge,
               repo: "acme/widget",
               forge_opts: []
             },
             42,
             issue,
             {"pipe", "build"},
             %{},
             opts
           ) do
        {:ok, brief, kind, _mount} -> {:ok, brief, kind}
        other -> other
      end
    end

    defp authored_workops(tmp) do
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      {:ok, %{ref: ref, sha: sha}} =
        BriefArtifact.commit(work_dir, "LE DOC COMPLET.\n", name_hint: "my-slug")

      {ref, sha}
    end

    test "pointer ticket → the PINNED doc becomes the brief (worker order carries the doc, not the pointer)",
         %{tmp_dir: tmp} do
      {ref, sha} = authored_workops(tmp)
      body = "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha, "acme/widget")

      assert {:ok, brief, "worker"} =
               build_worker(%{"number" => 42, "body" => body}, ops_root: tmp)

      assert brief =~ "~/issues/brief.md"
      refute brief =~ "LE DOC COMPLET."
      refute brief =~ "Brief: #{ref}"

      # No full or abbreviated pin in the order; runtime metadata owns provenance.
      refute brief =~ sha
      refute brief =~ String.slice(sha, 0, 7)
      refute brief =~ "Source du brief"
    end

    test "unresolvable pointer (wrong sha) → DEFER via the criterion rail, never a guessed brief",
         %{tmp_dir: tmp} do
      {ref, _sha} = authored_workops(tmp)

      body =
        "Résumé.\n\n---\n" <>
          Fleet.Layout.brief_pointer_trailer(ref, String.duplicate("0", 40), "acme/widget")

      assert {:error, {:criterion_unavailable, {:brief_pointer, _}}} =
               build_worker(%{"number" => 42, "body" => body}, ops_root: tmp)
    end

    test "no pointer → inline body IS the brief (both channels honest, same downstream)", %{
      tmp_dir: tmp
    } do
      assert {:ok, brief, "worker"} =
               build_worker(%{"number" => 42, "body" => "inline brief"}, ops_root: tmp)

      assert brief =~ "inline brief"

      refute brief =~ "Source du brief"
    end
  end

  describe "deliverable-judge criterion — the gate-brief points at it, and cites no pin" do
    @describetag :tmp_dir

    defp authored_criterion(tmp) do
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      {:ok, %{ref: ref, sha: sha}} =
        BriefArtifact.commit(work_dir, "LE CRITÈRE COMPLET.\n", name_hint: "crit")

      {ref, sha}
    end

    test "pointer ticket → the judge gets a PURE POINTER, no pin cited (the runtime engraves it)",
         %{
           tmp_dir: tmp
         } do
      {ref, sha} = authored_criterion(tmp)
      body = "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha, "acme/widget")

      assert {:ok, brief, "judge", mount} =
               build4([_issue: {:ok, %{"body" => body}}], ops_root: tmp)

      # The order names a mount, without embedding its content; this test does not materialize it.
      assert brief =~ "~/issues/criteria.md"
      refute brief =~ "LE CRITÈRE COMPLET."

      # Pin stays in mount metadata, not in instructions for the judge to repeat.
      refute brief =~ "#{ref}"
      refute brief =~ String.slice(sha, 0, 7)
      assert %{ref: ^ref, sha: ^sha} = mount

      # Naming the ops environment variable would reintroduce dependence on an ops mount.
      refute brief =~ "LCARS_PROJECT_OPS"
    end

    test "the criterion says read-and-evaluate — defused means do-not-execute, not do-not-read",
         %{tmp_dir: tmp} do
      {ref, sha} = authored_criterion(tmp)
      body = "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha, "acme/widget")

      assert {:ok, brief, "judge"} =
               build([_issue: {:ok, %{"body" => body}}], ops_root: tmp)

      # Do-not-execute must coexist with read-and-evaluate; it must not discourage reading the criterion.
      assert brief =~ "DO NOT execute"
      assert brief =~ "ne l'exécute pas"
      assert brief =~ "lis-le"
    end

    test "INVERSE TWIN — an inline brief is still embedded: there is nothing to point at", %{
      tmp_dir: tmp
    } do
      assert {:ok, brief, "judge"} =
               build([_issue: {:ok, %{"body" => "CRITÈRE INLINE."}}], ops_root: tmp)

      assert brief =~ "CRITÈRE INLINE."
      refute brief =~ "LCARS_PROJECT_OPS"
    end
  end

  describe "conflict rework brief — one mechanic, two voices" do
    # An outsider has no original brief to resume; conflict voices must retain this distinction.
    defmodule ConflictForge do
      def change_request_feedback(_repo, _pr, _opts), do: {:ok, []}

      # Successful CI isolates the conflict section.
      def get_pull(_repo, _pr, _opts), do: {:ok, %{"head" => %{"sha" => "deadbeef"}}}
      def commit_ci_state(_repo, _sha, _opts), do: {:ok, :success}
    end

    # Require the actual PR base even though the executable ref is always lcars/base.
    defp conflict_brief(voice, base \\ "main") do
      BriefBuilder.rework_brief("engineer", ConflictForge, "fleet/x", 7, [], nil,
        conflict: voice,
        base_branch: base
      )
    end

    test "the PRODUCER is told its own brief is unchanged (it is resuming approved work)" do
      brief = conflict_brief(:producer)

      assert brief =~ "Ton brief est INCHANGÉ"
      assert brief =~ "l'intention de TON brief"
      refute brief =~ "Passe d'exception"
    end

    test "the OUTSIDER is told it has no brief, and must compose rather than pick a side" do
      # Voice depends on ownership, not whichever role holds the exception capability.
      brief = conflict_brief(:exception)

      assert brief =~ "Passe d'exception"
      assert brief =~ "tu n'as pas de brief à reprendre"
      assert brief =~ "tu ne choisis pas un camp"

      # The outsider must be allowed to return blocked when composition needs an external decision.
      assert brief =~ "blocked"

      refute brief =~ "Ton brief est INCHANGÉ"
      refute brief =~ "TON brief"
    end

    # Single-branch clones may lack origin/<base>. Commands use lcars/base;
    # prose must still identify the actual PR base, including non-code faces.
    test "JG-137+6-135: les DEUX voix visent un ref qui EXISTE, et nomment la vraie base" do
      for voice <- [:producer, :exception] do
        brief = conflict_brief(voice, "workshop")

        assert brief =~ "git merge lcars/base",
               "voix #{voice} : la procedure vise un ref absent du clone d'un pod de review"

        assert brief =~ "workshop",
               "voix #{voice} : la procedure ne nomme plus la base reelle de la PR"

        refute brief =~ "git merge origin/",
               "voix #{voice} : une commande executable vise encore un `origin/<base>` inexistant"
      end
    end

    test "TEMOIN JG-137 — la base SUIT la PR, elle n'a pas juste change de nom" do
      # A second base prevents a constant prose substitution from satisfying the witness.
      assert conflict_brief(:producer, "main") =~ "divergé de `main`"
      assert conflict_brief(:producer, "workshop") =~ "divergé de `workshop`"
    end

    test "no conflict → no section at all (the default path is untouched)" do
      brief = BriefBuilder.rework_brief("engineer", ConflictForge, "fleet/x", 7, [], nil)

      refute brief =~ "Conflit de merge"
      refute brief =~ "Passe d'exception"
    end
  end

  describe "brief-judge (scoper) — mounts the brief it judges, cites no pin (transport_brief_v2)" do
    @describetag :tmp_dir

    defp scoper_profile do
      %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "scoper"},
        spec: %{"brief_kind" => "judge"}
      }
    end

    # Scoper mount metadata comes from the entry issue, not a fallback forge fetch.
    defp build_scoper(issue_map, opts) do
      BriefBuilder.build_brief(
        scoper_profile(),
        "scoper",
        %BriefBuilder.Access{
          forge: StubForge,
          repo: "acme/widget",
          forge_opts: []
        },
        42,
        issue_map,
        {"brief-gate", "brief-review"},
        %{"judge_target" => "brief"},
        opts
      )
    end

    test "pointer ticket → the scoper SURFACES a mount and judges a mounted file, no text, no pin",
         %{tmp_dir: tmp} do
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      {:ok, %{ref: ref, sha: sha}} =
        BriefArtifact.commit(work_dir, "LE BRIEF À JUGER.\n", name_hint: "brf")

      body = "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha, "acme/widget")

      assert {:ok, brief, "judge", mount} =
               build_scoper(%{"body" => body}, ops_root: tmp)

      # Check the mount source as well as the absence of inline content and pin citations.
      assert %{ref: ^ref, sha: ^sha, filename: "brief.md"} = mount
      assert brief =~ "~/issues/brief.md"
      refute brief =~ "LE BRIEF À JUGER."
      refute brief =~ "#{ref}"
      refute brief =~ sha
      refute brief =~ String.slice(sha, 0, 7)
    end

    test "inline ticket (no pointer) → the brief IS the thing to judge, embedded, no mount",
         %{tmp_dir: tmp} do
      assert {:ok, brief, "judge", mount} =
               build_scoper(%{"body" => "brief inline à juger"}, ops_root: tmp)

      assert is_nil(mount)
      assert brief =~ "brief inline à juger"
      refute brief =~ "~/issues/brief.md"
    end
  end
end
