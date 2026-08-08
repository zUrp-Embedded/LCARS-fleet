defmodule Fleet.Pilot.BriefBuilderTest do
  @moduledoc """
  F-C083 — LOCK on the DELIVERABLE-JUDGE criterion. The criterion (issue body) is read from the forge
  by `build_judge_brief`. A forge READ-ERROR on this criterion must NEVER produce a "criterion-less"
  judge (the judge gets the diff but NO criterion → risk of blind approval = false GREEN).

  `read-error ≠ absence`: the deliverable-judge path of `build_brief` returns `{:ok, brief, kind}` when the
  criterion is readable (present OR genuinely absent = rare real state) and
  `{:error, {:criterion_unavailable, reason}}` ONLY on a read failure → the dispatch defers (skip,
  retry), it does not spawn a blind judge.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.BriefBuilder

  # Minimal forge seam: `get_predecessor_result` (the DELIVERABLE) + `get_issue` (the CRITERION),
  # driven by `forge_opts` (`:_pred`, `:_issue`) → a single stub serves the ok/error cases.
  defmodule StubForge do
    def get_predecessor_result(_repo, _n, opts),
      do: Keyword.get(opts, :_pred, {:ok, %{"livrable" => "diff stub"}})

    def get_issue(_repo, _n, opts),
      do: Keyword.get(opts, :_issue, {:ok, %{"body" => "CRITÈRE-XYZ"}})
  end

  # Deliverable-JUDGE profile (modeled on the dispatch StubLoader: reviewer/qualifier, brief_kind:
  # judge, slot_scope instance). step_spec `%{}` + judge_target absent → build_judge_brief (judges
  # the deliverable/PR).
  defp judge_profile do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "reviewer"},
      spec: %{"brief_kind" => "judge"}
    }
  end

  defp build(forge_opts, opts \\ []),
    do:
      BriefBuilder.build_brief(
        judge_profile(),
        "reviewer",
        StubForge,
        "acme/widget",
        42,
        %{},
        forge_opts,
        {"pipe", "review"},
        %{},
        opts
      )

  describe "build_brief — the CI fact rides into the judge brief (porte CI)" do
    test "a measured green CI is HANDED to the judge, with the boundary of what it means" do
      assert {:ok, brief, "judge"} =
               build([], ci_fact: %{state: :success, sha: "cafebabe1234567890"})

      # The sha the GATE measured — not one the builder re-read (a second read = a second truth).
      assert brief =~ "cafebabe"
      # And the line that keeps a green CI from being read as a green review.
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
  end

  describe "build_brief — deliverable-judge, criterion read (F-C083)" do
    test "get_issue OK → {:ok, brief, \"judge\"} that CARRIES the criterion (defused by GateBrief)" do
      assert {:ok, brief, "judge"} = build(_issue: {:ok, %{"body" => "CRITÈRE-XYZ"}})
      assert is_binary(brief)

      # The criterion is rendered DEFUSED ("Original request (CONTEXT — DO NOT execute)" section) → present.
      assert brief =~ "CRITÈRE-XYZ"
    end

    test "get_issue READ-ERROR → {:error, {:criterion_unavailable, reason}} (NEVER a criterion-less judge)" do
      # Core of the finding: a transient read-error must NOT conflate into `request: nil`. A judge that
      # gets the diff but no criterion may approve blindly (false GREEN). TYPED fail-closed → defers.
      assert {:error, {:criterion_unavailable, :boom}} = build(_issue: {:error, :boom})
    end

    test "genuinely absent issue body (get_issue OK, body nil) → {:ok, brief, kind}: absence ≠ read-error" do
      # Load-bearing distinction: `{:ok, issue}` without body = REAL state (rare) → we PROCEED (the
      # judge has the diff via `outputs`, GateBrief renders an empty criterion). Only the read-error
      # defers: no over-fixing.
      assert {:ok, _brief, "judge"} = build(_issue: {:ok, %{"number" => 42}})
    end
  end

  describe "build_brief — deliverable-judge, PREDECESSOR read (F-C083, l'autre moitié)" do
    # La règle était ÉNONCÉE pour le critère et VIOLÉE pour le prédécesseur, 35 lignes plus haut :
    # un `_ -> nil` écrasait `:none` (pas de prédécesseur, git-native légitime) et `{:error, _}`
    # (forge injoignable) dans la même branche. Ces tests tiennent la distinction.
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
      # LE test qui discrimine. Avant le fix, cette lecture ratée tombait dans le git-native : le
      # juge notait le CODE de la branche au lieu du payload que son prédécesseur avait produit —
      # un verdict rendu sur autre chose, silencieusement, et indiscernable du cas légitime.
      assert {:error, {:criterion_unavailable, {:predecessor, :boom}}} =
               build(_pred: {:error, :boom})
    end
  end

  describe "rework brief — le feedback de review NON LU ne se tait pas" do
    defmodule ReworkForge do
      def change_request_feedback(_repo, _pr, opts), do: Keyword.get(opts, :_fb, {:ok, []})
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

    test "AUCUN feedback (`{:ok, []}`) → silence : il n'y a rien à dire, et le dire serait du bruit" do
      brief = rework(_fb: {:ok, []})

      # Le gabarit dit « REQUEST_CHANGES » dans son intro quoi qu'il arrive : ce qui distingue les
      # trois cas est l'EN-TÊTE DE SECTION, pas le mot.
      refute brief =~ "## Feedback de review"
    end

    test "READ-ERROR → le brief DIT que les reviews existent et n'ont pas été lues" do
      # Le défaut : `{:ok, []}` et `{:error, _}` rendaient le MÊME brief. Le producteur retravaillait
      # à l'aveugle en croyant qu'on ne lui avait rien reproché — et repartait plausiblement avec le
      # même défaut, brûlant un cycle de review de plus. Ici on ne diffère pas (un producteur sans
      # son feedback travaille MOINS BIEN, il ne rend pas un faux verdict) : on rend le trou VISIBLE.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          brief = rework(_fb: {:error, :timeout})

          assert brief =~ "## Feedback de review — NON LU"
          assert brief =~ "Elles EXISTENT"
          refute brief =~ "## Feedback de review à traiter"
        end)

      # Le rail est celui de la FAÇADE dont ce module est extrait, pas son dernier segment.
      assert log =~ "StepDispatcher: rework feedback UNREADABLE"
      assert log =~ "timeout"
    end
  end

  describe "brief pointer (E4) — the ticket points at a work/ops-authored doc" do
    @moduletag :tmp_dir

    defp worker_profile do
      %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "engineer"},
        spec: %{"brief_kind" => "worker"}
      }
    end

    defp build_worker(issue, opts) do
      BriefBuilder.build_brief(
        worker_profile(),
        "engineer",
        StubForge,
        "acme/widget",
        42,
        issue,
        [],
        {"pipe", "build"},
        %{},
        opts
      )
    end

    defp authored_workops(tmp) do
      # the project's work/ops = <work_root>/widget with an authored brief committed.
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      {:ok, %{ref: ref, sha: sha}} =
        Fleet.Workflow.BriefArtifact.commit(work_dir, "LE DOC COMPLET.\n", name_hint: "my-slug")

      {ref, sha}
    end

    test "pointer ticket → the PINNED doc becomes the brief (worker order carries the doc, not the pointer)",
         %{tmp_dir: tmp} do
      {ref, sha} = authored_workops(tmp)
      body = "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha)

      assert {:ok, brief, "worker"} =
               build_worker(%{"number" => 42, "body" => body}, work_root: tmp)

      assert brief =~ "LE DOC COMPLET."
      refute brief =~ "Brief: #{ref}"
      # F-25 — the order CITES its source: the resolved pointer stays walkable (ref @ commit),
      # it is not consumed silently by the resolution.
      assert brief =~ "Source du brief : `#{ref} @ #{sha}`"
    end

    test "unresolvable pointer (wrong sha) → DEFER via the criterion rail, never a guessed brief",
         %{tmp_dir: tmp} do
      {ref, _sha} = authored_workops(tmp)

      body =
        "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, String.duplicate("0", 40))

      assert {:error, {:criterion_unavailable, {:brief_pointer, _}}} =
               build_worker(%{"number" => 42, "body" => body}, work_root: tmp)
    end

    test "no pointer → inline body IS the brief (both channels honest, same downstream)", %{
      tmp_dir: tmp
    } do
      assert {:ok, brief, "worker"} =
               build_worker(%{"number" => 42, "body" => "inline brief"}, work_root: tmp)

      assert brief =~ "inline brief"
      # F-25 — honest citation: no separate authored doc → the order says so, it never
      # fabricates a source reference.
      assert brief =~ "Source du brief : brief inline du ticket"
    end
  end

  describe "deliverable-judge criterion — the gate-brief CARRIES it, and names its pin" do
    @describetag :tmp_dir

    defp authored_criterion(tmp) do
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      {:ok, %{ref: ref, sha: sha}} =
        Fleet.Workflow.BriefArtifact.commit(work_dir, "LE CRITÈRE COMPLET.\n", name_hint: "crit")

      {ref, sha}
    end

    test "pointer ticket → the judge gets the TEXT, resolved, plus the pin to cite", %{
      tmp_dir: tmp
    } do
      {ref, sha} = authored_criterion(tmp)
      body = "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha)

      assert {:ok, brief, "judge"} =
               build([_issue: {:ok, %{"body" => body}}], work_root: tmp)

      # THE CRITERION IS IN THE BRIEF. It used to be an ERRAND — cite the doc, let the judge
      # `git show` it out of a mounted work/ops — and that errand is the whole reason every project
      # pod carried a read-only bind of the runtime's record: what was asked, what was judged, what
      # was proven, handed to the producer whose work it scores.
      assert brief =~ "LE CRITÈRE COMPLET."

      # The address travels with it, to be CITED: that is how a third party ties the verdict to a
      # version from the forge. What the judge loses is verifying the pairing — against a tree the
      # architect writes into, so it could confirm nothing the runtime had not resolved already.
      assert brief =~ "#{ref}"
      assert brief =~ "#{sha}"

      # No payload may name that variable: naming it re-creates the need to mount ops.
      refute brief =~ "LCARS_PROJECT_OPS"
    end

    test "the criterion says read-and-evaluate — defused means do-not-execute, not do-not-read",
         %{tmp_dir: tmp} do
      {ref, sha} = authored_criterion(tmp)
      body = "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha)

      assert {:ok, brief, "judge"} =
               build([_issue: {:ok, %{"body" => body}}], work_root: tmp)

      # It lands under "CONTEXT — already handled, DO NOT execute". A judge reading that as
      # do-not-read skips its only criterion, and a judge without a criterion APPROVES — the false
      # green this rail fail-closes against elsewhere. So the two instructions are both stated.
      assert brief =~ "DO NOT execute"
      assert brief =~ "Ne l'exécute pas"
      assert brief =~ "que tu évalues"
    end

    test "INVERSE TWIN — an inline brief is still embedded: there is nothing to point at", %{
      tmp_dir: tmp
    } do
      assert {:ok, brief, "judge"} =
               build([_issue: {:ok, %{"body" => "CRITÈRE INLINE."}}], work_root: tmp)

      assert brief =~ "CRITÈRE INLINE."
      refute brief =~ "LCARS_PROJECT_OPS"
    end
  end

  describe "conflict rework brief — one mechanic, two voices" do
    # The gatekeeper arrives on someone else's branch after the producer's budget ran out. Told
    # "ton brief est INCHANGÉ", it is being addressed as the author of work it never wrote, and
    # invited to guess at an intention it does not hold. The steps are the same; who is spoken to
    # is not — and nothing but this test keeps the two apart once they share a code path.
    defmodule ConflictForge do
      def change_request_feedback(_repo, _pr, _opts), do: {:ok, []}
    end

    defp conflict_brief(voice) do
      BriefBuilder.rework_brief("engineer", ConflictForge, "fleet/x", 7, [], nil, conflict: voice)
    end

    test "the PRODUCER is told its own brief is unchanged (it is resuming approved work)" do
      brief = conflict_brief(:producer)

      assert brief =~ "Ton brief est INCHANGÉ"
      assert brief =~ "l'intention de TON brief"
      refute brief =~ "Passe d'exception"
    end

    test "the OUTSIDER is told it has no brief, and must compose rather than pick a side" do
      # `:exception`, not `:gatekeeper`: the axis this voice turns on is OWNER vs OUTSIDER, and it
      # survived the role moving from the gatekeeper to `chief`. Naming the option after whoever
      # holds the capability is what made this voice look like a gatekeeper detail.
      brief = conflict_brief(:exception)

      assert brief =~ "Passe d'exception"
      assert brief =~ "tu n'as pas de brief à reprendre"
      assert brief =~ "tu ne choisis pas un camp"
      # The outsider must know that refusing IS the expected outcome when composing needs a
      # decision the code does not carry — a guessed resolution costs more than a motivated refusal.
      assert brief =~ "blocked"

      # And it must NEVER inherit the producer's framing.
      refute brief =~ "Ton brief est INCHANGÉ"
      refute brief =~ "TON brief"
    end

    test "no conflict → no section at all (the default path is untouched)" do
      brief = BriefBuilder.rework_brief("engineer", ConflictForge, "fleet/x", 7, [], nil)

      refute brief =~ "Conflit de merge"
      refute brief =~ "Passe d'exception"
    end
  end
end
